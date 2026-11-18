# Run on its own: `bundle exec rspec spec_rails`. Loading Rails defines `Rails`, which
# changes Config's default logger, so this file stays out of the main `spec/` suite.
require "spec_helper"
require "rails"
require "featureflip/railtie"
require "stringio"

RSpec.describe Featureflip::Railtie do
  let(:sdk_key) { "test-sdk-key-for-railtie" }
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }
  let(:flags_body) do
    {
      "flags" => [{
        "key" => "dark-mode", "version" => 1, "type" => "Boolean", "enabled" => true,
        "variations" => [{ "key" => "true", "value" => true }, { "key" => "false", "value" => false }],
        "rules" => [], "fallthrough" => { "type" => "Fixed", "variation" => "true" },
        "offVariation" => "false"
      }],
      "segments" => []
    }.to_json
  end
  let(:base_options) { { streaming: false, send_events: false, poll_interval: 9999 } }

  def stub_flags(key = sdk_key)
    stub_request(:get, "https://eval.featureflip.io/v1/sdk/flags")
      .with(headers: { "Authorization" => key })
      .to_return(status: 200, body: flags_body, headers: { "Content-Type" => "application/json" })
  end

  def fake_app(options, credentials: nil)
    opts = ActiveSupport::OrderedOptions.new
    options.each { |k, v| opts[k] = v }
    config = ActiveSupport::OrderedOptions.new
    config.featureflip = opts
    creds = credentials
    Struct.new(:config, :credentials).new(config, creds)
  end

  around do |example|
    saved = ENV.delete("FEATUREFLIP_SDK_KEY")
    example.run
  ensure
    ENV["FEATUREFLIP_SDK_KEY"] = saved if saved
    Featureflip.close
  end

  before { allow(Rails).to receive(:logger).and_return(logger) }

  describe "wiring" do
    it "is a Rails::Railtie exposing config.featureflip as OrderedOptions" do
      expect(described_class.superclass).to eq(Rails::Railtie)
      expect(described_class.config.featureflip).to be_a(ActiveSupport::OrderedOptions)
    end
  end

  describe ".setup" do
    it "builds the singleton client from config.featureflip.sdk_key and exposes it" do
      stub_flags
      app = fake_app(base_options.merge(sdk_key: sdk_key))

      client = described_class.setup(app)

      expect(client).to be_a(Featureflip::Client)
      expect(app.config.featureflip_client).to equal(client)
      expect(Featureflip.default_client).to equal(client)
      expect(client.bool_variation("dark-mode", {}, false)).to be(true)
      expect(Featureflip.bool_variation("dark-mode", {}, false)).to be(true)
    end

    it "shares the SDK's cached core with Client.get for the same key" do
      stub_flags
      described_class.setup(fake_app(base_options.merge(sdk_key: sdk_key)))

      Featureflip::Client.get(sdk_key).close

      expect(WebMock).to have_requested(:get, /sdk\/flags/).once
    end

    it "falls back to FEATUREFLIP_SDK_KEY" do
      stub_flags("sdk-from-env")
      ENV["FEATUREFLIP_SDK_KEY"] = "sdk-from-env"

      client = described_class.setup(fake_app(base_options))

      expect(client.bool_variation("dark-mode", {}, false)).to be(true)
    end

    it "falls back to credentials featureflip.sdk_key" do
      stub_flags("sdk-from-credentials")
      creds = Class.new { def dig(*keys) = { featureflip: { sdk_key: "sdk-from-credentials" } }.dig(*keys) }.new

      client = described_class.setup(fake_app(base_options, credentials: creds))

      expect(client.bool_variation("dark-mode", {}, false)).to be(true)
    end

    it "prefers the configured key over the environment" do
      stub_flags
      ENV["FEATUREFLIP_SDK_KEY"] = "sdk-from-env"

      described_class.setup(fake_app(base_options.merge(sdk_key: sdk_key)))

      expect(WebMock).to have_requested(:get, /sdk\/flags/).with(headers: { "Authorization" => sdk_key })
    end

    it "passes the other options through to the client config and identifies the wrapper" do
      stub_flags
      client = described_class.setup(fake_app(base_options.merge(sdk_key: sdk_key, init_timeout: 7)))

      core_config = client.instance_variable_get(:@core).instance_variable_get(:@config)
      expect(core_config.init_timeout).to eq(7)
      expect(core_config.poll_interval).to eq(9999)
      expect(core_config.wrapper_name).to eq("featureflip-rails")
      expect(core_config.wrapper_version).to eq(Rails.version)
    end

    it "skips construction with a warning that does not carry a key when none is configured" do
      app = fake_app(base_options)

      expect(described_class.setup(app)).to be_nil

      expect(app.config.featureflip_client).to be_nil
      expect(Featureflip.default_client).to be_nil
      expect(log_io.string).to match(/WARN.*Featureflip.*no SDK key/i)
      expect(WebMock).not_to have_requested(:get, /sdk\/flags/)
    end

    it "does not log the key when construction fails" do
      stub_request(:get, /sdk\/flags/).to_return(status: 401, body: "")
      app = fake_app(base_options.merge(sdk_key: sdk_key, init_timeout: 1))

      expect { described_class.setup(app) }.to raise_error(Featureflip::Error) { |e|
        expect(e.message).not_to include(sdk_key)
      }
      expect(log_io.string).not_to include(sdk_key)
    end

    it "rejects an unknown option by name without echoing the key" do
      app = fake_app(base_options.merge(sdk_key: sdk_key, bogus: 1))

      expect { described_class.setup(app) }.to raise_error(Featureflip::ConfigurationError) { |e|
        expect(e.message).to include("bogus")
        expect(e.message).not_to include(sdk_key)
      }
    end

    it "closes the client at shutdown" do
      stub_flags
      client = described_class.setup(fake_app(base_options.merge(sdk_key: sdk_key)))

      described_class.shutdown

      expect(client.initialized?).to be(false)
      expect(Featureflip.default_client).to be_nil
    end
  end

  # Puma preload_app! / Unicorn build the client in the parent, and every worker inherits
  # both its event queue and the at_exit hook that closes it (#5778). Process.pid is
  # stubbed to play the worker.
  describe "shutdown in a forked worker" do
    let(:events_url) { "https://eval.featureflip.io/v1/sdk/events" }
    let(:event_options) { base_options.merge(sdk_key: sdk_key, send_events: true, flush_interval: 9999) }

    let(:posted_user_ids) { [] }

    before do
      stub_flags
      stub_request(:post, events_url).to_return do |request|
        posted_user_ids.concat(JSON.parse(request.body)["events"].map { |e| e["userId"] })
        { status: 202, body: "" }
      end
    end

    def become_worker
      worker_pid = Process.pid + 1
      allow(Process).to receive(:pid).and_return(worker_pid)
    end

    it "does not re-send the parent's queued events" do
      described_class.setup(fake_app(event_options))
      Featureflip.bool_variation("dark-mode", { "user_id" => "parent" }, false)
      become_worker

      described_class.shutdown

      expect(posted_user_ids).to be_empty
    end

    it "sends only the worker's own events after Featureflip.restart" do
      described_class.setup(fake_app(event_options))
      Featureflip.bool_variation("dark-mode", { "user_id" => "parent" }, false)
      become_worker

      Featureflip.restart
      Featureflip.bool_variation("dark-mode", { "user_id" => "worker" }, false)
      described_class.shutdown

      expect(posted_user_ids).to eq(["worker"])
    end

    it "still sends the parent's events from the parent" do
      described_class.setup(fake_app(event_options))
      Featureflip.bool_variation("dark-mode", { "user_id" => "parent" }, false)

      described_class.shutdown

      expect(posted_user_ids).to eq(["parent"])
    end
  end

  describe "booting a Rails application" do
    it "runs the initializer after the app's own initializers" do
      stub_flags
      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(StringIO.new)
        config.secret_key_base = "x" * 64
        config.featureflip.sdk_key = "test-sdk-key-for-railtie"
        config.featureflip.streaming = false
        config.featureflip.send_events = false
        config.featureflip.poll_interval = 9999
      end
      stub_const("RailtieSpecApp", app_class)

      app_class.initialize!

      client = app_class.instance.config.featureflip_client
      expect(client).to be_a(Featureflip::Client)
      expect(client.bool_variation("dark-mode", {}, false)).to be(true)
    end
  end
end
