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
        data = JSON.parse(response.body)
        flags = (data["flags"] || []).map { |f| parse_flag(f) }
        segments = (data["segments"] || []).map { |s| parse_segment(s) }
        [flags, segments]
      end

      def get_flag(key)
        response = request(:get, "/v1/sdk/flags/#{key}")
        parse_flag(JSON.parse(response.body))
      end

      def post_events(events)
        request(:post, "/v1/sdk/events", { events: events })
      end

      def close
        # No persistent connection to close with net/http
      end

      private

      def request(method, path, body = nil, retries: 1)
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

        if response.is_a?(Net::HTTPServerError) && retries > 0
          sleep(1)
          return request(method, path, body, retries: retries - 1)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise Featureflip::Error, "HTTP #{response.code}: #{path}"
        end

        response
      rescue IOError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
             Net::OpenTimeout, Net::ReadTimeout => e
        raise if retries <= 0
        sleep(1)
        request(method, path, body, retries: retries - 1)
      end

      def parse_flag(data)
        Models::FlagConfiguration.new(
          key: data["key"],
          version: data["version"],
          type: data["type"],
          enabled: data["enabled"],
          variations: (data["variations"] || []).map { |v| Models::Variation.new(key: v["key"], value: v["value"]) },
          rules: (data["rules"] || []).map { |r| parse_rule(r) },
          fallthrough: parse_serve(data["fallthrough"]),
          off_variation: data["offVariation"]
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
          operator: data["operator"] || "And",
          conditions: (data["conditions"] || []).map { |c| parse_condition(c) }
        )
      end

      def parse_condition(data)
        Models::Condition.new(
          attribute: data["attribute"],
          operator: data["operator"],
          values: data["values"],
          negate: data["negate"] || false
        )
      end

      def parse_serve(data)
        variations = if data["variations"]
          data["variations"].map { |v| Models::WeightedVariation.new(key: v["key"], weight: v["weight"]) }
        end

        Models::ServeConfig.new(
          type: data["type"],
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
          condition_logic: data["conditionLogic"] || "And"
        )
      end
    end
  end
end
