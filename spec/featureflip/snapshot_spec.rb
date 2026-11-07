require "spec_helper"
require "tmpdir"
require "json"
require "logger"

RSpec.describe "snapshot envelope and file store" do
  let(:snapshot) { Featureflip::Snapshot }
  let(:base_url) { "https://eval.featureflip.io" }
  let(:key_hash) { snapshot.compute_key_hash(base_url, "sdk-key") }
  let(:now_ms) { 1_800_000_000_000 }
  let(:data_text) do
    { "flags" => [], "segments" => [] }.to_json
  end

  def envelope(overrides = {})
    base = { "v" => 1, "keyHash" => key_hash, "fetchedAt" => now_ms, "data" => JSON.parse(data_text) }
    JSON.generate(base.merge(overrides))
  end

  def decode(text)
    snapshot.decode_envelope(text, key_hash, now_ms)
  end

  def invalid_why(text)
    decode(text)
    nil
  rescue Featureflip::Snapshot::InvalidError => e
    e.why
  end

  describe ".compute_key_hash" do
    it "is the hex SHA-256 of the base URL (slashes stripped), a newline and the key" do
      expected = Digest::SHA256.hexdigest("#{base_url}\nsdk-key")
      expect(snapshot.compute_key_hash("#{base_url}///", "sdk-key")).to eq(expected)
    end

    it "does not contain the key" do
      expect(key_hash).not_to include("sdk-key")
    end
  end

  describe ".encode_envelope" do
    it "writes v, keyHash, an integer fetchedAt and the data" do
      text = snapshot.encode_envelope(key_hash, now_ms, data_text)
      parsed = JSON.parse(text)
      expect(parsed.keys).to eq(%w[v keyHash fetchedAt data])
      expect(parsed["v"]).to eq(1)
      expect(parsed["fetchedAt"]).to eq(now_ms)
      expect(parsed["fetchedAt"]).to be_a(Integer)
      expect(parsed["data"]).to eq("flags" => [], "segments" => [])
      expect(text).not_to include("sdk-key")
    end
  end

  describe ".decode_envelope" do
    it "accepts a valid envelope" do
      decoded = decode(envelope)
      expect(decoded.flags).to eq([])
      expect(decoded.segments).to eq([])
      expect(decoded.fetched_at_ms).to eq(now_ms)
    end

    {
      "empty text" => ["", "empty text"],
      "unparseable text" => ["{not json", "not valid JSON"],
      "truncated text" => ['{"v":1,"keyHash":"abc"', "not valid JSON"],
      "a non-object" => ["[1,2]", "not a snapshot envelope"],
      "null" => ["null", "not a snapshot envelope"]
    }.each do |name, (text, why)|
      it "rejects #{name}" do
        expect(invalid_why(text)).to eq(why)
      end
    end

    it "rejects a non-text value from the store" do
      expect(invalid_why(42)).to eq("store returned a non-string value")
      expect(invalid_why({ "v" => 1 })).to eq("store returned a non-string value")
    end

    it "rejects an unsupported version" do
      expect(invalid_why(envelope("v" => 2))).to eq("unsupported envelope version")
      expect(invalid_why(envelope("v" => "1"))).to eq("unsupported envelope version")
      expect(invalid_why(envelope("v" => true))).to eq("unsupported envelope version")
    end

    it "rejects another SDK key or base URL" do
      other = snapshot.compute_key_hash(base_url, "other-key")
      expect(invalid_why(envelope("keyHash" => other))).to eq("written for a different SDK key or base URL")
      other = snapshot.compute_key_hash("https://other.example", "sdk-key")
      expect(invalid_why(envelope("keyHash" => other))).to eq("written for a different SDK key or base URL")
    end

    [0, -5, 1.5, "1", nil, true].each do |bad|
      it "rejects fetchedAt #{bad.inspect}" do
        expect(invalid_why(envelope("fetchedAt" => bad))).to eq("fetchedAt is not a positive integer")
      end
    end

    it "accepts fetchedAt up to 60 s ahead and rejects 61 s ahead" do
      expect { decode(envelope("fetchedAt" => now_ms + 60_000)) }.not_to raise_error
      expect(invalid_why(envelope("fetchedAt" => now_ms + 61_000))).to eq("fetchedAt is in the future")
    end

    it "rejects missing or non-object data" do
      expect(invalid_why(JSON.generate("v" => 1, "keyHash" => key_hash, "fetchedAt" => now_ms))).to eq("missing data")
      expect(invalid_why(envelope("data" => [1]))).to eq("missing data")
    end

    it "rejects data failing payload validation" do
      expect(invalid_why(envelope("data" => { "flags" => {}, "segments" => [] }))).to eq("data failed payload validation")
      expect(invalid_why(envelope("data" => { "flags" => [] }))).to eq("data failed payload validation")
      bad = { "flags" => [{ "key" => "f", "version" => 1, "type" => 5, "enabled" => true }], "segments" => [] }
      expect(invalid_why(envelope("data" => bad))).to eq("data failed payload validation")
    end

    it "checks in the pinned order (version before key hash before fetchedAt)" do
      expect(invalid_why(envelope("v" => 2, "keyHash" => "x", "fetchedAt" => 0))).to eq("unsupported envelope version")
      expect(invalid_why(envelope("keyHash" => "x", "fetchedAt" => 0))).to eq("written for a different SDK key or base URL")
    end
  end

  describe Featureflip::FileSnapshotStore do
    let(:dir) { Dir.mktmpdir("ff-snapshot") }
    let(:path) { File.join(dir, "snap.json") }
    let(:logger) { instance_double(Logger, info: nil, warn: nil, debug: nil, error: nil) }
    let(:store) { described_class.new(path, logger: logger) }

    after { FileUtils.rm_rf(dir) }

    it "round trips text" do
      store.put("héllo ✓")
      expect(store.get).to eq("héllo ✓")
    end

    it "writes mode 0600" do
      store.put("x")
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it "tightens a pre-existing target with broader permissions" do
      File.write(path, "old")
      File.chmod(0o644, path)
      store.put("new")
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(store.get).to eq("new")
    end

    it "leaves no temp file behind" do
      store.put("x")
      expect(Dir.children(dir)).to eq(["snap.json"])
    end

    it "leaves no temp file behind after concurrent puts" do
      threads = 12.times.map { |i| Thread.new { store.put("text-#{i}") } }
      threads.each(&:join)
      expect(Dir.children(dir)).to eq(["snap.json"])
      expect(store.get).to match(/\Atext-\d+\z/)
    end

    it "treats a missing file as a silent miss" do
      expect(store.get).to be_nil
      expect(logger).not_to have_received(:warn)
    end

    it "warns and misses when the path is a directory" do
      FileUtils.mkdir(path)
      expect(store.get).to be_nil
      expect(logger).to have_received(:warn).with(/snapshot file read failed/)
    end

    it "does not create parent directories and never raises" do
      missing = File.join(dir, "nope", "snap.json")
      s = described_class.new(missing, logger: logger)
      expect { s.put("x") }.not_to raise_error
      expect(Dir.exist?(File.join(dir, "nope"))).to be(false)
      expect(logger).to have_received(:warn).with(/snapshot file write failed/)
    end

    it "removes its temp file when the rename fails" do
      FileUtils.mkdir(path) # rename of a file over a directory fails
      store.put("x")
      expect(Dir.children(dir)).to eq(["snap.json"])
      expect(logger).to have_received(:warn).with(/snapshot file write failed/)
    end

    it "reads invalid UTF-8 without raising (the SDK then reads it as invalid)" do
      File.binwrite(path, "\xFF\xFE{")
      expect(store.get).to be_a(String)
      expect(store.get.valid_encoding?).to be(true)
    end
  end
end
