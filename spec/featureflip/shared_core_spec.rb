require "spec_helper"

RSpec.describe Featureflip::SharedCore do
  let(:sdk_key) { "sdk-test-key" }
  let(:flags_response) { '{"flags":[],"segments":[]}' }

  def make_config(overrides = {})
    Featureflip::Config.new(
      streaming: false,
      send_events: false,
      poll_interval: 9999,
      **overrides
    )
  end

  before(:each) do
    stub_request(:get, /\/v1\/sdk\/flags/)
      .to_return(status: 200, body: flags_response, headers: { "Content-Type" => "application/json" })
  end

  describe "._get_or_create" do
    it "returns a core with refcount 1 on first call" do
      config = make_config
      core = described_class._get_or_create(sdk_key, config)

      expect(core).to be_a(Featureflip::SharedCore)
      expect(core._ref_count).to eq(1)
    end

    it "shares one core with refcount 2 when same key is used twice" do
      config = make_config
      core1 = described_class._get_or_create(sdk_key, config)
      core2 = described_class._get_or_create(sdk_key, config)

      expect(core1).to equal(core2)
      expect(core1._ref_count).to eq(2)
    end

    it "creates independent cores for different keys" do
      config = make_config
      core_a = described_class._get_or_create("key-a", config)
      core_b = described_class._get_or_create("key-b", config)

      expect(core_a).not_to equal(core_b)
      expect(core_a._ref_count).to eq(1)
      expect(core_b._ref_count).to eq(1)
    end

    it "warns when config mismatches on same key" do
      logger = instance_double(Logger)
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)

      config1 = make_config(logger: logger, poll_interval: 30)
      config2 = make_config(logger: logger, poll_interval: 60)

      described_class._get_or_create(sdk_key, config1)
      described_class._get_or_create(sdk_key, config2)

      expect(logger).to have_received(:warn).with(/different config/)
    end

    it "replaces a stale entry when core has been shut down" do
      config = make_config
      core1 = described_class._get_or_create(sdk_key, config)
      core1._release # refcount -> 0, shuts down

      core2 = described_class._get_or_create(sdk_key, config)
      expect(core2).not_to equal(core1)
      expect(core2._ref_count).to eq(1)
    end

    it "shares one core across 32 concurrent _get_or_create calls" do
      config = make_config
      cores = []
      mutex = Mutex.new
      barrier = Queue.new

      threads = 32.times.map do
        Thread.new do
          barrier.pop # wait for go signal
          core = described_class._get_or_create(sdk_key, config)
          mutex.synchronize { cores << core }
        end
      end

      # release all threads at once
      32.times { barrier << :go }
      threads.each(&:join)

      expect(cores.uniq { |c| c.object_id }.size).to eq(1)
      expect(cores.first._ref_count).to eq(32)
    end
  end

  describe "._release" do
    it "decrements refcount" do
      config = make_config
      core = described_class._get_or_create(sdk_key, config)
      described_class._get_or_create(sdk_key, config) # refcount 2

      core._release
      expect(core._ref_count).to eq(1)
    end

    it "shuts down and removes from LIVE_CORES at zero" do
      config = make_config
      core = described_class._get_or_create(sdk_key, config)

      core._release
      expect(core._ref_count).to eq(0)
      expect(Featureflip::SharedCore::LIVE_CORES).not_to have_key(sdk_key)
    end

    it "is idempotent on over-release (no error)" do
      config = make_config
      core = described_class._get_or_create(sdk_key, config)

      expect { 3.times { core._release } }.not_to raise_error
      expect(core._ref_count).to eq(0)
    end
  end

  describe "._acquire" do
    it "returns false after shutdown" do
      config = make_config
      core = described_class._get_or_create(sdk_key, config)
      core._release # shuts down

      expect(core._acquire).to be false
    end
  end

  describe "._create_for_testing" do
    it "creates a core not in LIVE_CORES" do
      test_core = described_class._create_for_testing({ "my-flag" => true })

      expect(test_core).to be_a(Featureflip::SharedCore)
      expect(test_core._ref_count).to eq(1)
      expect(Featureflip::SharedCore::LIVE_CORES.values).not_to include(test_core)
    end
  end

  describe "._reset_for_testing" do
    it "clears all live cores" do
      config = make_config
      described_class._get_or_create("key-1", config)
      described_class._get_or_create("key-2", config)

      expect(Featureflip::SharedCore::LIVE_CORES.size).to eq(2)

      described_class._reset_for_testing

      expect(Featureflip::SharedCore::LIVE_CORES).to be_empty
    end
  end
end
