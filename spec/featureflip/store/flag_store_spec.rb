require "spec_helper"

RSpec.describe Featureflip::Store::FlagStore do
  let(:store) { described_class.new }

  def make_flag(key:, version: 1, enabled: true)
    Featureflip::Models::FlagConfiguration.new(
      key: key,
      version: version,
      type: "Boolean",
      enabled: enabled,
      variations: [],
      rules: [],
      fallthrough: Featureflip::Models::ServeConfig.new(type: "Fixed", variation: "true"),
      off_variation: "false"
    )
  end

  def make_segment(key:, version: 1)
    Featureflip::Models::Segment.new(
      key: key,
      version: version,
      conditions: [],
      condition_logic: "And"
    )
  end

  describe "#init" do
    it "stores flags and segments" do
      flag = make_flag(key: "flag-1")
      segment = make_segment(key: "seg-1")

      store.init([flag], [segment])

      expect(store.get_flag("flag-1")).to eq(flag)
      expect(store.get_segment("seg-1")).to eq(segment)
    end

    it "clears previous data" do
      old_flag = make_flag(key: "old-flag")
      store.init([old_flag], [])

      new_flag = make_flag(key: "new-flag")
      store.init([new_flag], [])

      expect(store.get_flag("old-flag")).to be_nil
      expect(store.get_flag("new-flag")).to eq(new_flag)
    end
  end

  describe "#get_flag" do
    it "returns nil for missing key" do
      expect(store.get_flag("nonexistent")).to be_nil
    end
  end

  describe "#all_flags" do
    it "returns all stored flags" do
      flag1 = make_flag(key: "a")
      flag2 = make_flag(key: "b")
      store.init([flag1, flag2], [])

      expect(store.all_flags).to contain_exactly(flag1, flag2)
    end
  end

  describe "#upsert" do
    it "adds a new flag" do
      flag = make_flag(key: "new", version: 1)
      store.upsert(flag)

      expect(store.get_flag("new")).to eq(flag)
    end

    it "updates with higher version" do
      old = make_flag(key: "f", version: 1)
      new_flag = make_flag(key: "f", version: 2)
      store.init([old], [])

      store.upsert(new_flag)

      expect(store.get_flag("f")).to eq(new_flag)
      expect(store.get_flag("f").version).to eq(2)
    end

    it "ignores lower version" do
      current = make_flag(key: "f", version: 5, enabled: true)
      old = make_flag(key: "f", version: 3, enabled: false)
      store.init([current], [])

      store.upsert(old)

      expect(store.get_flag("f").version).to eq(5)
      expect(store.get_flag("f").enabled).to be(true)
    end

    # The wire version is second-granular (#2088), so two edits to one flag
    # inside the same wall-clock second carry an identical version. Treating
    # equal as stale discarded the second edit's config outright, and streaming
    # disables polling, so no later snapshot corrected it — the SDK evaluated
    # against the pre-edit config until an SSE `sync` or reconnect.
    it "applies a same-version delta" do
      store.init([make_flag(key: "f", version: 3, enabled: true)], [])

      store.upsert(make_flag(key: "f", version: 3, enabled: false))

      expect(store.get_flag("f").enabled).to be(false)
    end

    it "applies successive same-version deltas, keeping the newest" do
      store.init([make_flag(key: "f", version: 7, enabled: true)], [])

      store.upsert(make_flag(key: "f", version: 7, enabled: false))
      expect(store.get_flag("f").enabled).to be(false)

      store.upsert(make_flag(key: "f", version: 7, enabled: true))
      expect(store.get_flag("f").enabled).to be(true)
    end
  end

  describe "thread safety" do
    it "handles concurrent reads and writes" do
      threads = 10.times.map do |i|
        Thread.new do
          flag = make_flag(key: "flag-#{i}", version: i + 1)
          store.upsert(flag)
          store.get_flag("flag-#{i}")
          store.all_flags
        end
      end

      threads.each(&:join)

      10.times do |i|
        flag = store.get_flag("flag-#{i}")
        expect(flag).not_to be_nil
        expect(flag.key).to eq("flag-#{i}")
      end
    end
  end

  describe "change reporting" do
    def with_prereq(flag, prereq_key)
      flag.dup.tap do |f|
        f.prerequisites = [Featureflip::Models::Prerequisite.new(prerequisite_flag_key: prereq_key, expected_variation_key: "true")]
      end
    end

    it "reports nothing for the first snapshot (the baseline)" do
      expect(store.init([make_flag(key: "a")], [])).to eq([])
    end

    it "reports nothing when a later snapshot is identical" do
      store.init([make_flag(key: "a")], [make_segment(key: "s")])
      expect(store.init([make_flag(key: "a")], [make_segment(key: "s")])).to eq([])
    end

    it "reports the diff for a later snapshot" do
      store.init([make_flag(key: "a"), make_flag(key: "b")], [])
      expect(store.init([make_flag(key: "a", enabled: false), make_flag(key: "c")], [])).to eq(%w[a b c])
    end

    it "reports an upsert that changes the flag, with its dependents" do
      store.init([make_flag(key: "p"), with_prereq(make_flag(key: "child"), "p")], [])
      expect(store.upsert(make_flag(key: "p", version: 2, enabled: false))).to eq(%w[child p])
    end

    it "reports nothing for an identical redelivery" do
      store.init([make_flag(key: "a")], [])
      expect(store.upsert(make_flag(key: "a"))).to eq([])
    end

    it "reports nothing for an equal-version redelivery of identical config" do
      store.init([make_flag(key: "a", version: 5)], [])
      expect(store.upsert(make_flag(key: "a", version: 5))).to eq([])
    end

    it "applies and reports an equal-version upsert with different content" do
      store.init([make_flag(key: "a", version: 5)], [])
      expect(store.upsert(make_flag(key: "a", version: 5, enabled: false))).to eq(%w[a])
      expect(store.get_flag("a").enabled).to be(false)
    end

    it "reports nothing when an older version is rejected" do
      store.init([make_flag(key: "a", version: 5)], [])
      expect(store.upsert(make_flag(key: "a", version: 4, enabled: false))).to eq([])
      expect(store.get_flag("a").enabled).to be(true)
    end

    it "reports a delete with the dependents that still reference it" do
      store.init([make_flag(key: "p"), with_prereq(make_flag(key: "child"), "p")], [])
      expect(store.remove_flag("p")).to eq(%w[child p])
    end

    it "reports nothing when deleting an absent flag" do
      store.init([make_flag(key: "a")], [])
      expect(store.remove_flag("missing")).to eq([])
    end
  end
end
