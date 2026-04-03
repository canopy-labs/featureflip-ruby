require "spec_helper"

RSpec.describe Featureflip::Config do
  it "has sensible defaults" do
    config = Featureflip::Config.new
    expect(config.base_url).to eq("https://eval.featureflip.io")
    expect(config.streaming).to eq(true)
    expect(config.poll_interval).to eq(30)
    expect(config.flush_interval).to eq(30)
    expect(config.flush_batch_size).to eq(100)
    expect(config.init_timeout).to eq(10)
    expect(config.connect_timeout).to eq(5)
    expect(config.read_timeout).to eq(10)
    expect(config.max_stream_retries).to eq(5)
    expect(config.send_events).to eq(true)
  end

  it "accepts custom values" do
    config = Featureflip::Config.new(
      base_url: "http://localhost:8080",
      streaming: false,
      poll_interval: 60,
      init_timeout: 30
    )
    expect(config.base_url).to eq("http://localhost:8080")
    expect(config.streaming).to eq(false)
    expect(config.poll_interval).to eq(60)
  end

  it "strips trailing slashes from base_url" do
    config = Featureflip::Config.new(base_url: "http://localhost:8080///")
    expect(config.base_url).to eq("http://localhost:8080")
  end

  it "validates positive numeric values" do
    expect { Featureflip::Config.new(poll_interval: -1) }.to raise_error(Featureflip::ConfigurationError)
    expect { Featureflip::Config.new(init_timeout: 0) }.to raise_error(Featureflip::ConfigurationError)
  end
end
