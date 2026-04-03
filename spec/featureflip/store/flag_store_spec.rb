require "spec_helper"

RSpec.describe Featureflip::Store::FlagStore do
  let(:store) { described_class.new }

  def make_flag(key:, version: 1)
    Featureflip::Models::FlagConfiguration.new(
      key: key,
      version: version,
      type: "Boolean",
      enabled: true,
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
      current = make_flag(key: "f", version: 5)
      old = make_flag(key: "f", version: 3)
      store.init([current], [])

      store.upsert(old)

      expect(store.get_flag("f").version).to eq(5)
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
end
