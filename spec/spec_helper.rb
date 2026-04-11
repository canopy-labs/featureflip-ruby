require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
end

require "featureflip"
require "webmock/rspec"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.before(:each) do
    Featureflip::SharedCore._reset_for_testing
  end

  config.after(:each) do
    Featureflip::SharedCore._reset_for_testing
  end
end
