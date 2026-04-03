module Featureflip
  module Events
    class EventProcessor
      def initialize(http_client, flush_interval: 30, flush_batch_size: 100)
        @http_client = http_client
        @flush_interval = flush_interval
        @flush_batch_size = flush_batch_size
        @queue = []
        @mutex = Mutex.new
        @stop_flag = false
        @thread = nil
      end

      def queue_event(event)
        should_flush = false
        @mutex.synchronize do
          @queue << event
          should_flush = @queue.length >= @flush_batch_size
        end
        flush if should_flush
      end

      def flush
        events_to_send = nil
        @mutex.synchronize do
          return if @queue.empty?
          events_to_send = @queue.dup
          @queue.clear
        end

        return unless events_to_send&.any?

        @http_client.post_events(events_to_send)
      rescue StandardError
        # Events are best-effort — drop on failure
      end

      def start
        @stop_flag = false
        @thread = Thread.new do
          elapsed = 0
          until @stop_flag
            sleep(1)
            elapsed += 1
            queue_size = @mutex.synchronize { @queue.length }
            if elapsed >= @flush_interval || queue_size >= @flush_batch_size
              elapsed = 0
              flush unless @stop_flag
            end
          end
        end
      end

      def stop
        @stop_flag = true
        @thread&.wakeup rescue nil
        @thread&.join(5)
        @thread = nil
        flush
      end
    end
  end
end
