require "spec_helper"

RSpec.describe Featureflip::DataSource::StreamingHandler do
  let(:sdk_key) { "sdk-test-key" }
  let(:config) { Featureflip::Config.new(sdk_key: sdk_key, base_url: "https://eval.featureflip.io") }
  let(:http_client) { instance_double(Featureflip::Http::Client) }
  let(:on_flag_updated) { instance_double(Proc) }
  let(:on_flag_deleted) { instance_double(Proc) }
  let(:on_segment_updated) { instance_double(Proc) }
  let(:on_error) { instance_double(Proc) }
  let(:handler) do
    described_class.new(
      sdk_key: sdk_key,
      config: config,
      http_client: http_client,
      on_flag_updated: on_flag_updated,
      on_flag_deleted: on_flag_deleted,
      on_segment_updated: on_segment_updated,
      on_error: on_error
    )
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
end
