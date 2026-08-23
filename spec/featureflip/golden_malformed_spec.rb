require "spec_helper"
require "json"

# Runner for the shared `malformedConfigVectors` class (#2315).
#
# The rule: a config payload violating the wire contract is discarded WHOLESALE,
# never partially applied. Ruby is one of the two SDKs that used to fail this
# silently — `data["conditionLogic"] || "And"` does not rescue an integer, because
# 0 is truthy in Ruby, so the store held `condition_logic = 0` and every segment
# with conditions stopped matching anyone (#2285, from the #2279 server bug).
#
# `http/malformed_payload_spec.rb` covers that per-SDK. This runner covers the same
# ground from the SHARED fixture, so a divergence between SDKs fails a build.
RSpec.describe "golden malformedConfigVectors" do
  VECTORS_PATH = File.join(__dir__, "..", "golden", "vectors.json")
  BLOCK = JSON.parse(File.read(VECTORS_PATH)).fetch("malformedConfigVectors").freeze

  let(:config) do
    Featureflip::Config.new(sdk_key: "sdk-test-key-123", base_url: "https://eval.featureflip.io")
  end
  let(:client) { Featureflip::Http::Client.new("sdk-test-key-123", config) }

  # Applies the shared seed. A runner whose seed silently failed would "pass" every
  # reject vector for entirely the wrong reason, so this raises rather than returning.
  def seeded_store(client)
    store = Featureflip::Store::FlagStore.new
    flags, segments = client.parse_flags_response(BLOCK.fetch("seed"))
    store.init(flags, segments)
    raise "seed snapshot did not apply — the runner would prove nothing" unless store.get_flag("mc-seed")

    store
  end

  it "has vectors to run" do
    expect(BLOCK.fetch("vectors")).not_to be_empty
  end

  it "holds every vector to the wholesale-discard contract" do
    executed = 0

    BLOCK.fetch("vectors").each do |v|
      executed += 1
      store = seeded_store(client)
      label = "[#{v['id']}] #{v['description']}"

      applied =
        begin
          flags, segments = client.parse_flags_response(v.fetch("payload"))
          store.init(flags, segments)
          true
        rescue Featureflip::MalformedPayloadError
          false
        end

      case v.fetch("expect")
      when "reject"
        expect(applied).to be(false), "#{label}: payload was accepted"
        # Wholesale: the previous config still serves, nothing leaked in.
        expect(store.get_flag("mc-seed")).not_to be_nil, "#{label}: seeded config was replaced"
        expect(store.get_flag("mc-bad-type")).to be_nil, "#{label}: rejected payload partially applied"
      when "accept"
        expect(applied).to be(true), "#{label}: forward-compatible payload was rejected"
        accepted = store.get_flag("mc-accepted-flag") || store.get_segment("mc-accepted")
        expect(accepted).not_to be_nil, "#{label}: accepted payload did not apply"
      else
        raise "unmapped expect #{v.fetch('expect').inspect}"
      end
    end

    expect(executed).to be >= 8, "only #{executed} malformed vectors executed"
  end
end
