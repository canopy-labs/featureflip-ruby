module Featureflip
  module DataSource
    class PollingHandler
      def initialize(http_client:, config:, on_update:, on_error:)
        @http_client = http_client
        @config = config
        @on_update = on_update
        @on_error = on_error
        @stop_flag = false
        @thread = nil
      end

      def start
        @stop_flag = false
        @thread = Thread.new { run }
      end

      def stop
        @stop_flag = true
        thread = @thread
        @thread = nil
        # Called from a listener running on the poll thread: it can't join itself,
        # and the stop flag ends its loop once the listener returns.
        return if thread.nil? || thread.equal?(Thread.current)

        thread.wakeup rescue nil
        thread.join(5)
      end

      private

      def run
        until @stop_flag
          begin
            flags, segments = @http_client.get_flags
            @on_update.call(flags, segments)
          rescue StandardError => e
            @on_error.call(e)
          end
          elapsed = 0
          while elapsed < @config.poll_interval && !@stop_flag
            sleep(1)
            elapsed += 1
          end
        end
      end
    end
  end
end
