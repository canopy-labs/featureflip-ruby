require "spec_helper"

RSpec.describe Featureflip::DataSource::PollingHandler do
  let(:http_client) { instance_double(Featureflip::Http::Client) }
  let(:config) { Featureflip::Config.new(sdk_key: "sdk-key", base_url: "https://eval.featureflip.io", poll_interval: 1) }
  let(:updates) { [] }
  let(:errors) { [] }
  let(:on_update) { ->(flags, segments) { updates << [flags, segments] } }
  let(:on_error) { ->(e) { errors << e } }
  let(:handler) do
    described_class.new(
      http_client: http_client,
      config: config,
      on_update: on_update,
      on_error: on_error
    )
  end

  describe "polling" do
    it "calls on_update with fetched flags" do
      flags = [instance_double(Featureflip::Models::FlagConfiguration)]
      segments = [instance_double(Featureflip::Models::Segment)]
      allow(http_client).to receive(:get_flags).and_return([flags, segments])

      handler.start
      sleep(0.1)
      handler.stop

      expect(updates.length).to be >= 1
      expect(updates.first).to eq([flags, segments])
    end

    it "calls on_error on failure" do
      error = StandardError.new("connection refused")
      allow(http_client).to receive(:get_flags).and_raise(error)

      handler.start
      sleep(0.1)
      handler.stop

      expect(errors.length).to be >= 1
      expect(errors.first.message).to eq("connection refused")
    end
  end
end
