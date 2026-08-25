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

  describe "#parse_flags_response" do
    it "parses a snapshot hash into flag and segment models (no HTTP)" do
      flags, segments = client.parse_flags_response(flags_response)

      expect(flags.map(&:key)).to eq(["dark-mode"])
      expect(flags.first.version).to eq(3)
      expect(segments.map(&:key)).to eq(["beta-users"])
    end

    it "tolerates a snapshot with no flags or segments" do
      flags, segments = client.parse_flags_response({})
      expect(flags).to eq([])
      expect(segments).to eq([])
    end
  end

  describe "#get_flags error handling" do
    it "raises Featureflip::Error on HTTP 500 without an inner retry" do
      stub_request(:get, "https://eval.featureflip.io/v1/sdk/flags")
        .to_return(status: 500, body: "Internal Server Error")

      expect { client.get_flags }.to raise_error(Featureflip::Error, /HTTP 500/)
      expect(WebMock).to have_requested(:get, "https://eval.featureflip.io/v1/sdk/flags").times(1)
    end

    # The poller re-fetches every poll_interval and the streaming source reconnects with
    # backoff, so an inner retry here buys nothing and doubles request volume against a
    # dependency that is already failing. It also blocked for a second inside the
    # init_timeout budget on cold start. eval-api now answers 503 (not 401) when it cannot
    # reach the Management API, which is precisely the status that used to trip it.
    it "does not double-request a 503" do
      stub_request(:get, "https://eval.featureflip.io/v1/sdk/flags")
        .to_return(status: 503, body: "Service Unavailable")

      expect { client.get_flags }.to raise_error(Featureflip::Error, /HTTP 503/)
      expect(WebMock).to have_requested(:get, "https://eval.featureflip.io/v1/sdk/flags").times(1)
    end
  end

  describe "#post_events error handling" do
    # Events are the one caller that retries inline. EventProcessor#flush drains the queue
    # before sending, so a batch only survives a failure because the processor puts it back
    # (#2456) — this absorbs the common transient blip before that machinery is needed,
    # and the processor's backoff gate is measured from the moment it gives up. It stays.
    it "retries a 5xx once, so a transient blip never reaches the re-queue path" do
      stub_request(:post, "https://eval.featureflip.io/v1/sdk/events")
        .to_return(status: 503, body: "Service Unavailable")
        .then.to_return(status: 202, body: "")

      client.post_events([{ "key" => "dark-mode" }])

      expect(WebMock).to have_requested(:post, "https://eval.featureflip.io/v1/sdk/events").times(2)
    end

    it "gives up after the single retry" do
      stub_request(:post, "https://eval.featureflip.io/v1/sdk/events")
        .to_return(status: 503, body: "Service Unavailable")

      expect { client.post_events([{ "key" => "dark-mode" }]) }.to raise_error(Featureflip::Error, /HTTP 503/)
      expect(WebMock).to have_requested(:post, "https://eval.featureflip.io/v1/sdk/events").times(2)
    end

    # EventProcessor branches on the status to decide whether a failed batch is worth
    # keeping, so the status has to survive as data rather than only as message text.
    it "raises an error carrying the status" do
      allow(client).to receive(:sleep) # the inline retry back-off
      stub_request(:post, "https://eval.featureflip.io/v1/sdk/events")
        .to_return(status: 503, body: "Service Unavailable")

      expect { client.post_events([{ "key" => "dark-mode" }]) }
        .to raise_error(Featureflip::HttpStatusError) { |e| expect(e.status).to eq(503) }
    end

    it "raises a status-carrying error for a 4xx too" do
      stub_request(:post, "https://eval.featureflip.io/v1/sdk/events")
        .to_return(status: 401, body: "Unauthorized")

      expect { client.post_events([{ "key" => "dark-mode" }]) }
        .to raise_error(Featureflip::HttpStatusError) { |e| expect(e.status).to eq(401) }
      expect(WebMock).to have_requested(:post, "https://eval.featureflip.io/v1/sdk/events").times(1)
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

  describe "prerequisite parsing" do
    let(:flag_with_prereqs) do
      {
        "flags" => [
          {
            "key" => "dependent-flag",
            "version" => 1,
            "type" => "Boolean",
            "enabled" => true,
            "variations" => [
              { "key" => "on", "value" => true },
              { "key" => "off", "value" => false }
            ],
            "rules" => [],
            "fallthrough" => { "type" => "Fixed", "variation" => "on" },
            "offVariation" => "off",
            "prerequisites" => [
              { "prerequisiteFlagKey" => "parent-a", "expectedVariationKey" => "on" },
              { "prerequisiteFlagKey" => "parent-b", "expectedVariationKey" => "blue" }
            ]
          }
        ],
        "segments" => []
      }
    end

    it "parses prerequisites from the wire format" do
      stub_request(:get, "https://eval.featureflip.io/v1/sdk/flags")
        .to_return(status: 200, body: flag_with_prereqs.to_json, headers: { "Content-Type" => "application/json" })

      flags, _segments = client.get_flags
      flag = flags.first

      expect(flag.prerequisites.length).to eq(2)
      expect(flag.prerequisites[0].prerequisite_flag_key).to eq("parent-a")
      expect(flag.prerequisites[0].expected_variation_key).to eq("on")
      expect(flag.prerequisites[1].prerequisite_flag_key).to eq("parent-b")
      expect(flag.prerequisites[1].expected_variation_key).to eq("blue")
    end

    it "defaults prerequisites to an empty list when absent" do
      response_without_prereqs = {
        "flags" => [flag_with_prereqs["flags"].first.reject { |k, _| k == "prerequisites" }],
        "segments" => []
      }
      stub_request(:get, "https://eval.featureflip.io/v1/sdk/flags")
        .to_return(status: 200, body: response_without_prereqs.to_json, headers: { "Content-Type" => "application/json" })

      flags, _segments = client.get_flags
      expect(flags.first.prerequisites).to eq([])
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
