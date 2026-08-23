# frozen_string_literal: true

require "json"
require "spec_helper"

# Golden-vector parity harness for the Ruby SDK (#1477).
#
# Drives the 39 canonical cross-SDK vectors vendored at
# spec/golden/vectors.json against:
#   - Featureflip::Evaluation::Bucketing.compute_bucket (bucket vectors)
#   - Featureflip::Evaluation::Evaluator#evaluate         (rollout / condition / flag vectors)
#
# Builder helpers mirror Http::Client#parse_flag / parse_rule / parse_serve /
# parse_condition_group / parse_condition / parse_segment (all private there)
# so that wire-format hashes construct the same model objects the HTTP path
# produces.  Any future divergence between helpers here and the client's
# private parse_* methods is a bug to fix in one or the other — never edit
# the fixture to paper over it.

RSpec.describe "golden vectors" do
  VECTORS = JSON.parse(File.read(File.expand_path("../../golden/vectors.json", __dir__))).freeze

  # ---------------------------------------------------------------------------
  # Builder helpers — mirror Http::Client private parse_* methods exactly.
  # ---------------------------------------------------------------------------

  def build_condition(d)
    Featureflip::Models::Condition.new(
      attribute: d["attribute"],
      operator: d["operator"],
      values: d["values"],
      negate: d["negate"] || false
    )
  end

  def build_condition_group(d)
    Featureflip::Models::ConditionGroup.new(
      operator: d["operator"] || "And",
      conditions: (d["conditions"] || []).map { |c| build_condition(c) }
    )
  end

  def build_serve(d)
    return nil if d.nil?

    variations = if d["variations"]
      d["variations"].map { |v| Featureflip::Models::WeightedVariation.new(key: v["key"], weight: v["weight"]) }
    end

    Featureflip::Models::ServeConfig.new(
      type: d["type"],
      variation: d["variation"],
      bucket_by: d["bucketBy"],
      salt: d["salt"],
      variations: variations
    )
  end

  def build_rule(d)
    Featureflip::Models::TargetingRule.new(
      id: d["id"],
      priority: d["priority"],
      condition_groups: (d["conditionGroups"] || []).map { |g| build_condition_group(g) },
      serve: build_serve(d["serve"]),
      segment_key: d["segmentKey"]
    )
  end

  def build_prerequisite(d)
    Featureflip::Models::Prerequisite.new(
      prerequisite_flag_key: d["prerequisiteFlagKey"],
      expected_variation_key: d["expectedVariationKey"]
    )
  end

  def build_flag(d)
    Featureflip::Models::FlagConfiguration.new(
      key: d["key"],
      version: d["version"],
      type: d["type"],
      enabled: d["enabled"],
      variations: (d["variations"] || []).map { |v| Featureflip::Models::Variation.new(key: v["key"], value: v["value"]) },
      rules: (d["rules"] || []).map { |r| build_rule(r) },
      fallthrough: build_serve(d["fallthrough"]),
      off_variation: d["offVariation"],
      prerequisites: (d["prerequisites"] || []).map { |p| build_prerequisite(p) }
    )
  end

  def build_segment(d)
    Featureflip::Models::Segment.new(
      key: d["key"],
      version: d["version"],
      conditions: (d["conditions"] || []).map { |c| build_condition(c) },
      condition_logic: d["conditionLogic"] || "And"
    )
  end

  # ---------------------------------------------------------------------------
  # Reason normalizer — EvaluationDetail → wire-compatible hash.
  # Ruby reasons are already PascalCase strings so this is near-identity.
  # ---------------------------------------------------------------------------

  def normalize_reason(result)
    r = { "kind" => result.reason }
    r["ruleId"] = result.rule_id unless result.rule_id.nil?
    r["prerequisiteKey"] = result.prerequisite_key unless result.prerequisite_key.nil?
    r
  end

  # ---------------------------------------------------------------------------
  # Evaluator (shared across all examples in this file)
  # ---------------------------------------------------------------------------

  let(:evaluator) { Featureflip::Evaluation::Evaluator.new }

  # ---------------------------------------------------------------------------
  # Bucket vectors
  # ---------------------------------------------------------------------------

  describe "bucket vectors" do
    VECTORS["bucketVectors"].each do |v|
      it "#{v["id"]}: MD5 bucket matches engine" do
        expect(Featureflip::Evaluation::Bucketing.compute_bucket(v["salt"], v["value"]))
          .to eq(v["expectedBucket"]), v["id"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Rollout vectors
  # ---------------------------------------------------------------------------

  describe "rollout vectors" do
    VECTORS["rolloutVectors"].each do |v|
      it "#{v["id"]}: rollout selects expected variation" do
        flag = build_flag(
          "key" => "rollout-test",
          "version" => 1,
          "type" => "String",
          "enabled" => true,
          "variations" => v["variations"].map { |w| { "key" => w["key"], "value" => w["key"] } },
          "rules" => [],
          "fallthrough" => {
            "type" => "Rollout",
            "salt" => v["salt"],
            "bucketBy" => "userId",
            "variations" => v["variations"]
          },
          "offVariation" => v["variations"][0]["key"],
          "prerequisites" => []
        )
        result = evaluator.evaluate(flag, { "userId" => v["value"] })
        expect(result.variation_key).to eq(v["expectedVariation"]), v["id"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Condition vectors
  # ---------------------------------------------------------------------------

  # Defines one example per vector. Shared by the engine-generated condition
  # vectors and the hand-authored unknown-operator vectors, which have an
  # identical input shape. Defined as a class method so nested example groups
  # (RSpec subclasses) inherit it.
  def self.condition_vector_examples(vectors)
    vectors.each do |v|
      it "#{v["id"]}: condition match == #{v["expectedMatch"]}" do
        # Build a minimal two-variation flag with a single rule whose one
        # condition exercises the vector.  The attribute value is taken from the
        # typed JSON (Integer/Float/true/false/String) so the #1458 numeric
        # coercion path fires correctly when the type is "number".
        attr_value = v["attribute"]["value"]

        flag = build_flag(
          "key" => "cond-test",
          "version" => 1,
          "type" => "String",
          "enabled" => true,
          "variations" => [
            { "key" => "match", "value" => "match" },
            { "key" => "nomatch", "value" => "nomatch" }
          ],
          "rules" => [
            {
              "id" => "r",
              "priority" => 0,
              "serve" => { "type" => "Fixed", "variation" => "match" },
              "conditionGroups" => [
                {
                  "operator" => "And",
                  "conditions" => [
                    {
                      "attribute" => "attr",
                      "operator" => v["operator"],
                      "values" => v["values"],
                      "negate" => v["negate"] || false
                    }
                  ]
                }
              ]
            }
          ],
          "fallthrough" => { "type" => "Fixed", "variation" => "nomatch" },
          "offVariation" => "nomatch",
          "prerequisites" => []
        )

        result = evaluator.evaluate(flag, { "attr" => attr_value })
        got = result.variation_key == "match"
        expect(got).to eq(v["expectedMatch"]), v["id"]
      end
    end
  end

  describe "condition vectors" do
    condition_vector_examples(VECTORS["conditionVectors"])
  end

  # ---------------------------------------------------------------------------
  # Unknown-operator vectors (#2262)
  # ---------------------------------------------------------------------------
  #
  # Hand-authored, not engine-generated: the generator resolves operators with
  # Enum.Parse<ConditionOperator>, which throws on an unrecognised name, so these
  # cases cannot exist as conditionVectors. They lock the rule that an operator
  # this SDK does not recognise means "cannot evaluate", NOT "did not match" — so
  # `negate` must never invert it into a match-everyone, which would serve the
  # flag to 100% of traffic. Ruby carries the operator as a raw string, so unlike
  # the enum-typed SDKs it can genuinely receive one of these over the wire.

  describe "unknown-operator vectors" do
    condition_vector_examples(VECTORS["unknownOperatorVectors"])
  end

  # ---------------------------------------------------------------------------
  # Flag vectors
  # ---------------------------------------------------------------------------

  describe "flag vectors" do
    VECTORS["flagVectors"].each do |v|
      it "#{v["id"]}: full flag evaluation matches engine" do
        all_flags = v["flags"].to_h { |f| [f["key"], build_flag(f)] }
        segments = (v["segments"] || []).to_h { |s| [s["key"], build_segment(s)] }

        # Context: userId at top level + any extra attributes.
        ctx = { "userId" => v.dig("context", "userId") }
        (v.dig("context", "attributes") || {}).each { |k, val| ctx[k] = val }

        result = evaluator.evaluate(
          all_flags[v["flagKey"]],
          ctx,
          get_segment: ->(k) { segments[k] },
          all_flags: all_flags
        )

        exp = v["expected"]
        expect(result.variation_key).to eq(exp["variation"]), "#{v["id"]}: variation_key"
        expect(JSON.generate(result.value)).to eq(JSON.generate(exp["value"])), "#{v["id"]}: value"
        expect(normalize_reason(result)).to eq(exp["reason"]), "#{v["id"]}: reason"
      end
    end
  end
end
