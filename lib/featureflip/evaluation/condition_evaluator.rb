module Featureflip
  module Evaluation
    class ConditionEvaluator
      def evaluate_condition(condition, context)
        attr_value = context[condition.attribute]

        return condition.negate if attr_value.nil?

        str_value = attr_value.to_s.downcase
        targets = condition.values.map { |v| v.to_s.downcase }

        result = evaluate_operator(condition.operator, str_value, targets)
        condition.negate ? !result : result
      end

      def evaluate_conditions(conditions, logic, context)
        return true if conditions.empty?

        if logic == "And"
          conditions.all? { |c| evaluate_condition(c, context) }
        else
          conditions.any? { |c| evaluate_condition(c, context) }
        end
      end

      def evaluate_condition_groups(condition_groups, context)
        return true if condition_groups.nil? || condition_groups.empty?

        condition_groups.all? do |group|
          evaluate_conditions(group.conditions, group.operator, context)
        end
      end

      private

      def evaluate_operator(operator, value, targets)
        case operator
        when "Equals"
          targets.any? { |t| value == t }
        when "NotEquals"
          targets.all? { |t| value != t }
        when "Contains"
          targets.any? { |t| value.include?(t) }
        when "NotContains"
          targets.all? { |t| !value.include?(t) }
        when "StartsWith"
          targets.any? { |t| value.start_with?(t) }
        when "EndsWith"
          targets.any? { |t| value.end_with?(t) }
        when "In"
          targets.include?(value)
        when "NotIn"
          !targets.include?(value)
        when "MatchesRegex"
          targets.any? do |t|
            Regexp.new(t, Regexp::IGNORECASE).match?(value)
          rescue RegexpError
            false
          end
        when "GreaterThan"
          compare_numeric(value, targets[0], :>)
        when "GreaterThanOrEqual"
          compare_numeric(value, targets[0], :>=)
        when "LessThan"
          compare_numeric(value, targets[0], :<)
        when "LessThanOrEqual"
          compare_numeric(value, targets[0], :<=)
        when "Before"
          return false if targets.empty?
          value < targets[0]
        when "After"
          return false if targets.empty?
          value > targets[0]
        else
          false
        end
      end

      def compare_numeric(value, target, op)
        val = Float(value)
        tgt = Float(target)
        val.send(op, tgt)
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
