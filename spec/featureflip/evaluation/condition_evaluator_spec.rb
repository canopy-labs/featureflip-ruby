require "spec_helper"

RSpec.describe Featureflip::Evaluation::ConditionEvaluator do
  subject(:evaluator) { described_class.new }

  def condition(operator:, attribute: "country", values: ["US"], negate: false)
    Featureflip::Models::Condition.new(
      attribute: attribute, operator: operator, values: values, negate: negate
    )
  end

  describe "#evaluate_condition" do
    context "Equals operator" do
      it "matches when value equals target" do
        c = condition(operator: "Equals")
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be true
      end

      it "does not match when value differs" do
        c = condition(operator: "Equals")
        expect(evaluator.evaluate_condition(c, { "country" => "UK" })).to be false
      end

      it "matches any target value" do
        c = condition(operator: "Equals", values: ["US", "UK"])
        expect(evaluator.evaluate_condition(c, { "country" => "UK" })).to be true
      end

      it "is case insensitive" do
        c = condition(operator: "Equals")
        expect(evaluator.evaluate_condition(c, { "country" => "us" })).to be true
        expect(evaluator.evaluate_condition(c, { "country" => "Us" })).to be true
      end
    end

    context "NotEquals operator" do
      it "matches when value differs from all targets" do
        c = condition(operator: "NotEquals", values: ["US", "UK"])
        expect(evaluator.evaluate_condition(c, { "country" => "CA" })).to be true
      end

      it "does not match when value equals any target" do
        c = condition(operator: "NotEquals", values: ["US", "UK"])
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be false
      end
    end

    context "Contains operator" do
      it "matches when value contains target" do
        c = condition(operator: "Contains", attribute: "email", values: ["gmail"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@gmail.com" })).to be true
      end

      it "does not match when value does not contain target" do
        c = condition(operator: "Contains", attribute: "email", values: ["gmail"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@yahoo.com" })).to be false
      end
    end

    context "NotContains operator" do
      it "matches when value does not contain any target" do
        c = condition(operator: "NotContains", attribute: "email", values: ["gmail"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@yahoo.com" })).to be true
      end

      it "does not match when value contains a target" do
        c = condition(operator: "NotContains", attribute: "email", values: ["gmail"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@gmail.com" })).to be false
      end
    end

    context "StartsWith operator" do
      it "matches when value starts with target" do
        c = condition(operator: "StartsWith", attribute: "name", values: ["jo"])
        expect(evaluator.evaluate_condition(c, { "name" => "John" })).to be true
      end

      it "does not match when value does not start with target" do
        c = condition(operator: "StartsWith", attribute: "name", values: ["jo"])
        expect(evaluator.evaluate_condition(c, { "name" => "Alice" })).to be false
      end
    end

    context "EndsWith operator" do
      it "matches when value ends with target" do
        c = condition(operator: "EndsWith", attribute: "email", values: [".com"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@test.com" })).to be true
      end

      it "does not match when value does not end with target" do
        c = condition(operator: "EndsWith", attribute: "email", values: [".com"])
        expect(evaluator.evaluate_condition(c, { "email" => "user@test.org" })).to be false
      end
    end

    context "In operator" do
      it "matches when value is in targets" do
        c = condition(operator: "In", values: ["us", "uk", "ca"])
        expect(evaluator.evaluate_condition(c, { "country" => "UK" })).to be true
      end

      it "does not match when value is not in targets" do
        c = condition(operator: "In", values: ["us", "uk"])
        expect(evaluator.evaluate_condition(c, { "country" => "CA" })).to be false
      end
    end

    context "NotIn operator" do
      it "matches when value is not in targets" do
        c = condition(operator: "NotIn", values: ["us", "uk"])
        expect(evaluator.evaluate_condition(c, { "country" => "CA" })).to be true
      end

      it "does not match when value is in targets" do
        c = condition(operator: "NotIn", values: ["us", "uk"])
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be false
      end
    end

    context "MatchesRegex operator" do
      it "matches when value matches regex" do
        c = condition(operator: "MatchesRegex", attribute: "email", values: ['^\w+@gmail\.com$'])
        expect(evaluator.evaluate_condition(c, { "email" => "user@gmail.com" })).to be true
      end

      it "does not match when value does not match regex" do
        c = condition(operator: "MatchesRegex", attribute: "email", values: ['^\w+@gmail\.com$'])
        expect(evaluator.evaluate_condition(c, { "email" => "user@yahoo.com" })).to be false
      end

      it "returns false for invalid regex" do
        c = condition(operator: "MatchesRegex", attribute: "name", values: ["[invalid"])
        expect(evaluator.evaluate_condition(c, { "name" => "test" })).to be false
      end

      it "is case insensitive" do
        c = condition(operator: "MatchesRegex", attribute: "name", values: ["^alice$"])
        expect(evaluator.evaluate_condition(c, { "name" => "Alice" })).to be true
      end
    end

    context "GreaterThan operator" do
      it "matches when value is greater" do
        c = condition(operator: "GreaterThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "25" })).to be true
      end

      it "does not match when value is equal" do
        c = condition(operator: "GreaterThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "18" })).to be false
      end

      it "does not match when value is less" do
        c = condition(operator: "GreaterThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "10" })).to be false
      end

      it "returns false for non-numeric values" do
        c = condition(operator: "GreaterThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "abc" })).to be false
      end
    end

    context "GreaterThanOrEqual operator" do
      it "matches when value is equal" do
        c = condition(operator: "GreaterThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "18" })).to be true
      end

      it "matches when value is greater" do
        c = condition(operator: "GreaterThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "25" })).to be true
      end

      it "does not match when value is less" do
        c = condition(operator: "GreaterThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "10" })).to be false
      end
    end

    context "LessThan operator" do
      it "matches when value is less" do
        c = condition(operator: "LessThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "10" })).to be true
      end

      it "does not match when value is equal" do
        c = condition(operator: "LessThan", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "18" })).to be false
      end
    end

    context "LessThanOrEqual operator" do
      it "matches when value is equal" do
        c = condition(operator: "LessThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "18" })).to be true
      end

      it "matches when value is less" do
        c = condition(operator: "LessThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "10" })).to be true
      end

      it "does not match when value is greater" do
        c = condition(operator: "LessThanOrEqual", attribute: "age", values: ["18"])
        expect(evaluator.evaluate_condition(c, { "age" => "25" })).to be false
      end

      it "returns false for non-numeric target" do
        c = condition(operator: "LessThanOrEqual", attribute: "age", values: ["abc"])
        expect(evaluator.evaluate_condition(c, { "age" => "10" })).to be false
      end
    end

    context "Before operator" do
      it "matches when value is before target" do
        c = condition(operator: "Before", attribute: "date", values: ["2024-01-01"])
        expect(evaluator.evaluate_condition(c, { "date" => "2023-06-15" })).to be true
      end

      it "does not match when value is after target" do
        c = condition(operator: "Before", attribute: "date", values: ["2024-01-01"])
        expect(evaluator.evaluate_condition(c, { "date" => "2024-06-15" })).to be false
      end
    end

    context "After operator" do
      it "matches when value is after target" do
        c = condition(operator: "After", attribute: "date", values: ["2024-01-01"])
        expect(evaluator.evaluate_condition(c, { "date" => "2024-06-15" })).to be true
      end

      it "does not match when value is before target" do
        c = condition(operator: "After", attribute: "date", values: ["2024-01-01"])
        expect(evaluator.evaluate_condition(c, { "date" => "2023-06-15" })).to be false
      end
    end

    context "unknown operator" do
      it "returns false" do
        c = condition(operator: "Unknown")
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be false
      end
    end

    context "negate flag" do
      it "inverts a true result to false" do
        c = condition(operator: "Equals", negate: true)
        expect(evaluator.evaluate_condition(c, { "country" => "US" })).to be false
      end

      it "inverts a false result to true" do
        c = condition(operator: "Equals", negate: true)
        expect(evaluator.evaluate_condition(c, { "country" => "UK" })).to be true
      end
    end

    context "missing attribute" do
      it "returns false when attribute is absent" do
        c = condition(operator: "Equals")
        expect(evaluator.evaluate_condition(c, {})).to be false
      end

      it "returns true when attribute is absent and negate is true" do
        c = condition(operator: "Equals", negate: true)
        expect(evaluator.evaluate_condition(c, {})).to be true
      end
    end
  end

  describe "#evaluate_conditions" do
    context "empty conditions" do
      it "returns true" do
        expect(evaluator.evaluate_conditions([], "And", {})).to be true
        expect(evaluator.evaluate_conditions([], "Or", {})).to be true
      end
    end

    context "AND logic" do
      it "returns true when all conditions match" do
        conditions = [
          condition(operator: "Equals", attribute: "country", values: ["US"]),
          condition(operator: "Equals", attribute: "plan", values: ["pro"])
        ]
        context = { "country" => "US", "plan" => "pro" }
        expect(evaluator.evaluate_conditions(conditions, "And", context)).to be true
      end

      it "returns false when any condition fails" do
        conditions = [
          condition(operator: "Equals", attribute: "country", values: ["US"]),
          condition(operator: "Equals", attribute: "plan", values: ["pro"])
        ]
        context = { "country" => "US", "plan" => "free" }
        expect(evaluator.evaluate_conditions(conditions, "And", context)).to be false
      end
    end

    context "OR logic" do
      it "returns true when any condition matches" do
        conditions = [
          condition(operator: "Equals", attribute: "country", values: ["US"]),
          condition(operator: "Equals", attribute: "country", values: ["UK"])
        ]
        context = { "country" => "UK" }
        expect(evaluator.evaluate_conditions(conditions, "Or", context)).to be true
      end

      it "returns false when no conditions match" do
        conditions = [
          condition(operator: "Equals", attribute: "country", values: ["US"]),
          condition(operator: "Equals", attribute: "country", values: ["UK"])
        ]
        context = { "country" => "CA" }
        expect(evaluator.evaluate_conditions(conditions, "Or", context)).to be false
      end
    end
  end

  describe "#evaluate_condition_groups" do
    def group(conditions, operator: "And")
      Featureflip::Models::ConditionGroup.new(operator: operator, conditions: conditions)
    end

    context "empty groups" do
      it "returns true for nil" do
        expect(evaluator.evaluate_condition_groups(nil, {})).to be true
      end

      it "returns true for empty array" do
        expect(evaluator.evaluate_condition_groups([], {})).to be true
      end
    end

    context "single group" do
      it "returns true when group conditions match with AND" do
        groups = [
          group([
            condition(operator: "Equals", attribute: "country", values: ["US"]),
            condition(operator: "Equals", attribute: "plan", values: ["pro"])
          ], operator: "And")
        ]
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "US", "plan" => "pro" })).to be true
      end

      it "returns false when any AND condition fails" do
        groups = [
          group([
            condition(operator: "Equals", attribute: "country", values: ["US"]),
            condition(operator: "Equals", attribute: "plan", values: ["pro"])
          ], operator: "And")
        ]
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "US", "plan" => "free" })).to be false
      end

      it "returns true when any OR condition matches" do
        groups = [
          group([
            condition(operator: "Equals", attribute: "country", values: ["US"]),
            condition(operator: "Equals", attribute: "country", values: ["UK"])
          ], operator: "Or")
        ]
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "UK" })).to be true
      end
    end

    context "multiple groups (ANDed together)" do
      it "returns true when all groups match" do
        groups = [
          group([condition(operator: "Equals", attribute: "country", values: ["US"])]),
          group([condition(operator: "Equals", attribute: "plan", values: ["pro"])])
        ]
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "US", "plan" => "pro" })).to be true
      end

      it "returns false when any group fails" do
        groups = [
          group([condition(operator: "Equals", attribute: "country", values: ["US"])]),
          group([condition(operator: "Equals", attribute: "plan", values: ["pro"])])
        ]
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "US", "plan" => "free" })).to be false
      end

      it "supports mixed operators across groups" do
        groups = [
          group([
            condition(operator: "Equals", attribute: "country", values: ["US"]),
            condition(operator: "Equals", attribute: "country", values: ["UK"])
          ], operator: "Or"),
          group([
            condition(operator: "Equals", attribute: "plan", values: ["pro"])
          ], operator: "And")
        ]
        # country=UK matches first group (Or), plan=pro matches second group (And)
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "UK", "plan" => "pro" })).to be true
        # country=CA fails first group
        expect(evaluator.evaluate_condition_groups(groups, { "country" => "CA", "plan" => "pro" })).to be false
      end
    end
  end
end
