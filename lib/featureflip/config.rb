module Featureflip
  class Config
    attr_accessor :sdk_key, :base_url, :streaming, :poll_interval, :flush_interval,
                  :flush_batch_size, :init_timeout, :connect_timeout, :read_timeout,
                  :max_stream_retries, :send_events, :logger

    # Identifies a library that wraps this SDK, such as the OpenFeature provider. Its
    # token is sent after the SDK's own in the User-Agent
    # (`featureflip-ruby/<version> my-wrapper/1.0.0`) so usage through the wrapper can be
    # counted. Both parts must be valid HTTP tokens; an invalid wrapper is ignored with a
    # logged warning. wrapper_version may be nil. Leave unset when calling the SDK
    # directly. Excluded from SharedCore._configs_equal: it identifies the caller rather
    # than changing behavior.
    attr_accessor :wrapper_name, :wrapper_version

    # Opt-in last-known-config store (see Featureflip::FileSnapshotStore). When the
    # initial fetch fails or times out the client starts from the stored snapshot
    # instead of serving defaults. Honored on the first Client.get per SDK key. Not
    # part of the different-config comparison; its identity is compared separately.
    attr_accessor :snapshot_store

    # How old a stored snapshot may be and still be used, in seconds. Must be a
    # positive, finite number; there is no "never expire" value.
    DEFAULT_MAX_SNAPSHOT_AGE_SECONDS = 86_400
    UNSET = Object.new.freeze
    private_constant :UNSET
    attr_reader :max_snapshot_age_seconds

    def max_snapshot_age_seconds=(value)
      @max_snapshot_age_explicit = true
      @max_snapshot_age_seconds = value
    end

    # True when the caller passed a max age, so the "option ignored" warning can tell
    # an omitted option from the default.
    def max_snapshot_age_explicit?
      @max_snapshot_age_explicit
    end

    # Evaluation inspectors -- callables invoked once per variation call with a
    # Models::EvaluationEvent. Always an Array; non-callable entries are dropped
    # on assignment rather than blowing up on the evaluation hot path.
    attr_reader :inspectors

    def initialize(
      sdk_key: nil,
      base_url: "https://eval.featureflip.io",
      streaming: true,
      poll_interval: 30,
      flush_interval: 30,
      flush_batch_size: 100,
      init_timeout: 10,
      connect_timeout: 5,
      read_timeout: 10,
      max_stream_retries: 5,
      send_events: true,
      logger: nil,
      inspectors: nil,
      wrapper_name: nil,
      wrapper_version: nil,
      snapshot_store: nil,
      max_snapshot_age_seconds: UNSET
    )
      @sdk_key = sdk_key
      @base_url = base_url
      @streaming = streaming
      @poll_interval = poll_interval
      @flush_interval = flush_interval
      @flush_batch_size = flush_batch_size
      @init_timeout = init_timeout
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @max_stream_retries = max_stream_retries
      @send_events = send_events
      @logger = logger || default_logger
      self.inspectors = inspectors
      @wrapper_name = wrapper_name
      @wrapper_version = wrapper_version
      @snapshot_store = snapshot_store
      @max_snapshot_age_explicit = !UNSET.equal?(max_snapshot_age_seconds)
      @max_snapshot_age_seconds = @max_snapshot_age_explicit ? max_snapshot_age_seconds : DEFAULT_MAX_SNAPSHOT_AGE_SECONDS

      validate!
    end

    # Accepts a single callable or an array of callables. Anything that does not
    # respond to #call is filtered out here, so the evaluation path never has to
    # guard against it.
    def inspectors=(value)
      list = case value
             when nil then []
             when Array then value
             else [value]
             end
      @inspectors = list.select { |i| i.respond_to?(:call) }.freeze
    end

    # The User-Agent for every request: the SDK token, then the wrapper's (#4154). Built
    # on first use and memoized, so the HTTP client and the stream share one value and an
    # invalid wrapper is warned about once.
    def user_agent
      @user_agent ||= SdkIdentity.user_agent(self)
    end

    def validate!
      finalize!
      validate_positive_fields!
      validate_snapshot_options!
    end

    private

    def finalize!
      @base_url = @base_url.to_s.gsub(%r{/+$}, "")
    end

    def validate_positive_fields!
      %i[poll_interval flush_interval flush_batch_size init_timeout connect_timeout read_timeout].each do |field|
        value = send(field)
        if value <= 0
          raise ConfigurationError, "#{field} must be positive, got #{value}"
        end
      end
    end

    def validate_snapshot_options!
      age = @max_snapshot_age_seconds
      valid = age.is_a?(Numeric) && !age.is_a?(Complex) && age.to_f.finite? && age.positive?
      unless valid
        raise ConfigurationError, "max_snapshot_age_seconds must be a positive, finite number, got #{age.inspect}"
      end
      return if @snapshot_store.nil? || (@snapshot_store.respond_to?(:get) && @snapshot_store.respond_to?(:put))

      raise ConfigurationError, "snapshot_store must respond to #get and #put"
    end

    def default_logger
      if defined?(Rails) && Rails.respond_to?(:logger)
        Rails.logger
      else
        require "logger"
        ::Logger.new($stdout, level: ::Logger::INFO)
      end
    end
  end
end
