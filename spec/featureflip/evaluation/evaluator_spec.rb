require "spec_helper"

RSpec.describe Featureflip::Evaluation::Evaluator do
  subject(:evaluator) { described_class.new }

  before { Featureflip::Evaluation::UnbucketableWarnings.reset }

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

  describe "serving a variation key the flag does not define (#4236)" do
    it "reports Error with the served key and no rule id for a rule serving an unknown key" do
      flag = make_flag(rules: [make_rule(id: "r1", priority: 0, serve_variation: "zzz")])
      result = evaluator.evaluate(flag, { "user_id" => "u1" })

      expect(result.reason).to eq("Error")
      expect(result.variation_key).to eq("zzz")
      expect(result.rule_id).to be_nil
      expect(result.value).to be_nil
    end

    it "reports Error for a fallthrough serving an unknown key" do
      result = evaluator.evaluate(make_flag(fallthrough_variation: "zzz"), { "user_id" => "u1" })

      expect(result.reason).to eq("Error")
      expect(result.variation_key).to eq("zzz")
    end

    it "matches normally when the flag has a variation keyed with the empty string" do
      flag = make_flag(rules: [make_rule(id: "r1", priority: 0, serve_variation: "")])
      flag.variations << Featureflip::Models::Variation.new(key: "", value: "empty")
      result = evaluator.evaluate(flag, { "user_id" => "u1" })

      expect(result.reason).to eq("RuleMatch")
      expect(result.rule_id).to eq("r1")
      expect(result.variation_key).to eq("")
      expect(result.value).to eq("empty")
    end
  end

  describe "an off variation the flag does not define (#4236)" do
    def with_prereq(flag, key)
      flag.prerequisites = [Featureflip::Models::Prerequisite.new(prerequisite_flag_key: key, expected_variation_key: "true")]
      flag
    end

    it "reports Error with the off key and no value for a disabled flag" do
      result = evaluator.evaluate(make_flag(enabled: false, off_variation: "zzz"), { "user_id" => "u1" })

      expect(result.reason).to eq("Error")
      expect(result.variation_key).to eq("zzz")
      expect(result.value).to be_nil
    end

    it "reports Error, not PrerequisiteFailed, when the failed-prerequisite off variation is undefined" do
      parent = make_flag(enabled: false).tap { |f| f.key = "p" }
      main = with_prereq(make_flag(off_variation: "zzz"), "p")
      result = evaluator.evaluate(main, { "user_id" => "u1" }, all_flags: { "p" => parent })

      expect(result.reason).to eq("Error")
      expect(result.variation_key).to eq("zzz")
    end

    it "reports Error while serving its own off variation when a prerequisite's off variation is undefined" do
      parent = make_flag(enabled: false, off_variation: "zzz").tap { |f| f.key = "p" }
      main = with_prereq(make_flag, "p")
      result = evaluator.evaluate(main, { "user_id" => "u1" }, all_flags: { "p" => parent })

      expect(result.reason).to eq("Error")
      expect(result.variation_key).to eq("false")
      expect(result.value).to eq(false)
    end
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

      it "does not match when no segment source is provided (#1459)" do
        rule = make_rule(
          id: "seg-rule",
          priority: 1,
          conditions: [],
          segment_key: "beta-users"
        )
        flag = make_flag(rules: [rule], fallthrough_variation: "false")

        # No get_segment passed -> the segment source is not wired, so the
        # segment cannot be resolved. The rule must fail closed (no match),
        # mirroring the engine + C# SDK, rather than falling through to its
        # empty condition groups (which match unconditionally).
        result = evaluator.evaluate(flag, { "email" => "user@test.com" })

        expect(result.reason).to eq("Fallthrough")
        expect(result.variation_key).to eq("false")
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

      context "when the rollout can't bucket the context (#4236)" do
        let(:on_variation) { Featureflip::Models::Variation.new(key: "on", value: true) }
        let(:off_variation) { Featureflip::Models::Variation.new(key: "off", value: false) }
        let(:wv_on) { Featureflip::Models::WeightedVariation.new(key: "on", weight: 1) }
        let(:wv_off) { Featureflip::Models::WeightedVariation.new(key: "off", weight: 99) }
        let(:fixed_off) { Featureflip::Models::ServeConfig.new(type: "Fixed", variation: "off") }

        def rollout_serve(bucket_by: "userId")
          Featureflip::Models::ServeConfig.new(
            type: "Rollout", bucket_by: bucket_by, salt: "test-salt", variations: [wv_on, wv_off], variation: "off"
          )
        end

        def flag_with(key:, rules:, fallthrough:)
          Featureflip::Models::FlagConfiguration.new(
            key: key, version: 1, type: "Boolean", enabled: true,
            variations: [on_variation, off_variation], rules: rules,
            fallthrough: fallthrough, off_variation: "off"
          )
        end

        def rule(id, serve, priority: 0)
          Featureflip::Models::TargetingRule.new(id: id, priority: priority, condition_groups: [], serve: serve)
        end

        it "serves the fallthrough variation for a keyless context" do
          flag = flag_with(key: "rb-keyless-fallthrough", rules: [], fallthrough: rollout_serve)
          result = evaluator.evaluate(flag, {})
          expect(result.variation_key).to eq("off")
          expect(result.reason).to eq("Fallthrough")
        end

        it "skips a keyless rollout rule and serves the fallthrough" do
          flag = flag_with(key: "rb-keyless-rule", rules: [rule("r1", rollout_serve)], fallthrough: fixed_off)
          result = evaluator.evaluate(flag, {})
          expect(result.variation_key).to eq("off")
          expect(result.reason).to eq("Fallthrough")
        end

        it "continues to the next rule when a rollout rule can't bucket" do
          fixed_on = Featureflip::Models::ServeConfig.new(type: "Fixed", variation: "on")
          flag = flag_with(
            key: "rb-keyless-next",
            rules: [rule("r1", rollout_serve, priority: 0), rule("r2", fixed_on, priority: 1)],
            fallthrough: fixed_off
          )
          result = evaluator.evaluate(flag, {})
          expect(result.variation_key).to eq("on")
          expect(result.reason).to eq("RuleMatch")
          expect(result.rule_id).to eq("r2")
        end

        it "serves the fallthrough when a custom bucketBy is missing but userId is present" do
          flag = flag_with(key: "rb-custom-missing", rules: [], fallthrough: rollout_serve(bucket_by: "anonymous_id"))
          result = evaluator.evaluate(flag, { "userId" => "user-1" })
          expect(result.variation_key).to eq("off")
          expect(result.reason).to eq("Fallthrough")
        end

        it "treats an explicit nil and an empty string as unbucketable" do
          flag = flag_with(key: "rb-nil-empty", rules: [], fallthrough: rollout_serve(bucket_by: "k"))
          expect(Featureflip::Evaluation::Bucketing).not_to receive(:compute_bucket)
          [nil, ""].each do |v|
            expect(evaluator.evaluate(flag, { "k" => v }).variation_key).to eq("off")
          end
        end

        it "still buckets false, 0, whitespace and \"0\"" do
          flag = flag_with(key: "rb-bucketable", rules: [], fallthrough: rollout_serve(bucket_by: "k"))
          # A boolean hashes as JSON spells it, which is to_s; the engine's "True" would differ.
          { false => "false", true => "true", 0 => "0", " " => " ", "0" => "0" }.each do |v, hashed|
            expect(Featureflip::Evaluation::Bucketing).to receive(:compute_bucket).with("test-salt", hashed).and_call_original
            evaluator.evaluate(flag, { "k" => v })
          end
        end

        it "does not skip a rollout serve with no variations (#1469 degrade)" do
          serve = Featureflip::Models::ServeConfig.new(type: "Rollout", variation: "on", variations: [])
          flag = flag_with(key: "rb-degrade", rules: [rule("r1", serve)], fallthrough: fixed_off)
          result = evaluator.evaluate(flag, {})
          expect(result.variation_key).to eq("on")
          expect(result.reason).to eq("RuleMatch")
        end
      end

      it "serves the default variation when a rollout serve has no variations (#1469)" do
        # Env-level PercentageRollout emits a Rollout serve with its default variation set but
        # no weighted variations (no per-variation weight storage at the env level). Degrade to
        # the default variation instead of returning an empty key. Mirrors the engine + C#/Java.
        on_variation = Featureflip::Models::Variation.new(key: "on", value: true)
        off_variation = Featureflip::Models::Variation.new(key: "off", value: false)

        flag = Featureflip::Models::FlagConfiguration.new(
          key: "rollout-flag",
          version: 1,
          type: "Boolean",
          enabled: true,
          variations: [on_variation, off_variation],
          rules: [],
          fallthrough: Featureflip::Models::ServeConfig.new(
            type: "Rollout",
            bucket_by: "userId",
            variation: "off",
            variations: []
          ),
          off_variation: "off"
        )

        result = evaluator.evaluate(flag, { "userId" => "user-1" })

        expect(result.variation_key).to eq("off")
        expect(result.value).to eq(false)
        expect(result.reason).to eq("Fallthrough")
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
