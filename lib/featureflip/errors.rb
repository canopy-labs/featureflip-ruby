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
end
