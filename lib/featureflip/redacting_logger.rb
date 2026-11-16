module Featureflip
  # Strips the SDK key out of anything the SDK logs (#5167).
  #
  # Failure paths report the underlying exception verbatim, so a config-load failure is
  # never silent. That exception can come from a transport the SDK does not control, and
  # the SDK sets the key as the Authorization header on every request: a client that
  # quotes request headers in its message would hand the credential to whatever the host
  # logs to (#5152 was the same leak from a call site).
  #
  # Applied once, as a decorator around the resolved logger when a core is built, so it
  # covers every call site that exists today and any added later, and the default
  # logger too -- stdout is no safer a place for a credential than an aggregator.
  #
  # @api private
  class RedactingLogger
    REPLACEMENT = "[redacted]".freeze

    # Below this the value is not treated as a credential. A real key is always 54
    # characters; redacting a short one corrupts every line it appears inside (with the
    # key "k", "skipped" becomes "s[redacted]ipped"). A string too short to be a
    # Featureflip key cannot authenticate, so there is nothing to protect.
    MIN_REDACTABLE_LENGTH = 20

    # Independent of any logger, so the exceptions the SDK raises can be scrubbed even
    # when the host configured no logger.
    def self.redact(text, secret)
      secret = secret.to_s
      return text unless text.is_a?(String) && secret.length >= MIN_REDACTABLE_LENGTH

      text.gsub(secret, REPLACEMENT)
    end

    def self.wrap(logger, secret)
      return logger if logger.nil? || logger.is_a?(RedactingLogger)

      new(logger, secret)
    end

    def initialize(inner, secret)
      @inner = inner
      @secret = secret.to_s
    end

    %i[debug info warn error fatal unknown].each do |name|
      define_method(name) do |message = nil, &block|
        if block
          @inner.public_send(name, redact_object(message)) { redact_object(block.call) }
        else
          @inner.public_send(name, redact_object(message))
        end
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      if block
        @inner.add(severity, redact_object(message), redact_object(progname)) { redact_object(block.call) }
      else
        @inner.add(severity, redact_object(message), redact_object(progname))
      end
    end
    alias_method :log, :add

    def <<(message)
      @inner << redact_object(message)
    end

    def progname
      redact_object(@inner.progname)
    end

    def method_missing(name, *args, **kwargs, &block)
      return super unless @inner.respond_to?(name)

      @inner.public_send(name, *args, **kwargs, &block)
    end

    def respond_to_missing?(name, include_private = false)
      @inner.respond_to?(name) || super
    end

    def redact(text)
      self.class.redact(text, @secret)
    end

    private

    def redactable?
      @secret.length >= MIN_REDACTABLE_LENGTH
    end

    def redact_object(object)
      return object unless redactable?

      case object
      when String then redact(object)
      when Exception then redact_exception(object)
      when nil, Symbol, Numeric, true, false then object
      else
        # The logger would render this with #inspect; only touch it when the key is in it.
        # Skipped entirely when the logger would discard the line anyway.
        return object unless @inner.respond_to?(:level) && @inner.level.to_i <= Logger::FATAL

        text = object.inspect
        text.include?(@secret) ? redact(text) : object
      end
    end

    # Logger's formatter prints "message (Class)" plus the backtrace. A clean exception
    # is passed through as the original object (structured consumers keep it); a dirty
    # one is rendered from the redacted message so the sink never sees the original.
    def redact_exception(error)
      message = error.message.to_s
      backtrace = Array(error.backtrace)
      return error unless message.include?(@secret) || backtrace.any? { |l| l.include?(@secret) }

      lines = ["#{redact(message)} (#{error.class})"]
      lines.concat(backtrace.map { |l| redact(l) })
      lines.join("\n")
    end
  end
end
