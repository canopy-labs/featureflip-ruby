require "spec_helper"
require "logger"

RSpec.describe "Client#on_update" do
  let(:sdk_key) { "sdk-on-update" }
  let(:base_url) { "https://eval.featureflip.io" }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, debug: nil, error: nil) }
  let(:config) { Featureflip::Config.new(streaming: false, send_events: false, poll_interval: 9999, logger: logger) }

  def flag_json(key, enabled: true)
    {
      "key" => key, "version" => 1, "type" => "Boolean", "enabled" => enabled,
      "variations" => [{ "key" => "true", "value" => true }, { "key" => "false", "value" => false }],
      "rules" => [], "fallthrough" => { "type" => "Fixed", "variation" => "true" }, "offVariation" => "false"
    }
  end

  def body(*flags) = { "flags" => flags, "segments" => [] }.to_json

  def stub_flags(*bodies)
    stub = stub_request(:get, "#{base_url}/v1/sdk/flags")
    bodies.each_with_index do |b, i|
      resp = { status: 200, body: b, headers: { "Content-Type" => "application/json" } }
      stub = i.zero? ? stub.to_return(resp) : stub.then.to_return(resp)
    end
    stub
  end

  def model(key, enabled: true)
    Featureflip::Models::FlagConfiguration.new(
      key: key, version: 1, type: "Boolean", enabled: enabled,
      variations: [Featureflip::Models::Variation.new(key: "true", value: true), Featureflip::Models::Variation.new(key: "false", value: false)],
      rules: [], fallthrough: Featureflip::Models::ServeConfig.new(type: "Fixed", variation: "true"), off_variation: "false"
    )
  end

  def core_of(client) = client.instance_variable_get(:@core)

  # The poller fetches immediately on start, so it would race the snapshots these
  # examples apply by hand. Stop it; the polling example below uses the real thread.
  def quiet_client
    client = Featureflip::Client.get(sdk_key, config: config)
    core_of(client).instance_variable_get(:@polling_handler)&.stop
    client
  end

  before { stub_flags(body(flag_json("a"))) }

  it "does not fire for the initial load" do
    received = []
    client = quiet_client
    client.on_update { |keys| received << keys }
    core_of(client).send(:apply_snapshot, [model("a")], [])
    expect(received).to eq([])
  end

  it "fires once with the changed keys for a later snapshot" do
    received = []
    client = quiet_client
    client.on_update { |keys| received << keys }
    core_of(client).send(:apply_snapshot, [model("a", enabled: false), model("b")], [])
    expect(received).to eq([%w[a b]])
  end

  it "fires for an SSE upsert and delete, and not for an identical redelivery" do
    received = []
    client = quiet_client
    client.on_update(->(keys) { received << keys })
    core = core_of(client)
    core.send(:apply_flag_update, model("a"))
    core.send(:apply_flag_update, model("a", enabled: false))
    core.send(:apply_flag_delete, "a")
    expect(received).to eq([["a"], ["a"]])
  end

  it "isolates a raising listener and logs it" do
    received = []
    client = quiet_client
    client.on_update { |_keys| raise "boom" }
    client.on_update { |keys| received << keys }
    core_of(client).send(:apply_snapshot, [model("a", enabled: false)], [])
    expect(received).to eq([["a"]])
    expect(logger).to have_received(:warn).with(/flag update listener raised RuntimeError: boom/)
  end

  it "gives each listener its own copy of the keys" do
    seen = []
    client = quiet_client
    client.on_update { |keys| keys.clear }
    client.on_update { |keys| seen << keys }
    core_of(client).send(:apply_snapshot, [model("a", enabled: false)], [])
    expect(seen).to eq([["a"]])
  end

  it "stops firing after unsubscribe, and unsubscribing twice is harmless" do
    received = []
    client = quiet_client
    unsubscribe = client.on_update { |keys| received << keys }
    unsubscribe.call
    unsubscribe.call
    core_of(client).send(:apply_snapshot, [model("a", enabled: false)], [])
    expect(received).to eq([])
  end

  it "lets a listener unsubscribe itself from inside its callback" do
    received = []
    client = quiet_client
    unsubscribe = nil
    unsubscribe = client.on_update { |keys| received << keys; unsubscribe.call }
    core = core_of(client)
    core.send(:apply_snapshot, [model("a", enabled: false)], [])
    core.send(:apply_snapshot, [model("a")], [])
    expect(received).to eq([["a"]])
  end

  it "drops only the closing handle's listeners when two handles share a core" do
    a_received = []
    b_received = []
    handle_a = quiet_client
    handle_b = quiet_client
    expect(core_of(handle_a)).to equal(core_of(handle_b))
    handle_a.on_update { |keys| a_received << keys }
    handle_b.on_update { |keys| b_received << keys }
    handle_a.close
    core_of(handle_b).send(:apply_snapshot, [model("a", enabled: false)], [])
    expect(a_received).to eq([])
    expect(b_received).to eq([["a"]])
  end

  it "returns a no-op unsubscribe on a closed handle without registering" do
    client = quiet_client
    keep_core_alive = quiet_client
    client.close
    received = []
    unsubscribe = client.on_update { |keys| received << keys }
    expect { unsubscribe.call }.not_to raise_error
    core_of(keep_core_alive).send(:apply_snapshot, [model("a", enabled: false)], [])
    expect(received).to eq([])
  end

  it "accepts a subscription on a for_testing client that never fires" do
    client = Featureflip::Client.for_testing("a" => true)
    unsubscribe = client.on_update { |_keys| raise "must not fire" }
    expect { unsubscribe.call }.not_to raise_error
  end

  it "rejects a missing listener, a non-callable, and both a listener and a block" do
    client = quiet_client
    expect { client.on_update }.to raise_error(ArgumentError, /listener or a block/)
    expect { client.on_update(42) }.to raise_error(ArgumentError, /respond to #call/)
    expect { client.on_update(->(_k) {}) { |_k| } }.to raise_error(ArgumentError, /not both/)
  end

  it "fires from the real polling thread for a changed poll, not for an identical one" do
    WebMock.reset!
    # initial fetch; the poller's immediate first tick (identical); then a change
    stub_flags(body(flag_json("a")), body(flag_json("a")), body(flag_json("a", enabled: false)))
    received = Queue.new
    polling = Featureflip::Config.new(streaming: false, send_events: false, poll_interval: 1, logger: logger)
    client = Featureflip::Client.get(sdk_key, config: polling)
    client.on_update { |keys| received << keys }
    expect(received.pop(timeout: 5)).to eq(["a"])
    expect(received.pop(timeout: 1.5)).to be_nil
  ensure
    client&.close
  end

  it "is reachable through the Featureflip module facade" do
    Featureflip.configure do |c|
      c.sdk_key = sdk_key
      c.streaming = false
      c.send_events = false
      c.poll_interval = 9999
    end
    expect(Featureflip.on_update { |_k| }).to respond_to(:call)
  ensure
    Featureflip.close
  end
end
