# frozen_string_literal: true

require "json"
require "spec_helper"

# eventPayloadVectors — what identify() and track() actually put on the wire:
# {type, flagKey, userId?, variation?, timestamp, metadata?}.
#
# That shape had no executable spec at all, which is the direct cause of #2359 —
# a three-way payload divergence across six server SDKs (js/node/python forwarded
# the caller's attributes as +metadata+; php/go/ruby, this one included, discarded
# them) sat unnoticed indefinitely. Nothing compared an emitted event against an
# expected shape, and the receiving end reduces every event to a counter tuple,
# so no downstream assertion caught it either.
#
# Hand-authored rather than engine-generated, because the engine emits no events:
# it returns an EvaluationResult, and the payload is built a layer above that.
# See tools/golden-vectors/README.md for the full runner contract.
RSpec.describe "golden: event payload vectors" do
  EVENT_VECTORS = JSON.parse(
    File.read(File.join(__dir__, "..", "golden", "vectors.json"))
  ).fetch("eventPayloadVectors").freeze

  # An ISO-8601 instant that designates UTC. Deliberately not an equality check:
  # the precision and the zero-offset spelling differ legitimately per SDK (this
  # one emits whole seconds and a "Z"), so a literal expectation would lock in a
  # divergence rather than a contract.
  UTC_INSTANT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|\+00:00)\z/.freeze

  # The context capabilities this SDK has. A vector requiring anything outside
  # this set is skipped explicitly, so a structural gap cannot masquerade as a
  # pass. Ruby takes a plain hash, so it has both: the identity spelling is
  # observable, and a context can carry attributes with no identity at all.
  CAPABILITIES = %w[mapContext anonymousContext].freeze

  let(:base_url) { "https://eval.example.com" }

  it "has vectors to run" do
    expect(EVENT_VECTORS).not_to be_empty
  end

  it "asserts every event payload vector" do
    executed = 0

    EVENT_VECTORS.each do |v|
      next unless (v.fetch("requires", []) - CAPABILITIES).empty?

      sdk_key = "events-#{v['id']}"
      captured = []

      stub_request(:get, "#{base_url}/v1/sdk/flags")
        .to_return(
          status: 200,
          body: JSON.generate(
            environment: "test", version: 1,
            flags: v.fetch("flags", []), segments: v.fetch("segments", [])
          ),
          headers: { "Content-Type" => "application/json" }
        )

      # Capture the SERIALIZED request body. Reading the queued hash instead
      # would defeat the purpose: omission is a serialization-time property
      # across the fleet, and an absent optional is what #2359 was about.
      stub_request(:post, "#{base_url}/v1/sdk/events")
        .to_return { |request| captured.concat(JSON.parse(request.body)["events"]); { status: 202 } }

      config = Featureflip::Config.new(
        base_url: base_url, streaming: false, send_events: true,
        poll_interval: 9999, flush_interval: 9999
      )
      client = Featureflip::Client.get(sdk_key, config: config)

      begin
        if v["kind"] == "evaluation"
          client.bool_variation(v["flagKey"], v["context"], false)
        elsif v["kind"] == "identify"
          client.identify(v["context"])
        elsif v.key?("metadata")
          client.track(v["eventKey"], v["context"], v["metadata"])
        else
          # No +metadata+ key at all -> the argument is omitted, which must put
          # the same bytes on the wire as an explicitly empty bag.
          client.track(v["eventKey"], v["context"])
        end
        client.flush
      ensure
        client.close
      end

      expect(captured.length).to eq(1), "#{v['id']}: got #{captured.length} events, want 1"
      event = captured.first

      # The EXACT field set, not a subset: #2359 was a field being present in
      # three SDKs and absent in three, which a subset assertion cannot see.
      expect(event.keys.sort).to eq((v["expect"].keys + ["timestamp"]).sort), v["id"]

      v["expect"].each do |field, expected|
        expect(event[field]).to eq(expected), "#{v['id']}: #{field}"
      end

      expect(event["timestamp"]).to match(UTC_INSTANT), v["id"]
      executed += 1
    end

    # A runner that silently skips everything is worse than no runner at all.
    expect(executed).to be >= 19
  end

  # An Error read can still carry the rule that selected the variation (here a
  # String flag read through the bool accessor); that rule did not serve the
  # traffic, so the event must not name it.
  it "omits ruleId when a rule-served value is rejected by the typed accessor" do
    captured = []
    flag = {
      "key" => "greeting", "version" => 1, "type" => "String", "enabled" => true,
      "variations" => [{ "key" => "hi", "value" => "hello" }, { "key" => "bye", "value" => "bye" }],
      "rules" => [{
        "id" => "rule-1", "priority" => 0, "segmentKey" => nil,
        "conditionGroups" => [{ "operator" => "And", "conditions" => [
          { "attribute" => "plan", "operator" => "Equals", "values" => ["pro"], "negate" => false }
        ] }],
        "serve" => { "type" => "Fixed", "variation" => "hi" }
      }],
      "fallthrough" => { "type" => "Fixed", "variation" => "bye" },
      "offVariation" => "bye", "prerequisites" => []
    }
    stub_request(:get, "#{base_url}/v1/sdk/flags")
      .to_return(status: 200, body: JSON.generate(environment: "test", version: 1, flags: [flag], segments: []),
                 headers: { "Content-Type" => "application/json" })
    stub_request(:post, "#{base_url}/v1/sdk/events")
      .to_return { |request| captured.concat(JSON.parse(request.body)["events"]); { status: 202 } }

    config = Featureflip::Config.new(
      base_url: base_url, streaming: false, send_events: true, poll_interval: 9999, flush_interval: 9999
    )
    client = Featureflip::Client.get("events-typed-error", config: config)
    begin
      expect(client.bool_variation("greeting", { "user_id" => "u", "plan" => "pro" }, false)).to eq(false)
      client.flush
    ensure
      client.close
    end

    expect(captured.length).to eq(1)
    expect(captured.first["reason"]).to eq("error")
    expect(captured.first).not_to have_key("ruleId")
  end

  # The evaluator raising degrades the read to the caller's default with reason
  # Error, and the read is still counted, as in every other server SDK.
  it "records an error event when the evaluator raises" do
    captured = []
    flag = {
      "key" => "flag", "version" => 1, "type" => "Boolean", "enabled" => true,
      "variations" => [{ "key" => "on", "value" => true }, { "key" => "off", "value" => false }],
      "rules" => [], "fallthrough" => { "type" => "Fixed", "variation" => "on" },
      "offVariation" => "off", "prerequisites" => []
    }
    stub_request(:get, "#{base_url}/v1/sdk/flags")
      .to_return(status: 200, body: JSON.generate(environment: "test", version: 1, flags: [flag], segments: []),
                 headers: { "Content-Type" => "application/json" })
    stub_request(:post, "#{base_url}/v1/sdk/events")
      .to_return { |request| captured.concat(JSON.parse(request.body)["events"]); { status: 202 } }

    config = Featureflip::Config.new(
      base_url: base_url, streaming: false, send_events: true, poll_interval: 9999, flush_interval: 9999
    )
    client = Featureflip::Client.get("events-evaluator-raises", config: config)
    begin
      allow_any_instance_of(Featureflip::Evaluation::Evaluator).to receive(:evaluate).and_raise(StandardError, "boom")
      expect(client.bool_variation("flag", { "user_id" => "u" }, false)).to eq(false)
      client.flush
    ensure
      client.close
    end

    expect(captured).to eq([{ "type" => "Evaluation", "flagKey" => "flag", "userId" => "u",
                              "timestamp" => captured.first["timestamp"], "reason" => "error" }])
  end
end
