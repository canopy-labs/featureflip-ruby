require "rails/railtie"
require "active_support/ordered_options"

module Featureflip
  # Builds the shared client when a Rails app boots. Loaded by `require "featureflip"`
  # only when Rails::Railtie is already defined, so non-Rails apps never see it and the
  # gem does not depend on Rails.
  #
  #   # config/application.rb or an environment file
  #   config.featureflip.sdk_key = ENV["FEATUREFLIP_SDK_KEY"]  # optional, see below
  #   config.featureflip.poll_interval = 60
  #
  # Any Featureflip::Config option can be set on config.featureflip. The SDK key is
  # read from config.featureflip.sdk_key, then FEATUREFLIP_SDK_KEY, then
  # credentials.featureflip.sdk_key. With no key the client is not built and a warning
  # is logged.
  #
  # The client is the same one the singleton API uses:
  #   Rails.application.config.featureflip_client
  #   Featureflip.bool_variation("flag", { "user_id" => "1" }, false)
  class Railtie < ::Rails::Railtie
    WRAPPER_NAME = "featureflip-rails".freeze

    config.featureflip = ActiveSupport::OrderedOptions.new

    # after_initialize, so config/initializers and credentials are all loaded.
    config.after_initialize do |app|
      Featureflip::Railtie.setup(app)
    end

    class << self
      # Builds the client from app.config.featureflip and stores it at
      # app.config.featureflip_client. Returns nil (after a warning) when no SDK key
      # is configured. A failed first fetch raises Featureflip::InitializationError
      # and stops boot; set `snapshot_store` to start from the last known flags
      # instead.
      def setup(app)
        options = app.config.featureflip.to_h.transform_keys(&:to_sym)
        sdk_key = options.delete(:sdk_key) || ENV["FEATUREFLIP_SDK_KEY"] || credentials_key(app)

        if sdk_key.nil? || sdk_key.to_s.strip.empty?
          logger&.warn("Featureflip: no SDK key configured (config.featureflip.sdk_key, " \
                       "FEATUREFLIP_SDK_KEY or credentials featureflip.sdk_key); " \
                       "the client was not started")
          return app.config.featureflip_client = nil
        end

        Featureflip.configure do |c|
          c.sdk_key = sdk_key
          c.logger = logger if logger
          c.wrapper_name = WRAPPER_NAME
          c.wrapper_version = ::Rails.version
          options.each do |name, value|
            setter = "#{name}="
            raise ConfigurationError, "Unknown config.featureflip option: #{name}" unless c.respond_to?(setter)

            c.public_send(setter, value)
          end
        end

        register_shutdown
        app.config.featureflip_client = Featureflip.default_client
      end

      def shutdown
        Featureflip.close
      end

      private

      def logger
        ::Rails.logger
      end

      def credentials_key(app)
        app.credentials.dig(:featureflip, :sdk_key)
      rescue StandardError
        # A missing or unreadable master key must not stop an app that sets the key elsewhere.
        nil
      end

      def register_shutdown
        return if @shutdown_registered

        @shutdown_registered = true
        at_exit { shutdown }
      end
    end
  end
end
