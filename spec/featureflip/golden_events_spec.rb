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
          body: JSON.generate(flags: [], segments: []),
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
        if v["kind"] == "identify"
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
    expect(executed).to be >= 13
  end
end
