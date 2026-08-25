require "spec_helper"
require "logger"

RSpec.describe Featureflip::Events::EventProcessor do
  let(:http_client) { instance_double(Featureflip::Http::Client) }
  let(:logger) { instance_double(Logger, warn: nil, info: nil, debug: nil) }
  let(:processor) { described_class.new(http_client, flush_interval: 30, flush_batch_size: 3, logger: logger) }

  describe "#queue_event and #flush" do
    it "stores events and flushes them" do
      allow(http_client).to receive(:post_events)

      processor.queue_event({ type: "eval", key: "a" })
      processor.queue_event({ type: "eval", key: "b" })
      processor.flush

      expect(http_client).to have_received(:post_events).with([
        { type: "eval", key: "a" },
        { type: "eval", key: "b" }
      ])
    end

    it "background thread flushes when batch size is reached" do
      allow(http_client).to receive(:post_events)
      bg_processor = described_class.new(http_client, flush_interval: 60, flush_batch_size: 3, logger: logger)
      bg_processor.start

      bg_processor.queue_event({ type: "eval", key: "1" })
      bg_processor.queue_event({ type: "eval", key: "2" })
      bg_processor.queue_event({ type: "eval", key: "3" })
      sleep(1.5) # Allow background thread to check and flush

      expect(http_client).to have_received(:post_events).once
      bg_processor.stop
    end

    it "flushes immediately when batch size threshold is reached" do
      allow(http_client).to receive(:post_events)

      processor.queue_event({ type: "eval", key: "1" })
      processor.queue_event({ type: "eval", key: "2" })
      # batch_size is 3, so this should trigger an immediate flush
      processor.queue_event({ type: "eval", key: "3" })

      expect(http_client).to have_received(:post_events).with([
        { type: "eval", key: "1" },
        { type: "eval", key: "2" },
        { type: "eval", key: "3" }
      ])
    end

    it "does nothing when queue is empty" do
      allow(http_client).to receive(:post_events)

      processor.flush

      expect(http_client).not_to have_received(:post_events)
    end

    it "clears queue after flush" do
      allow(http_client).to receive(:post_events)

      processor.queue_event({ type: "eval", key: "a" })
      processor.flush
      processor.flush

      expect(http_client).to have_received(:post_events).once
    end
  end

  describe "error handling" do
    it "swallows HTTP errors" do
      allow(http_client).to receive(:post_events).and_raise(StandardError, "network error")

      processor.queue_event({ type: "eval", key: "a" })

      expect { processor.flush }.not_to raise_error
    end
  end

  # The queue is drained BEFORE the POST, so a batch that fails to send is only
  # recoverable if the processor puts it back. The production edge answers this endpoint
  # with a 503 at a low but constant rate, so "best effort, drop on failure" was losing
  # evaluation analytics steadily (#2456).
  describe "retryable send failures" do
    let(:event) { { type: "Evaluation", flagKey: "dark-mode" } }

    it "keeps a batch the endpoint 503'd so the next flush re-sends it" do
      allow(http_client).to receive(:post_events)
        .and_raise(Featureflip::HttpStatusError.new(503, "/v1/sdk/events"))

      processor.queue_event(event)
      processor.flush

      allow(http_client).to receive(:post_events).and_return(nil)
      processor.flush

      expect(http_client).to have_received(:post_events).with([event]).twice
    end

    it "keeps a batch that failed with a 429" do
      allow(http_client).to receive(:post_events)
        .and_raise(Featureflip::HttpStatusError.new(429, "/v1/sdk/events"))

      processor.queue_event(event)
      processor.flush

      allow(http_client).to receive(:post_events).and_return(nil)
      processor.flush

      expect(http_client).to have_received(:post_events).with([event]).twice
    end

    # A transport fault carries no status at all — it is exactly the kind of failure a
    # later flush gets past, so it must be treated as retryable rather than as "not a
    # 5xx, therefore permanent".
    it "keeps a batch that failed with a network error" do
      allow(http_client).to receive(:post_events).and_raise(Errno::ECONNREFUSED)

      processor.queue_event(event)
      processor.flush

      allow(http_client).to receive(:post_events).and_return(nil)
      processor.flush

      expect(http_client).to have_received(:post_events).with([event]).twice
    end

    it "keeps a batch that timed out" do
      allow(http_client).to receive(:post_events).and_raise(Net::ReadTimeout)

      processor.queue_event(event)
      processor.flush

      allow(http_client).to receive(:post_events).and_return(nil)
      processor.flush

      expect(http_client).to have_received(:post_events).with([event]).twice
    end

    it "re-queues at the FRONT so the failed batch goes out ahead of newer events" do
      allow(http_client).to receive(:post_events)
        .and_raise(Featureflip::HttpStatusError.new(503, "/v1/sdk/events"))

      processor.queue_event({ n: 1 })
      processor.flush

      allow(http_client).to receive(:post_events).and_return(nil)
      processor.queue_event({ n: 2 })
      processor.flush

      expect(http_client).to have_received(:post_events).with([{ n: 1 }, { n: 2 }])
    end

    # This fix must not hide the underlying edge problem.
    it "logs every failure" do
      allow(http_client).to receive(:post_events)
        .and_raise(Featureflip::HttpStatusError.new(503, "/v1/sdk/events"))

      processor.queue_event(event)
      processor.flush

      expect(logger).to have_received(:warn).with(/HTTP 503/)
    end
  end

  describe "non-retryable send failures" do
    let(:event) { { type: "Evaluation", flagKey: "dark-mode" } }

    # 401/403 means the SDK key was rejected and 400 means the body is malformed: the
    # same batch fails identically next time, and retrying it forever would pin the queue
    # at its bound and starve every later event.
    it "drops a batch the endpoint rejected with a 401 and does not retry it" do
      allow(http_client).to receive(:post_events)
        .and_raise(Featureflip::HttpStatusError.new(401, "/v1/sdk/events"))

      processor.queue_event(event)
      processor.flush

      allow(http_client).to receive(:post_events).and_return(nil)
      processor.flush

      expect(http_client).to have_received(:post_events).once
    end

    it "drops a 400 without retrying it" do
      allow(http_client).to receive(:post_events)
        .and_raise(Featureflip::HttpStatusError.new(400, "/v1/sdk/events"))

      processor.queue_event(event)
      processor.flush

      allow(http_client).to receive(:post_events).and_return(nil)
      processor.flush

      expect(http_client).to have_received(:post_events).once
    end

    it "says the batch was dropped as non-retryable" do
      allow(http_client).to receive(:post_events)
        .and_raise(Featureflip::HttpStatusError.new(401, "/v1/sdk/events"))

      processor.queue_event(event)
      processor.flush

      expect(logger).to have_received(:warn).with(/not retryable/)
    end
  end

  describe "queue bound" do
    it "sheds the OLDEST events once the bound is reached" do
      allow(http_client).to receive(:post_events)
      bounded = described_class.new(http_client, flush_interval: 30, flush_batch_size: 100,
                                    max_queue_size: 3, logger: logger)

      5.times { |n| bounded.queue_event({ n: n }) }
      bounded.flush

      expect(http_client).to have_received(:post_events).with([{ n: 2 }, { n: 3 }, { n: 4 }])
    end

    it "reports how many events it dropped" do
      allow(http_client).to receive(:post_events)
      bounded = described_class.new(http_client, flush_interval: 30, flush_batch_size: 100,
                                    max_queue_size: 3, logger: logger)

      5.times { |n| bounded.queue_event({ n: n }) }

      expect(logger).to have_received(:warn).with(/dropped 1 of the oldest/).twice
    end

    # A long outage must shed the stale re-queued batches rather than starve new events.
    it "sheds re-queued events too" do
      allow(http_client).to receive(:post_events)
        .and_raise(Featureflip::HttpStatusError.new(503, "/v1/sdk/events"))
      bounded = described_class.new(http_client, flush_interval: 30, flush_batch_size: 100,
                                    max_queue_size: 2, logger: logger)

      bounded.queue_event({ n: 1 })
      bounded.queue_event({ n: 2 })
      bounded.flush

      allow(http_client).to receive(:post_events).and_return(nil)
      bounded.queue_event({ n: 3 })
      bounded.flush

      expect(http_client).to have_received(:post_events).with([{ n: 2 }, { n: 3 }])
    end

    it "defaults the bound to 10,000 events" do
      expect(described_class::DEFAULT_MAX_QUEUE_SIZE).to eq(10_000)
    end
  end

  # Re-queuing is what lets the queue grow to its bound during an outage, and the old flush
  # posted the WHOLE queue in one request. A body that large risks an outright rejection —
  # and a 413 is non-retryable, so the entire backlog would be dropped by the very path
  # added to preserve it.
  describe "draining a backlog" do
    # Builds a five-event backlog by failing every send while they are queued: the first
    # failure arms the backoff gate, so the remaining events just pile up.
    def backlog_of_five(mode_ref)
      sent = []
      allow(http_client).to receive(:post_events) do |events|
        sent << events
        case mode_ref[:mode]
        when :failing then raise Featureflip::HttpStatusError.new(503, "/v1/sdk/events")
        when :poison
          mode_ref[:mode] = :ok
          raise Featureflip::HttpStatusError.new(400, "/v1/sdk/events")
        end
      end

      processor = described_class.new(http_client, flush_interval: 30, flush_batch_size: 2, logger: logger)
      5.times { |n| processor.queue_event({ n: n }) }
      [processor, sent]
    end

    it "never puts more than a batch in one request, and still delivers everything" do
      mode = { mode: :failing }
      processor, sent = backlog_of_five(mode)

      mode[:mode] = :ok
      sent.clear
      processor.flush

      # The batch cap is the assertion that matters: a single 5-event request would deliver
      # everything too, and pass a totals-only check.
      expect(sent.map(&:length)).to all(be <= 2)
      expect(sent.flatten).to eq((0..4).map { |n| { n: n } })
    end

    it "drops a permanently-rejected batch and keeps draining the backlog behind it" do
      mode = { mode: :failing }
      processor, sent = backlog_of_five(mode)

      mode[:mode] = :poison
      sent.clear
      processor.flush

      # [0, 1] is dropped as non-retryable; the events behind it must not go down with it.
      expect(sent).to eq([[{ n: 0 }, { n: 1 }], [{ n: 2 }, { n: 3 }], [{ n: 4 }]])
    end

    it "stops on a retryable failure instead of re-sending the batch it just put back" do
      mode = { mode: :failing }
      processor, sent = backlog_of_five(mode)

      sent.clear
      processor.flush

      # The batch is back at the head of the queue the loop is draining, so continuing
      # would spin for the whole outage.
      expect(sent.length).to eq(1)
    end
  end

  # A re-queued batch leaves the queue at or above the batch size, so without a gate every
  # subsequent tracked event would trigger another flush — turning a failing endpoint into
  # one request per evaluation, which is worse for the server than the dropping this
  # replaced. The background thread's interval tick stays the retry vehicle.
  describe "auto-flush backoff" do
    it "makes only ONE send attempt no matter how many events arrive while the endpoint is down" do
      allow(http_client).to receive(:post_events)
        .and_raise(Featureflip::HttpStatusError.new(503, "/v1/sdk/events"))
      hot = described_class.new(http_client, flush_interval: 30, flush_batch_size: 1, logger: logger)

      10.times { |n| hot.queue_event({ n: n }) }

      expect(http_client).to have_received(:post_events).once
    end

    it "re-opens the size trigger after a successful send" do
      allow(http_client).to receive(:post_events)
      hot = described_class.new(http_client, flush_interval: 30, flush_batch_size: 1, logger: logger)

      3.times { |n| hot.queue_event({ n: n }) }

      expect(http_client).to have_received(:post_events).exactly(3).times
    end

    # The gate is only armed once a flush has already FAILED, and the size trigger fires
    # again long before the first round-trip returns — so the latch is load-bearing on its
    # own, not a belt-and-braces duplicate of the gate.
    it "does not start a second size-triggered flush while one is in flight" do
      in_flight = Queue.new
      release = Queue.new
      calls = []
      calls_mutex = Mutex.new

      allow(http_client).to receive(:post_events) do |events|
        calls_mutex.synchronize { calls << events }
        in_flight << true
        release.pop
        raise Featureflip::HttpStatusError.new(503, "/v1/sdk/events")
      end

      hot = described_class.new(http_client, flush_interval: 30, flush_batch_size: 1, logger: logger)
      blocked = Thread.new { hot.queue_event({ n: 0 }) }
      in_flight.pop # the first flush is now inside post_events

      others = (1..5).map { |n| Thread.new { hot.queue_event({ n: n }) } }
      others.each { |t| expect(t.join(5)).to be(t) }

      release << true
      blocked.join(5)

      expect(calls_mutex.synchronize { calls.length }).to eq(1)
    end
  end

  describe "#stop" do
    it "flushes remaining events" do
      allow(http_client).to receive(:post_events)

      processor.queue_event({ type: "eval", key: "final" })
      processor.stop

      expect(http_client).to have_received(:post_events).with([{ type: "eval", key: "final" }])
    end

    # Nothing flushes after stop, so looping until the queue drains would hang shutdown for
    # as long as the endpoint stayed down. One attempt, then let go.
    it "terminates while the endpoint is failing and discards the remainder" do
      allow(http_client).to receive(:post_events)
        .and_raise(Featureflip::HttpStatusError.new(503, "/v1/sdk/events"))

      processor.queue_event({ type: "eval", key: "a" })
      Timeout.timeout(10) { processor.stop }

      expect(http_client).to have_received(:post_events).once
      # "re-queued for the next flush" would be a lie here — say what actually happened.
      expect(logger).to have_received(:warn).with(/shutting down and will not flush again/)

      # The remainder is discarded rather than held for a flush that will never come.
      allow(http_client).to receive(:post_events).and_return(nil)
      processor.queue_event({ type: "eval", key: "b" })
      processor.flush

      expect(http_client).to have_received(:post_events).once
    end
  end

  # An instance_double cannot prove the shipped Http::Client actually surfaces the status
  # the processor branches on, nor that the single inline retry inside post_events survives
  # this change. These run the real client against a stubbed endpoint.
  describe "against the real Http::Client" do
    let(:events_url) { "https://eval.featureflip.io/v1/sdk/events" }
    let(:config) { Featureflip::Config.new(sdk_key: "sdk-test-key-123", base_url: "https://eval.featureflip.io", logger: logger) }
    let(:real_client) { Featureflip::Http::Client.new("sdk-test-key-123", config) }
    let(:real_processor) { described_class.new(real_client, flush_interval: 30, flush_batch_size: 100, logger: logger) }
    let(:event) { { "type" => "Evaluation", "flagKey" => "dark-mode" } }

    before do
      # post_events sleeps a second before its inline retry; the suite should not.
      allow(real_client).to receive(:sleep)
    end

    it "re-sends a batch that survived the inline retry as a 503" do
      stub_request(:post, events_url)
        .to_return(status: 503, body: "Service Unavailable")
        .then.to_return(status: 503, body: "Service Unavailable")
        .then.to_return(status: 202, body: "")

      real_processor.queue_event(event)
      real_processor.flush # initial attempt + the client's single inline retry, both 503
      real_processor.flush # the batch is still queued, so it goes out again

      expect(WebMock).to have_requested(:post, events_url)
        .with(body: { events: [event] }.to_json).times(3)
    end

    it "drops a batch the endpoint rejected with a 401, without an inline retry" do
      stub_request(:post, events_url).to_return(status: 401, body: "Unauthorized")

      real_processor.queue_event(event)
      real_processor.flush
      real_processor.flush

      expect(WebMock).to have_requested(:post, events_url).times(1)
    end
  end
end
