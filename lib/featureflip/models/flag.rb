module Featureflip
  module Models
    Variation = Struct.new(:key, :value, keyword_init: true)

    WeightedVariation = Struct.new(:key, :weight, keyword_init: true)

    Condition = Struct.new(:attribute, :operator, :values, :negate, keyword_init: true) do
      def initialize(attribute:, operator:, values:, negate: false)
        super
      end
    end

    ServeConfig = Struct.new(:type, :variation, :bucket_by, :salt, :variations, keyword_init: true) do
      def initialize(type:, variation: nil, bucket_by: nil, salt: nil, variations: nil)
        super
      end
    end

    ConditionGroup = Struct.new(:operator, :conditions, keyword_init: true) do
      def initialize(operator: "And", conditions: [])
        super
      end
    end

    TargetingRule = Struct.new(:id, :priority, :condition_groups, :serve, :segment_key, keyword_init: true) do
      def initialize(id:, priority:, condition_groups:, serve:, segment_key: nil)
        super
      end
    end

    FlagConfiguration = Struct.new(:key, :version, :type, :enabled, :variations, :rules, :fallthrough, :off_variation, keyword_init: true) do
      def get_variation(key)
        @variations_by_key ||= variations.each_with_object({}) { |v, h| h[v.key] = v }
        @variations_by_key[key]
      end
    end
  end
end
