module Featureflip
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class InitializationError < Error; end

  # Raised when a config payload violates the wire contract — e.g. an enum field
  # arriving as a number where the contract specifies a string.
  #
  # Deliberately NOT raised for an unrecognised enum *string*: that is how a newer
  # server introduces a new operator, and the evaluator already degrades an unknown
  # operator to no-match. Only a TYPE violation is rejected, because that can never
  # be a legitimate newer-server payload. See #2285.
  class MalformedPayloadError < Error; end

  # Raised when the API answers a request with a non-success status. Carries the status
  # so a caller can decide what to do about it.
  #
  # The events flush is the caller that has to: it re-queues a batch a later attempt could
  # plausibly deliver (5xx, 429) and drops one the server will reject identically forever
  # (401/403 = key rejected, 400 = malformed body). Before this the status only existed
  # inside the message string, so every failure looked alike and the batch was dropped
  # either way (#2456).
  #
  # Subclasses Error and keeps the historical "HTTP <code>: <path>" message, so callers
  # rescuing Featureflip::Error — or matching on that message — are unaffected.
  class HttpStatusError < Error
    attr_reader :status

    def initialize(status, path)
      @status = status
      super("HTTP #{status}: #{path}")
    end
  end

  # Raised when a flag or segment carries an enum value this SDK build cannot
  # EVALUATE — an unrecognised `serve.type` or `conditionLogic` (#2402).
  #
  # Distinct from MalformedPayloadError, and the distinction is the whole point. That
  # one means the payload is the wrong SHAPE and is discarded wholesale. This one means
  # the payload is perfectly well-formed and simply describes behaviour a newer server
  # understands and this build does not — so only the containing ENTITY is dropped and
  # the rest of the configuration still applies.
  #
  # Not raised for an unrecognised condition OPERATOR: the evaluator already fails an
  # unknown operator closed (#2262), so the condition just does not match and the flag
  # remains perfectly evaluable. `serve.type` and `conditionLogic` have no such
  # fail-closed arm — each dispatches on a two-way branch and an unrecognised value
  # takes the ELSE arm, silently serving a rollout or matching ANY condition.
  class UnevaluableEntityError < Error; end
end
