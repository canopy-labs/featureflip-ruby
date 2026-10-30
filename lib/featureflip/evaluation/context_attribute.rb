module Featureflip
  module Evaluation
    # Looks an attribute up in an evaluation context hash.
    #
    # "user_id" is the canonical spelling of the user identifier and "userId" is
    # accepted as an alias (#4518). A lookup of exactly one of the two returns
    # "user_id" when it is non-nil, else "userId" when it is non-nil, else nil.
    # An empty string is a value and does not fall through. Every other key,
    # including other casings, is an ordinary attribute.
    module ContextAttribute
      module_function

      def resolve(context, attribute)
        if attribute == "user_id" || attribute == "userId"
          value = context["user_id"]
          value = context["userId"] if value.nil?
          value
        else
          context[attribute]
        end
      end
    end
  end
end
