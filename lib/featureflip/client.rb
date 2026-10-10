module Featureflip
  class Client
    private_class_method :new

    NOOP_UNSUBSCRIBE = -> {}.freeze
    private_constant :NOOP_UNSUBSCRIBE

    def self.get(sdk_key = nil, config: nil)
      sdk_key ||= ENV["FEATUREFLIP_SDK_KEY"]
      raise ConfigurationError, "SDK key is required. Pass sdk_key parameter or set FEATUREFLIP_SDK_KEY env var." unless sdk_key

      config ||= Config.new
      core = SharedCore._get_or_create(sdk_key, config)
      new(core)
    end

    def self.for_testing(flags)
      core = SharedCore._create_for_testing(flags)
      new(core)
    end

    # A closed handle reports false (#2287). Every variation accessor here was
    # already guarded, so a closed client correctly served defaults while still
    # claiming to be initialized. close releases the core -- stopping streaming
    # and polling -- so the store it would read can never update again.
    def initialized?
      return false if @closed
      @core.initialized?
    end

    def bool_variation(key, context, default_value)
      return default_value if @closed
      @core.bool_variation(key, context, default_value)
    end

    def string_variation(key, context, default_value)
      return default_value if @closed
      @core.string_variation(key, context, default_value)
    end

    def number_variation(key, context, default_value)
      return default_value if @closed
      @core.number_variation(key, context, default_value)
    end

    def json_variation(key, context, default_value)
      return default_value if @closed
      @core.json_variation(key, context, default_value)
    end

    def variation_detail(key, context, default_value)
      if @closed
        return Models::EvaluationDetail.new(value: default_value, reason: "Error")
      end
      @core.variation_detail(key, context, default_value)
    end

    def track(event_key, context, metadata = nil)
      return if @closed
      @core.track(event_key, context, metadata)
    end

    def identify(context)
      return if @closed
      @core.identify(context)
    end

    def flush
      return if @closed
      @core.flush
    end

    def close
      subscriptions = @close_mutex.synchronize do
        return if @closed

        @closed = true
        @subscriptions.dup.tap { @subscriptions.clear }
      end
      # This handle's listeners only: the core is shared and other handles may
      # still be subscribed.
      subscriptions.each { |s| @core._remove_update_listener(s) }
      @core._release
    end

    def restart
      return if @closed
      @core.restart
    end

    # Subscribe to flag-configuration changes. The listener (a block or any
    # #call-able) receives the sorted keys whose configuration changed, batched
    # into one call per update. It runs on the SDK's streaming or polling
    # thread, so it must not block.
    #
    # The initial flag load does NOT fire. Reported keys include flags added,
    # removed or modified, flags referencing an edited segment, and flags
    # depending on a changed flag through a prerequisite. A raising listener is
    # logged and isolated.
    #
    # Returns a callable that unsubscribes (calling it twice is harmless). One
    # dispatch already in flight may still reach the listener after the
    # unsubscribe returns. While the fallback poller and the stream overlap
    # (#3071) a listener can be called from two threads at once, so it must be
    # thread-safe.
    # Closing this handle drops every subscription it made.
    def on_update(listener = nil, &block)
      raise ArgumentError, "pass a listener or a block, not both" if listener && block

      callable = listener || block
      raise ArgumentError, "on_update requires a listener or a block" if callable.nil?
      raise ArgumentError, "listener must respond to #call" unless callable.respond_to?(:call)

      # A distinct wrapper per subscription, so registering the same callable
      # twice yields two independently removable subscriptions.
      subscription = ->(keys) { callable.call(keys) }
      @close_mutex.synchronize do
        return NOOP_UNSUBSCRIBE if @closed

        @subscriptions << subscription
        @core._add_update_listener(subscription)
      end

      lambda do
        @close_mutex.synchronize { @subscriptions.delete_if { |s| s.equal?(subscription) } }
        @core._remove_update_listener(subscription)
        nil
      end
    end

    private

    def initialize(core)
      @core = core
      @closed = false
      @close_mutex = Mutex.new
      @subscriptions = []
    end
  end
end
