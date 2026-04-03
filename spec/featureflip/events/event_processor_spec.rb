require "spec_helper"

RSpec.describe Featureflip::Events::EventProcessor do
  let(:http_client) { instance_double(Featureflip::Http::Client) }
  let(:processor) { described_class.new(http_client, flush_interval: 30, flush_batch_size: 3) }

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
      bg_processor = described_class.new(http_client, flush_interval: 60, flush_batch_size: 3)
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

  describe "#stop" do
    it "flushes remaining events" do
      allow(http_client).to receive(:post_events)

      processor.queue_event({ type: "eval", key: "final" })
      processor.stop

      expect(http_client).to have_received(:post_events).with([{ type: "eval", key: "final" }])
    end
  end
end
