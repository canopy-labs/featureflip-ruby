module Featureflip
  class Client
    private_class_method :new

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

    def initialized?
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
      @close_mutex.synchronize do
        return if @closed
        @closed = true
      end
      @core._release
    end

    def restart
      return if @closed
      @core.restart
    end

    private

    def initialize(core)
      @core = core
      @closed = false
      @close_mutex = Mutex.new
    end
  end
end
