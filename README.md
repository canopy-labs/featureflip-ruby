# Featureflip Ruby SDK

Ruby SDK for [Featureflip](https://featureflip.io) - evaluate feature flags locally with near-zero latency.

## Installation

Add to your Gemfile:

```ruby
gem "featureflip"
```

Or install directly:

```bash
gem install featureflip
```

## Quick Start

```ruby
require "featureflip"

# Initialize the client (blocks until flags are loaded)
client = Featureflip::Client.new(sdk_key: "your-sdk-key")

# Evaluate a feature flag
enabled = client.bool_variation("my-feature", { "user_id" => "user-123" }, false)

if enabled
  puts "Feature is enabled!"
else
  puts "Feature is disabled"
end

# Clean shutdown
client.close
```

## Configuration

```ruby
config = Featureflip::Config.new(
  base_url: "https://eval.featureflip.io",  # Evaluation API URL (default)
  streaming: true,                            # Use SSE for real-time updates (default)
  poll_interval: 30,                          # Polling interval in seconds
  send_events: true,                          # Enable analytics event tracking (default)
  flush_interval: 30,                         # Event flush interval in seconds
  flush_batch_size: 100,                      # Events per batch
  init_timeout: 10,                           # Max seconds to wait for initialization
  connect_timeout: 5,                         # HTTP connection timeout in seconds
  read_timeout: 10,                           # HTTP read timeout in seconds
  max_stream_retries: 5,                      # SSE retries before falling back to polling
)

client = Featureflip::Client.new(sdk_key: "your-sdk-key", config: config)
```

The SDK key can also be set via the `FEATUREFLIP_SDK_KEY` environment variable.

## Singleton Convenience API

For applications that use a single client instance:

```ruby
Featureflip.configure do |c|
  c.sdk_key = "your-sdk-key"
  c.base_url = "https://eval.featureflip.io"
  c.streaming = true
end

enabled = Featureflip.bool_variation("my-feature", { "user_id" => "123" }, false)

# On shutdown
Featureflip.close
```

## Evaluation

Context can use string or symbol keys:

```ruby
context = { user_id: "123", email: "user@example.com" }
# or
context = { "user_id" => "123", "email" => "user@example.com" }

# Boolean flag
enabled = client.bool_variation("feature-key", context, false)

# String flag
tier = client.string_variation("pricing-tier", context, "free")

# Number flag
limit = client.number_variation("rate-limit", context, 100)

# JSON flag
config = client.json_variation("ui-config", context, { "theme" => "light" })
```

### Detailed Evaluation

```ruby
detail = client.variation_detail("feature-key", { user_id: "123" }, false)

detail.value          # The evaluated value
detail.reason         # "RuleMatch", "Fallthrough", "FlagDisabled", "FlagNotFound"
detail.rule_id        # Rule ID if reason is "RuleMatch"
detail.variation_key  # Key of the matched variation
```

## Event Tracking

```ruby
# Track custom events
client.track("checkout-completed", { user_id: "123" }, { total: 99.99 })

# Identify users for segment building
client.identify({ user_id: "123", email: "user@example.com", plan: "pro" })

# Force flush pending events
client.flush
```

## Testing

Use the test client for deterministic unit tests with no network calls:

```ruby
client = Featureflip::Client.for_testing(
  "my-feature" => true,
  "pricing-tier" => "pro"
)

client.bool_variation("my-feature", {}, false)      # => true
client.string_variation("pricing-tier", {}, "free")  # => "pro"
client.bool_variation("unknown", {}, false)           # => false (default)
```

## Rails Setup

Featureflip is framework-agnostic. For Rails, initialize in an initializer:

```ruby
# config/initializers/featureflip.rb
Featureflip.configure do |c|
  c.sdk_key = ENV["FEATUREFLIP_SDK_KEY"]
  c.streaming = true
end

# For Puma/Unicorn/Passenger — respawn threads after fork
# config/puma.rb
on_worker_boot do
  Featureflip.restart
end
```

## Features

- **Local evaluation** - Near-zero latency after initialization
- **Real-time updates** - SSE streaming with automatic polling fallback
- **Event tracking** - Automatic batching and background flushing
- **Test support** - `for_testing` factory for deterministic unit tests
- **Thread-safe** - Mutex-protected flag store and event queue
- **Fork-safe** - `restart` method for Puma/Unicorn/Passenger worker processes
- **Zero runtime dependencies** - Uses only Ruby stdlib (`net/http`, `digest/md5`)

## Requirements

- Ruby 3.2+

## Development

```bash
# Install dependencies
bundle install

# Run tests
bundle exec rspec

# Run specific test file
bundle exec rspec spec/featureflip/evaluation/evaluator_spec.rb
```

## License

Apache-2.0
