require "set"

module Featureflip
  module Evaluation
    # Process-wide, deduplicated warning for a percentage rollout that was skipped
    # because the context has no value for its bucket-by attribute (#4236).
    #
    # Logs once per (flag key, rule id or "fallthrough", bucket_by). The set is
    # capped at MAX_KEYS; once full, unseen keys are dropped silently. Only the
    # flag key, rule id and bucket-by attribute NAME are logged, never a context
    # value.
    module UnbucketableWarnings
      MAX_KEYS = 1000

      @mutex = Mutex.new
      @seen = Set.new

      class << self
        def warn(logger, flag_key, rule_id, bucket_by)
          where = rule_id.nil? ? "fallthrough" : "rule #{rule_id}"
          key = [flag_key, where, bucket_by]

          @mutex.synchronize do
            return if @seen.include?(key) || @seen.size >= MAX_KEYS

            @seen.add(key)
          end

          logger&.warn(
            "[featureflip] Skipped the percentage rollout in flag \"#{flag_key}\" (#{where}): " \
            "the context has no value for \"#{bucket_by}\". " \
            "Pass a stable id in that attribute to include this context in the rollout."
          )
        end

        # Number of distinct keys recorded so far.
        def count
          @mutex.synchronize { @seen.size }
        end

        # Clears the dedup set. For tests.
        def reset
          @mutex.synchronize { @seen.clear }
        end
      end
    end
  end
end
