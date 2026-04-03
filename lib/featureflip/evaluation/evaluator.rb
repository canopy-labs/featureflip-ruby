require_relative "condition_evaluator"
require_relative "bucketing"

module Featureflip
  module Evaluation
    class Evaluator
      def initialize
        @condition_evaluator = ConditionEvaluator.new
      end

      def evaluate(flag, context, get_segment: nil)
        unless flag.enabled
          variation = flag.get_variation(flag.off_variation)
          return Models::EvaluationDetail.new(
            value: variation&.value,
            reason: "FlagDisabled",
            variation_key: flag.off_variation
          )
        end

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
            return Models::EvaluationDetail.new(
              value: variation&.value,
              reason: "RuleMatch",
              rule_id: rule.id,
              variation_key: variation_key
            )
          end
        end

        variation_key = resolve_serve(flag.fallthrough, context)
        variation = flag.get_variation(variation_key)
        Models::EvaluationDetail.new(
          value: variation&.value,
          reason: "Fallthrough",
          variation_key: variation_key
        )
      end

      private

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
