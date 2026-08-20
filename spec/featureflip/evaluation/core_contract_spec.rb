# frozen_string_literal: true

require "json"
require "spec_helper"
require_relative "golden_vector_spec_helpers" if File.exist?(
  File.join(__dir__, "golden_vector_spec_helpers.rb")
)

# coreContractVectors — the shared CORE's contract, one layer above the evaluator.
#
# The four classes in golden_vector_spec.rb assert what the evaluator computes,
# with the .NET engine as their oracle. This class asserts the shared core's
# client-facing contract (typed-accessor strictness, malformed-variation
# handling), where the engine has no opinion and in fact disagrees: it returns
# nil where an SDK must return the CALLER'S default. That is why #1989 and #2281
# could not be locked with the existing classes, and why both shipped as
# 6-of-7-SDK divergences no CI could see. These vectors are hand-authored.
#
# expect.reason is a CANONICAL token mapped to Ruby's vocabulary below.
RSpec.describe "golden: core contract vectors" do
  VECTORS = JSON.parse(
    File.read(File.join(__dir__, "..", "..", "golden", "vectors.json"))
  ).freeze

  CANONICAL_REASONS = {
    "Error" => "Error",
    "Fallthrough" => "Fallthrough",
    "FlagNotFound" => "FlagNotFound"
  }.freeze

  let(:base_url) { "https://eval.example.com" }

  # Serve the vector's flags over the stubbed HTTP path rather than poking the
  # store, so the real wire-parse the SDK uses in production runs too.
  def client_for(vector, events)
    sdk_key = "contract-#{vector['id']}"
    stub_request(:get, "#{base_url}/v1/sdk/flags")
      .with(headers: { "Authorization" => sdk_key })
      .to_return(
        status: 200,
        body: JSON.generate(flags: vector["flags"], segments: []),
        headers: { "Content-Type" => "application/json" }
      )

    config = Featureflip::Config.new(
      base_url: base_url, streaming: false, send_events: false,
      poll_interval: 9999, inspectors: [->(e) { events << e }]
    )
    Featureflip::Client.get(sdk_key, config: config)
  end

  it "asserts every supported core contract vector" do
    vectors = VECTORS["coreContractVectors"]
    expect(vectors).not_to be_empty

    executed = 0
    vectors.each do |v|
      # Ruby exposes no separate int accessor — number_variation covers every
      # JSON number. The skip is explicit so a capability gap cannot pass.
      next if v["read"]["as"] == "int"

      events = []
      client = client_for(v, events)
      context = { "user_id" => v["context"]["userId"] }
      default = v["read"]["default"]

      got =
        case v["read"]["as"]
        when "bool" then client.bool_variation(v["flagKey"], context, default)
        when "string" then client.string_variation(v["flagKey"], context, default)
        when "number", "double" then client.number_variation(v["flagKey"], context, default)
        else raise "unmapped read.as #{v['read']['as']} — add it to the case"
        end

      expect(got).to eq(v["expect"]["value"]),
                     "[#{v['id']}] #{v['description']}: value=#{got.inspect}, " \
                     "expected #{v['expect']['value'].inspect}"

      # Typed accessors return only a value, so the reason is observed through
      # the inspector — the same surface a real caller would use.
      expect(events.size).to eq(1), "[#{v['id']}] inspector fired #{events.size} times, want 1"
      expect(events.first.reason).to eq(CANONICAL_REASONS.fetch(v["expect"]["reason"])),
                                     "[#{v['id']}] reason=#{events.first.reason.inspect}"

      client.close
      executed += 1
    end

    # A runner that silently skips everything is worse than no runner at all.
    expect(executed).to be >= 12, "only #{executed} contract vectors executed"
  end
end
