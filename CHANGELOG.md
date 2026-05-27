# Changelog

## 2.1.0

### Added

- **Prerequisite flag evaluation.** Flags can declare prerequisites that must serve a specific variation for the flag to evaluate normally. When a prerequisite is not satisfied, the flag serves its off-variation with reason `PrerequisiteFailed` and a `prerequisite_key` field on `EvaluationDetail`.
- Recursive prerequisite resolution with per-call memoization and a depth cap (`MAX_PREREQUISITE_DEPTH = 10`).
- `Evaluator#evaluate_with_shared_memo` for batch evaluations to share prerequisite results.

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
