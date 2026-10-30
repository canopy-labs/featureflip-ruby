require_relative "context_attribute"
require_relative "condition_evaluator"
require_relative "bucketing"
require_relative "canonical_number"
require_relative "unbucketable_warnings"

module Featureflip
  module Evaluation
    class Evaluator
      # Mirrors packages/js-sdk/src/core/evaluator.ts. The guard uses `>` (not `>=`)
      # so a chain of MAX_PREREQUISITE_DEPTH + 1 nested flags trips the cap — matches
      # the JS reference implementation; see prerequisite_spec.rb depth test.
      MAX_PREREQUISITE_DEPTH = 10

      def initialize(logger: nil)
        @condition_evaluator = ConditionEvaluator.new
        @logger = logger
      end

      def evaluate(flag, context, get_segment: nil, all_flags: {})
        evaluate_with_shared_memo(flag, context, get_segment: get_segment, all_flags: all_flags, memo: {})
      end

      def evaluate_with_shared_memo(flag, context, all_flags:, memo:, get_segment: nil)
        evaluate_internal(flag, context, get_segment, all_flags, 0, memo)
      end

      private

      def evaluate_internal(flag, context, get_segment, all_flags, depth, memo)
        if depth > MAX_PREREQUISITE_DEPTH
          return off_result(flag, reason: "Error")
        end

        unless flag.enabled
          return off_result(flag, reason: "FlagDisabled")
        end

        prereq_failure = resolve_prerequisites(flag, context, get_segment, all_flags, depth, memo)
        return prereq_failure if prereq_failure

        sorted_rules = flag.rules.sort_by(&:priority)
        sorted_rules.each do |rule|
          conditions_match = if rule.segment_key && !rule.segment_key.empty?
            # A segment-keyed rule must resolve its segment to match. If the
            # segment source isn't wired (get_segment is nil), or the segment
            # can't be found, fail closed (no match) -- mirroring the engine +
            # C# SDK -- rather than falling through to the rule's condition
            # groups (which match unconditionally when empty). See #1459.
            if get_segment
              segment = get_segment.call(rule.segment_key)
              if segment
                @condition_evaluator.evaluate_conditions(
                  segment.conditions, segment.condition_logic, context
                )
              else
                false
              end
            else
              false
            end
          else
            @condition_evaluator.evaluate_condition_groups(
              rule.condition_groups, context
            )
          end

          if conditions_match
            variation_key = resolve_serve(rule.serve, context)
            # A rollout that can't bucket the context doesn't match; fall to the next rule (#4236).
            if variation_key.nil?
              warn_unbucketable(flag, rule.id, rule.serve)
              next
            end

            # A served key that names no variation is malformed config: report Error (no
            # rule id) with the served key, like the engine's ServeVariation (#4236).
            variation = flag.get_variation(variation_key)
            if variation.nil?
              result = Models::EvaluationDetail.new(value: nil, reason: "Error", variation_key: variation_key)
              memo[flag.key] = result
              return result
            end

            result = Models::EvaluationDetail.new(
              value: variation&.value,
              reason: "RuleMatch",
              rule_id: rule.id,
              variation_key: variation_key
            )
            memo[flag.key] = result
            return result
          end
        end

        variation_key = resolve_serve(flag.fallthrough, context)
        if variation_key.nil?
          warn_unbucketable(flag, nil, flag.fallthrough)
          variation_key = flag.fallthrough.variation || ""
        end
        variation = flag.get_variation(variation_key)
        if variation.nil?
          result = Models::EvaluationDetail.new(value: nil, reason: "Error", variation_key: variation_key)
          memo[flag.key] = result
          return result
        end
        result = Models::EvaluationDetail.new(
          value: variation.value,
          reason: "Fallthrough",
          variation_key: variation_key
        )
        memo[flag.key] = result
        result
      end

      # Returns nil when all prerequisites pass; otherwise returns the off-variation
      # result for the flag and memoises it under flag.key. Mirrors the per-branch
      # memo writes in the JS SDK evaluator.
      def resolve_prerequisites(flag, context, get_segment, all_flags, depth, memo)
        prerequisites = flag.prerequisites || []
        prerequisites.each do |prereq|
          key = prereq.prerequisite_flag_key
          prereq_result = memo[key]

          unless prereq_result
            prereq_flag = all_flags[key]
            unless prereq_flag
              return memoise(memo, flag.key, off_result(flag, reason: "PrerequisiteFailed", prerequisite_key: key))
            end

            prereq_result = evaluate_internal(prereq_flag, context, get_segment, all_flags, depth + 1, memo)
            memo[key] = prereq_result
          end

          if prereq_result.reason == "Error"
            return memoise(memo, flag.key, off_result(flag, reason: "Error"))
          end

          if prereq_result.variation_key != prereq.expected_variation_key
            return memoise(memo, flag.key, off_result(flag, reason: "PrerequisiteFailed", prerequisite_key: key))
          end
        end
        nil
      end

      def memoise(memo, key, result)
        memo[key] = result
        result
      end

      def off_result(flag, reason:, prerequisite_key: nil)
        variation = flag.get_variation(flag.off_variation)
        # An off variation the flag doesn't define is malformed config: report Error
        # (value nil, the key kept), like the engine's ServeVariation (#4236).
        if variation.nil?
          return Models::EvaluationDetail.new(value: nil, reason: "Error", variation_key: flag.off_variation)
        end

        Models::EvaluationDetail.new(
          value: variation.value,
          reason: reason,
          variation_key: flag.off_variation,
          prerequisite_key: prerequisite_key
        )
      end

      def warn_unbucketable(flag, rule_id, serve)
        UnbucketableWarnings.warn(@logger, flag.key, rule_id, serve.bucket_by || "user_id")
      end

      # Returns the variation key to serve, or nil when a Rollout serve can't bucket
      # the context (see resolve_rollout). A Fixed serve never returns nil.
      def resolve_serve(serve, context)
        if serve.type == "Fixed"
          serve.variation || ""
        else
          resolve_rollout(serve, context)
        end
      end

      def resolve_rollout(serve, context)
        bucket_by = serve.bucket_by || "user_id"
        # "user_id" and "userId" resolve the same identity (user_id first).
        bucket_value = ContextAttribute.resolve(context, bucket_by)
        bucket_value_str =
          # An Array or Hash (a JSON array or object, empty or not) has no spelling every
          # SDK shares, so it can't be bucketed, like a missing value (#4572).
          if bucket_value.nil? || bucket_value.is_a?(Array) || bucket_value.is_a?(Hash) then ""
          elsif bucket_value.is_a?(Float) then CanonicalNumber.format(bucket_value)
          elsif defined?(::BigDecimal) && bucket_value.is_a?(::BigDecimal) then CanonicalNumber.format_big_decimal(bucket_value)
          else bucket_value.to_s
          end

        # A Rollout serve can arrive with no weighted variations -- env-level PercentageRollout
        # has nowhere to store per-variation weights, so the mapper emits type=Rollout with no
        # variations (#1469). Degrade to the default fixed variation instead of returning an
        # empty key. Mirrors the engine + C#/Java SDK evaluators.
        return serve.variation || "" if (serve.variations || []).empty?

        # A missing, nil, empty or non-scalar bucket value can't be bucketed: return nil so the caller
        # skips the rule (or serves the fallthrough's variation) instead of hashing the empty
        # string into an arbitrary bucket. Whitespace, "0", 0 and false bucket normally (#4236).
        return nil if bucket_value_str == ""

        bucket = Bucketing.compute_bucket(serve.salt || "", bucket_value_str)

        cumulative = 0
        (serve.variations || []).each do |wv|
          cumulative += wv.weight
          return wv.key if bucket < cumulative
        end

        # Guaranteed non-empty: the no-variations case returned the default above.
        serve.variations.last.key
      end
    end
  end
end
