require "spec_helper"

RSpec.describe Featureflip::Evaluation::Evaluator, "prerequisite resolution" do
  subject(:evaluator) { described_class.new }

  let(:on_var) { Featureflip::Models::Variation.new(key: "on", value: true) }
  let(:off_var) { Featureflip::Models::Variation.new(key: "off", value: false) }
  let(:context) { { "user_id" => "user-1" } }

  def make_flag(key: "test-flag", enabled: true, prerequisites: [], fallthrough_variation: "on", off_variation_key: "off")
    Featureflip::Models::FlagConfiguration.new(
      key: key,
      version: 1,
      type: "Boolean",
      enabled: enabled,
      variations: [on_var, off_var],
      rules: [],
      fallthrough: Featureflip::Models::ServeConfig.new(type: "Fixed", variation: fallthrough_variation),
      off_variation: off_variation_key,
      prerequisites: prerequisites
    )
  end

  def make_prereq(flag_key, expected_variation_key)
    Featureflip::Models::Prerequisite.new(
      prerequisite_flag_key: flag_key,
      expected_variation_key: expected_variation_key
    )
  end

  describe "#evaluate with all_flags" do
    it "passes through when no prerequisites are defined" do
      flag = make_flag(key: "main", prerequisites: [])
      result = evaluator.evaluate(flag, context, all_flags: {})

      expect(result.reason).to eq("Fallthrough")
      expect(result.value).to eq(true)
    end

    it "serves on variation when prerequisite is satisfied" do
      prereq_flag = make_flag(key: "prereq", fallthrough_variation: "on")
      main_flag = make_flag(
        key: "main",
        prerequisites: [make_prereq("prereq", "on")]
      )
      result = evaluator.evaluate(main_flag, context, all_flags: { "prereq" => prereq_flag })

      expect(result.reason).to eq("Fallthrough")
      expect(result.value).to eq(true)
      expect(result.prerequisite_key).to be_nil
    end

    it "serves off variation when prerequisite serves the wrong variation" do
      prereq_flag = make_flag(key: "prereq", fallthrough_variation: "off")
      main_flag = make_flag(
        key: "main",
        prerequisites: [make_prereq("prereq", "on")]
      )
      result = evaluator.evaluate(main_flag, context, all_flags: { "prereq" => prereq_flag })

      expect(result.reason).to eq("PrerequisiteFailed")
      expect(result.variation_key).to eq("off")
      expect(result.value).to eq(false)
      expect(result.prerequisite_key).to eq("prereq")
    end

    it "serves off variation when prerequisite flag is disabled" do
      prereq_flag = make_flag(key: "prereq", enabled: false)
      main_flag = make_flag(
        key: "main",
        prerequisites: [make_prereq("prereq", "on")]
      )
      result = evaluator.evaluate(main_flag, context, all_flags: { "prereq" => prereq_flag })

      expect(result.reason).to eq("PrerequisiteFailed")
      expect(result.variation_key).to eq("off")
      expect(result.prerequisite_key).to eq("prereq")
    end

    it "reports first failing prerequisite when multiple fail" do
      prereq_a = make_flag(key: "prereq-a", fallthrough_variation: "off")
      prereq_b = make_flag(key: "prereq-b", fallthrough_variation: "off")
      main_flag = make_flag(
        key: "main",
        prerequisites: [
          make_prereq("prereq-a", "on"),
          make_prereq("prereq-b", "on")
        ]
      )
      all = { "prereq-a" => prereq_a, "prereq-b" => prereq_b }
      result = evaluator.evaluate(main_flag, context, all_flags: all)

      expect(result.reason).to eq("PrerequisiteFailed")
      expect(result.prerequisite_key).to eq("prereq-a")
    end

    it "resolves chained prerequisites" do
      grandchild = make_flag(key: "grandchild", fallthrough_variation: "on")
      child = make_flag(
        key: "child",
        prerequisites: [make_prereq("grandchild", "on")],
        fallthrough_variation: "on"
      )
      main_flag = make_flag(
        key: "main",
        prerequisites: [make_prereq("child", "on")]
      )
      all = { "grandchild" => grandchild, "child" => child }
      result = evaluator.evaluate(main_flag, context, all_flags: all)

      expect(result.reason).to eq("Fallthrough")
      expect(result.value).to eq(true)
    end

    it "propagates failure through chained prerequisites" do
      grandchild = make_flag(key: "grandchild", fallthrough_variation: "off")
      child = make_flag(
        key: "child",
        prerequisites: [make_prereq("grandchild", "on")],
        fallthrough_variation: "on"
      )
      main_flag = make_flag(
        key: "main",
        prerequisites: [make_prereq("child", "on")]
      )
      all = { "grandchild" => grandchild, "child" => child }
      result = evaluator.evaluate(main_flag, context, all_flags: all)

      expect(result.reason).to eq("PrerequisiteFailed")
    end

    it "serves off variation when prerequisite flag is missing from all_flags" do
      main_flag = make_flag(
        key: "main",
        prerequisites: [make_prereq("missing-flag", "on")]
      )
      result = evaluator.evaluate(main_flag, context, all_flags: {})

      expect(result.reason).to eq("PrerequisiteFailed")
      expect(result.variation_key).to eq("off")
      expect(result.prerequisite_key).to eq("missing-flag")
    end

    it "returns Error reason when prerequisite depth cap is exceeded" do
      # Linear chain of 12 flags exceeds MAX_PREREQUISITE_DEPTH = 10
      flags = {}
      12.times do |i|
        key = "flag-#{i}"
        prereqs = i.zero? ? [] : [make_prereq("flag-#{i - 1}", "on")]
        flags[key] = make_flag(
          key: key,
          prerequisites: prereqs,
          fallthrough_variation: "on"
        )
      end
      top = flags["flag-11"]
      result = evaluator.evaluate(top, context, all_flags: flags)

      expect(result.reason).to eq("Error")
    end
  end

  describe "#evaluate_with_shared_memo" do
    it "reuses memoised prerequisite results across evaluations" do
      prereq_flag = make_flag(key: "prereq", fallthrough_variation: "on")
      main_flag = make_flag(
        key: "main",
        prerequisites: [make_prereq("prereq", "on")]
      )
      all = { "prereq" => prereq_flag }

      memo = {}
      memo["prereq"] = Featureflip::Models::EvaluationDetail.new(
        value: true,
        reason: "Fallthrough",
        variation_key: "on"
      )

      result = evaluator.evaluate_with_shared_memo(main_flag, context, all_flags: all, memo: memo)

      expect(result.reason).to eq("Fallthrough")
      expect(memo).to have_key("main")
    end
  end
end
