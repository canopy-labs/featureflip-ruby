require "net/http"
require "uri"
require "json"

module Featureflip
  module DataSource
    class StreamingHandler
      def initialize(sdk_key:, config:, http_client:, on_flag_updated:, on_flag_deleted:, on_segment_updated:, on_error:, on_give_up: nil)
        @sdk_key = sdk_key
        @config = config
        @http_client = http_client
        @on_flag_updated = on_flag_updated
        @on_flag_deleted = on_flag_deleted
        @on_segment_updated = on_segment_updated
        @on_error = on_error
        @on_give_up = on_give_up
        @stop_flag = false
        @thread = nil
        @retry_count = 0
        @current_event_type = nil
        @current_data = nil
      end

      def start
        @stop_flag = false
        @retry_count = 0
        @thread = Thread.new { run }
      end

      def stop
        @stop_flag = true
        @thread&.wakeup rescue nil
        @thread&.join(5)
        @thread = nil
      end

      private

      def run
        until @stop_flag
          begin
            connect
          rescue StandardError => e
            break if @stop_flag
            @on_error.call(e)
            @retry_count += 1
            if @retry_count > @config.max_stream_retries
              @on_give_up&.call
              break
            end
            delay = [2**(@retry_count - 1), 30].min
            sleep(delay)
          end
        end
      end

      def connect
        uri = URI("#{@config.base_url}/v1/sdk/stream")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @config.connect_timeout
        http.read_timeout = 300 # 5 min — detect silent TCP drops

        req = Net::HTTP::Get.new(uri.request_uri)
        req["Authorization"] = @sdk_key
        req["Accept"] = "text/event-stream"
        req["User-Agent"] = "featureflip-ruby/#{Featureflip::VERSION}"

        http.request(req) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            raise Featureflip::Error, "SSE connection failed: #{response.code}"
          end

          @retry_count = 0
          @current_event_type = nil
          @current_data = nil

          response.read_body do |chunk|
            break if @stop_flag
            chunk.each_line do |line|
              process_sse_line(line.strip)
            end
          end
        end
      end

      def process_sse_line(line)
        if line.start_with?("event: ")
          @current_event_type = line[7..]
        elsif line.start_with?("data: ")
          @current_data = line[6..]
        elsif line.empty? && @current_event_type && @current_data
          handle_event(@current_event_type, @current_data)
          @current_event_type = nil
          @current_data = nil
        end
      end

      def handle_event(event_type, data)
        case event_type
        when "flag.created", "flag.updated"
          payload = JSON.parse(data)
          key = payload["key"]
          return if key.nil? || key.empty?
          flag = @http_client.get_flag(key)
          @on_flag_updated.call(flag)
        when "flag.deleted"
          payload = JSON.parse(data)
          key = payload["key"]
          return if key.nil? || key.empty?
          @on_flag_deleted.call(key)
        when "segment.updated"
          flags, segments = @http_client.get_flags
          @on_segment_updated.call(flags, segments)
        end
      rescue StandardError
        # Swallow event processing errors
      end
    end
  end
end
