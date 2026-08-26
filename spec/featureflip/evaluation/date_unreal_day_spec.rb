require "spec_helper"

# A date operand that matches the ISO grammar but names no real calendar day must match
# NOTHING, as it does in the engine, csharp, go, python and java (#2491).
#
# #2480 converged the seven SDKs on one ISO grammar, but a character class cannot express
# "is a real day": "2024-02-30" matches \d{4}-\d{2}-\d{2} everywhere, so the grammar guard
# is silent on it. Three SDKs then ROLLED IT OVER -- ruby, js and php all resolved it to
# 2024-03-01 -- while the engine and the other four rejected it. A flag therefore served
# different variations to two users purely by which SDK their service used, off one saved
# rule.
#
# This is one of the few cross-SDK date questions where the engine is NOT the outlier, so
# the fix moves ruby TOWARD it, and the expectations are engine-generated in the shared
# golden vectors (c-date-unreal-*) rather than hand-authored.
#
# The rollover was invisible to any suite that only asserted parseability: the operand
# parses fine, just to the wrong instant. These assert the OUTCOME of a comparison that
# inverts across the month boundary instead.
RSpec.describe Featureflip::Evaluation::ConditionEvaluator, "unreal calendar days (#2491)" do
  subject(:evaluator) { described_class.new }

  def matches?(attr, operator, target)
    c = Featureflip::Models::Condition.new(
      attribute: "attr", operator: operator, values: [target], negate: false
    )
    evaluator.evaluate_condition(c, { "attr" => attr })
  end

  # An operand that parses to SOME instant satisfies exactly one of these; one that parses
  # to nothing satisfies neither. Comparing in both directions AND on both sides of the
  # condition is what separates "unparseable" from "parsed to an extreme instant" -- a
  # single assertion cannot, and a rolled-over date is a perfectly ordinary instant.
  def unparseable?(operand)
    !matches?(operand, "After", "0") &&
      !matches?(operand, "Before", "0") &&
      !matches?("0", "After", operand) &&
      !matches?("0", "Before", operand)
  end

  describe "operands naming no real calendar day" do
    # The reported class: the day is within 01-31 so the grammar admits it, but the month
    # is shorter than that. All three rolling SDKs resolved these to the 1st of the month
    # after.
    [
      ["2024-02-30", "February 30 in a leap year"],
      ["2024-02-31", "February 31 in a leap year"],
      ["2023-02-29", "February 29 in a NON-leap year"],
      ["2023-02-30", "February 30 in a non-leap year"],
      ["2024-04-31", "April has 30 days"],
      ["2024-06-31", "June has 30 days"],
      ["2024-09-31", "September has 30 days"],
      ["2024-11-31", "November has 30 days"]
    ].each do |operand, why|
      it "rejects #{operand.inspect} (#{why})" do
        expect(unparseable?(operand)).to be true
      end
    end

    # The century rule. Divisible by 100 but not 400 is NOT a leap year -- the case a naive
    # `year % 4 == 0` check accepts.
    ["1900-02-29", "1800-02-29", "2100-02-29", "2200-02-29"].each do |operand|
      it "rejects #{operand.inspect} (century year divisible by 100 but not 400)" do
        expect(unparseable?(operand)).to be true
      end
    end

    # Structurally out of range. These already matched nothing here, because Time.iso8601
    # raises for them -- pinned so the explicit check that now replaces that incidental
    # rejection cannot silently widen or narrow it.
    [
      ["2024-13-01", "month 13"],
      ["2024-99-01", "month 99"],
      ["2024-01-32", "day 32"],
      ["2024-01-99", "day 99"]
    ].each do |operand, why|
      it "rejects #{operand.inspect} (#{why})" do
        expect(unparseable?(operand)).to be true
      end
    end

    # Zero month / zero day. ruby and js already rejected these; php ALONE rolled them
    # BACKWARDS into the previous year. Pinned in all three so the contract is stated once
    # rather than per-SDK.
    [
      ["2024-00-01", "month 0"],
      ["2024-01-00", "day 0"],
      ["2024-00-00", "month and day both 0"]
    ].each do |operand, why|
      it "rejects #{operand.inspect} (#{why})" do
        expect(unparseable?(operand)).to be true
      end
    end

    # The check is on the WRITTEN date, so a time component or an offset cannot smuggle one
    # past it.
    [
      ["2024-02-30T12:00:00Z", "with a time and Z"],
      ["2024-02-30 00:00:00", "with a space separator and no offset"],
      ["2024-02-30T00:00:00.500Z", "with fractional seconds"],
      ["2024-02-30T00:00:00+0500", "with a basic offset"]
    ].each do |operand, why|
      it "rejects #{operand.inspect} (#{why})" do
        expect(unparseable?(operand)).to be true
      end
    end

    # The decisive one. "2024-02-30T00:00:00+05:00" resolves to 2024-02-29T19:00Z, whose UTC
    # date IS a real day -- so an implementation that validated the RESOLVED UTC components
    # instead of the written triple would accept it and stay divergent.
    it "rejects an unreal day whose offset would shift it onto a real UTC day" do
      expect(unparseable?("2024-02-30T00:00:00+05:00")).to be true
    end
  end

  describe "the rollover itself is gone, not merely unasserted" do
    # Before the fix "2024-02-30" resolved to 2024-03-01, so this Before comparison was
    # TRUE. The control on the next line is the same assertion against the date it used to
    # roll into, proving the comparison still works and only the unreal operand changed.
    it "does not resolve 2024-02-30 to 2024-03-01" do
      expect(matches?("2024-02-30", "Before", "2024-03-02")).to be false
      expect(matches?("2024-03-01", "Before", "2024-03-02")).to be true
    end

    it "does not resolve 2023-02-29 to 2023-03-01" do
      expect(matches?("2023-02-29", "Before", "2023-03-02")).to be false
      expect(matches?("2023-03-01", "Before", "2023-03-02")).to be true
    end

    it "does not resolve an unreal day on the CONDITION side either" do
      expect(matches?("2024-06-01", "After", "2024-02-30")).to be false
      expect(matches?("2024-06-01", "After", "2024-03-01")).to be true
    end
  end

  describe "real calendar days still resolve" do
    # Every month's true last day, in a leap year and a non-leap year. This is what stops
    # the check from over-rejecting, and it walks the whole month-length table rather than
    # sampling it. A lambda rather than a `def`, because the example names are built at
    # describe-block scope where an instance method is not yet in play.
    month_ends = lambda do |year, feb|
      [31, feb, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].each_with_index.map do |d, i|
        format("%04d-%02d-%02d", year, i + 1, d)
      end
    end

    (month_ends.(2024, 29) + month_ends.(2023, 28) + ["2024-01-01", "2024-12-31"]).each do |operand|
      it "accepts #{operand.inspect}" do
        expect(unparseable?(operand)).to be false
      end
    end

    # Both halves of the century rule: divisible by 400 IS a leap year.
    ["2000-02-29", "1600-02-29", "2400-02-29"].each do |operand|
      it "accepts #{operand.inspect} (century year divisible by 400 is a leap year)" do
        expect(unparseable?(operand)).to be false
      end
    end

    it "accepts a real day carrying a time and an offset" do
      expect(unparseable?("2024-02-29T12:00:00+05:00")).to be false
    end
  end
end
