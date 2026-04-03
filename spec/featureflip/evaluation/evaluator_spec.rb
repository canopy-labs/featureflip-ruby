require "spec_helper"

RSpec.describe Featureflip::Evaluation::Evaluator do
  subject(:evaluator) { described_class.new }

  let(:true_variation) { Featureflip::Models::Variation.new(key: "true", value: true) }
  let(:false_variation) { Featureflip::Models::Variation.new(key: "false", value: false) }

  def make_flag(enabled: true, rules: [], fallthrough_variation: "true", off_variation: "false")
    Featureflip::Models::FlagConfiguration.new(
      key: "test-flag",
      version: 1,
      type: "Boolean",
      enabled: enabled,
      variations: [true_variation, false_variation],
      rules: rules,
      fallthrough: Featureflip::Models::ServeConfig.new(type: "Fixed", variation: fallthrough_variation),
      off_variation: off_variation
    )
  end

  def make_condition(attribute:, operator:, values:, negate: false)
    Featureflip::Models::Condition.new(
      attribute: attribute, operator: operator, values: values, negate: negate
    )
  end

  def make_condition_group(conditions, operator: "And")
    Featureflip::Models::ConditionGroup.new(operator: operator, conditions: conditions)
  end

  def make_rule(id:, priority:, conditions: [], serve_variation: "true", condition_logic: "And", segment_key: nil, condition_groups: nil)
    groups = condition_groups || [make_condition_group(conditions, operator: condition_logic)]
    Featureflip::Models::TargetingRule.new(
      id: id,
      priority: priority,
      condition_groups: groups,
      serve: Featureflip::Models::ServeConfig.new(type: "Fixed", variation: serve_variation),
      segment_key: segment_key
    )
  end

  describe "#evaluate" do
    context "when flag is disabled" do
      it "returns off variation with FlagDisabled reason" do
        flag = make_flag(enabled: false)
        result = evaluator.evaluate(flag, { "user_id" => "123" })

        expect(result.value).to eq(false)
        expect(result.reason).to eq("FlagDisabled")
        expect(result.variation_key).to eq("false")
      end
    end

    context "when no rules match" do
      it "returns fallthrough variation" do
        flag = make_flag(rules: [])
        result = evaluator.evaluate(flag, { "user_id" => "123" })

        expect(result.value).to eq(true)
        expect(result.reason).to eq("Fallthrough")
        expect(result.variation_key).to eq("true")
      end
    end

    context "when a rule matches" do
      it "returns the rule variation with RuleMatch reason and rule_id" do
        rule = make_rule(
          id: "rule-1",
          priority: 1,
          conditions: [make_condition(attribute: "country", operator: "Equals", values: ["US"])],
          serve_variation: "true"
        )
        flag = make_flag(rules: [rule], fallthrough_variation: "false")
        result = evaluator.evaluate(flag, { "country" => "US" })

        expect(result.value).to eq(true)
        expect(result.reason).to eq("RuleMatch")
        expect(result.rule_id).to eq("rule-1")
        expect(result.variation_key).to eq("true")
      end
    end

    context "when rule conditions do not match" do
      it "falls through to default" do
        rule = make_rule(
          id: "rule-1",
          priority: 1,
          conditions: [make_condition(attribute: "country", operator: "Equals", values: ["US"])]
        )
        flag = make_flag(rules: [rule], fallthrough_variation: "false")
        result = evaluator.evaluate(flag, { "country" => "UK" })

        expect(result.value).to eq(false)
        expect(result.reason).to eq("Fallthrough")
      end
    end

    context "priority ordering" do
      it "evaluates rules in priority order (lower number first)" do
        rule_high = make_rule(
          id: "rule-high",
          priority: 10,
          conditions: [make_condition(attribute: "country", operator: "Equals", values: ["US"])],
          serve_variation: "false"
        )
        rule_low = make_rule(
          id: "rule-low",
          priority: 1,
          conditions: [make_condition(attribute: "country", operator: "Equals", values: ["US"])],
          serve_variation: "true"
        )
        # Intentionally pass in wrong order to verify sorting
        flag = make_flag(rules: [rule_high, rule_low])
        result = evaluator.evaluate(flag, { "country" => "US" })

        expect(result.rule_id).to eq("rule-low")
        expect(result.variation_key).to eq("true")
      end
    end

    context "segment-based rules" do
      it "evaluates segment conditions when get_segment is provided" do
        rule = make_rule(
          id: "seg-rule",
          priority: 1,
          conditions: [],
          segment_key: "beta-users"
        )
        flag = make_flag(rules: [rule])

        segment = Featureflip::Models::Segment.new(
          key: "beta-users",
          version: 1,
          conditions: [make_condition(attribute: "email", operator: "EndsWith", values: ["@test.com"])],
          condition_logic: "And"
        )

        get_segment = ->(key) { key == "beta-users" ? segment : nil }
        result = evaluator.evaluate(flag, { "email" => "user@test.com" }, get_segment: get_segment)

        expect(result.reason).to eq("RuleMatch")
        expect(result.rule_id).to eq("seg-rule")
      end

      it "does not match when segment is not found" do
        rule = make_rule(
          id: "seg-rule",
          priority: 1,
          conditions: [],
          segment_key: "missing-segment"
        )
        flag = make_flag(rules: [rule], fallthrough_variation: "false")

        get_segment = ->(_key) { nil }
        result = evaluator.evaluate(flag, { "email" => "user@test.com" }, get_segment: get_segment)

        expect(result.reason).to eq("Fallthrough")
        expect(result.variation_key).to eq("false")
      end

      it "does not match when segment conditions fail" do
        rule = make_rule(
          id: "seg-rule",
          priority: 1,
          conditions: [],
          segment_key: "beta-users"
        )
        flag = make_flag(rules: [rule], fallthrough_variation: "false")

        segment = Featureflip::Models::Segment.new(
          key: "beta-users",
          version: 1,
          conditions: [make_condition(attribute: "email", operator: "EndsWith", values: ["@test.com"])],
          condition_logic: "And"
        )

        get_segment = ->(key) { key == "beta-users" ? segment : nil }
        result = evaluator.evaluate(flag, { "email" => "user@other.com" }, get_segment: get_segment)

        expect(result.reason).to eq("Fallthrough")
      end
    end

    context "rollout serve config" do
      it "returns deterministic result for the same user" do
        wv_true = Featureflip::Models::WeightedVariation.new(key: "true", weight: 50)
        wv_false = Featureflip::Models::WeightedVariation.new(key: "false", weight: 50)

        flag = Featureflip::Models::FlagConfiguration.new(
          key: "rollout-flag",
          version: 1,
          type: "Boolean",
          enabled: true,
          variations: [true_variation, false_variation],
          rules: [],
          fallthrough: Featureflip::Models::ServeConfig.new(
            type: "Rollout",
            bucket_by: "userId",
            salt: "test-salt",
            variations: [wv_true, wv_false]
          ),
          off_variation: "false"
        )

        results = 5.times.map { evaluator.evaluate(flag, { "userId" => "user-42" }) }
        expect(results.map(&:value).uniq.length).to eq(1)
        expect(results.map(&:reason).uniq).to eq(["Fallthrough"])
      end

      it "assigns different users to different buckets" do
        wv_true = Featureflip::Models::WeightedVariation.new(key: "true", weight: 50)
        wv_false = Featureflip::Models::WeightedVariation.new(key: "false", weight: 50)

        flag = Featureflip::Models::FlagConfiguration.new(
          key: "rollout-flag",
          version: 1,
          type: "Boolean",
          enabled: true,
          variations: [true_variation, false_variation],
          rules: [],
          fallthrough: Featureflip::Models::ServeConfig.new(
            type: "Rollout",
            bucket_by: "userId",
            salt: "test-salt",
            variations: [wv_true, wv_false]
          ),
          off_variation: "false"
        )

        values = 100.times.map do |i|
          evaluator.evaluate(flag, { "userId" => "user-#{i}" }).value
        end

        # With 50/50 split over 100 users, both values should appear
        expect(values).to include(true)
        expect(values).to include(false)
      end

      it "uses rollout in rule serve config" do
        wv_true = Featureflip::Models::WeightedVariation.new(key: "true", weight: 100)

        rule = Featureflip::Models::TargetingRule.new(
          id: "rollout-rule",
          priority: 1,
          condition_groups: [make_condition_group([make_condition(attribute: "country", operator: "Equals", values: ["US"])])],
          serve: Featureflip::Models::ServeConfig.new(
            type: "Rollout",
            bucket_by: "userId",
            salt: "rule-salt",
            variations: [wv_true]
          )
        )
        flag = make_flag(rules: [rule], fallthrough_variation: "false")
        result = evaluator.evaluate(flag, { "country" => "US", "userId" => "user-1" })

        expect(result.reason).to eq("RuleMatch")
        expect(result.value).to eq(true)
      end
    end

    context "determinism" do
      it "produces the same result for identical inputs" do
        flag = make_flag
        context = { "user_id" => "abc-123" }

        results = 10.times.map { evaluator.evaluate(flag, context) }
        expect(results.map(&:value).uniq.length).to eq(1)
        expect(results.map(&:reason).uniq.length).to eq(1)
      end
    end
  end
end
