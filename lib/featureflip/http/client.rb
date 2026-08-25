require "json"
require "net/http"
require "uri"

module Featureflip
  module Http
    class Client
      def initialize(sdk_key, config)
        @sdk_key = sdk_key
        @config = config
        @base_url = config.base_url
      end

      def get_flags
        response = request(:get, "/v1/sdk/flags")
        parse_flags_response(JSON.parse(response.body))
      end

      # Parse a GET /v1/sdk/flags-shaped snapshot into models. Reused for the
      # connect-time `sync` SSE snapshot, which carries the identical payload
      # shape inline (no extra HTTP round-trip).
      def parse_flags_response(data)
        flags = drop_unevaluable((data["flags"] || []).map { |f| parse_flag(f) }, "flag") do |flag|
          unevaluable_flag_reason(flag)
        end
        segments = drop_unevaluable((data["segments"] || []).map { |s| parse_segment(s) }, "segment") do |segment|
          unevaluable_segment_reason(segment)
        end
        [flags, segments]
      end

      def get_flag(key)
        response = request(:get, "/v1/sdk/flags/#{key}")
        flag = parse_flag(JSON.parse(response.body))

        # An unevaluable enum drops the flag rather than upserting it (#2402). For a
        # delta whose whole scope is one flag that means leaving the store's previous
        # copy alone: replacing it with one this build would mis-evaluate is the outcome
        # the drop exists to prevent, and FLAG_NOT_FOUND is the honest answer if there
        # was no previous copy.
        reason = unevaluable_flag_reason(flag)
        raise UnevaluableEntityError, "flag #{key.inspect}: #{reason}" if reason

        flag
      end

      def post_events(events)
        # The one caller that retries inline. EventProcessor#flush drains the queue before
        # sending, so a batch only survives a failure because the processor puts it back --
        # this absorbs a single transient 5xx before that machinery is needed, which keeps
        # the common blip off the re-queue path entirely. The processor's backoff gate is
        # measured from the moment this finally gives up, not from the first attempt.
        request(:post, "/v1/sdk/events", { events: events }, retry_server_errors: true)
      end

      def close
        # No persistent connection to close with net/http
      end

      private

      # retry_server_errors: retry once on a 5xx. Off by default — the poller re-fetches
      # every poll_interval and the streaming source reconnects with backoff, so for flag
      # reads an inner retry buys nothing and doubles request volume against a dependency
      # that is already failing (it also blocked for a second inside the init_timeout
      # budget on cold start). eval-api answers 503 when it cannot reach the Management
      # API, which is exactly the status this used to trip on.
      def request(method, path, body = nil, retries: 1, retry_server_errors: false)
        uri = URI("#{@base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @config.connect_timeout
        http.read_timeout = @config.read_timeout

        req = case method
        when :get
          Net::HTTP::Get.new(uri.request_uri)
        when :post
          r = Net::HTTP::Post.new(uri.request_uri)
          r.body = JSON.generate(body)
          r
        end

        req["Authorization"] = @sdk_key
        req["Content-Type"] = "application/json"
        req["User-Agent"] = "featureflip-ruby/#{Featureflip::VERSION}"

        response = http.request(req)

        if retry_server_errors && response.is_a?(Net::HTTPServerError) && retries > 0
          sleep(1)
          return request(method, path, body, retries: retries - 1, retry_server_errors: retry_server_errors)
        end

        unless response.is_a?(Net::HTTPSuccess)
          # HttpStatusError, not a bare Error: the events flush branches on the status to
          # decide whether the batch is worth keeping (#2456). Same message and same
          # ancestry, so nothing that rescues Featureflip::Error changes behaviour.
          raise HttpStatusError.new(response.code.to_i, path)
        end

        response
      rescue IOError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
             Net::OpenTimeout, Net::ReadTimeout => e
        raise if retries <= 0
        sleep(1)
        request(method, path, body, retries: retries - 1, retry_server_errors: retry_server_errors)
      end

      # Enum fields are strings on the wire. Ruby keeps whatever it is handed and the
      # evaluator compares against string literals, so a non-string here is stored
      # verbatim and then silently matches nothing forever — note `value || "And"`
      # does NOT save us, because 0 is truthy in Ruby (#2285).
      #
      # Only the TYPE is checked. An unrecognised enum *string* is how a newer server
      # introduces a new operator, and the evaluator already degrades that to
      # no-match; rejecting it would break this SDK against every future server.
      def require_enum_string!(value, field)
        return value if value.nil? || value.is_a?(String)

        raise MalformedPayloadError,
          "#{field} must be a string, got #{value.class} (#{value.inspect})"
      end

      def parse_flag(data)
        Models::FlagConfiguration.new(
          key: data["key"],
          version: data["version"],
          type: require_enum_string!(data["type"], "flag.type"),
          enabled: data["enabled"],
          variations: (data["variations"] || []).map { |v| Models::Variation.new(key: v["key"], value: v["value"]) },
          rules: (data["rules"] || []).map { |r| parse_rule(r) },
          fallthrough: parse_serve(data["fallthrough"]),
          off_variation: data["offVariation"],
          prerequisites: (data["prerequisites"] || []).map { |p| parse_prerequisite(p) }
        )
      end

      def parse_prerequisite(data)
        Models::Prerequisite.new(
          prerequisite_flag_key: data["prerequisiteFlagKey"],
          expected_variation_key: data["expectedVariationKey"]
        )
      end

      def parse_rule(data)
        condition_groups = (data["conditionGroups"] || []).map { |g| parse_condition_group(g) }

        Models::TargetingRule.new(
          id: data["id"],
          priority: data["priority"],
          condition_groups: condition_groups,
          serve: parse_serve(data["serve"]),
          segment_key: data["segmentKey"]
        )
      end

      def parse_condition_group(data)
        Models::ConditionGroup.new(
          operator: require_enum_string!(data["operator"], "conditionGroup.operator") || "And",
          conditions: (data["conditions"] || []).map { |c| parse_condition(c) }
        )
      end

      def parse_condition(data)
        Models::Condition.new(
          attribute: data["attribute"],
          operator: require_enum_string!(data["operator"], "condition.operator"),
          values: data["values"],
          negate: data["negate"] || false
        )
      end

      def parse_serve(data)
        variations = if data["variations"]
          data["variations"].map { |v| Models::WeightedVariation.new(key: v["key"], weight: v["weight"]) }
        end

        Models::ServeConfig.new(
          type: require_enum_string!(data["type"], "serve.type"),
          variation: data["variation"],
          bucket_by: data["bucketBy"],
          salt: data["salt"],
          variations: variations
        )
      end

      def parse_segment(data)
        Models::Segment.new(
          key: data["key"],
          version: data["version"],
          conditions: (data["conditions"] || []).map { |c| parse_condition(c) },
          condition_logic: require_enum_string!(data["conditionLogic"], "segment.conditionLogic") || "And"
        )
      end

      # Entity-level drop for enum values this SDK build cannot evaluate (#2402).
      #
      # `serve.type` and `conditionLogic` are the two enums that are BOTH carried on the
      # wire as strings AND consulted by the evaluator, and each dispatches on a two-way
      # branch with no third arm:
      #
      #   serve.type == "Fixed" ... else ROLLOUT
      #   logic      == "And"   ... else ANY (OR)
      #
      # So an unrecognised value does not fail — it takes the ELSE arm. A segment
      # carrying conditionLogic "Xor" evaluates as OR, so a segment meant to require ALL
      # of its conditions matches ANY of them: the rule fails OPEN and over-targets.
      #
      # Neither obvious fix works. Tolerating the value — as an unknown flag.type is
      # tolerated — IS that silent mis-evaluation; flag.type is safe to tolerate only
      # because nothing evaluates it. Raising MalformedPayloadError would discard the
      # whole payload, so one additive server change takes down every flag on a pinned
      # client (the #2372/#2395 outage shape).
      #
      # So the containing entity goes instead. Dropping a segment leaves rules pointing
      # at it dangling, which is safe: Evaluation::Evaluator already treats an
      # unresolvable segment_key as no-match (#1459), so the cascade fails CLOSED. The
      # engine-generated `f-segment-unresolvable` golden vector pins that.
      #
      # Scoped deliberately to a NON-EMPTY unrecognised value. An absent field already
      # defaults to "And" above, and the missing-required-field axis is a separate
      # concern that the SDKs deliberately disagree on; checking only values that are
      # present and unrecognised keeps this change purely additive.
      SERVE_TYPES = ["Fixed", "Rollout"].freeze
      CONDITION_LOGIC = ["And", "Or"].freeze

      def drop_unevaluable(entities, kind)
        entities.reject do |entity|
          reason = yield(entity)
          next false unless reason

          @config.logger&.warn(
            "Featureflip: dropping #{kind} #{entity.key.inspect}: #{reason}. This SDK " \
            "version may be older than the flag configuration; the rest of the " \
            "configuration was applied."
          )
          true
        end
      end

      # Why this flag cannot be evaluated, or nil if it can. A reason rather than a
      # boolean so the diagnostic can name the field and the value actually received.
      def unevaluable_flag_reason(flag)
        reason = unevaluable_serve_reason(flag.fallthrough, "fallthrough")
        return reason if reason

        (flag.rules || []).each do |rule|
          reason = unevaluable_serve_reason(rule.serve, "rule[#{rule.id}].serve")
          return reason if reason

          (rule.condition_groups || []).each do |group|
            next if group.operator.nil? || group.operator.empty?
            next if CONDITION_LOGIC.include?(group.operator)

            return "rule[#{rule.id}].conditionGroup.operator #{group.operator.inspect} " \
                   "is not a condition logic this SDK version understands"
          end
        end

        nil
      end

      # Why this segment cannot be evaluated, or nil if it can.
      def unevaluable_segment_reason(segment)
        logic = segment.condition_logic
        return nil if logic.nil? || logic.empty? || CONDITION_LOGIC.include?(logic)

        "conditionLogic #{logic.inspect} is not a condition logic this SDK version understands"
      end

      def unevaluable_serve_reason(serve, path)
        type = serve&.type
        return nil if type.nil? || type.empty? || SERVE_TYPES.include?(type)

        "#{path}.type #{type.inspect} is not a serve type this SDK version understands"
      end
    end
  end
end
