# Changelog

## 2.0.0

### Breaking Changes

- **`Client.new` is no longer public.** Use `Client.get(sdk_key)` or `Client.get(sdk_key, config: config)` instead.
- The SDK now enforces singleton-by-construction: same SDK key returns handles sharing one set of connections and background threads.

### Added

- `Client.get(sdk_key, config:)` — factory method that returns a handle backed by a refcounted shared core.
- Multiple handles for the same SDK key share resources. Closing the last handle cleans up.
- `Featureflip.configure` continues to work unchanged.

## 1.0.1

- Initial public release.
