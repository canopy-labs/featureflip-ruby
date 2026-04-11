require "timeout"

module Featureflip
  class SharedCore
    LIVE_CORES = {}
    LIVE_CORES_MUTEX = Mutex.new

    # --- Class-level factory methods ---

    def self._get_or_create(sdk_key, config)
      LIVE_CORES_MUTEX.synchronize do
        existing = LIVE_CORES[sdk_key]

        if existing
          if existing._acquire
            unless _configs_equal(existing._config, config)
              config.logger&.warn(
                "Featureflip: Client.get called with different config for same SDK key. " \
                "Using existing configuration. Close all handles first to apply new config."
              )
            end
            return existing
          else
            # Stale entry — remove and replace
            LIVE_CORES.delete(sdk_key)
          end
        end

        core = new(sdk_key: sdk_key, config: config)
        LIVE_CORES[sdk_key] = core
        core
      end
    end

    def self._create_for_testing(flags)
      core = allocate
      core.send(:init_test_mode, flags)
      core
    end

    def self._reset_for_testing
      cores_to_release = LIVE_CORES_MUTEX.synchronize do
        snapshot = LIVE_CORES.values.dup
        LIVE_CORES.clear
        snapshot
      end
      cores_to_release.each { |c| c._release }
    end

    # --- Instance methods ---

    def initialize(sdk_key:, config:)
      @sdk_key = sdk_key
      @config = config
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
      @ref_count = 1
      @ref_mutex = Mutex.new
      @shut_down = false

      bootstrap!
    end

    def _acquire
      @ref_mutex.synchronize do
        return false if @ref_count <= 0
        @ref_count += 1
        true
      end
    end

    def _release
      run_shutdown = false
      @ref_mutex.synchronize do
        return if @ref_count <= 0
        @ref_count -= 1
        if @ref_count == 0 && !@shut_down
          @shut_down = true
          run_shutdown = true
        end
      end
      _shutdown if run_shutdown
    end

    def _config
      @config
    end

    def _ref_count
      @ref_mutex.synchronize { @ref_count }
    end

    def initialized?
      @initialized
    end

    # --- Evaluation methods ---

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

    # --- Event methods ---

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

    def restart
      return if @shut_down

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

    private

    def _shutdown
      LIVE_CORES_MUTEX.synchronize do
        LIVE_CORES.delete(@sdk_key) if LIVE_CORES[@sdk_key].equal?(self)
      end
      _shutdown_internal
    end

    def _shutdown_internal
      @closed = true
      begin
        @streaming_handler&.stop
      rescue StandardError
        # ignore
      end
      @streaming_handler = nil

      begin
        @polling_handler&.stop
      rescue StandardError
        # ignore
      end
      @polling_handler = nil

      begin
        @event_processor&.stop
      rescue StandardError
        # ignore
      end
      @event_processor = nil

      @config.logger&.info("Featureflip: core shut down for SDK key #{@sdk_key}")
    end

    def bootstrap!
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

    def init_test_mode(flags)
      @sdk_key = "test-key"
      @config = Config.new
      @store = Store::FlagStore.new
      @evaluator = Evaluation::Evaluator.new
      @initialized = true
      @closed = false
      @test_mode = true
      @test_values = flags.dup
      @http_client = nil
      @streaming_handler = nil
      @polling_handler = nil
      @event_processor = nil
      @ref_count = 1
      @ref_mutex = Mutex.new
      @shut_down = false
    end

    def self._configs_equal(a, b)
      a.base_url == b.base_url &&
        a.streaming == b.streaming &&
        a.poll_interval == b.poll_interval &&
        a.flush_interval == b.flush_interval &&
        a.flush_batch_size == b.flush_batch_size &&
        a.init_timeout == b.init_timeout &&
        a.connect_timeout == b.connect_timeout &&
        a.read_timeout == b.read_timeout &&
        a.send_events == b.send_events
    end

    private_class_method :_configs_equal
  end
end
