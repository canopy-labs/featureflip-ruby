require_relative "condition_evaluator"
require_relative "bucketing"

module Featureflip
  module Evaluation
    class Evaluator
      # Mirrors packages/js-sdk/src/core/evaluator.ts. The guard uses `>` (not `>=`)
      # so a chain of MAX_PREREQUISITE_DEPTH + 1 nested flags trips the cap — matches
      # the JS reference implementation; see prerequisite_spec.rb depth test.
      MAX_PREREQUISITE_DEPTH = 10

      def initialize
        @condition_evaluator = ConditionEvaluator.new
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
          conditions_match = if rule.segment_key && get_segment
            segment = get_segment.call(rule.segment_key)
            if segment
              @condition_evaluator.evaluate_conditions(
                segment.conditions, segment.condition_logic, context
              )
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
            variation = flag.get_variation(variation_key)
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
        variation = flag.get_variation(variation_key)
        result = Models::EvaluationDetail.new(
          value: variation&.value,
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
        Models::EvaluationDetail.new(
          value: variation&.value,
          reason: reason,
          variation_key: flag.off_variation,
          prerequisite_key: prerequisite_key
        )
      end

      def resolve_serve(serve, context)
        if serve.type == "Fixed"
          serve.variation || ""
        else
          resolve_rollout(serve, context)
        end
      end

      def resolve_rollout(serve, context)
        bucket_by = serve.bucket_by || "userId"
        bucket_value = context[bucket_by]
        # Alias "userId" <-> "user_id" for the built-in user identifier
        bucket_value = context["user_id"] if bucket_value.nil? && bucket_by == "userId"
        bucket_value = context["userId"] if bucket_value.nil? && bucket_by == "user_id"
        bucket_value_str = bucket_value.nil? ? "" : bucket_value.to_s

        bucket = Bucketing.compute_bucket(serve.salt || "", bucket_value_str)

        cumulative = 0
        (serve.variations || []).each do |wv|
          cumulative += wv.weight
          return wv.key if bucket < cumulative
        end

        serve.variations&.last&.key || ""
      end
    end
  end
end
