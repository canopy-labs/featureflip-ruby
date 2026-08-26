module Featureflip
  module Events
    class EventProcessor
      # Upper bound on buffered events.
      #
      # Only reachable once #flush starts putting batches back faster than they drain --
      # i.e. a sustained outage of the events endpoint. Past the bound the OLDEST events
      # are shed, which caps memory and keeps the freshest analytics. It also means a long
      # outage sheds the stale re-queued batches rather than starving new events, so the
      # SDK degrades to the old drop-on-failure behaviour instead of hoarding data it
      # cannot send.
      DEFAULT_MAX_QUEUE_SIZE = 10_000

      def initialize(http_client, flush_interval: 30, flush_batch_size: 100,
                     max_queue_size: DEFAULT_MAX_QUEUE_SIZE, logger: nil)
        @http_client = http_client
        @flush_interval = flush_interval
        # Clamped to at least 1: #flush drains @flush_batch_size events per pass and stops
        # when the queue is empty, so a non-positive size would shift nothing off a
        # non-empty queue and spin forever. Config#validate! already rejects such values,
        # but this class is constructed directly too.
        @flush_batch_size = flush_batch_size.to_i.positive? ? flush_batch_size.to_i : 1
        @max_queue_size = max_queue_size.to_i.positive? ? max_queue_size.to_i : DEFAULT_MAX_QUEUE_SIZE
        @logger = logger
        @queue = []
        @mutex = Mutex.new
        @stop_flag = false
        @stopped = false
        @thread = nil

        # Monotonic instant before which the batch-size trigger must not start another
        # flush, and a latch held while a size-triggered flush is in flight. Both exist to
        # stop a re-queued batch from turning every subsequent event into another request
        # — see #auto_flush.
        @next_auto_flush_at = 0.0
        @auto_flush_in_flight = false

        # Coalescing state for the drain loop. @auto_flush_in_flight above only ever
        # guarded the SIZE trigger; nothing stopped the background thread's interval
        # tick, an explicit Client#flush and a size-triggered flush from entering the
        # loop together. Two concurrent drains mean two request streams against the
        # endpoint the backoff gate exists to protect — and a success in one clears
        # the gate a failure in the other has just armed, re-opening the
        # one-request-per-event behaviour outright (#2477).
        #
        # Generation counters rather than a bare flag: a waiter has to be able to
        # tell "the drain I was waiting for has finished" from "a later drain is
        # running", or it would sleep through its own completion.
        @drain_in_flight = false
        @drain_started = 0
        @drain_finished = 0
        @drain_done = ConditionVariable.new
      end

      def queue_event(event)
        dropped = 0
        @mutex.synchronize do
          # After #stop nothing will flush again, so buffering here would only leak.
          return if @stopped

          @queue << event
          dropped = trim_to_bound
        end

        warn_overflow(dropped)
        auto_flush
      end

      # Drains the queue a batch at a time, one request per batch.
      #
      # This used to post the WHOLE queue in a single request, which was harmless while a
      # failure emptied the queue: it never grew far past @flush_batch_size. Re-queuing
      # failures (#2456) is what changed that — after a sustained outage the queue can sit
      # at its 10,000-event bound, and posting all of that at once risks a body the server
      # rejects outright. A 413 is non-retryable, so the entire backlog would be dropped by
      # the very path added to preserve it.
      # At most one drain runs at a time. A caller arriving while one is already
      # going waits for it and returns — it does NOT start its own, and it does NOT
      # return early, because a caller that asked for a flush is asking for its
      # events to be sent. This matches the js/node SDKs, whose flush() has always
      # returned the in-flight promise (#2477).
      def flush
        mine = @mutex.synchronize do
          if @drain_in_flight
            nil
          else
            @drain_in_flight = true
            @drain_started += 1
          end
        end

        if mine.nil?
          @mutex.synchronize do
            waiting_for = @drain_started
            @drain_done.wait(@mutex) while @drain_finished < waiting_for
          end
          return
        end

        begin
          drain
        ensure
          @mutex.synchronize do
            @drain_in_flight = false
            @drain_finished = mine
            @drain_done.broadcast
          end
        end
      end

      # The drain loop itself, callable when coalescing must be bypassed.
      # Private: #flush is the public entry point, and #stop reaches this directly.
      private def drain
        loop do
          batch = drain_batch
          return if batch.empty?

          # False means the batch went back on the queue, and it is at the HEAD of the very
          # queue this loop drains — carrying on would re-send it immediately and spin for
          # as long as the endpoint stayed down. A dropped batch returns true instead: the
          # queue has shrunk, so the loop still terminates, and one poison batch must not
          # block the backlog behind it.
          return unless send_batch(batch)
        end
      end

      def start
        @stop_flag = false
        @thread = Thread.new do
          elapsed = 0
          until @stop_flag
            sleep(1)
            elapsed += 1
            next if @stop_flag

            if elapsed >= @flush_interval
              # The interval tick is the retry vehicle for a re-queued batch, so it is
              # deliberately NOT subject to the size trigger's backoff gate.
              elapsed = 0
              flush
            elsif auto_flush
              elapsed = 0
            end
          end
        end
      end

      def stop
        @stop_flag = true
        @thread&.wakeup rescue nil
        @thread&.join(5)
        @thread = nil

        # Closed BEFORE the final flush so a failure there is dropped rather than
        # re-queued: nothing will flush again, and retrying until the queue drains would
        # hang shutdown for as long as the endpoint stayed down. One attempt, then let go.
        @mutex.synchronize { @stopped = true }
        # drain, not flush: shutdown must never be the call that gets coalesced
        # away. If the interval tick's drain happens to be in flight, flush would
        # wait for it and return, and anything queued after that loop's last look
        # would be discarded unsent. Two drains overlapping is safe here precisely
        # because @stopped is already set, so neither can re-queue and there is no
        # backoff left to disarm.
        drain
        @mutex.synchronize { @queue.clear }
      end

      private

      # Batch-size-triggered flush. Returns true only if it actually sent.
      #
      # A re-queued batch leaves the queue at or above @flush_batch_size, so without a gate
      # every subsequent event would trigger another flush — turning a failing endpoint
      # into one request per evaluation, which is worse for the server than the dropping
      # this replaced. Two guards, and both are load-bearing:
      #
      #   * the backoff gate suppresses the size trigger for one flush interval after a
      #     retryable failure, leaving the background thread's interval tick as the retry
      #     vehicle;
      #   * the in-flight latch covers what the gate cannot, because the gate is only armed
      #     once a flush has already FAILED and the size trigger fires again long before
      #     the first round-trip returns. Without it a tight loop of events starts a pile
      #     of concurrent flushes.
      #
      # An explicit #flush (the public API, and the interval tick) bypasses both: the
      # caller asked for a send.
      def auto_flush
        return false unless @mutex.synchronize { claim_size_trigger }

        begin
          flush
        ensure
          @mutex.synchronize { @auto_flush_in_flight = false }
        end
        true
      end

      # Whether a size-triggered flush may start, claiming the latch if so.
      # Caller holds @mutex.
      def claim_size_trigger
        return false if @stopped
        return false if @auto_flush_in_flight
        return false if @queue.length < @flush_batch_size
        return false if monotonic_now < @next_auto_flush_at

        @auto_flush_in_flight = true
      end

      # Never called with @mutex held: the POST blocks for as long as the endpoint takes to
      # answer — and Http::Client sleeps a second before its own single inline retry — so
      # the background thread and every queue_event caller would block behind it.
      # Sends one batch. Returns true if #flush may go on to the next one — see the comment
      # at its call site for why a re-queued batch must stop the drain.
      def send_batch(events)
        @http_client.post_events(events)
        @mutex.synchronize { @next_auto_flush_at = 0.0 }
        true
      rescue StandardError => e
        unless retryable_failure?(e)
          @logger&.warn(
            "Featureflip: dropped #{events.length} analytics event(s) the events endpoint " \
            "rejected (#{e.class}: #{e.message}); the failure is not retryable"
          )
          return true
        end

        dropped = requeue(events)
        # Armed here rather than at the first attempt, so the interval is counted from the
        # moment post_events' inline retry finally gave up.
        @mutex.synchronize { @next_auto_flush_at = monotonic_now + @flush_interval }

        if dropped.nil?
          @logger&.warn(
            "Featureflip: dropped #{events.length} analytics event(s) " \
            "(#{e.class}: #{e.message}); the processor is shutting down and will not flush again"
          )
        else
          @logger&.warn(
            "Featureflip: failed to send #{events.length} analytics event(s) " \
            "(#{e.class}: #{e.message}); re-queued for the next flush"
          )
          warn_overflow(dropped)
        end

        false
      end

      # Whether the same batch could succeed if it were sent again.
      #
      # For an HTTP answer the status decides: any 5xx — the production edge answers this
      # endpoint with a 503 at a low but constant rate (#2456) — and 429, where the server
      # is explicitly asking us to come back later. Anything else will fail identically next
      # time: 401/403 means the SDK key was rejected, 400 means the body is malformed, and
      # retrying either forever would pin the queue at its bound and starve every later
      # event.
      #
      # Everything that is NOT an HTTP answer is treated as transient. A transport fault
      # (connection reset, DNS, TLS) or a timeout carries no status at all and is exactly
      # the kind of failure a later flush gets past, so the default has to be "keep it"
      # rather than "not a 5xx, therefore permanent".
      def retryable_failure?(error)
        return error.status >= 500 || error.status == 429 if error.is_a?(Featureflip::HttpStatusError)

        true
      end

      # Takes up to @flush_batch_size of the OLDEST events, leaving the rest queued.
      def drain_batch
        @mutex.synchronize do
          return [] if @queue.empty?

          @queue.shift([@flush_batch_size, @queue.length].min)
        end
      end

      # Puts a batch that failed to send back at the FRONT of the queue, so the next flush
      # retries it ahead of newer events and rough chronological order survives.
      #
      # Returns how many events were shed to stay within the bound — or nil if it refused
      # the batch entirely because #stop has closed the queue. The caller needs to tell
      # those apart: "re-queued for the next flush" is a lie once there will be no next
      # flush, and this is the branch a shutdown during an outage takes.
      def requeue(events)
        @mutex.synchronize do
          return nil if @stopped

          @queue.unshift(*events)
          trim_to_bound
        end
      end

      # Sheds oldest-first until the queue fits the bound, returning how many went.
      # Caller holds @mutex.
      def trim_to_bound
        overflow = @queue.length - @max_queue_size
        return 0 if overflow <= 0

        @queue.shift(overflow)
        overflow
      end

      def warn_overflow(dropped)
        return if dropped.zero?

        @logger&.warn(
          "Featureflip: event queue is full (#{@max_queue_size}); " \
          "dropped #{dropped} of the oldest analytics event(s)"
        )
      end

      # Wall-clock time can jump backwards (NTP, a suspended host); the backoff gate must
      # not be extended or skipped by that.
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
