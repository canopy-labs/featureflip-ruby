require "spec_helper"

# Stands in for Minitest::Assertion and RSpec::Expectations::ExpectationNotMetError:
# an assertion that fails inside a test's inspector raises an Exception subclass
# that is NOT a StandardError, which is the realistic trigger for the isolation
# gap this suite guards.
class InspectorAssertionError < Exception; end # rubocop:disable Lint/InheritException

RSpec.describe "evaluation inspectors" do
  let(:sdk_key) { "sdk-inspector-key" }

  # A snapshot exercising each exit path of SharedCore#variation_detail:
  #   flag-on     -> Fallthrough
  #   flag-off    -> FlagDisabled (off variation)
  #   flag-rule   -> RuleMatch (rule-1)
  #   flag-prereq -> PrerequisiteFailed (flag-off never serves "on")
  #   flag-error  -> Error. Malformed on purpose: two rules whose priorities are
  #                  nil and 1, so `rules.sort_by(&:priority)` raises inside the
  #                  evaluator and trips variation_detail's rescue.
  let(:flags_response) do
    JSON.generate(
      flags: [
        {
          key: "flag-on", version: 1, type: "Boolean", enabled: true,
          variations: [{ key: "on", value: true }, { key: "off", value: false }],
          rules: [],
          fallthrough: { type: "Fixed", variation: "on" },
          offVariation: "off"
        },
        {
          key: "flag-off", version: 1, type: "Boolean", enabled: false,
          variations: [{ key: "on", value: true }, { key: "off", value: false }],
          rules: [],
          fallthrough: { type: "Fixed", variation: "on" },
          offVariation: "off"
        },
        {
          key: "flag-rule", version: 1, type: "Boolean", enabled: true,
          variations: [{ key: "on", value: true }, { key: "off", value: false }],
          rules: [
            {
              id: "rule-1", priority: 1,
              conditionGroups: [
                {
                  operator: "And",
                  conditions: [
                    { attribute: "user_id", operator: "Equals", values: ["alice"], negate: false }
                  ]
                }
              ],
              serve: { type: "Fixed", variation: "on" }
            }
          ],
          fallthrough: { type: "Fixed", variation: "off" },
          offVariation: "off"
        },
        {
          key: "flag-prereq", version: 1, type: "Boolean", enabled: true,
          variations: [{ key: "on", value: true }, { key: "off", value: false }],
          rules: [],
          fallthrough: { type: "Fixed", variation: "on" },
          offVariation: "off",
          prerequisites: [{ prerequisiteFlagKey: "flag-off", expectedVariationKey: "on" }]
        },
        {
          key: "flag-error", version: 1, type: "Boolean", enabled: true,
          variations: [{ key: "on", value: true }, { key: "off", value: false }],
          rules: [
            {
              id: "rule-nil-priority", priority: nil, conditionGroups: [],
              serve: { type: "Fixed", variation: "on" }
            },
            {
              id: "rule-int-priority", priority: 1, conditionGroups: [],
              serve: { type: "Fixed", variation: "on" }
            }
          ],
          fallthrough: { type: "Fixed", variation: "on" },
          offVariation: "off"
        },
        # flag-missing-variation -> Error. Malformed on purpose: the fallthrough
        # serves a variation key the flag does not define (e.g. a since-deleted
        # variation). Degrades to the caller's default and reports Error --
        # mirroring the engine + C#/Java (#1989).
        {
          key: "flag-missing-variation", version: 1, type: "Boolean", enabled: true,
          variations: [{ key: "on", value: true }, { key: "off", value: false }],
          rules: [],
          fallthrough: { type: "Fixed", variation: "ghost" },
          offVariation: "off"
        }
      ],
      segments: []
    )
  end

  before(:each) do
    stub_request(:get, /\/v1\/sdk\/flags/)
      .to_return(status: 200, body: flags_response, headers: { "Content-Type" => "application/json" })
  end

  def make_client(inspectors, logger: nil)
    config = Featureflip::Config.new(
      streaming: false,
      send_events: false,
      poll_interval: 9999,
      inspectors: inspectors,
      logger: logger
    )
    Featureflip::Client.get(sdk_key, config: config)
  end

  describe "payload on each exit path" do
    it "fires once with the full payload on the fallthrough path" do
      events = []
      client = make_client([->(e) { events << e }])

      context = { "user_id" => "bob", "plan" => "pro" }
      expect(client.bool_variation("flag-on", context, false)).to eq(true)

      expect(events.size).to eq(1)
      event = events.first
      expect(event).to be_a(Featureflip::Models::EvaluationEvent)
      expect(event.flag_key).to eq("flag-on")
      expect(event.value).to eq(true)
      expect(event.variation_key).to eq("on")
      expect(event.reason).to eq("Fallthrough")
      expect(event.rule_id).to be_nil
      expect(event.prerequisite_key).to be_nil
      expect(event.context).to eq(context)
      expect(event.timestamp).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/)
      expect { Time.iso8601(event.timestamp) }.not_to raise_error

      client.close
    end

    it "reports rule_id on a rule match" do
      events = []
      client = make_client([->(e) { events << e }])

      expect(client.bool_variation("flag-rule", { "user_id" => "alice" }, false)).to eq(true)

      expect(events.size).to eq(1)
      expect(events.first.reason).to eq("RuleMatch")
      expect(events.first.rule_id).to eq("rule-1")
      expect(events.first.variation_key).to eq("on")
      expect(events.first.prerequisite_key).to be_nil

      client.close
    end

    it "reports FlagDisabled with the off value" do
      events = []
      client = make_client([->(e) { events << e }])

      expect(client.bool_variation("flag-off", { "user_id" => "bob" }, true)).to eq(false)

      expect(events.size).to eq(1)
      expect(events.first.reason).to eq("FlagDisabled")
      expect(events.first.value).to eq(false)
      expect(events.first.variation_key).to eq("off")

      client.close
    end

    it "reports FlagNotFound with the default value and no variation_key" do
      events = []
      client = make_client([->(e) { events << e }])

      expect(client.bool_variation("missing", { "user_id" => "bob" }, true)).to eq(true)

      expect(events.size).to eq(1)
      expect(events.first.flag_key).to eq("missing")
      expect(events.first.reason).to eq("FlagNotFound")
      expect(events.first.value).to eq(true)
      expect(events.first.variation_key).to be_nil
      expect(events.first.rule_id).to be_nil
      expect(events.first.prerequisite_key).to be_nil

      client.close
    end

    it "reports PrerequisiteFailed with prerequisite_key" do
      events = []
      client = make_client([->(e) { events << e }])

      expect(client.bool_variation("flag-prereq", { "user_id" => "bob" }, true)).to eq(false)

      expect(events.size).to eq(1)
      expect(events.first.reason).to eq("PrerequisiteFailed")
      expect(events.first.prerequisite_key).to eq("flag-off")
      expect(events.first.value).to eq(false)

      client.close
    end

    it "reports Error and still returns the default when evaluation raises" do
      events = []
      client = make_client([->(e) { events << e }])

      expect(client.bool_variation("flag-error", { "user_id" => "bob" }, true)).to eq(true)

      expect(events.size).to eq(1)
      expect(events.first.reason).to eq("Error")
      expect(events.first.value).to eq(true)
      expect(events.first.variation_key).to be_nil
      expect(events.first.prerequisite_key).to be_nil

      client.close
    end

    it "reports Error when the served variation key is not defined on the flag" do
      events = []
      client = make_client([->(e) { events << e }])

      # The returned detail (what the caller sees) degrades to the default and
      # reports Error -- not the misleading Fallthrough the evaluator resolved.
      detail = client.variation_detail("flag-missing-variation", { "user_id" => "bob" }, false)
      expect(detail.reason).to eq("Error")
      expect(detail.value).to eq(false)
      expect(detail.variation_key).to eq("ghost") # kept for diagnostics

      expect(events.size).to eq(1)
      expect(events.first.reason).to eq("Error")
      expect(events.first.value).to eq(false)

      client.close
    end

    it "fires for variation_detail as well as the typed variation helpers" do
      events = []
      client = make_client([->(e) { events << e }])

      detail = client.variation_detail("flag-on", { "user_id" => "bob" }, false)

      expect(detail.value).to eq(true)
      expect(events.size).to eq(1)
      expect(events.first.reason).to eq("Fallthrough")

      client.close
    end
  end

  describe "timestamp precision" do
    # Whole-second stamps (`Time#iso8601` with no digit argument) silently collapse
    # repeat exposures for an analytics sink de-duplicating on
    # (flag, user, timestamp), so precision is part of the contract -- and merely
    # asserting Time.iso8601 parses the string would not catch a regression.
    it "stamps events with millisecond precision, not whole seconds" do
      events = []
      client = make_client([->(e) { events << e }])

      # Spaced ~2ms apart: over that window at most one sample can land exactly on
      # a whole second, so "at least one non-zero fraction" below is deterministic.
      5.times do
        client.bool_variation("flag-on", { "user_id" => "bob" }, false)
        sleep 0.002
      end

      expect(events.size).to eq(5)
      events.each do |event|
        # Exactly three fractional digits + the Z designator. A whole-second
        # timestamp carries no fractional part at all and fails this.
        expect(event.timestamp).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/)
      end

      # Guards a hard-coded ".000": the sub-second digits must be real.
      fractions = events.map { |e| Time.iso8601(e.timestamp).nsec }
      expect(fractions.any?(&:positive?)).to be(true)

      client.close
    end
  end

  describe "multiple inspectors" do
    it "invokes every registered inspector" do
      first = []
      second = []
      client = make_client([->(e) { first << e }, ->(e) { second << e }])

      client.bool_variation("flag-on", { "user_id" => "bob" }, false)

      expect(first.size).to eq(1)
      expect(second.size).to eq(1)

      client.close
    end

    it "accepts any callable, not just lambdas" do
      callable = Class.new do
        attr_reader :events

        def initialize
          @events = []
        end

        def call(event)
          @events << event
        end
      end.new

      client = make_client([callable, proc { |_e| }])

      client.bool_variation("flag-on", { "user_id" => "bob" }, false)

      expect(callable.events.size).to eq(1)
      expect(callable.events.first.flag_key).to eq("flag-on")

      client.close
    end
  end

  describe "error isolation" do
    it "does not change the value, still fires siblings, and logs a warning" do
      logger = instance_double(Logger)
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)

      after = []
      boom = ->(_e) { raise "inspector boom" }
      client = make_client([boom, ->(e) { after << e }], logger: logger)

      expect(client.bool_variation("flag-on", { "user_id" => "bob" }, false)).to eq(true)
      expect(after.size).to eq(1)
      expect(logger).to have_received(:warn).with(/evaluation inspector raised/)

      client.close
    end

    # `rescue StandardError` around inspector.call let these escape into the
    # caller's request handler -- the whole point of the isolation guarantee.
    [
      ["a NotImplementedError", -> { raise NotImplementedError, "not done" }, /NotImplementedError/],
      ["an assertion failure", -> { raise InspectorAssertionError, "expected true" },
       /InspectorAssertionError/]
    ].each do |label, raiser, log_pattern|
      it "contains #{label} (not a StandardError) without changing the value" do
        logger = instance_double(Logger)
        allow(logger).to receive(:info)
        allow(logger).to receive(:warn)

        after = []
        client = make_client([->(_e) { raiser.call }, ->(e) { after << e }], logger: logger)

        expect(client.bool_variation("flag-on", { "user_id" => "bob" }, false)).to eq(true)
        expect(after.size).to eq(1)
        expect(logger).to have_received(:warn).with(log_pattern)

        client.close
      end
    end

    it "contains a non-StandardError raised on the variation_detail path too" do
      logger = instance_double(Logger)
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)

      client = make_client([->(_e) { raise NotImplementedError }], logger: logger)

      detail = nil
      expect { detail = client.variation_detail("flag-on", { "user_id" => "bob" }, false) }
        .not_to raise_error
      expect(detail.value).to eq(true)
      expect(detail.reason).to eq("Fallthrough")

      client.close
    end

    # The deliberate holes in the isolation: a misbehaving analytics callback must
    # not be able to eat a Ctrl-C or an `exit`.
    it "lets an Interrupt (Ctrl-C) propagate to the caller" do
      client = make_client([->(_e) { raise Interrupt }])

      expect { client.bool_variation("flag-on", { "user_id" => "bob" }, false) }
        .to raise_error(Interrupt)

      client.close
    end

    it "lets a SystemExit propagate to the caller" do
      client = make_client([->(_e) { raise SystemExit.new(2) }])

      expect { client.variation_detail("flag-on", { "user_id" => "bob" }, false) }
        .to raise_error(SystemExit)

      client.close
    end

    it "still fires siblings registered before an un-isolated raise" do
      before_events = []
      client = make_client([->(e) { before_events << e }, ->(_e) { raise Interrupt }])

      expect { client.bool_variation("flag-on", { "user_id" => "bob" }, false) }
        .to raise_error(Interrupt)
      expect(before_events.size).to eq(1)

      client.close
    end
  end

  describe "defensive filtering" do
    it "ignores non-callable entries without raising" do
      events = []
      client = make_client([nil, "nope", 42, ->(e) { events << e }])

      expect { client.bool_variation("flag-on", { "user_id" => "bob" }, false) }.not_to raise_error
      expect(events.size).to eq(1)

      client.close
    end

    it "drops non-callables at Config construction" do
      config = Featureflip::Config.new(inspectors: [nil, "nope", ->(_e) {}])
      expect(config.inspectors.size).to eq(1)
    end

    it "wraps a single callable into an array" do
      config = Featureflip::Config.new(inspectors: ->(_e) {})
      expect(config.inspectors.size).to eq(1)
    end

    it "defaults to an empty list" do
      expect(Featureflip::Config.new.inspectors).to eq([])
    end
  end

  describe "no inspectors configured" do
    it "is a no-op" do
      client = make_client(nil)

      expect(client.bool_variation("flag-on", { "user_id" => "bob" }, false)).to eq(true)
      expect(client.bool_variation("missing", { "user_id" => "bob" }, true)).to eq(true)

      client.close
    end
  end

  describe "context copying" do
    it "hands the inspector a copy the caller's hash is insulated from" do
      events = []
      client = make_client([->(e) { events << e }])

      context = { "user_id" => "bob", "plan" => "pro" }
      client.bool_variation("flag-on", context, false)

      event_context = events.first.context
      expect(event_context).to eq(context)
      expect(event_context).not_to equal(context)

      event_context["plan"] = "mutated"
      event_context["injected"] = true
      expect(context).to eq({ "user_id" => "bob", "plan" => "pro" })

      client.close
    end
  end
end
