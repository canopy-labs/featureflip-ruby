require "spec_helper"
require "logger"
require "stringio"

# The SDK token plus a wrapper's token in the User-Agent (#4154, contract in #4138).
# featureflip-ruby/<version> was already sent; what was missing is a way for a library
# that wraps the SDK (the OpenFeature provider) to name itself. Asserted on the wire for
# the flag fetch, the event post and the stream connect, which builds its own request.
RSpec.describe "SDK identity" do
  let(:base) { "https://eval.featureflip.io" }
  let(:sdk_token) { "featureflip-ruby/#{Featureflip::VERSION}" }
  let(:log) { StringIO.new }

  def agents_for(**config_opts)
    config = Featureflip::Config.new(sdk_key: "k", base_url: base, logger: Logger.new(log), **config_opts)
    stub_request(:get, "#{base}/v1/sdk/flags").to_return(status: 200, body: { flags: [], segments: [] }.to_json)
    stub_request(:post, "#{base}/v1/sdk/events").to_return(status: 202)
    stub_request(:get, "#{base}/v1/sdk/stream").to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })

    client = Featureflip::Http::Client.new("k", config)
    client.get_flags
    client.post_events([{ type: "Custom", flagKey: "f" }])
    Featureflip::DataSource::StreamingHandler.new(
      sdk_key: "k", config: config, http_client: client,
      on_flag_updated: ->(_) {}, on_flag_deleted: ->(_) {}, on_segment_updated: -> {}, on_error: ->(_) {}
    ).send(:connect)

    %w[flags events stream].to_h do |path|
      method = path == "events" ? :post : :get
      agent = nil
      WebMock::RequestRegistry.instance.requested_signatures.hash.each_key do |sig|
        agent = sig.headers["User-Agent"] if sig.method == method && sig.uri.path == "/v1/sdk/#{path}"
      end
      [path, agent]
    end
  end

  it "sends the bare SDK token on every path when no wrapper is set" do
    expect(agents_for).to eq("flags" => sdk_token, "events" => sdk_token, "stream" => sdk_token)
  end

  it "appends the wrapper's token on every path" do
    expected = "#{sdk_token} featureflip-openfeature-ruby/0.6.1"

    agents = agents_for(wrapper_name: "featureflip-openfeature-ruby", wrapper_version: "0.6.1")

    expect(agents).to eq("flags" => expected, "events" => expected, "stream" => expected)
  end

  it "sends a wrapper without a version as a bare name" do
    expect(agents_for(wrapper_name: "my-wrapper")["flags"]).to eq("#{sdk_token} my-wrapper")
  end

  it "drops an invalid wrapper with a warning" do
    # A space is not a legal product-token character, and Net::HTTP would send it inside
    # the header value regardless. Identity metadata must never stop the client starting,
    # so it is dropped and said so.
    expect(agents_for(wrapper_name: "bad name", wrapper_version: "1.0")["flags"]).to eq(sdk_token)
    expect(log.string).to include("WARN").and include("bad name")
  end

  it "does not count the wrapper as a different config" do
    # It identifies the caller rather than changing behavior, so the provider sharing an
    # SDK key with the host application must not trip the warning.
    a = Featureflip::Config.new(sdk_key: "k")
    b = Featureflip::Config.new(sdk_key: "k", wrapper_name: "w", wrapper_version: "1")

    expect(Featureflip::SharedCore.send(:_configs_equal, a, b)).to be(true)
  end
end
