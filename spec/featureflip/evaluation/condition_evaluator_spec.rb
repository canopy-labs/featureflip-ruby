require "spec_helper"

RSpec.describe Featureflip::Evaluation::ConditionEvaluator do
  subject(:evaluator) { described_class.new }

  def condition(operator:, attribute: "country", values: ["US"], negate: false)
    Featureflip::Models::Condition.new(
      attribute: attribute, operator: operator, values: values, negate: negate
    )
  end

  describe "#evaluate_condition" do
    context "Equals operator" do
      it "matches when value equals target" do
        c = condition(operator: "Equals")
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be true
      end

      it "does not match when value differs" do
        c = condition(operator: "Equals")
        expect(evaluator.evaluate_condition(c, { "country" => "UK" })).to be false
      end

      it "matches any target value" do
        c = condition(operator: "Equals", values: ["US", "UK"])
        expect(evaluator.evaluate_condition(c, { "country" => "UK" })).to be true
      end

      it "is case insensitive" do
        c = condition(operator: "Equals")
        expect(evaluator.evaluate_condition(c, { "country" => "us" })).to be true
        expect(evaluator.evaluate_condition(c, { "country" => "Us" })).to be true
      end
    end

    context "NotEquals operator" do
      it "matches when value differs from all targets" do
        c = condition(operator: "NotEquals", values: ["US", "UK"])
        expect(evaluator.evaluate_condition(c, { "country" => "CA" })).to be true
      end

      it "does not match when value equals any target" do
        c = condition(operator: "NotEquals", values: ["US", "UK"])
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be false
      end
    end

    context "Contains operator" do
      it "matches when value contains target" do
        c = condition(operator: "Contains", attribute: "email", values: ["gmail"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@gmail.com" })).to be true
      end

      it "does not match when value does not contain target" do
        c = condition(operator: "Contains", attribute: "email", values: ["gmail"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@yahoo.com" })).to be false
      end
    end

    context "NotContains operator" do
      it "matches when value does not contain any target" do
        c = condition(operator: "NotContains", attribute: "email", values: ["gmail"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@yahoo.com" })).to be true
      end

      it "does not match when value contains a target" do
        c = condition(operator: "NotContains", attribute: "email", values: ["gmail"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@gmail.com" })).to be false
      end
    end

    context "StartsWith operator" do
      it "matches when value starts with target" do
        c = condition(operator: "StartsWith", attribute: "name", values: ["jo"])
        expect(evaluator.evaluate_condition(c, { "name" => "John" })).to be true
      end

      it "does not match when value does not start with target" do
        c = condition(operator: "StartsWith", attribute: "name", values: ["jo"])
        expect(evaluator.evaluate_condition(c, { "name" => "Alice" })).to be false
      end
    end

    context "EndsWith operator" do
      it "matches when value ends with target" do
        c = condition(operator: "EndsWith", attribute: "email", values: [".com"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@test.com" })).to be true
      end

      it "does not match when value does not end with target" do
        c = condition(operator: "EndsWith", attribute: "email", values: [".com"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@test.org" })).to be false
      end
    end

    context "In operator" do
      it "matches when value is in targets" do
        c = condition(operator: "In", values: ["us", "uk", "ca"])
        expect(evaluator.evaluate_condition(c, { "country" => "UK" })).to be true
      end

      it "does not match when value is not in targets" do
        c = condition(operator: "In", values: ["us", "uk"])
        expect(evaluator.evaluate_condition(c, { "country" => "CA" })).to be false
      end
    end

    context "NotIn operator" do
      it "matches when value is not in targets" do
        c = condition(operator: "NotIn", values: ["us", "uk"])
        expect(evaluator.evaluate_condition(c, { "country" => "CA" })).to be true
      end

      it "does not match when value is in targets" do
        c = condition(operator: "NotIn", values: ["us", "uk"])
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be false
      end
    end

    # Issue #1458: when the attribute is a native numeric (Integer/Float, never a
    # boolean), Equals/NotEquals/In/NotIn coerce the condition values to numbers
    # and compare numerically — so 1.0 == "1" — instead of comparing stringified
    # forms ("1.0" != "1"). Mirrors the engine's type-aware path: only these four
    # operators coerce, the literal parse is strict (Float("1abc") raises -> no
    # match), and booleans (not Numeric in Ruby) stay on the string path.
    context "numeric Equals coercion (Issue #1458)" do
      def num_eval(op, value, values, negate: false)
        c = condition(operator: op, attribute: "score", values: values, negate: negate)
        evaluator.evaluate_condition(c, { "score" => value })
      end

      it "matches a Float value against a decimal string target (Equals)" do
        expect(num_eval("Equals", 1.0, ["1.0"])).to be true
      end

      it "matches a Float value against an integer string target (Equals)" do
        expect(num_eval("Equals", 1.0, ["1"])).to be true
      end

      it "matches an Integer value against a decimal string target (Equals)" do
        expect(num_eval("Equals", 1, ["1.0"])).to be true
      end

      it "matches an Integer value against an integer string target (Equals)" do
        expect(num_eval("Equals", 1, ["1"])).to be true
      end

      it "matches a fractional Float value (Equals)" do
        expect(num_eval("Equals", 1.5, ["1.5"])).to be true
      end

      it "does not match a fractional value against a different number (Equals)" do
        expect(num_eval("Equals", 1.5, ["1"])).to be false
      end

      it "matches when a numeric value is in the targets (In)" do
        expect(num_eval("In", 2, ["1", "2.0"])).to be true
      end

      it "does not match when a numeric value is not in the targets (In)" do
        expect(num_eval("In", 3, ["1", "2"])).to be false
      end

      it "does not match when the value equals the target (NotEquals)" do
        expect(num_eval("NotEquals", 1.0, ["1.0"])).to be false
      end

      it "matches when the value differs from the target (NotEquals)" do
        expect(num_eval("NotEquals", 1.0, ["2"])).to be true
      end

      it "matches when a numeric value is not in the targets (NotIn)" do
        expect(num_eval("NotIn", 3, ["1", "2"])).to be true
      end

      it "does not match a non-numeric target (strict parse, Equals)" do
        expect(num_eval("Equals", 1, ["abc"])).to be false
      end

      it "does not match a partially-numeric target (strict parse, Equals)" do
        expect(num_eval("Equals", 1, ["1abc"])).to be false
      end

      it "treats a boolean true as a string (not Numeric) so 1-string does not match" do
        expect(num_eval("Equals", true, ["1"])).to be false
      end

      it "treats a boolean true as a string so 'true' matches via the string path" do
        expect(num_eval("Equals", true, ["true"])).to be true
      end

      it "keeps a String value on the string path (no numeric coercion, Equals)" do
        # "1.0" stringifies to "1.0", which is not equal to "1" lexically.
        expect(num_eval("Equals", "1.0", ["1"])).to be false
      end

      it "keeps a String value on the string path so leading zeros are significant" do
        expect(num_eval("Equals", "01234", ["1234"])).to be false
      end

      it "honors the negate flag on a numeric comparison" do
        # 1 != 2 numerically -> Equals false -> negate -> true.
        expect(num_eval("Equals", 1, ["2"], negate: true)).to be true
      end
    end

    context "MatchesRegex operator" do
      it "matches when value matches regex" do
        c = condition(operator: "MatchesRegex", attribute: "email", values: ['^\w+@gmail\.com$'])
        expect(evaluator.evaluate_condition(c, { "email" => "user@gmail.com" })).to be true
      end

      it "does not match when value does not match regex" do
        c = condition(operator: "MatchesRegex", attribute: "email", values: ['^\w+@gmail\.com$'])
        expect(evaluator.evaluate_condition(c, { "email" => "user@yahoo.com" })).to be false
      end

      it "returns false for invalid regex" do
        c = condition(operator: "MatchesRegex", attribute: "name", values: ["[invalid"])
        expect(evaluator.evaluate_condition(c, { "name" => "test" })).to be false
      end

      it "is case sensitive (engine parity)" do
        c = condition(operator: "MatchesRegex", attribute: "name", values: ["^Alice$"])
        # Exact-case match succeeds; a case-mismatched value does not (mirrors
        # the engine's RegexOptions.None — neither value nor pattern is folded).
        expect(evaluator.evaluate_condition(c, { "name" => "Alice" })).to be true
        expect(evaluator.evaluate_condition(c, { "name" => "alice" })).to be false
      end

      it "honors the (?i) inline case-insensitive flag" do
        c = condition(operator: "MatchesRegex", attribute: "name", values: ["(?i)^alice$"])
        expect(evaluator.evaluate_condition(c, { "name" => "Alice" })).to be true
      end

      it "fails safe (no-match) on catastrophic backtracking instead of hanging (#1460)" do
        # A pathological pattern with a backreference defeats Onigmo's
        # memoization and would otherwise backtrack ~forever. The per-regex
        # timeout (REGEX_TIMEOUT_SECONDS) must fire and be rescued to no-match,
        # mirroring the engine's 100ms guard. The 1s wall-clock assertion proves
        # the call returns promptly rather than hanging.
        c = condition(operator: "MatchesRegex", attribute: "name", values: ['(a|a)+\1+$'])
        ctx = { "name" => ("a" * 60) + "!" }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect(evaluator.evaluate_condition(c, ctx)).to be false
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
      end
    end

    context "GreaterThan operator" do
      it "matches when value is greater" do
        c = condition(operator: "GreaterThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "25" })).to be true
      end

      it "does not match when value is equal" do
        c = condition(operator: "GreaterThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "18" })).to be false
      end

      it "does not match when value is less" do
        c = condition(operator: "GreaterThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "10" })).to be false
      end

      it "returns false for non-numeric values" do
        c = condition(operator: "GreaterThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "abc" })).to be false
      end
    end

    context "GreaterThanOrEqual operator" do
      it "matches when value is equal" do
        c = condition(operator: "GreaterThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "18" })).to be true
      end

      it "matches when value is greater" do
        c = condition(operator: "GreaterThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "25" })).to be true
      end

      it "does not match when value is less" do
        c = condition(operator: "GreaterThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "10" })).to be false
      end
    end

    context "LessThan operator" do
      it "matches when value is less" do
        c = condition(operator: "LessThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "10" })).to be true
      end

      it "does not match when value is equal" do
        c = condition(operator: "LessThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "18" })).to be false
      end
    end

    context "LessThanOrEqual operator" do
      it "matches when value is equal" do
        c = condition(operator: "LessThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "18" })).to be true
      end

      it "matches when value is less" do
        c = condition(operator: "LessThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "10" })).to be true
      end

      it "does not match when value is greater" do
        c = condition(operator: "LessThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "25" })).to be false
      end

      it "returns false for non-numeric target" do
        c = condition(operator: "LessThanOrEqual", attribute: "age", values: ["abc"])
        expect(evaluator.evaluate_condition(c, { "age" => "10" })).to be false
      end
    end

    context "Before operator" do
      it "matches when value is before target" do
        c = condition(operator: "Before", attribute: "date", values: ["2024-01-01"])
        expect(evaluator.evaluate_condition(c, { "date" => "2023-06-15" })).to be true
      end

      it "does not match when value is after target" do
        c = condition(operator: "Before", attribute: "date", values: ["2024-01-01"])
        expect(evaluator.evaluate_condition(c, { "date" => "2024-06-15" })).to be false
      end
    end

    context "After operator" do
      it "matches when value is after target" do
        c = condition(operator: "After", attribute: "date", values: ["2024-01-01"])
        expect(evaluator.evaluate_condition(c, { "date" => "2024-06-15" })).to be true
      end

      it "does not match when value is before target" do
        c = condition(operator: "After", attribute: "date", values: ["2024-01-01"])
        expect(evaluator.evaluate_condition(c, { "date" => "2023-06-15" })).to be false
      end
    end

    # Issue #1455: Before/After must parse both operands as real date-times,
    # normalize to UTC (honoring offsets, assuming UTC when none is present),
    # with a Unix-seconds fallback — mirroring the engine's CompareDateTime.
    # Unparseable values produce NO match (never a lexical string compare).
    context "date parsing semantics (Issue #1455)" do
      def date_eval(op, value, values)
        c = condition(operator: op, attribute: "date", values: values)
        evaluator.evaluate_condition(c, { "date" => value })
      end

      it "normalizes timezone offsets before comparing (Before)" do
        # 12:00+05:00 == 07:00Z, which is before 08:00Z.
        expect(date_eval("Before", "2026-01-01T12:00:00+05:00", ["2026-01-01T08:00:00Z"])).to be true
      end

      it "normalizes timezone offsets before comparing (After)" do
        expect(date_eval("After", "2026-01-01T12:00:00+05:00", ["2026-01-01T08:00:00Z"])).to be false
      end

      it "treats an integer value as Unix seconds (After)" do
        # 1700000000 -> 2023-11-14T22:13:20Z, after 2020.
        expect(date_eval("After", "1700000000", ["2020-01-01T00:00:00Z"])).to be true
      end

      it "treats an integer value as Unix seconds (Before)" do
        expect(date_eval("Before", "1700000000", ["2020-01-01T00:00:00Z"])).to be false
      end

      it "does not fall back to lexical comparison for unparseable input (Before)" do
        # "hello" < "world" lexically, but neither parses as a date -> no match.
        expect(date_eval("Before", "hello", ["world"])).to be false
      end

      it "does not fall back to lexical comparison for unparseable input (After)" do
        expect(date_eval("After", "hello", ["world"])).to be false
      end

      it "assumes UTC when the value carries no offset (Before)" do
        expect(date_eval("Before", "2026-01-01T08:00:00", ["2026-01-01T09:00:00Z"])).to be true
      end

      it "compares full UTC instants (After)" do
        expect(date_eval("After", "2026-06-01T00:00:00Z", ["2026-01-01T00:00:00Z"])).to be true
      end

      it "compares full UTC instants (Before)" do
        expect(date_eval("Before", "2026-06-01T00:00:00Z", ["2026-01-01T00:00:00Z"])).to be false
      end

      it "matches when ANY condition value satisfies the comparison" do
        expect(date_eval("After", "2026-03-01T00:00:00Z",
                         ["2030-01-01T00:00:00Z", "2020-01-01T00:00:00Z"])).to be true
      end

      it "skips unparseable condition values and matches a parseable one" do
        expect(date_eval("Before", "2026-01-01T07:30:00Z",
                         ["garbage", "2026-01-01T08:00:00Z"])).to be true
      end

      it "parses a Unix-seconds condition value" do
        # 1700000000 -> 2023-11-14T22:13:20Z; the value 2023-11-15 is after it.
        expect(date_eval("After", "2023-11-15T00:00:00Z", ["1700000000"])).to be true
      end
    end

    # Issue #1443: numeric/date operators must match if the value satisfies the
    # comparison against ANY supplied condition value (mirroring the server
    # engine), not just values[0].
    context "multi-value relational operators (Issue #1443)" do
      it "GreaterThan matches when a non-first value is satisfied" do
        c = condition(operator: "GreaterThan", attribute: "age", values: ["20", "10"])
        # any(15 > 20, 15 > 10) -> true; values[0]-only would be false
        expect(evaluator.evaluate_condition(c, { "age" => "15" })).to be true
      end

      it "GreaterThan does not match when no value is satisfied" do
        c = condition(operator: "GreaterThan", attribute: "age", values: ["20", "10"])
        expect(evaluator.evaluate_condition(c, { "age" => "5" })).to be false
      end

      it "Before matches when a non-first value is satisfied" do
        c = condition(operator: "Before", attribute: "date", values: ["2020-01-01", "2030-01-01"])
        # any(2025 < 2020, 2025 < 2030) -> true; values[0]-only would be false
        expect(evaluator.evaluate_condition(c, { "date" => "2025-06-15" })).to be true
      end

      it "After matches when a non-first value is satisfied" do
        c = condition(operator: "After", attribute: "date", values: ["2030-01-01", "2020-01-01"])
        # any(2025 > 2030, 2025 > 2020) -> true; values[0]-only would be false
        expect(evaluator.evaluate_condition(c, { "date" => "2025-06-15" })).to be true
      end

      it "returns false (no error) when values is empty" do
        %w[GreaterThan LessThan Before After].each do |op|
          c = condition(operator: op, attribute: "age", values: [])
          expect(evaluator.evaluate_condition(c, { "age" => "15" })).to be false
        end
      end
    end

    # Issue #1434: dedicated semantic-version operators so version targeting
    # compares by precedence instead of as a decimal. Mirrors the JS reference
    # evaluator and the .NET SemverComparer (and the Go/C#/Java/Python ports).
    context "Semver operators" do
      def semver(op, version, values)
        c = condition(operator: op, attribute: "app_version", values: values)
        evaluator.evaluate_condition(c, { "app_version" => version })
      end

      context "SemverGreaterThanOrEqual" do
        it "treats multi-segment versions numerically, not as decimals (regression)" do
          # The decimal path read "2.10.1" as 2.10 and silently returned false.
          expect(semver("SemverGreaterThanOrEqual", "2.10.1", ["2.0"])).to be true
        end

        it "matches an equal version" do
          expect(semver("SemverGreaterThanOrEqual", "2.0.0", ["2.0.0"])).to be true
        end

        it "treats a missing trailing segment as zero (2.0 == 2.0.0)" do
          expect(semver("SemverGreaterThanOrEqual", "2.0", ["2.0.0"])).to be true
          expect(semver("SemverLessThanOrEqual", "2.0", ["2.0.0"])).to be true
        end

        it "does not match a lower version" do
          expect(semver("SemverGreaterThanOrEqual", "1.9.9", ["2.0.0"])).to be false
        end
      end

      context "SemverGreaterThan" do
        it "compares minor segments numerically (2.10 > 2.9)" do
          expect(semver("SemverGreaterThan", "2.10", ["2.9"])).to be true
        end

        it "does not match an equal version" do
          expect(semver("SemverGreaterThan", "2.0.0", ["2.0.0"])).to be false
        end

        it "tolerates a leading v/V prefix on either side" do
          expect(semver("SemverGreaterThan", "v2.1.0", ["V2.0.0"])).to be true
        end
      end

      context "SemverLessThan / SemverLessThanOrEqual" do
        it "matches a lower version" do
          expect(semver("SemverLessThan", "1.0.0", ["1.0.1"])).to be true
        end

        it "does not match a greater version" do
          expect(semver("SemverLessThan", "1.0.2", ["1.0.1"])).to be false
        end
      end

      context "SemverEquals" do
        it "ignores build metadata for precedence" do
          expect(semver("SemverEquals", "1.2.3+build.99", ["1.2.3"])).to be true
        end

        it "does not match different versions" do
          expect(semver("SemverEquals", "1.2.3", ["1.2.4"])).to be false
        end
      end

      context "prerelease precedence (semver §11)" do
        it "ranks a prerelease below the release version" do
          expect(semver("SemverLessThan", "1.0.0-alpha", ["1.0.0"])).to be true
          expect(semver("SemverGreaterThan", "1.0.0", ["1.0.0-alpha"])).to be true
        end

        it "ranks numeric identifiers below alphanumeric ones" do
          expect(semver("SemverLessThan", "1.0.0-1", ["1.0.0-alpha"])).to be true
        end

        it "gives the longer prerelease higher precedence when prefixes are equal" do
          expect(semver("SemverGreaterThan", "1.0.0-alpha.1", ["1.0.0-alpha"])).to be true
        end

        # CLAUDE.md / #1447: alphanumeric prerelease identifiers compare in ASCII
        # order (case-sensitive). Folding to lowercase would invert these.
        it "compares prerelease identifiers case-sensitively in ASCII order" do
          # 'B' (66) sorts before 'a' (97), so -Beta < -alpha.
          expect(semver("SemverLessThan", "1.0.0-Beta", ["1.0.0-alpha"])).to be true
          expect(semver("SemverGreaterThan", "1.0.0-Beta", ["1.0.0-alpha"])).to be false
        end

        it "treats mixed-case identifiers as unequal" do
          expect(semver("SemverEquals", "1.0.0-RC", ["1.0.0-rc"])).to be false
        end
      end

      context "unparseable input" do
        it "does not match when the value is not a version" do
          expect(semver("SemverGreaterThan", "not-a-version", ["1.0.0"])).to be false
        end

        it "skips unparseable targets but still matches a parseable one" do
          expect(semver("SemverGreaterThan", "2.0.0", ["nope", "1.0.0"])).to be true
        end

        it "rejects a non-numeric release segment" do
          expect(semver("SemverEquals", "1.x.0", ["1.0.0"])).to be false
        end
      end

      context "multi-value (any-of, Issue #1443)" do
        it "matches when a non-first value is satisfied" do
          expect(semver("SemverGreaterThan", "1.5.0", ["2.0.0", "1.0.0"])).to be true
        end

        it "returns false (no error) when values is empty" do
          %w[SemverEquals SemverGreaterThan SemverGreaterThanOrEqual
             SemverLessThan SemverLessThanOrEqual].each do |op|
            expect(semver(op, "1.0.0", [])).to be false
          end
        end
      end
    end

    context "unknown operator" do
      it "returns false" do
        c = condition(operator: "Unknown")
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be false
      end
    end

    context "negate flag" do
      it "inverts a true result to false" do
        c = condition(operator: "Equals", negate: true)
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be false
      end

      it "inverts a false result to true" do
        c = condition(operator: "Equals", negate: true)
        expect(evaluator.evaluate_condition(c, { "country" => "UK" })).to be true
      end
    end

    # Issue #2262: an operator this SDK does not recognise means "I cannot
    # evaluate this", NOT "this did not match". Inverting that inability with
    # `negate` would turn it into a match-everyone — the flag served to 100% of
    # traffic. The realistic trigger is a new operator shipped server-side
    # reaching an SDK pinned to an older version. Unrecognised operators fail
    # CLOSED, before negate is applied.
    #
    # Contrast the missing-attribute context below, which legitimately returns
    # `negate`: absence is a determinate fact about the user, whereas an
    # unrecognised operator is not a fact about the user at all.
    context "unrecognised operator" do
      it "does not match when not negated" do
        c = condition(operator: "SomeFutureOperator")
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be false
      end

      it "does not match when negated (fails closed, not open)" do
        c = condition(operator: "SomeFutureOperator", negate: true)
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be false
      end

      # Issue #2374: a MIS-CASED label is not an unknown operator. Underscores
      # are stripped and case folded before dispatch, so every spelling of a
      # known operator resolves to the same one — the shared definition js, go,
      # ruby and php now agree on. Only a name that is not an operator at all
      # reaches the fail-closed path asserted above.
      {
        "equals"     => ["US", true],
        "EQUALS"     => ["US", true],
        "notequals"  => ["CA", true],
        "not_equals" => ["CA", true],
        "NOTEQUALS"  => ["CA", true],
        "NOT_EQUALS" => ["CA", true]
      }.each do |operator, (value, expected)|
        it "resolves mis-cased #{operator} to the known operator" do
          c = condition(operator: operator, values: [value])
          expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be expected
        end
      end

      # The fail-closed rule of #2262 governs UNKNOWN operators. Once an
      # operator resolves, `negate` inverts it normally — so the `false` below
      # is a match that was inverted, not the fail-closed answer it used to be.
      it "applies negate normally to a resolved mis-cased operator" do
        expect(evaluator.evaluate_condition(
          condition(operator: "equals", negate: true), { "country" => "US" }
        )).to be false

        expect(evaluator.evaluate_condition(
          condition(operator: "equals", values: ["CA"], negate: true), { "country" => "US" }
        )).to be true
      end

      # Resolution must not lose the operator's case-sensitivity class: the
      # semver and regex arms read the RAW operands, so a mis-cased spelling
      # has to reach the same arm as the canonical one.
      it "keeps a mis-cased case-sensitive operator case-sensitive" do
        expect(evaluator.evaluate_condition(
          condition(operator: "matchesregex", attribute: "name", values: ["^abc$"]),
          { "name" => "ABC" }
        )).to be false

        expect(evaluator.evaluate_condition(
          condition(operator: "matchesregex", attribute: "name", values: ["^ABC$"]),
          { "name" => "ABC" }
        )).to be true
      end

      # Same hazard on the numeric-coercion lookup: a mis-cased equality
      # operator that skipped it would compare "1" against "1.0" lexically.
      it "keeps a mis-cased equality operator on the numeric path" do
        expect(evaluator.evaluate_condition(
          condition(operator: "not_equals", attribute: "age", values: ["1.0"]),
          { "age" => 1 }
        )).to be false
      end
    end

    context "missing attribute" do
      it "returns false when attribute is absent" do
        c = condition(operator: "Equals")
        expect(evaluator.evaluate_condition(c, {})).to be false
      end

      it "returns true when attribute is absent and negate is true" do
        c = condition(operator: "Equals", negate: true)
        expect(evaluator.evaluate_condition(c, {})).to be true
      end
    end
  end

  describe "#evaluate_conditions" do
    context "empty conditions" do
      it "returns true" do
        expect(evaluator.evaluate_conditions([], "And", {})).to be true
        expect(evaluator.evaluate_conditions([], "Or", {})).to be true
      end
    end

    context "AND logic" do
      it "returns true when all conditions match" do
        conditions = [
          condition(operator: "Equals", attribute: "country", values: ["US"]),
          condition(operator: "Equals", attribute: "plan", values: ["pro"])
        ]
        context = { "country" => "US", "plan" => "pro" }
        expect(evaluator.evaluate_conditions(conditions, "And", context)).to be true
      end

      it "returns false when any condition fails" do
        conditions = [
          condition(operator: "Equals", attribute: "country", values: ["US"]),
          condition(operator: "Equals", attribute: "plan", values: ["pro"])
        ]
        context = { "country" => "US", "plan" => "free" }
        expect(evaluator.evaluate_conditions(conditions, "And", context)).to be false
      end
    end

    context "OR logic" do
      it "returns true when any condition matches" do
        conditions = [
          condition(operator: "Equals", attribute: "country", values: ["US"]),
          condition(operator: "Equals", attribute: "country", values: ["UK"])
        ]
        context = { "country" => "UK" }
        expect(evaluator.evaluate_conditions(conditions, "Or", context)).to be true
      end

      it "returns false when no conditions match" do
        conditions = [
          condition(operator: "Equals", attribute: "country", values: ["US"]),
          condition(operator: "Equals", attribute: "country", values: ["UK"])
        ]
        context = { "country" => "CA" }
        expect(evaluator.evaluate_conditions(conditions, "Or", context)).to be false
      end
    end
  end

  describe "#evaluate_condition_groups" do
    def group(conditions, operator: "And")
      Featureflip::Models::ConditionGroup.new(operator: operator, conditions: conditions)
    end

    context "empty groups" do
      it "returns true for nil" do
        expect(evaluator.evaluate_condition_groups(nil, {})).to be true
      end

      it "returns true for empty array" do
        expect(evaluator.evaluate_condition_groups([], {})).to be true
      end
    end

    context "single group" do
      it "returns true when group conditions match with AND" do
        groups = [
          group([
            condition(operator: "Equals", attribute: "country", values: ["US"]),
            condition(operator: "Equals", attribute: "plan", values: ["pro"])
          ], operator: "And")
        ]
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "US", "plan" => "pro" })).to be true
      end

      it "returns false when any AND condition fails" do
        groups = [
          group([
            condition(operator: "Equals", attribute: "country", values: ["US"]),
            condition(operator: "Equals", attribute: "plan", values: ["pro"])
          ], operator: "And")
        ]
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "US", "plan" => "free" })).to be false
      end

      it "returns true when any OR condition matches" do
        groups = [
          group([
            condition(operator: "Equals", attribute: "country", values: ["US"]),
            condition(operator: "Equals", attribute: "country", values: ["UK"])
          ], operator: "Or")
        ]
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "UK" })).to be true
      end
    end

    context "multiple groups (ANDed together)" do
      it "returns true when all groups match" do
        groups = [
          group([condition(operator: "Equals", attribute: "country", values: ["US"])]),
          group([condition(operator: "Equals", attribute: "plan", values: ["pro"])])
        ]
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "US", "plan" => "pro" })).to be true
      end

      it "returns false when any group fails" do
        groups = [
          group([condition(operator: "Equals", attribute: "country", values: ["US"])]),
          group([condition(operator: "Equals", attribute: "plan", values: ["pro"])])
        ]
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "US", "plan" => "free" })).to be false
      end

      it "supports mixed operators across groups" do
        groups = [
          group([
            condition(operator: "Equals", attribute: "country", values: ["US"]),
            condition(operator: "Equals", attribute: "country", values: ["UK"])
          ], operator: "Or"),
          group([
            condition(operator: "Equals", attribute: "plan", values: ["pro"])
          ], operator: "And")
        ]
        # country=UK matches first group (Or), plan=pro matches second group (And)
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "UK", "plan" => "pro" })).to be true
        # country=CA fails first group
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "CA", "plan" => "pro" })).to be false
      end
    end
  end
end
