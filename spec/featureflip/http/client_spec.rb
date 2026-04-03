require "spec_helper"

RSpec.describe Featureflip::Http::Client do
  let(:sdk_key) { "sdk-test-key-123" }
  let(:config) { Featureflip::Config.new(sdk_key: sdk_key, base_url: "https://eval.featureflip.io") }
  let(:client) { described_class.new(sdk_key, config) }

  let(:flags_response) do
    {
      "flags" => [
        {
          "key" => "dark-mode",
          "version" => 3,
          "type" => "Boolean",
          "enabled" => true,
          "variations" => [
            { "key" => "true", "value" => true },
            { "key" => "false", "value" => false }
          ],
          "rules" => [
            {
              "id" => "rule-1",
              "priority" => 1,
              "conditionGroups" => [
                {
                  "operator" => "And",
                  "conditions" => [
                    { "attribute" => "country", "operator" => "Equals", "values" => ["US"], "negate" => false }
                  ]
                }
              ],
              "serve" => { "type" => "Fixed", "variation" => "true" }
            }
          ],
          "fallthrough" => {
            "type" => "Rollout",
            "bucketBy" => "user_id",
            "salt" => "abc",
            "variations" => [
              { "key" => "true", "weight" => 50 },
              { "key" => "false", "weight" => 50 }
            ]
          },
          "offVariation" => "false"
        }
      ],
      "segments" => [
        {
          "key" => "beta-users",
          "version" => 1,
          "conditions" => [
            { "attribute" => "email", "operator" => "EndsWith", "values" => ["@beta.com"] }
          ],
          "conditionLogic" => "And"
        }
      ]
    }
  end

  describe "#get_flags" do
    before do
      stub_request(:get, "https://eval.featureflip.io/v1/sdk/flags")
        .to_return(status: 200, body: flags_response.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "fetches and parses flags and segments" do
      flags, segments = client.get_flags

      expect(flags.length).to eq(1)
      flag = flags.first
      expect(flag.key).to eq("dark-mode")
      expect(flag.version).to eq(3)
      expect(flag.type).to eq("Boolean")
      expect(flag.enabled).to be true
      expect(flag.variations.length).to eq(2)
      expect(flag.variations.first.key).to eq("true")
      expect(flag.variations.first.value).to eq(true)

      # Rules
      expect(flag.rules.length).to eq(1)
      rule = flag.rules.first
      expect(rule.id).to eq("rule-1")
      expect(rule.condition_groups.length).to eq(1)
      group = rule.condition_groups.first
      expect(group.operator).to eq("And")
      expect(group.conditions.first.attribute).to eq("country")
      expect(group.conditions.first.operator).to eq("Equals")

      # Fallthrough rollout
      expect(flag.fallthrough.type).to eq("Rollout")
      expect(flag.fallthrough.bucket_by).to eq("user_id")
      expect(flag.fallthrough.variations.length).to eq(2)

      # Segments
      expect(segments.length).to eq(1)
      expect(segments.first.key).to eq("beta-users")
      expect(segments.first.conditions.first.attribute).to eq("email")
    end

    it "sends Authorization header" do
      client.get_flags

      expect(WebMock).to have_requested(:get, "https://eval.featureflip.io/v1/sdk/flags")
        .with(headers: { "Authorization" => sdk_key })
    end
  end

  describe "#get_flags error handling" do
    it "raises Featureflip::Error on HTTP 500 after retry" do
      stub_request(:get, "https://eval.featureflip.io/v1/sdk/flags")
        .to_return(status: 500, body: "Internal Server Error")
        .then.to_return(status: 500, body: "Internal Server Error")

      expect { client.get_flags }.to raise_error(Featureflip::Error, /HTTP 500/)
      expect(WebMock).to have_requested(:get, "https://eval.featureflip.io/v1/sdk/flags").times(2)
    end

    it "retries on 5xx and succeeds" do
      stub_request(:get, "https://eval.featureflip.io/v1/sdk/flags")
        .to_return(status: 503, body: "Service Unavailable")
        .then.to_return(status: 200, body: flags_response.to_json, headers: { "Content-Type" => "application/json" })

      flags, segments = client.get_flags
      expect(flags.length).to eq(1)
      expect(WebMock).to have_requested(:get, "https://eval.featureflip.io/v1/sdk/flags").times(2)
    end
  end

  describe "#get_flag" do
    it "fetches and parses a single flag" do
      flag_data = flags_response["flags"].first
      stub_request(:get, "https://eval.featureflip.io/v1/sdk/flags/dark-mode")
        .to_return(status: 200, body: flag_data.to_json, headers: { "Content-Type" => "application/json" })

      flag = client.get_flag("dark-mode")

      expect(flag.key).to eq("dark-mode")
      expect(flag.version).to eq(3)
      expect(flag.enabled).to be true
    end
  end

  describe "#post_events" do
    it "posts events to API" do
      stub_request(:post, "https://eval.featureflip.io/v1/sdk/events")
        .to_return(status: 200, body: "{}")

      events = [{ type: "Evaluation", flag_key: "dark-mode", value: true }]
      client.post_events(events)

      expect(WebMock).to have_requested(:post, "https://eval.featureflip.io/v1/sdk/events")
        .with(
          body: { events: events }.to_json,
          headers: { "Authorization" => sdk_key, "Content-Type" => "application/json" }
        )
    end
  end
end
