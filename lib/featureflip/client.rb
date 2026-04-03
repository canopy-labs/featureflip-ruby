require "timeout"

module Featureflip
  class Client
    attr_reader :initialized
    alias_method :initialized?, :initialized

    def initialize(sdk_key: nil, config: nil)
      @sdk_key = sdk_key || ENV["FEATUREFLIP_SDK_KEY"]
      raise ConfigurationError, "SDK key is required. Pass sdk_key parameter or set FEATUREFLIP_SDK_KEY env var." unless @sdk_key

      @config = config || Config.new
      @store = Store::FlagStore.new
      @evaluator = Evaluation::Evaluator.new
      @initialized = false
      @closed = false
      @test_mode = false
      @test_values = {}
      @http_client = nil
      @streaming_handler = nil
      @polling_handler = nil
      @event_processor = nil

      initialize!
    end

    def bool_variation(key, context, default_value)
      evaluate_flag(key, context, default_value)
    end

    def string_variation(key, context, default_value)
      evaluate_flag(key, context, default_value)
    end

    def number_variation(key, context, default_value)
      evaluate_flag(key, context, default_value)
    end

    def json_variation(key, context, default_value)
      evaluate_flag(key, context, default_value)
    end

    def variation_detail(key, context, default_value)
      context = normalize_context(context)

      if @test_mode
        value = @test_values.fetch(key, default_value)
        reason = @test_values.key?(key) ? "Fallthrough" : "FlagNotFound"
        return Models::EvaluationDetail.new(value: value, reason: reason)
      end

      flag = @store.get_flag(key)
      unless flag
        record_evaluation(key, context, nil)
        return Models::EvaluationDetail.new(value: default_value, reason: "FlagNotFound")
      end

      result = @evaluator.evaluate(flag, context, get_segment: method(:get_segment))
      value = result.value.nil? ? default_value : result.value
      record_evaluation(key, context, result.variation_key)

      Models::EvaluationDetail.new(
        value: value,
        reason: result.reason,
        rule_id: result.rule_id,
        variation_key: result.variation_key
      )
    rescue StandardError
      Models::EvaluationDetail.new(value: default_value, reason: "Error")
    end

    def track(event_key, context, metadata = nil)
      return unless @event_processor

      context = normalize_context(context)
      @event_processor.queue_event({
        type: "Custom",
        flagKey: event_key,
        userId: context["user_id"]&.to_s,
        metadata: metadata || {},
        timestamp: Time.now.utc.iso8601
      })
    end

    def identify(context)
      return unless @event_processor

      context = normalize_context(context)
      @event_processor.queue_event({
        type: "Identify",
        flagKey: "$identify",
        userId: context["user_id"]&.to_s,
        timestamp: Time.now.utc.iso8601
      })
    end

    def flush
      @event_processor&.flush
    end

    def close
      @closed = true
      @streaming_handler&.stop
      @streaming_handler = nil
      @polling_handler&.stop
      @polling_handler = nil
      @event_processor&.stop
      @event_processor = nil
    end

    def restart
      return if @closed

      @streaming_handler&.stop
      @polling_handler&.stop
      @event_processor&.stop

      if @config.streaming
        start_streaming
      else
        start_polling
      end
      start_event_processor if @config.send_events
    end

    def self.for_testing(flags)
      instance = allocate
      instance.instance_variable_set(:@sdk_key, "test-key")
      instance.instance_variable_set(:@config, Config.new)
      instance.instance_variable_set(:@store, Store::FlagStore.new)
      instance.instance_variable_set(:@evaluator, Evaluation::Evaluator.new)
      instance.instance_variable_set(:@initialized, true)
      instance.instance_variable_set(:@closed, false)
      instance.instance_variable_set(:@test_mode, true)
      instance.instance_variable_set(:@test_values, flags.dup)
      instance.instance_variable_set(:@http_client, nil)
      instance.instance_variable_set(:@streaming_handler, nil)
      instance.instance_variable_set(:@polling_handler, nil)
      instance.instance_variable_set(:@event_processor, nil)
      instance
    end

    private

    def initialize!
      @http_client = Http::Client.new(@sdk_key, @config)
      fetch_initial_flags
      start_data_source
      start_event_processor if @config.send_events
    end

    def fetch_initial_flags
      Timeout.timeout(@config.init_timeout) do
        flags, segments = @http_client.get_flags
        @store.init(flags, segments)
        @initialized = true
      end
    rescue Timeout::Error
      raise InitializationError, "Initialization timed out after #{@config.init_timeout}s"
    rescue InitializationError
      raise
    rescue StandardError => e
      raise InitializationError, "Failed to initialize: #{e.message}"
    end

    def start_data_source
      return if @closed

      if @config.streaming
        start_streaming
      else
        start_polling
      end
    end

    def start_streaming
      @streaming_handler = DataSource::StreamingHandler.new(
        sdk_key: @sdk_key,
        config: @config,
        http_client: @http_client,
        on_flag_updated: ->(flag) { @store.upsert(flag) },
        on_flag_deleted: ->(key) { @store.remove_flag(key) },
        on_segment_updated: ->(flags, segments) { @store.init(flags, segments) },
        on_error: ->(_err) { },
        on_give_up: -> { fallback_to_polling }
      )
      @streaming_handler.start
    end

    def fallback_to_polling
      @config.logger&.warn("Featureflip: streaming retries exhausted, falling back to polling")
      @streaming_handler = nil
      start_polling
    end

    def start_polling
      @polling_handler = DataSource::PollingHandler.new(
        http_client: @http_client,
        config: @config,
        on_update: ->(flags, segments) { @store.init(flags, segments) },
        on_error: ->(_err) { }
      )
      @polling_handler.start
    end

    def start_event_processor
      @event_processor = Events::EventProcessor.new(
        @http_client,
        flush_interval: @config.flush_interval,
        flush_batch_size: @config.flush_batch_size
      )
      @event_processor.start
    end

    def evaluate_flag(key, context, default_value)
      if @test_mode
        return @test_values.fetch(key, default_value)
      end

      detail = variation_detail(key, context, default_value)
      detail.value
    rescue StandardError
      default_value
    end

    def get_segment(key)
      @store.get_segment(key)
    end

    def normalize_context(context)
      return {} if context.nil?
      context.transform_keys(&:to_s)
    end

    def record_evaluation(key, context, variation_key)
      return unless @event_processor

      @event_processor.queue_event({
        type: "Evaluation",
        flagKey: key,
        userId: context["user_id"]&.to_s,
        variation: variation_key,
        timestamp: Time.now.utc.iso8601
      })
    end
  end
end
