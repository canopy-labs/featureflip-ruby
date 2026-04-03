require "spec_helper"

RSpec.describe Featureflip::Evaluation::Bucketing do
  describe ".compute_bucket" do
    it "returns deterministic result for same input" do
      a = described_class.compute_bucket("salt", "user-123")
      b = described_class.compute_bucket("salt", "user-123")
      expect(a).to eq(b)
    end

    it "returns value in range 0-99" do
      100.times do |i|
        bucket = described_class.compute_bucket("salt", "user-#{i}")
        expect(bucket).to be >= 0
        expect(bucket).to be < 100
      end
    end

    it "matches cross-SDK bucket computation" do
      # Pin a known value to catch accidental algorithm changes
      # md5("salt:user-123") => first 4 bytes LE uint32 = 746867710, 746867710 % 100 = 10
      expect(described_class.compute_bucket("salt", "user-123")).to eq(10)
    end

    it "produces roughly uniform distribution" do
      buckets = 10_000.times.map { |i| described_class.compute_bucket("salt", "user-#{i}") }
      counts = Array.new(10, 0)
      buckets.each { |b| counts[b / 10] += 1 }
      counts.each { |c| expect(c).to be_between(700, 1300) }
    end
  end
end
