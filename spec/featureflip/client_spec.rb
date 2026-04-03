require "spec_helper"

RSpec.describe Featureflip::Client do
  let(:sdk_key) { "test-sdk-key-123" }
  let(:base_url) { "https://eval.featureflip.io" }
  let(:config) do
    Featureflip::Config.new(
      streaming: false,
      send_events: false,
      poll_interval: 9999
    )
  end

  let(:bool_flag_response) do
    {
      "flags" => [
        {
          "key" => "dark-mode",
          "version" => 1,
          "type" => "Boolean",
          "enabled" => true,
          "variations" => [
            { "key" => "true", "value" => true },
            { "key" => "false", "value" => false }
          ],
          "rules" => [],
          "fallthrough" => { "type" => "Fixed", "variation" => "true" },
          "offVariation" => "false"
        },
        {
          "key" => "disabled-flag",
          "version" => 1,
          "type" => "Boolean",
          "enabled" => false,
          "variations" => [
            { "key" => "true", "value" => true },
            { "key" => "false", "value" => false }
          ],
          "rules" => [],
          "fallthrough" => { "type" => "Fixed", "variation" => "true" },
          "offVariation" => "false"
        },
        {
          "key" => "greeting",
          "version" => 1,
          "type" => "String",
          "enabled" => true,
          "variations" => [
            { "key" => "hello", "value" => "Hello, World!" },
            { "key" => "bye", "value" => "Goodbye!" }
          ],
          "rules" => [],
          "fallthrough" => { "type" => "Fixed", "variation" => "hello" },
          "offVariation" => "bye"
        }
      ],
      "segments" => []
    }.to_json
  end

  def stub_flags_request(response_body: bool_flag_response)
    stub_request(:get, "#{base_url}/v1/sdk/flags")
      .with(headers: { "Authorization" => sdk_key })
      .to_return(status: 200, body: response_body, headers: { "Content-Type" => "application/json" })
  end

  describe "#initialize" do
    it "raises ConfigurationError without SDK key" do
      expect { described_class.new(config: config) }
        .to raise_error(Featureflip::ConfigurationError, /SDK key is required/)
    end

    it "uses FEATUREFLIP_SDK_KEY env var" do
      original = ENV["FEATUREFLIP_SDK_KEY"]
      ENV["FEATUREFLIP_SDK_KEY"] = "sdk-from-env"
      stub_request(:get, "#{base_url}/v1/sdk/flags")
        .with(headers: { "Authorization" => "sdk-from-env" })
        .to_return(status: 200, body: { "flags" => [], "segments" => [] }.to_json,
                   headers: { "Content-Type" => "application/json" })

      client = described_class.new(config: config)
      expect(client.initialized?).to be true
      client.close
    ensure
      ENV["FEATUREFLIP_SDK_KEY"] = original
    end

    it "raises InitializationError on timeout" do
      stub_request(:get, "#{base_url}/v1/sdk/flags")
        .with(headers: { "Authorization" => sdk_key })
        .to_timeout

      timeout_config = Featureflip::Config.new(
        streaming: false,
        send_events: false,
        poll_interval: 9999,
        init_timeout: 1
      )

      expect { described_class.new(sdk_key: sdk_key, config: timeout_config) }
        .to raise_error(Featureflip::InitializationError)
    end
  end

  describe "with initialized client" do
    let!(:client) do
      stub_flags_request
      described_class.new(sdk_key: sdk_key, config: config)
    end

    after { client.close }

    describe "#initialized?" do
      it "returns true after successful init" do
        expect(client.initialized?).to be true
      end
    end

    describe "#bool_variation" do
      it "returns flag value for enabled flag" do
        result = client.bool_variation("dark-mode", { "user_id" => "user1" }, false)
        expect(result).to be true
      end

      it "returns default for unknown flag" do
        result = client.bool_variation("nonexistent", { "user_id" => "user1" }, false)
        expect(result).to be false
      end

      it "returns off variation for disabled flag" do
        result = client.bool_variation("disabled-flag", { "user_id" => "user1" }, true)
        expect(result).to be false
      end

      it "accepts symbol keys in context" do
        result = client.bool_variation("dark-mode", { user_id: "user1" }, false)
        expect(result).to be true
      end
    end

    describe "#string_variation" do
      it "returns string flag value" do
        result = client.string_variation("greeting", { "user_id" => "user1" }, "default")
        expect(result).to eq("Hello, World!")
      end
    end

    describe "#number_variation" do
      it "returns default for non-existent flag" do
        result = client.number_variation("missing-number", { "user_id" => "user1" }, 42)
        expect(result).to eq(42)
      end
    end

    describe "#json_variation" do
      it "returns default for non-existent flag" do
        result = client.json_variation("missing-json", { "user_id" => "user1" }, { "a" => 1 })
        expect(result).to eq({ "a" => 1 })
      end
    end

    describe "#variation_detail" do
      it "returns detail with Fallthrough reason for enabled flag" do
        detail = client.variation_detail("dark-mode", { "user_id" => "user1" }, false)
        expect(detail.value).to be true
        expect(detail.reason).to eq("Fallthrough")
        expect(detail.variation_key).to eq("true")
      end

      it "returns detail with FlagNotFound reason for missing flag" do
        detail = client.variation_detail("nonexistent", { "user_id" => "user1" }, false)
        expect(detail.value).to be false
        expect(detail.reason).to eq("FlagNotFound")
      end

      it "returns detail with FlagDisabled reason for disabled flag" do
        detail = client.variation_detail("disabled-flag", { "user_id" => "user1" }, true)
        expect(detail.value).to be false
        expect(detail.reason).to eq("FlagDisabled")
        expect(detail.variation_key).to eq("false")
      end
    end

    describe "#track" do
      it "does not raise" do
        expect { client.track("purchase", { "user_id" => "user1" }, { amount: 99 }) }.not_to raise_error
      end
    end

    describe "#identify" do
      it "does not raise" do
        expect { client.identify({ "user_id" => "user1" }) }.not_to raise_error
      end
    end
  end

  describe "event payloads" do
    let(:events_config) do
      Featureflip::Config.new(
        streaming: false,
        send_events: true,
        poll_interval: 9999
      )
    end

    let!(:client) do
      stub_flags_request
      stub_request(:post, "#{base_url}/v1/sdk/events").to_return(status: 200, body: "")
      described_class.new(sdk_key: sdk_key, config: events_config)
    end

    after { client.close }

    describe "#track" do
      it "queues event with PascalCase type and flagKey" do
        event_processor = client.instance_variable_get(:@event_processor)
        allow(event_processor).to receive(:queue_event).and_call_original

        client.track("purchase", { "user_id" => "user1" }, { "amount" => 99 })

        expect(event_processor).to have_received(:queue_event).with(
          hash_including(
            type: "Custom",
            flagKey: "purchase",
            userId: "user1"
          )
        )
      end

      it "does not include event_name or context fields" do
        event_processor = client.instance_variable_get(:@event_processor)
        allow(event_processor).to receive(:queue_event).and_call_original

        client.track("purchase", { "user_id" => "user1" })

        expect(event_processor).to have_received(:queue_event).with(
          hash_not_including(:event_name, :context)
        )
      end
    end

    describe "#identify" do
      it "queues event with PascalCase type and userId" do
        event_processor = client.instance_variable_get(:@event_processor)
        allow(event_processor).to receive(:queue_event).and_call_original

        client.identify({ "user_id" => "user1" })

        expect(event_processor).to have_received(:queue_event).with(
          hash_including(
            type: "Identify",
            userId: "user1"
          )
        )
      end

      it "includes flagKey '$identify' per SDK event contract" do
        event_processor = client.instance_variable_get(:@event_processor)
        allow(event_processor).to receive(:queue_event).and_call_original

        client.identify({ "user_id" => "user1" })

        expect(event_processor).to have_received(:queue_event).with(
          hash_including(
            flagKey: "$identify"
          )
        )
      end
    end

    describe "#variation_detail evaluation event" do
      it "queues event with PascalCase type and camelCase keys" do
        event_processor = client.instance_variable_get(:@event_processor)
        allow(event_processor).to receive(:queue_event).and_call_original

        client.variation_detail("dark-mode", { "user_id" => "user1" }, false)

        expect(event_processor).to have_received(:queue_event).with(
          hash_including(
            type: "Evaluation",
            flagKey: "dark-mode",
            userId: "user1"
          )
        )
      end

      it "does not include snake_case keys" do
        event_processor = client.instance_variable_get(:@event_processor)
        allow(event_processor).to receive(:queue_event).and_call_original

        client.variation_detail("dark-mode", { "user_id" => "user1" }, false)

        expect(event_processor).to have_received(:queue_event).with(
          hash_not_including(:flag_key, :user_id)
        )
      end
    end

    describe "#close" do
      it "can be called multiple times" do
        expect { client.close }.not_to raise_error
        expect { client.close }.not_to raise_error
      end
    end
  end

  describe ".for_testing" do
    it "creates client with fixed values and no network calls" do
      client = described_class.for_testing(
        "feature-a" => true,
        "feature-b" => "variant-x"
      )

      expect(client.initialized?).to be true
      expect(client.bool_variation("feature-a", {}, false)).to be true
      expect(client.string_variation("feature-b", {}, "default")).to eq("variant-x")
      expect(client.bool_variation("unknown", {}, false)).to be false
    end

    it "returns correct detail for test values" do
      client = described_class.for_testing("flag" => true)

      detail = client.variation_detail("flag", {}, false)
      expect(detail.value).to be true
      expect(detail.reason).to eq("Fallthrough")

      detail = client.variation_detail("missing", {}, false)
      expect(detail.value).to be false
      expect(detail.reason).to eq("FlagNotFound")
    end
  end
end
