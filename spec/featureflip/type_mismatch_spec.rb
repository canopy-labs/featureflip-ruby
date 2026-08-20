require "spec_helper"

# A typed accessor whose served value is not of the requested type must hand back
# the caller's default and report "Error", so the mismatch is detectable (#2281,
# #2286). Ruby's typed accessors previously did no type checking at all: they
# returned whatever the flag served, so bool_variation on a string flag handed the
# caller a String where their code expected true/false.
RSpec.describe "type-mismatched reads" do
  let(:sdk_key) { "sdk-type-mismatch-key" }

  let(:flags_response) do
    JSON.generate(
      flags: [
        {
          key: "bool-flag", version: 1, type: "Boolean", enabled: true,
          variations: [{ key: "on", value: true }, { key: "off", value: false }],
          rules: [],
          fallthrough: { type: "Fixed", variation: "off" },
          offVariation: "off"
        },
        {
          key: "str-flag", version: 1, type: "String", enabled: true,
          variations: [{ key: "v", value: "42" }],
          rules: [],
          fallthrough: { type: "Fixed", variation: "v" },
          offVariation: "v"
        },
        {
          key: "num-flag", version: 1, type: "Number", enabled: true,
          variations: [{ key: "v", value: 42 }],
          rules: [],
          fallthrough: { type: "Fixed", variation: "v" },
          offVariation: "v"
        }
      ],
      segments: []
    )
  end

  before(:each) do
    stub_request(:get, %r{/v1/sdk/flags})
      .to_return(status: 200, body: flags_response, headers: { "Content-Type" => "application/json" })
  end

  def make_client(inspectors = [])
    config = Featureflip::Config.new(
      streaming: false,
      send_events: false,
      poll_interval: 9999,
      inspectors: inspectors
    )
    Featureflip::Client.get(sdk_key, config: config)
  end

  describe "returns the caller's default instead of the served value" do
    it "bool flag read as a string" do
      client = make_client
      expect(client.string_variation("bool-flag", {}, "DEF")).to eq("DEF")
      client.close
    end

    it "bool flag read as a number" do
      client = make_client
      expect(client.number_variation("bool-flag", {}, -1)).to eq(-1)
      client.close
    end

    it "string flag read as a number" do
      client = make_client
      expect(client.number_variation("str-flag", {}, -1)).to eq(-1)
      client.close
    end

    it "string flag read as a bool" do
      client = make_client
      expect(client.bool_variation("str-flag", {}, true)).to be(true)
      client.close
    end

    it "number flag read as a string" do
      client = make_client
      expect(client.string_variation("num-flag", {}, "DEF")).to eq("DEF")
      client.close
    end

    it "number flag read as a bool" do
      client = make_client
      expect(client.bool_variation("num-flag", {}, true)).to be(true)
      client.close
    end
  end

  describe "reports the mismatch to inspectors" do
    it "reports Error with the caller's default as the value" do
      events = []
      client = make_client([->(e) { events << e }])

      client.number_variation("bool-flag", { "user_id" => "bob" }, -1)

      expect(events.size).to eq(1)
      expect(events.first.reason).to eq("Error")
      expect(events.first.value).to eq(-1)
      client.close
    end

    it "leaves a matching read reporting its real reason" do
      events = []
      client = make_client([->(e) { events << e }])

      expect(client.bool_variation("bool-flag", { "user_id" => "bob" }, true)).to be(false)

      expect(events.size).to eq(1)
      expect(events.first.reason).to eq("Fallthrough")
      expect(events.first.value).to be(false)
      client.close
    end
  end

  describe "matching reads are unaffected" do
    it "serves each flag through its own accessor" do
      client = make_client
      expect(client.bool_variation("bool-flag", {}, true)).to be(false)
      expect(client.string_variation("str-flag", {}, "DEF")).to eq("42")
      expect(client.number_variation("num-flag", {}, -1)).to eq(42)
      client.close
    end

    it "leaves the generic variation_detail unchecked" do
      # variation_detail takes no requested type, so there is nothing to mismatch
      # against -- it keeps returning the served value and its real reason.
      client = make_client
      detail = client.variation_detail("str-flag", {}, "DEF")
      expect(detail.value).to eq("42")
      expect(detail.reason).to eq("Fallthrough")
      client.close
    end
  end
end
