module Featureflip
  module Models
    EvaluationDetail = Struct.new(:value, :reason, :rule_id, :variation_key, keyword_init: true) do
      def initialize(value:, reason:, rule_id: nil, variation_key: nil)
        super
      end
    end
  end
end
