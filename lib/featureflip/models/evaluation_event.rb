module Featureflip
  module Models
    # The payload handed to every registered evaluation inspector, once per
    # variation call. This is the frozen cross-SDK inspector contract (see
    # docs/superpowers/specs/2026-07-13-sdk-onevaluation-inspector-design.md),
    # spelled in Ruby snake_case:
    #
    #   flag_key         the flag key evaluated
    #   context          the full evaluation context -- a copy, so mutating it
    #                    cannot affect the caller's hash
    #   value            the value the caller actually receives (default applied)
    #   variation_key    winning arm; nil on flag-not-found and on error
    #   reason           this SDK's native reason string (PascalCase, matching
    #                    EvaluationDetail#reason -- deliberately NOT converted)
    #   rule_id          set only on a rule match
    #   prerequisite_key set only on a prerequisite failure
    #   timestamp        ISO-8601 string
    EvaluationEvent = Struct.new(
      :flag_key, :context, :value, :variation_key, :reason,
      :rule_id, :prerequisite_key, :timestamp,
      keyword_init: true
    ) do
      def initialize(flag_key:, context:, value:, reason:, timestamp:,
                     variation_key: nil, rule_id: nil, prerequisite_key: nil)
        super
      end
    end
  end
end
