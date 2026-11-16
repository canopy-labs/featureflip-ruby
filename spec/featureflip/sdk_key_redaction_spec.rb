require "spec_helper"
require "stringio"
require "logger"

# The SDK key is a credential: it must never reach a log sink or an exception message
# the SDK raises (#5152, #5166). The stub transport errors embed the key the way a
# third-party HTTP stack quoting the Authorization header would, so these prove the
# redactor and not just clean call sites.
RSpec.describe "SDK key redaction" do
  let(:key) { "sdk_server_SentinelKeyMustNeverAppearInLogs-0123456789" }
  let(:io) { StringIO.new }
  let(:logger) { Logger.new(io, level: Logger::DEBUG) }
  let(:flags_body) do
    JSON.generate(
      "flags" => [{
        "key" => "greeting", "version" => 1, "type" => "String", "enabled" => true,
        "variations" => [{ "key" => "a", "value" => "hello" }],
        "rules" => [], "fallthrough" => { "type" => "Fixed", "variation" => "a" },
        "offVariation" => "a"
      }],
      "segments" => []
    )
  end
  let(:leaky_error) { IOError.new("connection failed; request headers: Authorization: #{key}") }
  let(:raised) { [] }

  before do
    allow_any_instance_of(Featureflip::Http::Client).to receive(:sleep)
  end

  def config(**overrides)
    Featureflip::Config.new(
      streaming: false, send_events: true, poll_interval: 9999, flush_interval: 9999,
      init_timeout: 5, logger: logger, **overrides
    )
  end

  def capture
    yield
  rescue Exception => e # rubocop:disable Lint/RescueException
    raised << e
    nil
  end

  def stub_flags(status: 200)
    stub_request(:get, /\/v1\/sdk\/flags/)
      .to_return(status: status, body: status == 200 ? flags_body : "", headers: { "Content-Type" => "application/json" })
  end

  def expect_clean
    expect(io.string).not_to include(key)
    raised.each do |e|
      expect(e.message).not_to include(key)
      expect(e.cause&.message.to_s).not_to include(key)
    end
  end

  it "stays clean through init, evaluate, events, a second get and close" do
    stub_flags
    stub_request(:post, /\/v1\/sdk\/events/).to_raise(leaky_error)

    client = Featureflip::Client.get(key, config: config)
    capture { Featureflip::Client.get(key, config: config(poll_interval: 60)).close }
    capture { client.string_variation("greeting", { user_id: "u1" }, "d") }
    capture { client.bool_variation("greeting", { user_id: "u1" }, false) } # type mismatch
    capture { client.string_variation("does-not-exist", { user_id: "u1" }, "d") }
    capture { client.track("click", { user_id: "u1" }, { "n" => 1 }) }
    capture { client.identify({ user_id: "u1" }) }
    capture { client.flush }
    capture { client.close }

    expect(io.string).to include("core shut down")
    expect(io.string).to include("[redacted]") # the events failure quoted the key
    expect_clean
  end

  it "redacts the key from a transport error raised during init" do
    stub_request(:get, /\/v1\/sdk\/flags/).to_raise(leaky_error)

    capture { Featureflip::Client.get(key, config: config) }

    expect(raised.length).to eq(1)
    expect(raised.first).to be_a(Featureflip::InitializationError)
    expect(raised.first.message).to include("[redacted]")
    expect_clean
  end

  it "redacts the key from a transport error when no logger is configured" do
    stub_request(:get, /\/v1\/sdk\/flags/).to_raise(leaky_error)
    cfg = config
    cfg.logger = nil

    capture { Featureflip::Client.get(key, config: cfg) }

    err = raised.first
    expect(err).to be_a(Featureflip::InitializationError)
    expect(err.message).to include("IOError")
    expect(err.cause).to be_a(RuntimeError)
    expect(err.cause.message).to include("IOError")
    expect(err.cause.backtrace.join).not_to include(key)
    expect_clean
  end

  it "stays clean when the stream handler errors with a message quoting the key" do
    stub_flags
    stub_request(:get, /\/v1\/sdk\/stream/).to_return(
      status: 200, headers: { "Content-Type" => "text/event-stream" },
      body: "event: flag.updated\ndata: {\"key\":\"greeting\"}\n\n"
    )
    # The delta fetch fails with an error quoting the key; the stream handler logs it.
    stub_request(:get, /\/v1\/sdk\/flags\/greeting/).to_raise(StandardError.new("boom Authorization: #{key}"))

    client = Featureflip::Client.get(key, config: config(streaming: true, send_events: false))
    deadline = Time.now + 5
    sleep 0.05 until io.string.include?("[redacted]") || Time.now > deadline
    client.close

    expect(io.string).to include("[redacted]")
    expect_clean
  end

  it "redacts the key from a non-IO transport error raised during init" do
    stub_request(:get, /\/v1\/sdk\/flags/).to_raise(StandardError.new("boom Authorization: #{key}"))

    capture { Featureflip::Client.get(key, config: config) }

    expect(raised.first).to be_a(Featureflip::InitializationError)
    expect_clean
  end

  it "stays clean when the SDK rejects the key (401) or the API fails (500)" do
    [401, 500].each do |status|
      stub_flags(status: status)
      capture { Featureflip::Client.get(key, config: config) }
    end

    expect(raised.length).to eq(2)
    expect_clean
  end

  it "redacts the key from a snapshot-fallback reason" do
    stub_request(:get, /\/v1\/sdk\/flags/).to_raise(StandardError.new("boom Authorization: #{key}"))
    store = Class.new do
      def get = nil
      def put(_text) = nil
    end.new

    capture { Featureflip::Client.get(key, config: config(snapshot_store: store)).close }

    expect(io.string).to include("[redacted]")
    expect_clean
  end

  it "does not touch the caller's logger or config" do
    stub_flags
    cfg = config
    client = Featureflip::Client.get(key, config: cfg)
    expect(cfg.logger).to equal(logger)
    client.close
  end
end
