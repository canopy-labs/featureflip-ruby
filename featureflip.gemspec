require_relative "lib/featureflip/version"

Gem::Specification.new do |spec|
  spec.name = "featureflip"
  spec.version = Featureflip::VERSION
  spec.authors = ["Featureflip"]
  spec.summary = "Featureflip feature flag SDK for Ruby"
  spec.description = "Server-side SDK for evaluating feature flags with Featureflip"
  spec.homepage = "https://featureflip.io"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata = {
    "homepage_uri" => "https://featureflip.io",
    "documentation_uri" => "https://featureflip.io/docs/sdks/ruby/"
  }

  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.23"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
