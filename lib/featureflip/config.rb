module Featureflip
  class Config
    attr_accessor :sdk_key, :base_url, :streaming, :poll_interval, :flush_interval,
                  :flush_batch_size, :init_timeout, :connect_timeout, :read_timeout,
                  :max_stream_retries, :send_events, :logger

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
      inspectors: nil
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

    def validate!
      finalize!
      validate_positive_fields!
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
