require "spec_helper"
require "logger"
require "stringio"

RSpec.describe Featureflip::Evaluation::UnbucketableWarnings do
  let(:io) { StringIO.new }
  let(:logger) { Logger.new(io) }
  let(:evaluator) { Featureflip::Evaluation::Evaluator.new(logger: logger) }

  before { described_class.reset }
  after { described_class.reset }

  def rollout_flag(key, enabled: true)
    wv_on = Featureflip::Models::WeightedVariation.new(key: "on", weight: 1)
    wv_off = Featureflip::Models::WeightedVariation.new(key: "off", weight: 99)
    serve = Featureflip::Models::ServeConfig.new(
      type: "Rollout", bucket_by: "userId", salt: "s", variations: [wv_on, wv_off], variation: "off"
    )
    rule = Featureflip::Models::TargetingRule.new(id: "r1", priority: 0, condition_groups: [], serve: serve)
    Featureflip::Models::FlagConfiguration.new(
      key: key, version: 1, type: "Boolean", enabled: enabled,
      variations: [Featureflip::Models::Variation.new(key: "on", value: true),
                   Featureflip::Models::Variation.new(key: "off", value: false)],
      rules: [rule],
      fallthrough: Featureflip::Models::ServeConfig.new(type: "Fixed", variation: "off"),
      off_variation: "off"
    )
  end

  it "warns once per flag and rule without leaking context values" do
    flag = rollout_flag("warn-once-flag")
    2.times { evaluator.evaluate(flag, { "email" => "secret@example.com" }) }

    lines = io.string.lines.select { |l| l.include?("[featureflip]") }
    expect(lines.size).to eq(1)
    expect(lines.first).to include('Skipped the percentage rollout in flag "warn-once-flag" (rule r1)')
    expect(lines.first).to include('no value for "userId"')
    expect(io.string).not_to include("secret@example.com")
  end

  it "does not warn for a disabled flag" do
    evaluator.evaluate(rollout_flag("warn-disabled-flag", enabled: false), {})
    expect(io.string).to be_empty
  end

  it "does not raise when the logger is nil" do
    quiet = Featureflip::Evaluation::Evaluator.new
    expect { quiet.evaluate(rollout_flag("warn-nil-logger"), {}) }.not_to raise_error
  end

  it "caps the dedup set at 1000 keys and drops the rest silently" do
    1000.times { |i| described_class.warn(logger, "cap-flag-#{i}", "r1", "userId") }
    expect(described_class.count).to eq(1000)
    io.truncate(0)
    io.rewind
    described_class.warn(logger, "cap-flag-new", "r1", "userId")
    expect(described_class.count).to eq(1000)
    expect(io.string).to be_empty
  end
end
