require "timeout"
require "time"

module Featureflip
  class SharedCore
    LIVE_CORES = {}
    LIVE_CORES_MUTEX = Mutex.new

    # Exception classes that are deliberately NOT isolated when an evaluation
    # inspector raises them (see #notify_inspectors). Everything else -- every
    # StandardError, plus the Exception-but-not-StandardError classes a buggy
    # callback realistically raises (NotImplementedError and other ScriptErrors,
    # Minitest::Assertion, RSpec::Expectations::ExpectationNotMetError) -- is
    # caught and logged so the caller's value is never affected.
    #
    # These four are re-raised because swallowing them would break something the
    # inspector has no business breaking:
    #   SystemExit        `exit`/`abort` -- the process is deliberately going down
    #   SignalException   SIGTERM and (via its subclass Interrupt) Ctrl-C
    #   NoMemoryError     the VM is out of memory; there is nothing safe to do
    #   SystemStackError  the stack is blown; unwinding is the only safe move
    # Timeout::ExitException is the private class `Timeout.timeout` throws into
    # the running thread to unwind it; eating it would silently neutralise a
    # caller that wrapped its variation call in a timeout.
    INSPECTOR_UNISOLATED_ERRORS = [
      SystemExit,
      SignalException,
      NoMemoryError,
      SystemStackError,
      (Timeout::ExitException if defined?(Timeout::ExitException))
    ].compact.freeze
    private_constant :INSPECTOR_UNISOLATED_ERRORS

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
      # Snapshot the (already-filtered) inspector list at construction: config is
      # immutable-after-init from the core's point of view, so the evaluation path
      # needs no locking. Deliberately excluded from _configs_equal -- callables
      # aren't structurally comparable and a differing inspector must not trigger
      # the "different config" warning.
      @inspectors = config.inspectors || []
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
        # Test-mode cores are built by _create_for_testing, which has no user
        # config, so there are never inspectors to notify here.
        value = @test_values.fetch(key, default_value)
        reason = @test_values.key?(key) ? "Fallthrough" : "FlagNotFound"
        return Models::EvaluationDetail.new(value: value, reason: reason)
      end

      flag = @store.get_flag(key)
      unless flag
        record_evaluation(key, context, nil)
        notify_inspectors(key, context, default_value, reason: "FlagNotFound")
        return Models::EvaluationDetail.new(value: default_value, reason: "FlagNotFound")
      end

      result = @evaluator.evaluate(
        flag,
        context,
        get_segment: method(:get_segment),
        all_flags: @store.all_flags_map
      )

      # Malformed config: the evaluator selected a variation key the flag does
      # not define (e.g. a fallthrough/rule naming a since-deleted variation).
      # Degrade to the caller's default and report Error, mirroring the engine's
      # ServeVariation + the C#/Java SDKs (#1989). A variation that genuinely
      # exists with a nil value is NOT this case -- hence the key lookup rather
      # than a `value.nil?` check, which cannot tell the two apart.
      reason = if result.variation_key && !result.variation_key.empty? &&
                  flag.get_variation(result.variation_key).nil?
                 "Error"
               else
                 result.reason
               end

      value = result.value.nil? ? default_value : result.value
      record_evaluation(key, context, result.variation_key)
      notify_inspectors(
        key, context, value,
        reason: reason,
        variation_key: result.variation_key,
        rule_id: result.rule_id,
        prerequisite_key: result.prerequisite_key
      )

      Models::EvaluationDetail.new(
        value: value,
        reason: reason,
        rule_id: result.rule_id,
        variation_key: result.variation_key,
        prerequisite_key: result.prerequisite_key
      )
    rescue StandardError
      # Prerequisite-resolution failures return PrerequisiteFailed cleanly through
      # the evaluator; this rescue only fires on unexpected exceptions (malformed
      # config, programming errors), so prerequisite_key has no defined value.
      notify_inspectors(key, context, default_value, reason: "Error")
      Models::EvaluationDetail.new(value: default_value, reason: "Error", prerequisite_key: nil)
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
        on_sync: ->(flags, segments) { @store.init(flags, segments) },
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

    # Fire the registered evaluation inspectors. Called once per variation call
    # on every exit path of variation_detail (success, flag-not-found, error)
    # with the reason and value the caller actually receives. A raising inspector
    # is isolated: it neither changes the returned value nor stops its siblings.
    def notify_inspectors(flag_key, context, value, reason:, variation_key: nil,
                          rule_id: nil, prerequisite_key: nil)
      return if @inspectors.nil? || @inspectors.empty?

      event = Models::EvaluationEvent.new(
        flag_key: flag_key,
        # Shallow copy so a buggy inspector cannot mutate the caller's hash.
        context: context.dup,
        value: value,
        variation_key: variation_key,
        reason: reason,
        rule_id: rule_id,
        prerequisite_key: prerequisite_key,
        # Millisecond precision, matching the sibling SDKs (PHP's "Y-m-d\TH:i:s.v\Z",
        # C#'s "o", Python's isoformat). Whole-second stamps make an analytics sink
        # that de-duplicates on (flag, user, timestamp) drop repeat exposures inside
        # the same second, so the digit argument is load-bearing -- don't drop it.
        timestamp: Time.now.utc.iso8601(3)
      )

      @inspectors.each do |inspector|
        begin
          inspector.call(event)
        # Order matters: the un-isolated list is matched first, then everything
        # else is contained. `rescue StandardError` is too narrow (an assertion
        # failure or NotImplementedError from an inspector would escape into the
        # caller's request handler, which the inspector contract forbids) and a
        # bare `rescue Exception` is too wide (it would eat Ctrl-C). See
        # INSPECTOR_UNISOLATED_ERRORS above before changing either arm.
        rescue *INSPECTOR_UNISOLATED_ERRORS
          raise
        rescue Exception => e # rubocop:disable Lint/RescueException
          @config.logger&.warn("Featureflip: evaluation inspector raised #{e.class}: #{e.message}")
        end
      end
    end

    def init_test_mode(flags)
      @sdk_key = "test-key"
      @config = Config.new
      @inspectors = []
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
