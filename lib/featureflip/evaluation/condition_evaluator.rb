require "time"

module Featureflip
  module Evaluation
    class ConditionEvaluator
      # Per-regex match timeout (seconds) for MatchesRegex, mirroring the
      # engine's 100ms RegexMatchTimeout guard against catastrophic
      # backtracking / ReDoS (#1460). Requires Ruby >= 3.2 (gemspec floor),
      # which added the Regexp `timeout:` keyword.
      REGEX_TIMEOUT_SECONDS = 0.1

      def evaluate_condition(condition, context)
        attr_value = context[condition.attribute]

        return condition.negate if attr_value.nil?

        # Issue #1458: when the attribute is a native numeric (Integer/Float —
        # Ruby's `true`/`false` are NOT Numeric, so booleans are naturally
        # excluded), the equality-family operators coerce the condition values to
        # numbers and compare numerically, so 1.0 matches "1". This mirrors the
        # engine's type-aware path and runs BEFORE stringification — a String
        # attribute (even "1.0") stays on the string path below.
        if attr_value.is_a?(Numeric) && NUMERIC_EQUALITY_OPERATORS.include?(condition.operator)
          return evaluate_numeric_equality(condition, attr_value)
        end

        # Pass the raw (case-preserved) strings to the operator dispatcher.
        # Most operators compare case-insensitively and downcase internally, but
        # the semver operators rely on case-sensitive prerelease precedence
        # (semver §11), so the original casing must survive to that point.
        str_value = attr_value.to_s
        targets = condition.values.map(&:to_s)

        result = evaluate_operator(condition.operator, str_value, targets)

        # Issue #2262: an unrecognised operator fails CLOSED. `!nil` is `true`
        # in Ruby, so without this guard a negated unknown operator would match
        # every user and roll the flag out to 100% of traffic. The realistic
        # trigger is a new operator shipped server-side reaching an SDK pinned
        # to an older version.
        return false if result.nil?

        condition.negate ? !result : result
      end

      def evaluate_conditions(conditions, logic, context)
        return true if conditions.empty?

        if logic == "And"
          conditions.all? { |c| evaluate_condition(c, context) }
        else
          conditions.any? { |c| evaluate_condition(c, context) }
        end
      end

      def evaluate_condition_groups(condition_groups, context)
        return true if condition_groups.nil? || condition_groups.empty?

        condition_groups.all? do |group|
          evaluate_conditions(group.conditions, group.operator, context)
        end
      end

      private

      # The equality-family operators that get type-aware numeric coercion when
      # the attribute is a native Numeric (Issue #1458). Relational/string ops
      # are deliberately excluded — only these four coerce.
      NUMERIC_EQUALITY_OPERATORS = %w[Equals NotEquals In NotIn].freeze
      private_constant :NUMERIC_EQUALITY_OPERATORS

      # A parsed semantic version: the release core as dot-separated numeric
      # segments plus an optional dot-separated prerelease identifier list.
      SemverVersion = Struct.new(:release, :prerelease)
      private_constant :SemverVersion

      # The ONLY characters trimmed from a date operand, and the whole of the
      # operand's permitted whitespace: U+0009..U+000D plus U+0020 -- exactly the
      # class the engine's NumberStyles.Integer accepts via AllowLeadingWhite |
      # AllowTrailingWhite.
      #
      # String#strip is deliberately NOT used: it also strips NUL, so "\0005" was
      # trimmed to "5" and matched here while the engine rejected it (#2468).
      OPERAND_WHITESPACE = "\t\n\v\f\r "
      private_constant :OPERAND_WHITESPACE

      # Characters no date operand may contain: a NUL or other control character, or
      # a non-ASCII whitespace/format character. An interior ASCII space is allowed
      # -- it is the ISO-8601 date/time separator.
      FORBIDDEN_OPERAND_CHAR =
        /[\u0000-\u001f\u007f-\u009f\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]/
      private_constant :FORBIDDEN_OPERAND_CHAR

      # The ISO-8601 grammar a date operand may use: a calendar date, optionally
      # followed by a time (seconds and fractional seconds optional) and an optional
      # offset in either extended (+05:00 / Z) or basic (+0500) form. The separator
      # may be "T" or a space -- the engine accepts both, but Time.iso8601 rejects
      # the space, which is why ruby alone read "2024-01-01 00:00:00" as no-match
      # (#2468).
      ISO_OPERAND =
        /\A(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?\z/
      private_constant :ISO_OPERAND

      def evaluate_operator(operator, value, targets)
        # Case-insensitive views for the string/relational/date operators.
        ci_value = value.downcase
        ci_targets = targets.map(&:downcase)

        case operator
        when "Equals"
          ci_targets.any? { |t| ci_value == t }
        when "NotEquals"
          ci_targets.all? { |t| ci_value != t }
        when "Contains"
          ci_targets.any? { |t| ci_value.include?(t) }
        when "NotContains"
          ci_targets.all? { |t| !ci_value.include?(t) }
        when "StartsWith"
          ci_targets.any? { |t| ci_value.start_with?(t) }
        when "EndsWith"
          ci_targets.any? { |t| ci_value.end_with?(t) }
        when "In"
          ci_targets.include?(ci_value)
        when "NotIn"
          !ci_targets.include?(ci_value)
        when "MatchesRegex"
          # Case-sensitive matching on the original-case value and pattern,
          # mirroring the engine (RegexOptions.None). Case-insensitivity is
          # opt-in via the (?i) inline flag in the pattern.
          #
          # A per-regex timeout bounds catastrophic backtracking / ReDoS like
          # the engine's 100ms guard (#1460). rescue RegexpError covers BOTH an
          # invalid pattern AND Regexp::TimeoutError (a RegexpError subclass),
          # so either fails safe to no-match.
          targets.any? do |t|
            Regexp.new(t, timeout: REGEX_TIMEOUT_SECONDS).match?(value)
          rescue RegexpError
            false
          end
        # Relational operators match if the value satisfies the comparison
        # against ANY condition value (mirroring the server engine), not just
        # values[0]. `.any?` over an empty array is false, so empty values
        # returns false without error.
        when "GreaterThan"
          ci_targets.any? { |t| compare_numeric(ci_value, t, :>) }
        when "GreaterThanOrEqual"
          ci_targets.any? { |t| compare_numeric(ci_value, t, :>=) }
        when "LessThan"
          ci_targets.any? { |t| compare_numeric(ci_value, t, :<) }
        when "LessThanOrEqual"
          ci_targets.any? { |t| compare_numeric(ci_value, t, :<=) }
        # Date operators compare against the RAW value/targets, not the
        # lowercased copies: downcasing breaks ISO-8601 parsing (the "Z" UTC
        # designator becomes "z", which is not valid). Both operands are parsed
        # to UTC instants — offsets are honored, no-offset strings are assumed
        # UTC, and a bare integer is treated as Unix seconds — so an unparseable
        # operand matches nothing instead of falling back to a string compare.
        when "Before"
          targets.any? { |t| compare_datetime(value, t, :<) }
        when "After"
          targets.any? { |t| compare_datetime(value, t, :>) }
        # Semantic-version operators compare against the RAW value/targets:
        # prerelease precedence is case-sensitive (semver §11), so the casing
        # preserved by `evaluate_condition` must not be folded here. An
        # unparseable version matches nothing, like the numeric/date operators.
        when "SemverEquals"
          targets.any? { |t| compare_semver(value, t, :==) }
        when "SemverGreaterThan"
          targets.any? { |t| compare_semver(value, t, :>) }
        when "SemverGreaterThanOrEqual"
          targets.any? { |t| compare_semver(value, t, :>=) }
        when "SemverLessThan"
          targets.any? { |t| compare_semver(value, t, :<) }
        when "SemverLessThanOrEqual"
          targets.any? { |t| compare_semver(value, t, :<=) }
        else
          # Unrecognised operator. `nil` — NOT `false` — so the caller can tell
          # "cannot evaluate" apart from "evaluated, did not match"; only the
          # latter may be inverted by `negate` (#2262).
          nil
        end
      end

      # Type-aware numeric equality for a native-Numeric attribute (Issue #1458).
      # Coerces each condition value with a strict literal parse and compares it
      # numerically against the attribute. Equals/In match if ANY value is equal;
      # NotEquals/NotIn are their negation. The `negate` flag is then applied,
      # mirroring `evaluate_condition`'s tail.
      def evaluate_numeric_equality(condition, attr_value)
        target = attr_value.to_f
        any_equal = condition.values.any? do |v|
          n = parse_numeric(v)
          n && n == target
        end

        positive = NUMERIC_EQUALITY_POSITIVE_OPERATORS.include?(condition.operator)
        result = positive ? any_equal : !any_equal
        condition.negate ? !result : result
      end

      # Equals/In are the "positive" members of the equality family (match on
      # equality); NotEquals/NotIn negate the same any-equal test.
      NUMERIC_EQUALITY_POSITIVE_OPERATORS = %w[Equals In].freeze
      private_constant :NUMERIC_EQUALITY_POSITIVE_OPERATORS

      # Strict literal parse of a condition value to a Float, reusing the same
      # `Float()` approach as `compare_numeric`: a partial number like "1abc"
      # raises and yields nil (no match), matching the engine's strict parse.
      def parse_numeric(value)
        Float(value)
      rescue ArgumentError, TypeError
        nil
      end

      def compare_numeric(value, target, op)
        val = Float(value)
        tgt = Float(target)
        val.send(op, tgt)
      rescue ArgumentError, TypeError
        false
      end

      # Compares `value` and `target` as UTC date-time instants and tests the
      # ordering against `op` (:< for Before, :> for After). Returns false when
      # either side is not parseable, mirroring how `compare_numeric` treats
      # non-numeric input (no lexical-string fallback).
      def compare_datetime(value, target, op)
        left = parse_datetime(value)
        right = parse_datetime(target)
        return false if left.nil? || right.nil?

        left.send(op, right)
      end

      # Parses a date-time to a UTC `Time`, mirroring the engine's
      # TryParseDateTime. ISO-8601 strings honor any timezone offset; a string
      # without an offset is assumed UTC. A bare integer is treated as Unix time
      # in seconds. Returns nil when the input parses as neither.
      # DateTimeOffset.MinValue / MaxValue as unix seconds -- the exact bounds the
      # engine's FromUnixTimeSeconds accepts before throwing (#2432).
      MIN_UNIX_SECONDS = -62_135_596_800
      MAX_UNIX_SECONDS = 253_402_300_799

      # Rewrites an accepted ISO operand into the strict extended form Time.iso8601
      # parses: "T" separator, seconds present, offset spelled "+HH:MM" or "Z".
      # Returns nil when the operand is not an accepted ISO shape.
      def canonicalize_iso(s)
        m = ISO_OPERAND.match(s)
        return nil if m.nil?

        date, hh, mm, ss, frac, off = m.captures
        return "#{date}T00:00:00Z" if hh.nil?

        # The engine's DateTimeOffset.TryParse rejects hour 24 outright rather than
        # rolling it over to 00:00 the next day, which is what Time.iso8601 does.
        return nil if hh >= "24"

        ss ||= "00"
        off =
          if off.nil? then "Z"
          elsif off.length == 5 && off != "Z" then "#{off[0, 3]}:#{off[3, 2]}"
          else off
          end
        "#{date}T#{hh}:#{mm}:#{ss}#{frac}#{off}"
      end

      def parse_datetime(value)
        s = value.to_s
        # Trim exactly the engine's whitespace class, then reject anything still
        # carrying a character no operand may contain.
        s = s.gsub(/\A[#{Regexp.escape(OPERAND_WHITESPACE)}]+|[#{Regexp.escape(OPERAND_WHITESPACE)}]+\z/, "")
        return nil if s.empty? || s.match?(FORBIDDEN_OPERAND_CHAR)

        iso = canonicalize_iso(s)
        if iso
          begin
            # Offset-less forms were canonicalized to an explicit "Z", mirroring
            # DateTimeOffset.TryParse with AssumeUniversal.
            return Time.iso8601(iso).utc
          rescue ArgumentError
            # A syntactically-valid but non-existent date (e.g. 2024-02-31) --
            # fall through to the Unix-seconds fallback, which will also reject it.
          end
        end

        # Integer fallback: treat a bare integer as Unix time in seconds.
        #
        # Out-of-range seconds match NOTHING rather than resolving to a far-future
        # instant: the engine's FromUnixTimeSeconds throws outside DateTimeOffset's
        # range and TryParseDateTime returns false. Ruby's Time has a far wider range
        # and would happily accept the value, so the bound has to be explicit. The
        # case that matters in practice is a MILLISECONDS timestamp pasted where
        # seconds belong, which would otherwise land in the year 55829 and satisfy
        # every `After` comparison (#2432).
        #
        # The sign class matches the engine's `long.TryParse` with
        # `NumberStyles.Integer` (`AllowLeadingWhite | AllowTrailingWhite |
        # AllowLeadingSign`), so a leading "+" is accepted deliberately rather than
        # incidentally, and `Integer()` reads it the same way. Omitting it made "+5"
        # an unparseable string matching NOTHING here while the engine and four other
        # SDKs read it as five seconds past the epoch (#2458).
        #
        # The whitespace flags now match too: the trim above is exactly
        # `AllowLeadingWhite`/`AllowTrailingWhite`'s class, and anything outside it
        # was already rejected by FORBIDDEN_OPERAND_CHAR (#2468).
        if s.match?(/\A[+-]?\d+\z/)
          begin
            # Base 10 EXPLICITLY. Bare `Integer(s)` honours Ruby's literal base
            # prefixes, so a leading zero means OCTAL: "0500" became 320 rather than
            # 500, and "0800" raised ArgumentError (8 is not an octal digit) and
            # matched nothing at all. Every other implementation parses base 10 --
            # the engine's `long.TryParse`, go's `ParseInt(s, 10, 64)`, java's
            # `Long.parseLong`, python's `int()`, php's `(int)` cast and js's
            # `Number()` -- so ruby was alone in reading a zero-padded unix timestamp
            # as a different instant. Pinned by `c-date-unix-leading-zero-*` (#2458).
            seconds = Integer(s, 10)
            return nil if seconds < MIN_UNIX_SECONDS || seconds > MAX_UNIX_SECONDS

            return Time.at(seconds).utc
          rescue RangeError, ArgumentError
            return nil
          end
        end

        nil
      end

      # Compares `value` and `target` as semantic versions and tests the
      # resulting precedence sign (-1/0/1) against `op`. Returns false when
      # either side is not a parseable version, mirroring how `compare_numeric`
      # treats non-numeric input.
      def compare_semver(value, target, op)
        left = parse_semver(value)
        right = parse_semver(target)
        return false if left.nil? || right.nil?

        compare_semver_parts(left, right).send(op, 0)
      end

      # Parses a semantic version (https://semver.org). Returns a SemverVersion,
      # or nil when the release core is missing or any release segment is
      # non-numeric. Tolerant of an optional leading "v"/"V", "+build" metadata
      # (ignored for precedence), and an optional "-prerelease" suffix.
      def parse_semver(value)
        s = value.strip
        return nil if s.empty?

        # Optional leading "v"/"V".
        s = s[1..] if s.start_with?("v", "V")

        # Build metadata ("+...") does not affect precedence.
        plus = s.index("+")
        s = s[0...plus] if plus

        # Split the release core from the optional "-prerelease" suffix.
        core = s
        prerelease = []
        dash = s.index("-")
        if dash
          core = s[0...dash]
          pre = s[(dash + 1)..]
          return nil if pre.empty? # trailing "-" with no identifiers is malformed

          # `split(".", -1)` keeps trailing empty fields so "rc." / "1.0.-x" are
          # rejected; the default `split` would silently drop them.
          prerelease = pre.split(".", -1)
          return nil if prerelease.any?(&:empty?)
        end

        return nil if core.empty?

        release = core.split(".", -1)
        return nil unless release.all? { |seg| all_digits?(seg) }

        SemverVersion.new(release, prerelease)
      end

      # Compares two parsed versions by semantic-version precedence: release
      # segments first (missing trailing segments treated as 0), then
      # prerelease. Returns -1, 0, or 1.
      def compare_semver_parts(a, b)
        [a.release.length, b.release.length].max.times do |i|
          seg_a = a.release[i] || "0"
          seg_b = b.release[i] || "0"
          cmp = compare_numeric_string(seg_a, seg_b)
          return cmp unless cmp.zero?
        end

        compare_prerelease(a.prerelease, b.prerelease)
      end

      # Compares two prerelease identifier lists per semver §11. A version with
      # no prerelease ranks above one that has a prerelease.
      def compare_prerelease(a, b)
        return 0 if a.empty? && b.empty?
        return 1 if a.empty?
        return -1 if b.empty?

        [a.length, b.length].min.times do |i|
          cmp = compare_prerelease_id(a[i], b[i])
          return cmp unless cmp.zero?
        end

        # All shared identifiers equal: the longer prerelease has higher precedence.
        a.length <=> b.length
      end

      # Compares two prerelease identifiers: numeric identifiers compare
      # numerically and rank below alphanumeric ones; alphanumeric identifiers
      # compare in ASCII sort order (case-sensitive) per semver §11.
      def compare_prerelease_id(a, b)
        a_num = all_digits?(a)
        b_num = all_digits?(b)
        return compare_numeric_string(a, b) if a_num && b_num
        return -1 if a_num
        return 1 if b_num

        a <=> b
      end

      # Compares two all-digit strings as non-negative integers without parsing
      # (overflow-free): strip leading zeros, then the longer string is the
      # larger number; equal lengths compare ordinally. Returns -1, 0, or 1.
      def compare_numeric_string(a, b)
        a = a.sub(/\A0+/, "")
        b = b.sub(/\A0+/, "")
        return a.length <=> b.length unless a.length == b.length

        a <=> b
      end

      # Reports whether `s` is non-empty and contains only ASCII digits.
      def all_digits?(s)
        s.match?(/\A[0-9]+\z/)
      end
    end
  end
end
