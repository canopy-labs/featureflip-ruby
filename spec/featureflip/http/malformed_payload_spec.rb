require "spec_helper"

# Ruby stores parsed values as-is in plain Structs and the evaluator compares them
# against string literals, so a payload that violates the wire contract used to be
# accepted silently and then mis-evaluate forever.
#
# The concrete case (#2285): the evaluation API briefly served enums as integers over
# SSE while serving them as strings over REST (#2279). `data["conditionLogic"] || "And"`
# does NOT rescue that — 0 is truthy in Ruby — so the store ended up holding
# `condition_logic = 0`, which matches neither "And" nor the else-branch's intent, and
# every segment with conditions silently stopped matching anyone.
#
# The rule (see packages/CLAUDE.md): a payload that violates the contract is rejected
# WHOLESALE, never partially applied. But that applies to TYPE violations only —
# an unknown enum *string* is how a newer server introduces a new operator, and must
# still be tolerated or this SDK breaks the moment the server adds one.
RSpec.describe "malformed config payloads" do
  let(:sdk_key) { "sdk-test-key-123" }
  let(:config) { Featureflip::Config.new(sdk_key: sdk_key, base_url: "https://eval.featureflip.io") }
  let(:client) { Featureflip::Http::Client.new(sdk_key, config) }

  def segment_payload(condition_logic:, operator:)
    {
      "flags" => [],
      "segments" => [
        {
          "key" => "seg",
          "version" => 1,
          "conditionLogic" => condition_logic,
          "conditions" => [
            { "attribute" => "plan", "operator" => operator, "values" => ["pro"] }
          ]
        }
      ]
    }
  end

  describe "type violations are rejected wholesale" do
    it "rejects an integer conditionLogic" do
      payload = segment_payload(condition_logic: 0, operator: "Equals")

      expect { client.parse_flags_response(payload) }
        .to raise_error(Featureflip::MalformedPayloadError, /conditionLogic/)
    end

    it "rejects an integer condition operator" do
      payload = segment_payload(condition_logic: "And", operator: 0)

      expect { client.parse_flags_response(payload) }
        .to raise_error(Featureflip::MalformedPayloadError, /operator/)
    end

    it "rejects an integer flag type" do
      payload = {
        "flags" => [
          {
            "key" => "f", "version" => 1, "type" => 0, "enabled" => true,
            "fallthrough" => { "type" => "Fixed", "variation" => "on" },
            "offVariation" => "off"
          }
        ],
        "segments" => []
      }

      expect { client.parse_flags_response(payload) }
        .to raise_error(Featureflip::MalformedPayloadError, /type/)
    end

    it "rejects an integer serve type" do
      payload = {
        "flags" => [
          {
            "key" => "f", "version" => 1, "type" => "Boolean", "enabled" => true,
            "fallthrough" => { "type" => 0, "variation" => "on" },
            "offVariation" => "off"
          }
        ],
        "segments" => []
      }

      expect { client.parse_flags_response(payload) }
        .to raise_error(Featureflip::MalformedPayloadError, /type/)
    end
  end

  describe "forward compatibility" do
    # A newer server introducing an operator this SDK predates must NOT take the
    # whole snapshot down. The evaluator already degrades an unknown operator to
    # no-match, which is the correct graceful path.
    it "accepts an unknown operator STRING" do
      payload = segment_payload(condition_logic: "And", operator: "NotMatchesRegex")

      expect { client.parse_flags_response(payload) }.not_to raise_error
    end

    it "accepts an unknown conditionLogic STRING" do
      payload = segment_payload(condition_logic: "Xor", operator: "Equals")

      expect { client.parse_flags_response(payload) }.not_to raise_error
    end

    it "still parses a well-formed payload" do
      payload = segment_payload(condition_logic: "And", operator: "Equals")

      flags, segments = client.parse_flags_response(payload)

      expect(flags).to be_empty
      expect(segments.first.condition_logic).to eq("And")
      expect(segments.first.conditions.first.operator).to eq("Equals")
    end
  end
end

# The parser raising is only half the fix: the streaming handler used to catch every
# StandardError and discard it with a bare `# Swallow event processing errors`. That
# turns a rejected snapshot into complete silence, which is the same silence that let
# the server-side bug behind #2285 run undetected.
RSpec.describe Featureflip::DataSource::StreamingHandler do
  let(:sdk_key) { "sdk-test-key" }
  let(:logger) { instance_double(Logger) }
  let(:config) do
    Featureflip::Config.new(sdk_key: sdk_key, base_url: "https://eval.featureflip.io", logger: logger)
  end
  let(:http_client) { Featureflip::Http::Client.new(sdk_key, config) }
  let(:on_sync) { instance_double(Proc) }

  let(:handler) do
    described_class.new(
      sdk_key: sdk_key,
      config: config,
      http_client: http_client,
      on_flag_updated: instance_double(Proc),
      on_flag_deleted: instance_double(Proc),
      on_segment_updated: instance_double(Proc),
      on_error: instance_double(Proc),
      on_sync: on_sync
    )
  end

  let(:malformed_sync) do
    JSON.generate(
      "flags" => [],
      "segments" => [
        {
          "key" => "seg", "version" => 1, "conditionLogic" => 0,
          "conditions" => [{ "attribute" => "plan", "operator" => 0, "values" => ["pro"] }]
        }
      ]
    )
  end

  it "does not apply a malformed sync snapshot to the store" do
    allow(logger).to receive(:warn)

    # The store replace runs through on_sync; it must never be invoked for a
    # payload that failed validation.
    expect(on_sync).not_to receive(:call)

    handler.send(:handle_event, "sync", malformed_sync)
  end

  it "logs the discard instead of swallowing it" do
    allow(on_sync).to receive(:call)

    expect(logger).to receive(:warn).with(/discarding malformed sync payload/)

    handler.send(:handle_event, "sync", malformed_sync)
  end

  it "still applies a well-formed sync snapshot" do
    allow(logger).to receive(:warn)
    well_formed = JSON.generate(
      "flags" => [],
      "segments" => [
        {
          "key" => "seg", "version" => 1, "conditionLogic" => "And",
          "conditions" => [{ "attribute" => "plan", "operator" => "Equals", "values" => ["pro"] }]
        }
      ]
    )

    expect(on_sync).to receive(:call)

    handler.send(:handle_event, "sync", well_formed)
  end
end
