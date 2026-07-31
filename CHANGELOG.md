# Changelog

## 2.4.1 — 2026-07-30

### Fixed

- **A same-version flag delta is no longer discarded.** `FlagStore#upsert` rejected any incoming flag whose version was not strictly greater than the stored one. Because the wire version is second-granular, two edits to one flag inside the same wall-clock second carry an identical version, so the second edit's configuration was dropped — and with streaming enabled there is no polling snapshot to correct it, leaving evaluations on the pre-edit configuration until an SSE `sync` or reconnect. Only strictly older configurations are now treated as stale (#2101).

## 2.4.0 — 2026-07-29

### Added

- **`onEvaluation` inspector callback.** `inspectors` config option registering in-process observers fired on every evaluation (#1914).

### Fixed

- A served variation key the flag does not define now reports reason `Error` with the caller's default, instead of a misleading success reason (#1989).
- An explicit `"flags": null` in a response payload no longer hangs initialization (#1934).

## 2.3.0 — 2026-07-13

### Fixed

- Outage-recovery hardening: infinite SSE read timeout and `sync` applied as a full store replace (#1869, #1896).
- SSE streaming hardening: chunk buffering, a liveness watchdog, and clean-EOF backoff (#1891, #1892, #1893).

## 2.2.0 — 2026-06-19

### Added

- **Semantic-version condition operators** (`SemverEquals`, `SemverGreaterThan`, `SemverGreaterThanOrEqual`, `SemverLessThan`, `SemverLessThanOrEqual`) for local rule evaluation, comparing per semver precedence rather than as decimals (#1434).

### Fixed

- `logger` is declared as a runtime dependency — without it the suite fails on Ruby 3.5+/4.0, where it is no longer a default gem (#1474).
- Relational operators match against **any** supplied condition value (#1443).
- `MatchesRegex` is case-sensitive, matching the engine. Invalid patterns fail safe to no-match, and a per-`Regexp` `timeout: 0.1` bounds catastrophic backtracking (#1453, #1460).
- `Before`/`After` date operators aligned with the engine (#1455).
- Type-aware numeric coercion for `Equals`/`In` (#1458).
- Keyless rollouts serve the control variation deterministically (#1457).
- Segment-keyed rules with no segment source fail closed. Ruby needed an explicit non-empty check, since `""` is truthy (#1459).
- Environment-level percentage rollouts with no variations no longer raise (#1469).

## 2.1.0 — 2026-05-27

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
