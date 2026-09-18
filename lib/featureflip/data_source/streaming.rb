require "net/http"
require "uri"
require "json"

module Featureflip
  module DataSource
    class StreamingHandler
      # Raised into the streaming thread by #stop to interrupt a blocking read
      # (Thread#wakeup only wakes a *sleeping* thread; it can't interrupt an
      # MRI IO read — Thread#raise can). Inherits from Exception, not
      # StandardError, so it bypasses handle_event's/run's generic `rescue
      # StandardError` arms (which would otherwise swallow a stop mid-event and
      # leave the thread blocking) and is only caught by the explicit
      # `rescue StreamStopped`.
      class StreamStopped < Exception; end # rubocop:disable Lint/InheritException

      # The server sends a keep-alive ping this often; a finite read timeout at
      # or below this interval would sever a healthy stream.
      SERVER_PING_INTERVAL_SECONDS = 30

      # Client-side liveness watchdog. net/http gives us no separate heartbeat,
      # so the read timeout IS the watchdog: if no data (not even a ping) arrives
      # for this long the socket is treated as dead — a half-open connection
      # (LB/NAT idle-drop or a partition with no FIN/RST) — and the blocking read
      # raises Net::ReadTimeout, which drives reconnect/backoff/polling. Set to
      # 3× the ping (3 missed pings) so it never severs a healthy stream but still
      # detects a dead socket within a bounded time. MUST stay finite and
      # > SERVER_PING_INTERVAL_SECONDS. (The rest of the server family now runs the
      # same finite 90s watchdog — java readTimeout(90s) / python read=90.0 / csharp
      # an idle-timeout CTS reset per event — so half-open detection is uniform.)
      STREAM_READ_TIMEOUT = SERVER_PING_INTERVAL_SECONDS * 3

      # Base reconnect backoff; also the floor applied after a healthy stream
      # closes cleanly, so even an accept-then-immediately-close server is
      # throttled instead of busy-looping.
      RECONNECT_BASE_DELAY_SECONDS = 1
      MAX_BACKOFF_SECONDS = 30

      def initialize(sdk_key:, config:, http_client:, on_flag_updated:, on_flag_deleted:, on_segment_updated:, on_error:, on_sync: nil, on_fallback_to_polling: nil, on_recovered: nil)
        @sdk_key = sdk_key
        @config = config
        @http_client = http_client
        @on_flag_updated = on_flag_updated
        @on_flag_deleted = on_flag_deleted
        @on_segment_updated = on_segment_updated
        @on_error = on_error
        @on_sync = on_sync
        @on_fallback_to_polling = on_fallback_to_polling
        @on_recovered = on_recovered
        @stop_flag = false
        @thread = nil
        @retry_count = 0
        # True between arming the polling fallback and the next delivered frame.
        # Only ever touched from the streaming thread.
        @fallback_active = false
        @current_event_type = nil
        @current_data = nil
        @line_buffer = String.new # ASCII-8BIT: raw read_body bytes concatenate safely
        @delivered_frame = false
        @wake_mutex = Mutex.new
        @wake_cond = ConditionVariable.new
      end

      def start
        @stop_flag = false
        @retry_count = 0
        @fallback_active = false
        @thread = Thread.new { run }
      end

      def stop
        @stop_flag = true
        # Wake an in-progress backoff wait.
        @wake_mutex.synchronize { @wake_cond.broadcast }

        thread = @thread
        @thread = nil
        return unless thread

        # Interrupt a thread blocked in read_body. Guard the raise: the thread may
        # finish between the alive? check and the raise (ThreadError on a dead one).
        begin
          thread.raise(StreamStopped.new) if thread.alive?
        rescue ThreadError
          # Thread already finished — nothing to interrupt.
        end
        thread.join(5)
      end

      private

      def run
        until @stop_flag
          begin
            connect
          rescue StreamStopped
            break
          rescue StandardError => e
            break if @stop_flag
            @on_error.call(e)
          end
          break if @stop_flag

          # Consult @delivered_frame (the instance var), NOT connect's return
          # value: connect only *returns* on a clean EOF, but the common stream
          # terminations (the liveness-watchdog Net::ReadTimeout, ECONNRESET,
          # IOError) RAISE — and a session that delivered frames before raising
          # must still count as healthy, or transient blips accumulate and
          # wrongly degrade a good stream to polling. @delivered_frame survives
          # the exception; connect resets it to false at the top of each attempt.
          if @delivered_frame
            # The stream genuinely stayed up (delivered ≥1 frame — the server
            # sends `sync` first). Reset the failure counter.
            @retry_count = 0
          else
            # A clean EOF (no frame) is treated as a failure for backoff/escalation
            # purposes — otherwise an accept-then-close server never accumulates
            # toward max_stream_retries and never degrades to polling.
            @retry_count += 1
            # The fallback is ADDITIVE, never terminal (#3071). Polling covers the
            # outage; this loop keeps retrying the stream underneath at the capped
            # backoff, and the next delivered frame retires the poller. Breaking out
            # here left the process polling — and blind to real-time updates — until
            # it restarted, after only ~31s of unreachability.
            if @retry_count > @config.max_stream_retries && !@fallback_active
              @fallback_active = true
              @on_fallback_to_polling&.call
            end
          end

          # Back off before every reconnect, including after a clean EOF, so we
          # never zero-delay busy-loop against a flapping endpoint.
          backoff_wait(backoff_delay(@retry_count))
        end
      rescue StreamStopped
        # stop() interrupted a backoff wait — clean shutdown.
      end

      # Connect to the SSE stream and process events until the connection ends.
      # Returns true if the stream delivered at least one complete frame (a live
      # stream), false if it returned 200 but closed without delivering one.
      def connect
        # Reset before anything can raise (a failed handshake / connection error
        # must not let run() read a stale `true` from the previous session).
        @delivered_frame = false

        uri = URI("#{@config.base_url}/v1/sdk/stream")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @config.connect_timeout
        http.read_timeout = STREAM_READ_TIMEOUT

        req = Net::HTTP::Get.new(uri.request_uri)
        req["Authorization"] = @sdk_key
        req["Accept"] = "text/event-stream"
        req["User-Agent"] = "featureflip-ruby/#{Featureflip::VERSION}"

        http.request(req) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            raise Featureflip::Error, "SSE connection failed: #{response.code}"
          end

          reset_stream_parser
          response.read_body do |chunk|
            break if @stop_flag
            feed_chunk(chunk)
          end
        end

        @delivered_frame
      end

      def reset_stream_parser
        @current_event_type = nil
        @current_data = nil
        @line_buffer = String.new # ASCII-8BIT: raw read_body bytes concatenate safely
      end

      # Append a raw SSE body chunk and dispatch every *complete* line it
      # completes. Net::HTTP#read_body yields arbitrary byte fragments with no
      # line alignment, so a line (or a `data:` payload) can span chunk
      # boundaries; buffer until a newline before parsing.
      def feed_chunk(chunk)
        @line_buffer << chunk
        while (newline_index = @line_buffer.index("\n"))
          line = @line_buffer.slice!(0, newline_index + 1)
          process_sse_line(line.chomp.force_encoding(Encoding::UTF_8))
        end
      end

      def process_sse_line(line)
        if line.start_with?("event: ")
          @current_event_type = line[7..]
        elsif line.start_with?("data: ")
          # Per the SSE spec multiple data: lines join with "\n" — concatenate,
          # never overwrite, or a chunked/multi-line payload loses everything but
          # its last fragment.
          fragment = line[6..]
          @current_data = @current_data.nil? ? fragment : "#{@current_data}\n#{fragment}"
        elsif line.empty? && @current_event_type && @current_data
          @delivered_frame = true
          # Retire the fallback poller HERE rather than when run() next comes round:
          # connect() blocks in read_body for the whole lifetime of a healthy stream,
          # so a reap on return would leave the poller alive that entire time, and its
          # periodic whole-store replaces would revert deltas applied by this stream.
          if @fallback_active
            @fallback_active = false
            @on_recovered&.call
          end
          handle_event(@current_event_type, @current_data)
          @current_event_type = nil
          @current_data = nil
        end
      end

      # Capped exponential backoff, jittered at every level. failures == 0 means a
      # healthy stream just closed cleanly; the jitter band's lower bound keeps the
      # base floor in force so we don't busy-loop.
      #
      # Jittering the FIRST reconnect is load-bearing, not cosmetic: the drops this
      # absorbs are fleet-wide — one edge event severs every stream at once (#2457)
      # — so every client re-enters here at failures == 0 together. A constant there
      # replayed the drop's own synchronisation as a reconnect spike one base delay
      # later (#2508).
      def backoff_delay(failures)
        exponent = failures <= 0 ? 0 : failures - 1
        with_jitter([RECONNECT_BASE_DELAY_SECONDS * (2**exponent), MAX_BACKOFF_SECONDS].min)
      end

      # Returns a value in [d/2, d] to de-correlate reconnects across many SDK
      # instances (thundering-herd avoidance after a shared outage).
      def with_jitter(delay)
        return delay if delay <= 0

        half = delay / 2.0
        half + (rand * half)
      end

      # Sleep for `seconds`, but return immediately if stop() fires — so a pending
      # shutdown isn't blocked behind a long backoff.
      def backoff_wait(seconds)
        @wake_mutex.synchronize do
          return if @stop_flag
          @wake_cond.wait(@wake_mutex, seconds)
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
        when "sync"
          # Full config snapshot the server sends on (re)connect. Replace the
          # whole store so flags changed OR deleted during a disconnect are
          # re-synced. Full replace, never a per-key merge.
          flags, segments = @http_client.parse_flags_response(JSON.parse(data))
          @on_sync&.call(flags, segments)
        end
      rescue UnevaluableEntityError => e
        # Not a malformed payload: the frame was well-formed and simply described
        # behaviour this build cannot evaluate, so the entity was dropped rather than
        # the payload discarded (#2402). Logged at the same volume — a flag that
        # silently stopped updating is exactly as confusing as one that never arrived.
        @config.logger&.warn(
          "Featureflip: dropping #{event_type} update: #{e.message}. This SDK version " \
          "may be older than the flag configuration."
        )
      rescue MalformedPayloadError => e
        # A payload that violates the wire contract is discarded WHOLESALE rather
        # than partially applied — a half-parsed snapshot silently mis-evaluates
        # every flag it touches, which is strictly worse than serving the previous
        # config until the next frame. See packages/CLAUDE.md.
        #
        # Never silent: a dropped `sync` means reconnect resync is not happening,
        # and staying quiet about exactly this is how #2279 ran undetected.
        @config.logger&.warn(
          "Featureflip: discarding malformed #{event_type} payload: #{e.message}"
        )
      rescue StandardError => e
        # Other event-processing errors must not kill the stream thread, but they
        # are still worth surfacing — this used to swallow silently.
        @config.logger&.warn(
          "Featureflip: error handling #{event_type} event: #{e.class}: #{e.message}"
        )
      end
    end
  end
end
