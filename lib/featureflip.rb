require_relative "featureflip/version"
require_relative "featureflip/errors"
require_relative "featureflip/config"
require_relative "featureflip/models/flag"
require_relative "featureflip/models/segment"
require_relative "featureflip/models/evaluation_detail"
require_relative "featureflip/evaluation/bucketing"
require_relative "featureflip/evaluation/condition_evaluator"
require_relative "featureflip/evaluation/evaluator"
require_relative "featureflip/store/flag_store"
require_relative "featureflip/http/client"
require_relative "featureflip/events/event"
require_relative "featureflip/events/event_processor"
require_relative "featureflip/data_source/streaming"
require_relative "featureflip/data_source/polling"
require_relative "featureflip/client"

module Featureflip
  @mutex = Mutex.new

  class << self
    attr_reader :default_client

    def configure
      @mutex.synchronize do
        @config = Config.new
        yield @config if block_given?
        @config.validate!
        @default_client = Client.new(sdk_key: @config.sdk_key, config: @config)
      end
    end

    def bool_variation(key, context, default_value)
      ensure_configured!
      @default_client.bool_variation(key, context, default_value)
    end

    def string_variation(key, context, default_value)
      ensure_configured!
      @default_client.string_variation(key, context, default_value)
    end

    def number_variation(key, context, default_value)
      ensure_configured!
      @default_client.number_variation(key, context, default_value)
    end

    def json_variation(key, context, default_value)
      ensure_configured!
      @default_client.json_variation(key, context, default_value)
    end

    def variation_detail(key, context, default_value)
      ensure_configured!
      @default_client.variation_detail(key, context, default_value)
    end

    def track(event_key, context, metadata = nil)
      ensure_configured!
      @default_client.track(event_key, context, metadata)
    end

    def identify(context)
      ensure_configured!
      @default_client.identify(context)
    end

    def flush
      ensure_configured!
      @default_client.flush
    end

    def close
      @mutex.synchronize do
        return unless @default_client
        @default_client.close
        @default_client = nil
      end
    end

    def restart
      ensure_configured!
      @default_client.restart
    end

    private

    def ensure_configured!
      raise Error, "Featureflip not configured. Call Featureflip.configure first." unless @default_client
    end
  end
end
