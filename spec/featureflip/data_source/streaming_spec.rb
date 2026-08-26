require "spec_helper"
require "timeout"

# Minimal stand-in for a successful Net::HTTP SSE response whose body is handed
# to the reader as arbitrary byte chunks — used to exercise the streaming
# parser's buffering across read_body chunk boundaries. The block form of
# read_body mirrors Net::HTTPResponse#read_body.
class FakeChunkedSseResponse
  def initialize(chunks)
    @chunks = chunks
  end

  def is_a?(klass)
    klass == Net::HTTPSuccess || super
  end

  def read_body(&block)
    @chunks.each(&block)
  end

  def code
    "200"
  end
end

RSpec.describe Featureflip::DataSource::StreamingHandler do
  let(:sdk_key) { "sdk-test-key" }
  let(:config) { Featureflip::Config.new(sdk_key: sdk_key, base_url: "https://eval.featureflip.io") }
  let(:http_client) { instance_double(Featureflip::Http::Client) }
  let(:on_flag_updated) { instance_double(Proc) }
  let(:on_flag_deleted) { instance_double(Proc) }
  let(:on_segment_updated) { instance_double(Proc) }
  let(:on_error) { instance_double(Proc) }
  let(:on_sync) { instance_double(Proc) }
  let(:on_give_up) { instance_double(Proc) }
  let(:handler) do
    described_class.new(
      sdk_key: sdk_key,
      config: config,
      http_client: http_client,
      on_flag_updated: on_flag_updated,
      on_flag_deleted: on_flag_deleted,
      on_segment_updated: on_segment_updated,
      on_error: on_error,
      on_sync: on_sync
    )
  end

  def build_handler(**overrides)
    described_class.new(
      **{
        sdk_key: sdk_key, config: config, http_client: http_client,
        on_flag_updated: on_flag_updated, on_flag_deleted: on_flag_deleted,
        on_segment_updated: on_segment_updated, on_error: on_error,
        on_sync: on_sync
      }.merge(overrides)
    )
  end

  # Stub Net::HTTP so #connect yields the given (already-successful) response
  # instead of opening a socket.
  def stub_streaming_connection(response)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_yield(response).and_return(response)
    http
  end

  def flag_hash(key)
    {
      "key" => key, "version" => 1, "type" => "Boolean", "enabled" => true,
      "variations" => [{ "key" => "true", "value" => true }, { "key" => "false", "value" => false }],
      "rules" => [],
      "fallthrough" => { "type" => "Fixed", "variation" => "true" },
      "offVariation" => "false"
    }
  end

  describe "#process_sse_line" do
    it "parses event type and data lines for flag.updated" do
      flag = instance_double(Featureflip::Models::FlagConfiguration)
      allow(http_client).to receive(:get_flag).with("my-flag").and_return(flag)
      allow(on_flag_updated).to receive(:call)

      handler.send(:process_sse_line, "event: flag.updated")
      handler.send(:process_sse_line, 'data: {"key":"my-flag"}')
      handler.send(:process_sse_line, "")

      expect(http_client).to have_received(:get_flag).with("my-flag")
      expect(on_flag_updated).to have_received(:call).with(flag)
    end
  end

  describe "#handle_event" do
    it "fetches updated flag and calls on_flag_updated for flag.updated" do
      flag = instance_double(Featureflip::Models::FlagConfiguration)
      allow(http_client).to receive(:get_flag).with("test-flag").and_return(flag)
      allow(on_flag_updated).to receive(:call)

      handler.send(:handle_event, "flag.updated", '{"key":"test-flag"}')

      expect(http_client).to have_received(:get_flag).with("test-flag")
      expect(on_flag_updated).to have_received(:call).with(flag)
    end

    it "fetches created flag and calls on_flag_updated for flag.created" do
      flag = instance_double(Featureflip::Models::FlagConfiguration)
      allow(http_client).to receive(:get_flag).with("new-flag").and_return(flag)
      allow(on_flag_updated).to receive(:call)

      handler.send(:handle_event, "flag.created", '{"key":"new-flag"}')

      expect(http_client).to have_received(:get_flag).with("new-flag")
      expect(on_flag_updated).to have_received(:call).with(flag)
    end

    it "calls on_flag_deleted with key for flag.deleted" do
      allow(on_flag_deleted).to receive(:call)

      handler.send(:handle_event, "flag.deleted", '{"key":"removed-flag"}')

      expect(on_flag_deleted).to have_received(:call).with("removed-flag")
    end

    it "calls on_segment_updated with flags and segments for segment.updated" do
      flags = [instance_double(Featureflip::Models::FlagConfiguration)]
      segments = [instance_double(Featureflip::Models::Segment)]
      allow(http_client).to receive(:get_flags).and_return([flags, segments])
      allow(on_segment_updated).to receive(:call)

      handler.send(:handle_event, "segment.updated", '{"key":"seg-1"}')

      expect(http_client).to have_received(:get_flags)
      expect(on_segment_updated).to have_received(:call).with(flags, segments)
    end

    it "ignores nil key for flag.updated" do
      allow(http_client).to receive(:get_flag)
      allow(on_flag_updated).to receive(:call)

      handler.send(:handle_event, "flag.updated", '{"key":null}')

      expect(http_client).not_to have_received(:get_flag)
      expect(on_flag_updated).not_to have_received(:call)
    end

    it "ignores nil key for flag.deleted" do
      allow(on_flag_deleted).to receive(:call)

      handler.send(:handle_event, "flag.deleted", '{"key":null}')

      expect(on_flag_deleted).not_to have_received(:call)
    end
  end

  describe "SSE read timeout (GAP 5)" do
    it "is a finite liveness watchdog: above the ping but bounded to a few missed pings" do
      t = described_class::STREAM_READ_TIMEOUT
      ping = described_class::SERVER_PING_INTERVAL_SECONDS
      # A nil (infinite) read timeout leaves a half-open socket blocked forever
      # with no recovery path — the watchdog MUST be finite.
      expect(t).to be_a(Numeric)
      expect(t).to be > ping        # never severs a healthy stream (data every ping)
      expect(t).to be <= ping * 4   # but detects a dead socket within a few missed pings
    end

    it "applies STREAM_READ_TIMEOUT to the SSE connection" do
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      expect(http).to receive(:read_timeout=).with(described_class::STREAM_READ_TIMEOUT)
      # Short-circuit before the blocking read loop.
      allow(http).to receive(:request).and_raise(Featureflip::Error)

      expect { handler.send(:connect) }.to raise_error(Featureflip::Error)
    end
  end

  describe "#handle_event sync (GAP 1)" do
    it "parses the inline snapshot and calls on_sync with flags and segments" do
      flags = [instance_double(Featureflip::Models::FlagConfiguration)]
      segments = [instance_double(Featureflip::Models::Segment)]
      snapshot = { "flags" => [{ "key" => "flag-a" }], "segments" => [] }
      allow(http_client).to receive(:parse_flags_response).with(snapshot).and_return([flags, segments])
      allow(on_sync).to receive(:call)

      handler.send(:handle_event, "sync", snapshot.to_json)

      expect(http_client).to have_received(:parse_flags_response).with(snapshot)
      expect(on_sync).to have_received(:call).with(flags, segments)
    end
  end

  describe "sync applies a full store replace (deleted flag dropped)" do
    it "drops a flag that is absent from the sync snapshot" do
      store = Featureflip::Store::FlagStore.new
      real_client = Featureflip::Http::Client.new(sdk_key, config)
      seed_flags, seed_segments = real_client.parse_flags_response(
        { "flags" => [flag_hash("stale"), flag_hash("fresh")], "segments" => [] }
      )
      store.init(seed_flags, seed_segments)

      sync_handler = described_class.new(
        sdk_key: sdk_key, config: config, http_client: real_client,
        on_flag_updated: on_flag_updated, on_flag_deleted: on_flag_deleted,
        on_segment_updated: on_segment_updated, on_error: on_error,
        on_sync: ->(flags, segments) { store.init(flags, segments) }
      )

      sync_handler.send(:handle_event, "sync", { "flags" => [flag_hash("fresh")], "segments" => [] }.to_json)

      expect(store.get_flag("stale")).to be_nil
      expect(store.get_flag("fresh")).not_to be_nil
    end
  end

  describe "SSE parser buffers across read_body chunk boundaries (#1891)" do
    it "reassembles a sync snapshot split mid-line across many small chunks" do
      real_client = Featureflip::Http::Client.new(sdk_key, config)
      store = Featureflip::Store::FlagStore.new
      handler = build_handler(http_client: real_client, on_sync: ->(flags, segments) { store.init(flags, segments) })

      snapshot = { "flags" => [flag_hash("a"), flag_hash("b"), flag_hash("c")], "segments" => [] }
      body = "event: sync\ndata: #{snapshot.to_json}\n\n"
      chunks = body.scan(/.{1,48}/m) # force boundaries mid-line and mid-`data:`
      expect(chunks.length).to be > 1

      stub_streaming_connection(FakeChunkedSseResponse.new(chunks))
      handler.send(:connect)

      expect(store.get_flag("a")).not_to be_nil
      expect(store.get_flag("b")).not_to be_nil
      expect(store.get_flag("c")).not_to be_nil
    end

    it "reassembles a multibyte UTF-8 payload split across a byte-level chunk boundary" do
      real_client = Featureflip::Http::Client.new(sdk_key, config)
      store = Featureflip::Store::FlagStore.new
      handler = build_handler(http_client: real_client, on_sync: ->(flags, segments) { store.init(flags, segments) })

      key = "flag-café-🚀"
      snapshot = { "flags" => [flag_hash(key)], "segments" => [] }
      body = "event: sync\ndata: #{snapshot.to_json}\n\n"
      # 3-byte binary chunks guarantee a multibyte character is split mid-sequence.
      body.b.scan(/.{1,3}/m).each { |chunk| handler.send(:feed_chunk, chunk) }

      expect(store.get_flag(key)).not_to be_nil
    end

    it "joins multiple data: lines with a newline before dispatch (SSE multi-line data)" do
      captured = nil
      handler = build_handler(on_sync: ->(flags, _segments) { captured = flags })
      allow(http_client).to receive(:parse_flags_response) { |data| [[data["flags"]], []] }

      # A JSON object split across two data: lines; per the SSE spec they join
      # with a newline, yielding valid JSON. Overwriting (the bug) keeps only the
      # last fragment, which fails to parse.
      handler.send(:process_sse_line, "event: sync")
      handler.send(:process_sse_line, 'data: {"flags":[1,')
      handler.send(:process_sse_line, "data: 2,3]}")
      handler.send(:process_sse_line, "")

      expect(captured).to eq([[1, 2, 3]])
    end
  end

  describe "#connect signals whether the stream delivered a frame (#1893)" do
    it "returns false when the stream returns 200 then EOFs without any frame" do
      stub_streaming_connection(FakeChunkedSseResponse.new([]))
      expect(handler.send(:connect)).to be(false)
    end

    it "returns true once the connect-time sync frame is delivered" do
      allow(http_client).to receive(:parse_flags_response).and_return([[], []])
      allow(on_sync).to receive(:call)
      body = "event: sync\ndata: {\"flags\":[],\"segments\":[]}\n\n"
      stub_streaming_connection(FakeChunkedSseResponse.new([body]))

      expect(handler.send(:connect)).to be(true)
    end
  end

  describe "#run backs off on clean EOF and escalates without an error (#1893)" do
    it "reconnects with backoff after each clean EOF and escalates to give-up" do
      local = build_handler(on_give_up: on_give_up)
      allow(on_give_up).to receive(:call)
      allow(on_error).to receive(:call)

      calls = 0
      allow(local).to receive(:connect) do
        calls += 1
        raise "runaway reconnect loop (no backoff)" if calls > 100
        false # 200, clean EOF, zero frames delivered — must NOT reset retry_count
      end
      backoffs = []
      allow(local).to receive(:backoff_wait) { |delay| backoffs << delay }

      local.send(:run)

      expect(on_give_up).to have_received(:call).once  # accumulated to the fallback threshold
      expect(on_error).not_to have_received(:call)     # a clean EOF is not an error
      expect(backoffs).not_to be_empty                 # backed off between reconnects
      expect(backoffs).to all(be > 0)                  # never a zero-delay busy-loop
    end

    it "resets the failure counter when a delivered stream drops via exception (watchdog/reset)" do
      local = build_handler(on_give_up: on_give_up)
      allow(on_give_up).to receive(:call)
      allow(on_error).to receive(:call)
      allow(local).to receive(:backoff_wait)

      # The common real-world termination: each session delivers a frame, then the
      # socket drops (liveness-watchdog Net::ReadTimeout / ECONNRESET) — connect
      # RAISES rather than returning. A healthy-then-dropped session must reset
      # the failure counter, never accumulate toward the polling fallback.
      attempts = 0
      allow(local).to receive(:connect) do
        attempts += 1
        local.instance_variable_set(:@delivered_frame, true)
        local.instance_variable_set(:@stop_flag, true) if attempts >= 10
        raise IOError, "socket dropped"
      end

      local.send(:run)

      expect(attempts).to be >= 10                # ran well past max_stream_retries (5)
      expect(on_give_up).not_to have_received(:call)
    end
  end

  describe "#stop interrupts a thread blocked on a read (#1892 — no leaked thread)" do
    it "terminates the streaming thread even while it is blocked in read_body" do
      reader, writer = IO.pipe
      read_started = Queue.new
      response = instance_double(Net::HTTPResponse)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(response).to receive(:read_body) do |&_block|
        read_started << :blocked
        reader.read # real blocking syscall; Thread#wakeup can't interrupt it, Thread#raise can
      end
      stub_streaming_connection(response)
      allow(on_error).to receive(:call)

      handler.start
      Timeout.timeout(5) { read_started.pop } # wait until the read is actually blocking
      thread = handler.instance_variable_get(:@thread)

      handler.stop

      expect(thread).not_to be_alive
    ensure
      reader&.close
      writer&.close
    end
  end

  describe "#backoff_delay jitters every level (#2508)" do
    # The drops this backoff absorbs are fleet-wide: one edge event severs every
    # stream at once (#2457 — measured at a 2.5-3.0ms spread across both eval-api
    # pods), so every client re-enters the backoff at failures == 0 together. A
    # constant there republishes the drop's own synchronisation as a reconnect
    # spike one base delay later.
    let(:handler) { build_handler }
    let(:base) { described_class::RECONNECT_BASE_DELAY_SECONDS }

    it "scatters the first reconnect instead of returning a constant" do
      samples = 200.times.flat_map { |_| [0, 1].map { |f| handler.send(:backoff_delay, f) } }.uniq

      expect(samples.size).to be > 1,
        "first-reconnect delay is deterministic (#{samples.size} distinct value(s)) — " \
        "a fleet-wide drop reconnects in lockstep"
    end

    it "keeps the first reconnect inside [base/2, base] and strictly positive" do
      200.times do
        [0, 1].each do |failures|
          delay = handler.send(:backoff_delay, failures)
          expect(delay).to be_between(base / 2.0, base)
          expect(delay).to be > 0 # anti-busy-loop on a clean EOF
        end
      end
    end

    it "still escalates and caps, each level jittered" do
      expect(handler.send(:backoff_delay, 2)).to be_between(base, base * 2)
      expect(handler.send(:backoff_delay, 50))
        .to be_between(described_class::MAX_BACKOFF_SECONDS / 2.0, described_class::MAX_BACKOFF_SECONDS)
    end
  end
end
