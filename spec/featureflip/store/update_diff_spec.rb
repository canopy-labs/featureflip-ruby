require "spec_helper"

RSpec.describe Featureflip::Store::UpdateDiff do

  def flag(key, version: 1, enabled: true, rules: [], prerequisites: [])
    Featureflip::Models::FlagConfiguration.new(
      key: key, version: version, type: "Boolean", enabled: enabled,
      variations: [Featureflip::Models::Variation.new(key: "true", value: true), Featureflip::Models::Variation.new(key: "false", value: false)],
      rules: rules,
      fallthrough: Featureflip::Models::ServeConfig.new(type: "Fixed", variation: "true"),
      off_variation: "false",
      prerequisites: prerequisites
    )
  end

  def segment(key, version: 1, values: ["a"])
    Featureflip::Models::Segment.new(
      key: key, version: version,
      conditions: [Featureflip::Models::Condition.new(attribute: "plan", operator: "Equals", values: values, negate: false)],
      condition_logic: "And"
    )
  end

  def segment_rule(segment_key)
    Featureflip::Models::TargetingRule.new(
      id: "r-#{segment_key}", priority: 1, condition_groups: [],
      serve: Featureflip::Models::ServeConfig.new(type: "Fixed", variation: "true"),
      segment_key: segment_key
    )
  end

  def prereq(key)
    Featureflip::Models::Prerequisite.new(prerequisite_flag_key: key, expected_variation_key: "true")
  end

  def by_key(items) = items.to_h { |i| [i.key, i] }

  describe ".diff_snapshot" do
    it "reports nothing for an identical snapshot" do
      flags = [flag("a"), flag("b")]
      segs = [segment("s")]
      expect(described_class.diff_snapshot(by_key(flags), by_key(segs), flags.map(&:dup), segs.map(&:dup))).to eq([])
    end

    it "reports added, removed and modified flags, sorted" do
      prev = by_key([flag("keep"), flag("gone"), flag("edit", enabled: true)])
      nxt = [flag("keep"), flag("edit", enabled: false), flag("new")]
      expect(described_class.diff_snapshot(prev, {}, nxt, [])).to eq(%w[edit gone new])
    end

    it "pulls in flags whose rules reference a modified segment" do
      flags = [flag("uses-seg", rules: [segment_rule("s")]), flag("other")]
      expect(
        described_class.diff_snapshot(by_key(flags), by_key([segment("s", values: ["a"])]),
                                      flags, [segment("s", values: ["b"])])
      ).to eq(["uses-seg"])
    end

    it "pulls in flags referencing an added or removed segment" do
      flags = [flag("uses-new", rules: [segment_rule("new")]), flag("uses-old", rules: [segment_rule("old")])]
      expect(
        described_class.diff_snapshot(by_key(flags), by_key([segment("old")]), flags, [segment("new")])
      ).to eq(%w[uses-new uses-old])
    end

    it "fans a segment-pulled flag out to its prerequisite dependents" do
      flags = [flag("uses-seg", rules: [segment_rule("s")]), flag("child", prerequisites: [prereq("uses-seg")])]
      expect(
        described_class.diff_snapshot(by_key(flags), by_key([segment("s", values: ["a"])]),
                                      flags, [segment("s", values: ["b"])])
      ).to eq(%w[child uses-seg])
    end

    it "fans a changed flag out through a multi-level prerequisite chain" do
      prev = [flag("root", enabled: true), flag("mid", prerequisites: [prereq("root")]),
              flag("leaf", prerequisites: [prereq("mid")]), flag("unrelated")]
      nxt = [flag("root", enabled: false), flag("mid", prerequisites: [prereq("root")]),
             flag("leaf", prerequisites: [prereq("mid")]), flag("unrelated")]
      expect(described_class.diff_snapshot(by_key(prev), {}, nxt, [])).to eq(%w[leaf mid root])
    end

    it "reports a removed prerequisite's dependents, which still carry the dangling row" do
      prev = [flag("p"), flag("child", prerequisites: [prereq("p")])]
      nxt = [flag("child", prerequisites: [prereq("p")])]
      expect(described_class.diff_snapshot(by_key(prev), {}, nxt, [])).to eq(%w[child p])
    end
  end

  describe ".add_prerequisite_dependents" do
    it "terminates on a prerequisite cycle" do
      flags = [flag("a", prerequisites: [prereq("b")]), flag("b", prerequisites: [prereq("a")])]
      changed = Set["a"]
      expect(described_class.add_prerequisite_dependents(flags, changed)).to eq(Set["a", "b"])
    end

    it "ignores blank prerequisite keys and returns the input set when nothing depends on it" do
      flags = [flag("x", prerequisites: [prereq(""), prereq(nil)])]
      changed = Set["y"]
      expect(described_class.add_prerequisite_dependents(flags, changed)).to equal(changed)
      expect(changed).to eq(Set["y"])
    end
  end
end
