require "spec_helper"

RSpec.describe Featureflip::Models do
  describe Featureflip::Models::Variation do
    it "stores key and value" do
      v = Featureflip::Models::Variation.new(key: "on", value: true)
      expect(v.key).to eq("on")
      expect(v.value).to eq(true)
    end
  end

  describe Featureflip::Models::Condition do
    it "stores condition fields with default negate" do
      c = Featureflip::Models::Condition.new(
        attribute: "country", operator: "Equals", values: ["US"]
      )
      expect(c.attribute).to eq("country")
      expect(c.negate).to eq(false)
    end
  end

  describe Featureflip::Models::ServeConfig do
    it "stores fixed serve config" do
      s = Featureflip::Models::ServeConfig.new(type: "Fixed", variation: "on")
      expect(s.type).to eq("Fixed")
      expect(s.variation).to eq("on")
      expect(s.bucket_by).to be_nil
    end

    it "stores rollout serve config" do
      wv = Featureflip::Models::WeightedVariation.new(key: "on", weight: 50)
      s = Featureflip::Models::ServeConfig.new(
        type: "Rollout", bucket_by: "user_id", salt: "abc", variations: [wv]
      )
      expect(s.type).to eq("Rollout")
      expect(s.variations.length).to eq(1)
    end
  end

  describe Featureflip::Models::FlagConfiguration do
    it "provides variation lookup" do
      flag = Featureflip::Models::FlagConfiguration.new(
        key: "test-flag", version: 1, type: "Boolean", enabled: true,
        variations: [
          Featureflip::Models::Variation.new(key: "true", value: true),
          Featureflip::Models::Variation.new(key: "false", value: false),
        ],
        rules: [],
        fallthrough: Featureflip::Models::ServeConfig.new(type: "Fixed", variation: "true"),
        off_variation: "false"
      )
      expect(flag.get_variation("true").value).to eq(true)
      expect(flag.get_variation("nonexistent")).to be_nil
    end
  end

  describe Featureflip::Models::EvaluationDetail do
    it "stores evaluation result with defaults" do
      d = Featureflip::Models::EvaluationDetail.new(value: true, reason: "Fallthrough")
      expect(d.value).to eq(true)
      expect(d.reason).to eq("Fallthrough")
      expect(d.rule_id).to be_nil
      expect(d.variation_key).to be_nil
    end
  end
end
