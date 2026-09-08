# Changelog

## 2.8.0 — 2026-09-01

### Fixed

- A condition operator is now recognised however it is spelled: `NotEquals`, `notequals`, `NOTEQUALS` and `not_equals` all resolve to the same operator. This SDK previously matched the canonical PascalCase label exactly and treated every other spelling as unrecognised — and an unrecognised operator fails closed (#2262), so a mis-spelled operator matched nobody rather than erroring. The go and php SDKs each applied a *different* rule: go folded case but kept underscores, so it resolved `notequals` and rejected `not_equals`, while php inserted underscores ahead of PascalCase runs and did exactly the reverse. Each accepted a form the other refused, so one saved rule could serve different variations to two users purely by which SDK their service ran. All four now normalise by removing underscores and folding case — the one rule that is a superset of all four previous ones, so no SDK gets stricter and no configuration that evaluated before stops doing so. (#2374)

- The operator is resolved **once** per condition and every subsequent lookup keys off that value, not just the dispatch arm. The operator name also selects the case-sensitivity set and the numeric-coercion set, so normalising at the dispatch alone would have made a mis-cased `MatchesRegex` match case-insensitively where its canonical spelling does not, and dropped a mis-cased `NotEquals` onto the string path, comparing `"1"` against `"1.0"` lexically. (#2374)

- The fail-closed guarantee is unchanged and re-asserted: this resolves *spellings*, it does not invent operators. A name that is not an operator is still unrecognised and still matches nothing before `negate` can invert it. (#2262)

## 2.7.0 — 2026-08-26

### Changed

- A `Before`/`After` date operand that matches the ISO grammar but names no real calendar day now matches nothing, where it previously **rolled over into the following month**. `2024-02-30` resolved to 2024-03-01, `2023-02-29` (2023 is not a leap year) to 2023-03-01 and `2024-04-31` to 2024-05-01 — so a rule evaluated against a date its author never wrote. The evaluation engine and the C#, Go, Python and Java SDKs have always rejected these, so this converges the SDKs rather than making this one an outlier; until now a single saved rule could serve different variations to two users purely by which SDK their service ran. Follows #2480, which pinned the date *grammar* — an unreal day is **inside** that grammar, because a character class cannot express "is a real day", so the grammar guard was silent on it. (#2491)

- The leap-year rule is applied in full, including the century exception: `1900-02-29` and `2100-02-29` match nothing (divisible by 100 but not 400), while `2000-02-29` and `2024-02-29` continue to match. The check runs on the operand's **written** date, before any offset is applied, so `2024-02-30T00:00:00+05:00` is rejected even though it would resolve to 2024-02-29T19:00Z — a date that does exist. (#2491)

**If you have a targeting rule using one of these operands**, rewrite it as the date you meant. The Management API has rejected an unreal day on write since #2480 (`PortableDateOperand` round-trips every grammar-matched operand through the engine's parser), so a rule saved from that release onward cannot carry one — only rules saved earlier are affected.

### Fixed

- An explicit `client.flush` no longer opens a second drain loop while one is already running. The in-flight latch added for #2456 guarded only the batch-size trigger, so the periodic flush, an explicit `client.flush` and a size-triggered flush could enter the loop together — two request streams against an endpoint the backoff gate exists to protect, and worse, a success in one cleared the gate a failure in the other had just armed, re-opening the one-request-per-evaluation behaviour outright. A caller arriving while a drain is running now waits for it and returns, matching the js and node SDKs. Shutdown still bypasses coalescing, because it is the last drain there will ever be. (#2477)

- A `Before`/`After` date operand that resolves outside the representable date range now matches nothing, where it previously resolved to a real instant. The evaluation engine parses with `DateTimeOffset.TryParse`, so its accepted range is 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999Z and it matches nothing outside that; this SDK resolved past **both** ends, so a single saved rule served different variations to two users purely by which SDK their service ran. (#2500)

- The two reachable shapes are a **year-zero** operand and an operand carried out of range **by its offset**. `0000-01-01` is inside the ISO grammar and is a real proleptic date (`0000-02-29` exists — year 0 is divisible by 400), so neither #2480's grammar guard nor #2491's calendar-day check excluded it. Separately, `[0-9]{4}` constrains only the **written** year while a timezone offset moves the resolved instant, so `0001-01-01T00:00:00+05:00` fell below the floor and `9999-12-31T23:59:59-05:00` rose above the ceiling from years the grammar allows. The check therefore runs on the **resolved** instant — deliberately unlike #2491's, which runs on the written date. (#2500)

- The exact boundaries remain accepted: `0001-01-01`, `0001-01-01T05:00:00+05:00`, `9999-12-31T23:59:59Z` and `9999-12-31T18:59:59-05:00` all still resolve. (#2500)

**If you have a targeting rule using one of these operands**, rewrite it as the date you meant. The Management API has rejected them on write since #2480 (`PortableDateOperand` round-trips every grammar-matched operand through the engine's own parser, so it inherits the range bound), meaning only rules saved before that release can carry one.

- The first SSE reconnect after a healthy stream drops is now jittered to `[d/2, d]`, like every other backoff level. The drops this absorbs are fleet-wide — a single edge event severs every stream at once — so every client re-entered the backoff together and waited an identical delay, republishing the drop's own synchronisation as a reconnect spike one backoff later. Measured in production: a drop spread across 2.5–3.0 ms produced a reconnect spread of 26–46 ms. The delay never exceeds the previous one and stays strictly positive, so a stream that fails immediately still cannot busy-loop. (#2508)

## 2.6.1 — 2026-08-24

### Fixed

- A date operand is now trimmed of exactly the whitespace the evaluation engine trims (tab, newline, vertical tab, form feed, carriage return and space), and is rejected outright if it still carries a NUL, another control character, or a non-ASCII whitespace character. Each SDK had been relying on its own language's `trim`, and no two of those cover the same set, so the same operand could match on one SDK and match nothing on another. (#2468)
- A date operand written with a space separator (`2024-01-01 00:00:00`), without seconds (`2024-01-01T00:00`), or with a basic offset (`+0500`) now parses. `Time.iso8601` rejects all three, so they were matching nothing here while the engine accepted them. (#2468)
- An ISO-8601 operand naming hour 24 (`2024-01-01T24:00:00`) matches nothing, rather than rolling over to the next day. (#2468)

## 2.6.0 — 2026-08-24

### Fixed

- Analytics events survive a failed send instead of being discarded. The queue was drained before the POST and the batch dropped on any failure, so every rejection cost that batch permanently — and the production edge answers this endpoint with a 503 at a low but constant rate, so the loss was steady rather than exceptional. A batch that fails for a reason a later attempt could get past — any 5xx, a 429, or a transport error or timeout — now goes back to the front of the queue and the next flush re-sends it. One the server will reject identically forever — 401/403 for a rejected SDK key, 400 for a malformed body — is still dropped, but now says so. Every failure is logged either way, so this does not hide the rejections it recovers from. (#2456)

### Added

- The event queue is bounded, at 10,000 events by default. Past the bound the oldest events are shed and the number dropped is logged, so an endpoint that stays down cannot grow the buffer without limit. (#2456)

### Changed

- `flush` sends at most `flush_batch_size` events per request instead of posting the whole queue in one. That only mattered once failed batches started being kept: a sustained outage can leave the queue sitting at its 10,000-event bound, and a body that large risks an outright rejection — which, being non-retryable, would have dropped the entire backlog through the very path meant to preserve it. A batch the server rejects permanently is dropped and the drain moves on to the events behind it, so one bad batch cannot block the backlog. (#2456)

- A re-queued batch no longer makes every subsequent tracked event trigger its own send. Keeping a failed batch leaves the queue at or above `flush_batch_size`, which would otherwise turn a failing endpoint into one request per evaluation. The batch-size trigger now stands down for one `flush_interval` after a retryable failure, and only one size-triggered flush runs at a time; the background flush thread remains the retry vehicle. (#2456)

## 2.5.2 — 2026-08-23

### Fixed

- A failed flag fetch no longer costs two requests. `get_flags` retried once on a 5xx before raising, which doubled request volume against a backend that was already failing and blocked for a second inside the `init_timeout` budget on cold start. The poller re-fetches every `poll_interval` and the streaming source reconnects with backoff, so the inner retry added nothing. Event delivery keeps its retry — `EventProcessor#flush` clears the queue before sending, so a dropped batch is unrecoverable. (#2454)

## 2.5.1 — 2026-08-23

### Fixed

- An unrecognised condition operator now fails closed instead of matching every user. The default arm returned `false`, which a negated condition then inverted to `true` — so a config naming an operator the SDK did not know could silently target everyone. (#2262)
- `identify()` and `track()` put the same payload on the wire as every other server SDK. The field set and shapes had drifted per language, so the same call produced different events depending on which SDK sent it. (#2359)

## 2.5.0 — 2026-08-20

### Fixed

- `initialized?` returns `false` after `close`. Every variation accessor was already guarded, so a closed client correctly served defaults while still claiming to be initialized. (#2287)

- Config payloads that violate the wire contract are rejected instead of being stored as-is and silently mis-evaluated. Values are compared against string literals, so a non-conforming payload was accepted without error and then targeted incorrectly forever. (#2285)
### Changed

- A type-mismatched read returns the caller's default and reports `'Error'`, instead of doing no type checking at all and handing back the served value. Reading a String flag through a number accessor, say, is now detectable rather than silent. Matching reads and the generic/JSON accessors are unchanged. (#2286)

## 2.4.2 — 2026-08-05

### Fixed

- `LICENSE` is now the verbatim Apache-2.0 text. Three phrases in the operative sections had been reworded and the appendix dropped, which left automated license scanners unable to identify it. The license itself is unchanged; the file now says what it always claimed to.

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
