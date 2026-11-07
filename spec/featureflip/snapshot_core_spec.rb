require "spec_helper"
require "tmpdir"
require "json"
require "logger"

# Core-level tests for the snapshot store: the data source is stubbed and the
# initial fetch is driven directly, so nothing here races a poller thread.
RSpec.describe "snapshot store in the shared core" do
  let(:sdk_key) { "sdk-snapshot-key" }
  let(:base_url) { "https://eval.featureflip.io" }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, debug: nil, error: nil) }
  let(:dir) { Dir.mktmpdir("ff-snapcore") }
  let(:snapshot) { Featureflip::Snapshot }
  let(:clock_state) { { wall: 1_800_000_000_000, mono: 1000.0 } }
  let(:clock) do
    state = clock_state
    Featureflip::SharedCore::Clock.new(-> { state[:wall] }, -> { state[:mono] })
  end

  after { FileUtils.rm_rf(dir) }

  def flag_json(key, enabled: true, value: true)
    {
      "key" => key, "version" => 1, "type" => "Boolean", "enabled" => enabled,
      "variations" => [{ "key" => "true", "value" => value }, { "key" => "false", "value" => false }],
      "rules" => [], "fallthrough" => { "type" => "Fixed", "variation" => "true" }, "offVariation" => "false",
      "prerequisites" => []
    }
  end

  def payload(*flags) = { "flags" => flags, "segments" => [] }

  def model(key, enabled: true)
    flags, = Featureflip::Http::Client.new(nil, Struct.new(:logger, :base_url).new(nil, "")).parse_flags_response(
      payload(flag_json(key, enabled: enabled))
    )
    flags.first
  end

  def stored_text(flag_keys, fetched_at:, url: base_url, key: sdk_key)
    flags = flag_keys.map { |k| model(k) }
    data = snapshot.serialize_flags_payload(flags, [])
    snapshot.encode_envelope(snapshot.compute_key_hash(url, key), fetched_at, data)
  end

  def make_config(**overrides)
    Featureflip::Config.new(
      streaming: false, send_events: false, poll_interval: 9999, logger: logger,
      init_timeout: 2, **overrides
    )
  end

  # Builds a core whose initial fetch behaves as +fetch+ says: :ok, an exception, or
  # a Proc. The data source is stubbed out.
  def build_core(store:, fetch: :ok, config: nil, key: sdk_key, flags: [flag_json("f")])
    config ||= make_config(snapshot_store: store)
    allow_any_instance_of(Featureflip::SharedCore).to receive(:start_data_source)
    allow_any_instance_of(Featureflip::Http::Client).to receive(:get_flags) do |client|
      case fetch
      when :ok then client.parse_flags_response(payload(*flags))
      when Proc then fetch.call
      else raise fetch
      end
    end
    Featureflip::SharedCore.new(sdk_key: key, config: config, clock: clock)
  end

  def wait_until(timeout = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end

  def down(status = 503) = Featureflip::HttpStatusError.new(status, "/v1/sdk/flags")

  describe "healthy start" do
    it "writes the snapshot and never reads the store" do
      store = SpecSupport::RecordingStore.new
      core = build_core(store: store)
      wait_until { store.count >= 1 }

      sleep 0.1
      expect(store.count).to eq(1) # exactly one write for the healthy start
      expect(store.gets).to eq(0)
      expect(core.startup_info).to eq(Featureflip::StartupInfo.new("live"))
      env = JSON.parse(store.texts.first)
      expect(env["v"]).to eq(1)
      expect(env["fetchedAt"]).to eq(clock_state[:wall])
      expect(env["keyHash"]).to eq(snapshot.compute_key_hash(base_url, sdk_key))
      expect(store.texts.first).not_to include(sdk_key)
      expect(env["data"]["flags"].map { |f| f["key"] }).to eq(["f"])
    end

    it "does not touch the store at all without one configured" do
      core = build_core(store: nil, config: make_config)
      expect(core.startup_info.source).to eq("live")
    end
  end

  describe "starting from a snapshot" do
    it "falls back after a fetch error and serves the stored flags" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] - 90_500))
      core = build_core(store: store, fetch: down(503))

      expect(core.initialized?).to be(true)
      info = core.startup_info
      expect(info.source).to eq("snapshot")
      expect(info.reason).to eq("snapshot")
      expect(info.snapshot_age_seconds).to eq(90)
      expect(core.bool_variation("f", { "user_id" => "u" }, false)).to be(true)
      expect(store.texts).to eq([]) # loading a snapshot never writes
      expect(logger).to have_received(:warn).with(/HTTP 503.*serving persisted snapshot \(90s old\)/)
    end

    it "falls back when the initial fetch times out" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] - 1000))
      config = make_config(snapshot_store: store, init_timeout: 0.3)
      core = build_core(store: store, config: config, fetch: -> { sleep 5 })

      expect(core.startup_info.source).to eq("snapshot")
      expect(logger).to have_received(:warn).with(/timed out after 0.3s/)
    end

    it "names the cause for a revoked key without leaking the key" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] - 1000))
      build_core(store: store, fetch: down(401))
      expect(logger).to have_received(:warn).with(/HTTP 401/)
      expect(logger).not_to have_received(:warn).with(/#{sdk_key}/)
    end

    it "reports snapshot-expired and serves defaults" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] - 86_401_000))
      core = build_core(store: store, fetch: down)

      expect(core.initialized?).to be(true)
      expect(core.startup_info).to eq(Featureflip::StartupInfo.new("none", "snapshot-expired", 86_401))
      expect(core.bool_variation("f", {}, false)).to be(false)
    end

    it "accepts a snapshot exactly at the max age" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] - 86_400_000))
      core = build_core(store: store, fetch: down)
      expect(core.startup_info.source).to eq("snapshot")
    end

    it "honors max_snapshot_age_seconds" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] - 11_000))
      config = make_config(snapshot_store: store, max_snapshot_age_seconds: 10)
      core = build_core(store: store, config: config, fetch: down)
      expect(core.startup_info.reason).to eq("snapshot-expired")
    end

    it "clamps the age of a snapshot up to 60 s in the future to 0" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] + 60_000))
      core = build_core(store: store, fetch: down)
      expect(core.startup_info).to eq(Featureflip::StartupInfo.new("snapshot", "snapshot", 0))
    end

    it "rejects a snapshot more than 60 s in the future" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] + 61_000))
      core = build_core(store: store, fetch: down)
      expect(core.startup_info).to eq(Featureflip::StartupInfo.new("none", "snapshot-invalid", nil))
    end

    it "treats no stored text as a plain miss: no reason, no ignore warning" do
      store = SpecSupport::RecordingStore.new(nil)
      core = build_core(store: store, fetch: down)
      expect(core.initialized?).to be(true)
      expect(core.startup_info).to eq(Featureflip::StartupInfo.new("none"))
      expect(logger).not_to have_received(:warn).with(/ignoring persisted snapshot/)
      expect(logger).to have_received(:warn).with(/HTTP 503.*no persisted snapshot; serving defaults/)
      expect(logger).not_to have_received(:warn).with(/#{sdk_key}/)
    end

    it "treats empty and non-text values as snapshot-invalid" do
      ["", 42].each do |value|
        core = build_core(store: SpecSupport::RecordingStore.new(value), fetch: down)
        expect(core.startup_info.reason).to eq("snapshot-invalid")
        expect(core.startup_info.source).to eq("none")
      end
    end

    it "keeps the old behavior without a store: a failed init raises" do
      expect { build_core(store: nil, config: make_config, fetch: down(500)) }
        .to raise_error(Featureflip::InitializationError, /Failed to initialize/)
      expect { build_core(store: nil, config: make_config(init_timeout: 0.2), fetch: -> { sleep 3 }) }
        .to raise_error(Featureflip::InitializationError, /timed out/)
    end

    it "serves defaults and is initialized when a store has nothing usable" do
      core = build_core(store: SpecSupport::RecordingStore.new, fetch: down)
      expect(core.initialized?).to be(true)
      expect(core.bool_variation("f", {}, false)).to be(false)
    end
  end

  describe "through the real file store" do
    let(:path) { File.join(dir, "snap.json") }
    let(:file_store) { Featureflip::FileSnapshotStore.new(path, logger: logger) }
    let(:good) { stored_text(["f"], fetched_at: clock_state[:wall] - 5000) }

    def start_with(text, **opts)
      File.write(path, text) unless text.nil?
      config = make_config(snapshot_store: file_store, **opts)
      build_core(store: file_store, config: config, fetch: down)
    end

    it "uses a good file" do
      expect(start_with(good).startup_info.source).to eq("snapshot")
    end

    {
      "garbage" => "not a snapshot at all",
      "truncated" => nil,
      "a v:2 envelope" => nil,
      "another SDK key" => nil,
      "another base URL" => nil,
      "a future fetchedAt" => nil
    }.each_key do |name|
      it "reports snapshot-invalid for #{name}" do
        text = case name
               when "garbage" then "not a snapshot at all"
               when "truncated" then good[0, good.length / 2]
               when "a v:2 envelope" then good.sub('"v":1', '"v":2')
               when "another SDK key" then stored_text(["f"], fetched_at: clock_state[:wall], key: "another-key")
               when "another base URL" then stored_text(["f"], fetched_at: clock_state[:wall], url: "https://other.example")
               else stored_text(["f"], fetched_at: clock_state[:wall] + 3_600_000)
               end
        info = start_with(text).startup_info
        expect(info.source).to eq("none")
        expect(info.reason).to eq("snapshot-invalid")
      end
    end

    it "treats a missing file as a plain miss" do
      info = start_with(nil).startup_info
      expect(info).to eq(Featureflip::StartupInfo.new("none"))
    end

    it "never leaks one SDK key's flags to another through a shared store" do
      writer = build_core(store: file_store, key: "key-one", config: make_config(snapshot_store: file_store))
      wait_until { File.exist?(path) }
      writer._release

      other = build_core(store: file_store, key: "key-two", fetch: down,
                         config: make_config(snapshot_store: file_store))
      expect(other.startup_info.reason).to eq("snapshot-invalid")
      expect(other.bool_variation("f", {}, false)).to be(false)
    end
  end

  describe "store failures" do
    it "treats a throwing get as a miss with a warning" do
      store = SpecSupport::RecordingStore.new
      store.get_error = RuntimeError.new("redis down")
      core = build_core(store: store, fetch: down)
      expect(core.initialized?).to be(true)
      expect(core.startup_info).to eq(Featureflip::StartupInfo.new("none"))
      expect(logger).to have_received(:warn).with(/snapshot store read failed: redis down/)
    end

    it "bounds a hung get by the init timeout and ignores the late result" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] - 1000))
      store.get_delay = 1.5
      config = make_config(snapshot_store: store, init_timeout: 0.3)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      core = build_core(store: store, config: config, fetch: down)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 1.2
      expect(core.initialized?).to be(true)
      expect(core.startup_info).to eq(Featureflip::StartupInfo.new("none"))
      sleep 1.4
      expect(core.startup_info.source).to eq("none")
      expect(core.bool_variation("f", {}, false)).to be(false)
      expect(logger).to have_received(:warn).with(/snapshot store read timed out/)
    end

    it "drops a throwing put with a warning and keeps going" do
      store = SpecSupport::RecordingStore.new
      store.put_error = RuntimeError.new("disk full")
      warnings = Queue.new
      allow(logger).to receive(:warn) { |msg| warnings << msg }
      core = build_core(store: store)
      expect(core.initialized?).to be(true)
      seen = []
      wait_until { (seen << warnings.pop) && seen.last.include?("disk full") }
      store.put_error = nil
      core.send(:apply_snapshot, [model("g")], [])
      wait_until { store.count >= 1 }
    end
  end

  describe "recovery from a snapshot" do
    it "fires listeners for the diff on the first live apply and moves startup info to live" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] - 1000))
      core = build_core(store: store, fetch: down)
      seen = []
      core._add_update_listener(->(keys) { seen << keys })
      expect(core.startup_info.source).to eq("snapshot")
      expect(seen).to eq([])

      core.send(:apply_snapshot, [model("f", enabled: false), model("g")], [])

      expect(seen).to eq([%w[f g]])
      expect(core.startup_info).to eq(Featureflip::StartupInfo.new("live"))
      wait_until { store.count >= 1 } # the first live full apply always writes
    end

    it "treats the first live apply after a none start as a silent baseline" do
      store = SpecSupport::RecordingStore.new
      core = build_core(store: store, fetch: down)
      seen = []
      core._add_update_listener(->(keys) { seen << keys })
      core.send(:apply_snapshot, [model("f")], [])
      expect(seen).to eq([])
      expect(core.startup_info.source).to eq("live")
    end

    it "persists single-flag deltas only after the client is live" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] - 1000))
      core = build_core(store: store, fetch: down)

      core.send(:apply_flag_update, model("f", enabled: false))
      core.send(:apply_flag_delete, "f")
      sleep 0.1
      expect(store.count).to eq(0)

      core.send(:apply_snapshot, [model("f")], [])
      wait_until { store.count == 1 }
      core.send(:apply_flag_update, model("g"))
      wait_until { store.count == 2 }
      core.send(:apply_flag_delete, "g")
      wait_until { store.count == 3 }
      expect(JSON.parse(store.texts.last)["data"]["flags"].map { |f| f["key"] }).to eq(["f"])
    end
  end

  describe "write coalescing" do
    it "keeps one put in flight plus one trailing write that reads the state when it runs" do
      store = SpecSupport::RecordingStore.new
      store.hold_puts!
      core = build_core(store: store)
      store.wait_for_put_entry # first put is held

      core.send(:apply_snapshot, [model("f"), model("a")], [])
      core.send(:apply_snapshot, [model("f"), model("a"), model("b")], [])
      store.release_put
      store.wait_for_put_entry
      store.release_put
      wait_until { store.count == 2 }
      sleep 0.1

      expect(store.count).to eq(2)
      keys = JSON.parse(store.texts.last)["data"]["flags"].map { |f| f["key"] }
      expect(keys).to eq(%w[a b f])
    end

    it "starts no trailing write once the core is shut down and does not wait for the pending one" do
      store = SpecSupport::RecordingStore.new
      store.hold_puts!
      core = build_core(store: store)
      store.wait_for_put_entry
      core.send(:apply_snapshot, [model("f"), model("a")], [])

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      core._release
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      store.release_put
      wait_until { store.count == 1 }
      sleep 0.15
      expect(store.count).to eq(1)
    end

    it "does not wedge persistence or break init when the writer cannot start" do
      store = SpecSupport::RecordingStore.new
      calls = 0
      allow_any_instance_of(Featureflip::SharedCore).to receive(:start_write_thread).and_wrap_original do |orig, *args|
        calls += 1
        raise ThreadError, "can't create Thread" if calls == 1

        orig.call(*args)
      end
      core = build_core(store: store)
      expect(core.initialized?).to be(true)
      expect(store.count).to eq(0)

      core.send(:apply_snapshot, [model("f"), model("a")], [])
      wait_until { store.count == 1 }
    end
  end

  describe "write slot robustness" do
    it "resets a claimed slot on restart (a forked child has no writer thread)" do
      store = SpecSupport::RecordingStore.new
      core = build_core(store: store)
      wait_until { store.count == 1 }
      allow_any_instance_of(Featureflip::SharedCore).to receive(:start_polling)

      # The parent's writer is gone in the child but the slot is still claimed.
      core.instance_variable_set(:@persist_in_flight, true)
      core.instance_variable_set(:@persist_queued, true)
      core.restart
      core.send(:apply_snapshot, [model("f"), model("after-restart")], [])

      wait_until { store.count == 2 }
    end

    it "releases the slot when a non-StandardError escapes before the writer starts" do
      boom = Class.new(Exception) # rubocop:disable Lint/InheritException
      store = SpecSupport::RecordingStore.new
      calls = 0
      allow_any_instance_of(Featureflip::SharedCore).to receive(:start_write_thread).and_wrap_original do |orig, *args|
        calls += 1
        raise boom, "interrupted" if calls == 2

        orig.call(*args)
      end
      core = build_core(store: store)
      wait_until { store.count == 1 }

      expect { core.send(:apply_snapshot, [model("f"), model("a")], []) }.to raise_error(boom)
      core.send(:apply_snapshot, [model("f"), model("a"), model("b")], [])
      wait_until { store.count == 2 }
    end

    it "does not release a slot a live writer owns when an exception lands after the thread starts" do
      boom = Class.new(Exception) # rubocop:disable Lint/InheritException
      store = SpecSupport::RecordingStore.new
      core = build_core(store: store)
      wait_until { store.count == 1 }
      store.hold_puts!
      allow_any_instance_of(Featureflip::SharedCore).to receive(:silence_thread_report).and_raise(boom)

      expect { core.send(:apply_snapshot, [model("f"), model("a")], []) }.to raise_error(boom)
      store.wait_for_put_entry # the writer is live and holding the slot
      core.send(:apply_snapshot, [model("f"), model("a"), model("b")], [])
      sleep 0.15
      expect(store.entries).to eq(2) # the healthy-start put plus the held one; no second writer

      store.release_put
      store.wait_for_put_entry # the queued trailing write runs after the first
      store.release_put
      wait_until { store.count == 3 }
    end

    it "does not let a timeout landing after a successful fetch fall back over live data" do
      stale = stored_text(["stale"], fetched_at: clock_state[:wall] - 1000)
      store = SpecSupport::RecordingStore.new(stale)
      config = make_config(snapshot_store: store, init_timeout: 0.2)
      allow_any_instance_of(Featureflip::SharedCore).to receive(:apply_snapshot).and_wrap_original do |orig, *args|
        sleep 0.5
        orig.call(*args)
      end
      core = build_core(store: store, config: config)

      expect(core.startup_info.source).to eq("live")
      expect(store.gets).to eq(0)
      expect(core.bool_variation("f", {}, false)).to be(true)
    end
  end

  describe "refresh rule" do
    it "rewrites an unchanged state on a ping at most once per 300 s" do
      store = SpecSupport::RecordingStore.new
      core = build_core(store: store)
      wait_until { store.count == 1 }

      clock_state[:mono] += 299
      core.send(:on_streaming_ping)
      sleep 0.1
      expect(store.count).to eq(1)

      clock_state[:mono] += 2
      clock_state[:wall] += 301_000
      core.send(:on_streaming_ping)
      wait_until { store.count == 2 }
      expect(JSON.parse(store.texts.last)["fetchedAt"]).to eq(clock_state[:wall])

      core.send(:on_streaming_ping)
      sleep 0.1
      expect(store.count).to eq(2)
    end

    it "skips an unchanged full apply inside the window but writes changed content at once" do
      store = SpecSupport::RecordingStore.new
      core = build_core(store: store)
      wait_until { store.count == 1 }

      core.send(:apply_snapshot, [model("f")], [])
      sleep 0.1
      expect(store.count).to eq(1)

      core.send(:apply_snapshot, [model("f", enabled: false)], [])
      wait_until { store.count == 2 }

      clock_state[:mono] += 301
      core.send(:apply_snapshot, [model("f", enabled: false)], [])
      wait_until { store.count == 3 }
    end

    it "never refreshes for a none start until the first live apply" do
      store = SpecSupport::RecordingStore.new
      core = build_core(store: store, fetch: down)
      clock_state[:mono] += 1000
      core.send(:on_streaming_ping)
      sleep 0.1
      expect(store.count).to eq(0)

      core.send(:apply_snapshot, [model("f")], [])
      wait_until { store.count == 1 }
    end

    it "never refreshes for a snapshot or none start until the first live apply" do
      store = SpecSupport::RecordingStore.new(stored_text(["f"], fetched_at: clock_state[:wall] - 1000))
      core = build_core(store: store, fetch: down)
      clock_state[:mono] += 1000
      core.send(:on_streaming_ping)
      sleep 0.1
      expect(store.count).to eq(0)

      core.send(:apply_snapshot, [model("f")], [])
      wait_until { store.count == 1 }
      clock_state[:mono] += 301
      core.send(:on_streaming_ping)
      wait_until { store.count == 2 }
    end

    it "does not refresh without a store" do
      core = build_core(store: nil, config: make_config)
      expect { core.send(:on_streaming_ping) }.not_to raise_error
    end
  end

  describe "through the real streaming handler" do
    let(:store) { SpecSupport::RecordingStore.new }

    # The core's own wiring: callbacks are built by start_streaming, frames are fed to
    # the handler's real SSE parser. Only the socket (Handler#start) is stubbed.
    def streaming_core(fetch: :ok)
      allow_any_instance_of(Featureflip::DataSource::StreamingHandler).to receive(:start)
      core = build_core(store: store, fetch: fetch, config: make_config(snapshot_store: store, streaming: true))
      core.send(:start_streaming)
      [core, core.instance_variable_get(:@streaming_handler)]
    end

    def frame(handler, event, data = "{}")
      handler.send(:feed_chunk, "event: #{event}\ndata: #{data}\n\n")
    end

    it "refreshes the unchanged state on a ping frame once the window has passed" do
      _core, handler = streaming_core
      wait_until { store.count == 1 }

      clock_state[:mono] += 100
      frame(handler, "ping")
      sleep 0.1
      expect(store.count).to eq(1)

      clock_state[:mono] += 201
      frame(handler, "ping")
      wait_until { store.count == 2 }
    end

    it "persists a sync frame" do
      _core, handler = streaming_core
      wait_until { store.count == 1 }

      frame(handler, "sync", payload(flag_json("f"), flag_json("synced")).to_json)
      wait_until { store.count == 2 }
      keys = JSON.parse(store.texts.last)["data"]["flags"].map { |f| f["key"] }
      expect(keys).to eq(%w[f synced])
    end

    it "persists the refetch after a segment.updated frame" do
      calls = 0
      fetch = lambda do
        calls += 1
        calls == 1 ? [[model("f")], []] : [[model("f"), model("after-segment")], []]
      end
      _core, handler = streaming_core(fetch: fetch)
      wait_until { store.count == 1 }

      frame(handler, "segment.updated", '{"key":"seg"}')
      wait_until { store.count == 2 }
      keys = JSON.parse(store.texts.last)["data"]["flags"].map { |f| f["key"] }
      expect(keys).to eq(%w[after-segment f])
    end

    it "persists flag.updated and flag.deleted deltas when live" do
      allow_any_instance_of(Featureflip::Http::Client).to receive(:get_flag).and_return(model("delta"))
      _core, handler = streaming_core
      wait_until { store.count == 1 }

      frame(handler, "flag.updated", '{"key":"delta"}')
      wait_until { store.count == 2 }
      expect(JSON.parse(store.texts.last)["data"]["flags"].map { |f| f["key"] }).to eq(%w[delta f])

      frame(handler, "flag.deleted", '{"key":"delta"}')
      wait_until { store.count == 3 }
      expect(JSON.parse(store.texts.last)["data"]["flags"].map { |f| f["key"] }).to eq(["f"])
    end
  end

  describe "factory option-ignored warning" do
    let(:store_a) { SpecSupport::RecordingStore.new }
    let(:store_b) { SpecSupport::RecordingStore.new }

    before do
      stub_request(:get, /v1\/sdk\/flags/).to_return(status: 200, body: payload.to_json)
    end

    def get_core(**opts)
      Featureflip::SharedCore._get_or_create(sdk_key, make_config(**opts))
    end

    it "warns when a later get passes a different store instance" do
      get_core(snapshot_store: store_a)
      get_core(snapshot_store: store_b)
      expect(logger).to have_received(:warn).with(/snapshot_store.*option ignored/)
    end

    it "stays silent for the same store instance, an omitted store and an omitted max age" do
      get_core(snapshot_store: store_a, max_snapshot_age_seconds: 600)
      get_core(snapshot_store: store_a)
      get_core
      expect(logger).not_to have_received(:warn).with(/option ignored/)
    end

    it "warns for an explicit different max age" do
      get_core(snapshot_store: store_a)
      get_core(snapshot_store: store_a, max_snapshot_age_seconds: 60)
      expect(logger).to have_received(:warn).with(/option ignored/)
    end
  end

  describe "configuration" do
    it "defaults the max age to 86400 and flags it as not explicit" do
      config = Featureflip::Config.new
      expect(config.max_snapshot_age_seconds).to eq(86_400)
      expect(config.max_snapshot_age_explicit?).to be(false)
    end

    [0, -1, "10", nil, Float::INFINITY, Float::NAN, true].each do |bad|
      it "rejects max_snapshot_age_seconds #{bad.inspect}" do
        expect { Featureflip::Config.new(max_snapshot_age_seconds: bad) }.to raise_error(Featureflip::ConfigurationError)
      end
    end

    it "accepts a positive float" do
      expect(Featureflip::Config.new(max_snapshot_age_seconds: 0.5).max_snapshot_age_seconds).to eq(0.5)
    end

    it "rejects a store without get and put" do
      expect { Featureflip::Config.new(snapshot_store: Object.new) }.to raise_error(Featureflip::ConfigurationError)
    end

    it "exposes startup info on a test client" do
      client = Featureflip::Client.for_testing("f" => true)
      expect(client.startup_info).to eq(Featureflip::StartupInfo.new("live"))
    end
  end

  describe "wire shape" do
    let(:parser) { Featureflip::Http::Client.new(nil, Struct.new(:logger, :base_url).new(nil, "")) }
    let(:rich) do
      {
        "flags" => [
          {
            "key" => "z-flag", "version" => 3, "type" => "Boolean", "enabled" => true,
            "variations" => [{ "key" => "on", "value" => true }, { "key" => "off", "value" => false }],
            "rules" => [{
              "id" => "r1", "priority" => 1,
              "conditionGroups" => [{
                "operator" => "Or",
                "conditions" => [{ "attribute" => "plan", "operator" => "In", "values" => %w[a b], "negate" => true }]
              }],
              "serve" => { "type" => "Rollout", "bucketBy" => "user_id", "salt" => "s",
                           "variations" => [{ "key" => "on", "weight" => 40 }, { "key" => "off", "weight" => 60 }] },
              "segmentKey" => "beta"
            }],
            "fallthrough" => { "type" => "Fixed", "variation" => "off" }, "offVariation" => "off",
            "prerequisites" => [{ "prerequisiteFlagKey" => "a-flag", "expectedVariationKey" => "on" }]
          },
          {
            "key" => "a-flag", "version" => 1, "type" => "Mystery", "enabled" => false,
            "variations" => [{ "key" => "on", "value" => { "k" => [1, 2.5, nil] } }],
            "rules" => [], "fallthrough" => { "type" => "Fixed", "variation" => "on" },
            "offVariation" => "on", "prerequisites" => []
          }
        ],
        "segments" => [
          { "key" => "beta", "version" => 2,
            "conditions" => [{ "attribute" => "email", "operator" => "EndsWith", "values" => ["@x.io"], "negate" => false }],
            "conditionLogic" => "And" }
        ]
      }
    end

    it "round trips through the SDK's own parser with real wire casing" do
      flags, segments = parser.parse_flags_response(rich)
      text = snapshot.serialize_flags_payload(flags, segments)
      reparsed = parser.parse_flags_response(JSON.parse(text))
      expect(reparsed).to eq([flags.sort_by(&:key), segments])

      wire = JSON.parse(text)
      expect(wire["flags"].map { |f| f["key"] }).to eq(%w[a-flag z-flag]) # sorted
      z = wire["flags"].last
      expect(z["type"]).to eq("Boolean")
      expect(z["fallthrough"]["type"]).to eq("Fixed")
      expect(z["rules"][0]["serve"]["type"]).to eq("Rollout")
      expect(z["rules"][0]["conditionGroups"][0]["operator"]).to eq("Or")
      expect(wire["flags"].first["type"]).to eq("Mystery") # unknown kept verbatim
      expect(wire["segments"][0]["conditionLogic"]).to eq("And")
    end

    it "is deterministic regardless of input order" do
      flags, segments = parser.parse_flags_response(rich)
      a = snapshot.serialize_flags_payload(flags, segments)
      b = snapshot.serialize_flags_payload(flags.reverse, segments.reverse)
      expect(a).to eq(b)
    end

    it "validates the stored data with the SDK's own parser" do
      env = snapshot.encode_envelope(snapshot.compute_key_hash(base_url, sdk_key), clock_state[:wall],
                                     snapshot.serialize_flags_payload(*parser.parse_flags_response(rich)))
      decoded = snapshot.decode_envelope(env, snapshot.compute_key_hash(base_url, sdk_key), clock_state[:wall])
      expect(decoded.flags.map(&:key)).to eq(%w[a-flag z-flag])
    end
  end

  describe "parity: sync, stop the API, start a fresh client" do
    it "serves real values from the file store after the server goes away" do
      path = File.join(dir, "shared.json")
      body = payload(flag_json("parity-flag", value: true)).to_json
      stub_request(:get, "#{base_url}/v1/sdk/flags")
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })

      a = Featureflip::Client.get(
        sdk_key, config: Featureflip::Config.new(
          streaming: false, send_events: false, poll_interval: 9999, logger: logger,
          snapshot_store: Featureflip::FileSnapshotStore.new(path, logger: logger)
        )
      )
      wait_until { File.exist?(path) }
      expect(a.startup_info.source).to eq("live")
      a.close

      WebMock.reset!
      stub_request(:get, "#{base_url}/v1/sdk/flags").to_raise(Errno::ECONNREFUSED)
      b = Featureflip::Client.get(
        sdk_key, config: Featureflip::Config.new(
          streaming: false, send_events: false, poll_interval: 9999, logger: logger, init_timeout: 5,
          snapshot_store: Featureflip::FileSnapshotStore.new(path, logger: logger)
        )
      )
      expect(b.initialized?).to be(true)
      expect(b.startup_info.source).to eq("snapshot")
      expect(b.bool_variation("parity-flag", { "user_id" => "u" }, false)).to be(true)
      b.close
    end
  end
end
