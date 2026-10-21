module Featureflip
  # The User-Agent every request carries so the Evaluation API can count SDK usage by
  # name and version (#4154, contract in #4138): `featureflip-ruby/<version>`, then the
  # configured wrapper's token. VERSION is the constant the publish workflow rewrites,
  # never a second literal (#2141).
  module SdkIdentity
    # RFC 9110 product token: tchars.
    TOKEN = /\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/

    def self.user_agent(config)
      sdk = "featureflip-ruby/#{Featureflip::VERSION}"
      name = config.wrapper_name
      return sdk if name.nil? || name.to_s.empty?

      version = config.wrapper_version
      unless TOKEN.match?(name.to_s) && (version.nil? || TOKEN.match?(version.to_s))
        # Dropped rather than raised: identity metadata must never stop the client starting.
        config.logger.warn(
          "Featureflip: ignoring wrapper '#{name}/#{version}': not a valid User-Agent product token"
        )
        return sdk
      end

      version.nil? ? "#{sdk} #{name}" : "#{sdk} #{name}/#{version}"
    end
  end
end
