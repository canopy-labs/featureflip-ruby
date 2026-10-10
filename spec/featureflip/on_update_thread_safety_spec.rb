require "spec_helper"
require "logger"

# Listeners run on the SDK's data-source threads, so close/restart called from a
# listener, or racing one, must not trip the stream's own shutdown machinery.
# Streaming is never enabled for real here (a real stream blocks on IO for
# read_timeout): a StreamingHandler is built but never started, and a plain
# Thread stands in for its stream thread.
RSpec.describe "on_update listeners and close/restart" do
  let(:sdk_key) { "sdk-on-update-threads" }
  let(:base_url) { "https://eval.featureflip.io" }
  let(:warnings) { [] }
  let(:logger) do
    Logger.new(nil).tap { |l| allow(l).to receive(:warn) { |m| warnings << m } }
  end
  let(:config) { Featureflip::Config.new(streaming: false, send_events: true, poll_interval: 9999, logger: logger) }

  def model(key, enabled: true)
    Featureflip::Models::FlagConfiguration.new(
      key: key, version: 1, type: "Boolean", enabled: enabled,
      variations: [Featureflip::Models::Variation.new(key: "true", value: true), Featureflip::Models::Variation.new(key: "false", value: false)],
      rules: [], fallthrough: Featureflip::Models::ServeConfig.new(type: "Fixed", variation: "true"), off_variation: "false"
    )
  end

  def core_of(client) = client.instance_variable_get(:@core)

  def stream_handler
    Featureflip::DataSource::StreamingHandler.new(
      sdk_key: "k", config: config, http_client: nil,
      on_flag_updated: ->(_) {}, on_flag_deleted: ->(_) {}, on_segment_updated: ->(_, _) {}, on_sync: ->(_, _) {},
      on_error: ->(_) {}, on_fallback_to_polling: -> {}, on_recovered: -> {}
    )
  end

  before do
    stub_request(:post, /events/).to_return(status: 200)
    stub_request(:get, "#{base_url}/v1/sdk/flags").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { "flags" => [], "segments" => [] }.to_json
    )
  end

  # Stops the real poller so it can't race the snapshots applied by hand.
  def quiet_client
    client = Featureflip::Client.get(sdk_key, config: config)
    core_of(client).instance_variable_get(:@polling_handler)&.stop
    core_of(client).instance_variable_set(:@polling_handler, nil)
    client
  end

  it "close from a listener on the stream thread stops the other components and logs no warning" do
    client = quiet_client
    core = core_of(client)
    ep = core.instance_variable_get(:@event_processor)
    ep_thread = ep.instance_variable_get(:@thread)
    sh = stream_handler
    core.instance_variable_set(:@streaming_handler, sh)
    client.on_update { |_keys| client.close }

    t = Thread.new do
      sh.instance_variable_set(:@thread, Thread.current)
      core.send(:apply_snapshot, [model("a")], [])
      core.send(:apply_snapshot, [model("a", enabled: false)], [])
      :returned
    end

    expect(t.join(5)).not_to be_nil
    expect(t.value).to eq(:returned)
    expect(core.instance_variable_get(:@event_processor)).to be_nil
    expect(ep_thread&.alive?).to be_falsey
    expect(warnings.grep(/listener raised/)).to eq([])
  end

  it "an async close while a listener runs on the stream thread stops it promptly" do
    core = Featureflip::SharedCore._create_for_testing({})
    core.instance_variable_set(:@config, config)
    sh = stream_handler
    started = Queue.new
    core._add_update_listener(->(_keys) { started << 1; sleep 0.5 })
    blocker = Queue.new
    outcome = nil
    t = Thread.new do
      begin
        core.send(:notify_update_listeners, ["a"])
        blocker.pop(timeout: 8) # stands in for read_body blocking on the next chunk
        outcome = :blocked_until_next_chunk
      rescue Featureflip::DataSource::StreamingHandler::StreamStopped
        outcome = :stream_stopped
      end
    end
    sh.instance_variable_set(:@thread, t)
    started.pop

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sh.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    expect(elapsed).to be < 3
    expect(t.alive?).to be(false)
    expect(outcome).to eq(:stream_stopped)
    expect(warnings.grep(/listener raised/)).to eq([])
  end

  it "restart from a listener on the stream thread leaves a live data source" do
    client = quiet_client
    core = core_of(client)
    sh = stream_handler
    core.instance_variable_set(:@streaming_handler, sh)
    # Restart exactly once: every restarted poller would otherwise fetch the
    # stubbed empty list, report a removal and restart again, racing the assertions.
    restarted = false
    client.on_update do |_keys|
      next if restarted

      restarted = true
      client.restart
    end

    t = Thread.new do
      sh.instance_variable_set(:@thread, Thread.current)
      core.send(:apply_snapshot, [model("a")], [])
      core.send(:apply_snapshot, [model("a", enabled: false)], [])
      :returned
    end

    expect(t.join(5)).not_to be_nil
    expect(t.value).to eq(:returned)
    expect(core.instance_variable_get(:@polling_handler)).not_to be_nil
    expect(core.instance_variable_get(:@streaming_handler)).to be_nil
    expect(warnings.grep(/listener raised/)).to eq([])
  end

  it "restart from a listener on the polling thread leaves a live data source" do
    client = quiet_client
    core = core_of(client)
    ph = Featureflip::DataSource::PollingHandler.new(
      http_client: nil, config: config, on_update: ->(_f, _s) {}, on_error: ->(_) {}
    )
    core.instance_variable_set(:@polling_handler, ph)
    # Restart exactly once: every restarted poller would otherwise fetch the
    # stubbed empty list, report a removal and restart again, racing the assertions.
    restarted = false
    client.on_update do |_keys|
      next if restarted

      restarted = true
      client.restart
    end

    t = Thread.new do
      ph.instance_variable_set(:@thread, Thread.current)
      core.send(:apply_snapshot, [model("a")], [])
      core.send(:apply_snapshot, [model("a", enabled: false)], [])
      :returned
    end

    expect(t.join(8)).not_to be_nil
    expect(t.value).to eq(:returned)
    replacement = core.instance_variable_get(:@polling_handler)
    expect(replacement).not_to be_nil
    expect(replacement).not_to equal(ph)
    expect(warnings.grep(/listener raised/)).to eq([])
  end
end
