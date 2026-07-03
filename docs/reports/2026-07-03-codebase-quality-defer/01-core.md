# LungfishCore — deferred items

Items the expert audits flagged but that were NOT applied confidently during the
refactor. Each is a candidate for the downstream LLM or a future Opus pass. Every
entry names the file, the reason it was deferred, and a concrete suggestion.

## BlastService.swift

- **BS-05 — merge the two chunked file/gzip readers (medium confidence).**
  `scanKrakenClassificationOutput` and `extractMatchingSequencesOnce` share
  gzip-launch + chunk-read boilerplate, but differ in residual semantics
  (byte-level `Data` vs string-level) and error behavior on gzip failure (one
  throws on nonzero exit, the other only logs). Deferred because a naive merge
  could change error semantics. Suggestion: extract only the process-launch, keep
  per-caller residual + exit handling.

- **BS-07 — debug-file writes on the hot path (medium confidence).**
  `getResults` unconditionally writes `{rid}-raw-response` and `{rid}-extracted.json`
  to temp on every fetch. Deferred: gating behind `#if DEBUG` would change release
  behavior (arguably not behavior-preserving). Suggestion: extract to a named
  `persistDebugResponse(...)` helper (pure extraction, no gating) if desired, or
  decide policy on whether these should ship.

- **BS-08 — `Thread.sleep` inside actor-isolated extraction (low/medium
  confidence).** `extractMatchingSequences` blocks the actor executor with
  `Thread.sleep(forTimeInterval: 0.5)`. Deferred: marking the pure-I/O helpers
  `nonisolated` is safe but changes isolation; switching to `Task.sleep` requires
  making the chain async (timing/cancellation behavior change). Suggestion: the
  minimal safe step is `nonisolated` on the pure-I/O helpers only, done under a
  dedicated review.

- **BS-10 — split the 1735-line file by responsibility (high confidence,
  mechanical).** Actor + submit/poll/verify vs the `nonisolated` parsing cluster
  vs the subsampling extension vs `SeededRandomNumberGenerator`. Deferred to a
  dedicated file-split pass (see the module-wide split note below) rather than
  mixed into a logic-change batch.

## NCBIService.swift

- **HEAD-request methods bypass the injected `httpClient` (medium confidence).**
  `getGenomeFileInfo` / `getAnnotationFileInfo` / `getAssemblyReportInfo` use
  `URLSession.shared.data(for:)` directly (lines ~741, 801, 864), so they are
  unthrottled against NCBI's FTP host and untestable via the `MockHTTPClient`
  used elsewhere. Deferred because routing through `httpClient` would change
  timeout (explicit 30/15s here vs client default) and User-Agent, i.e. live
  behavior. Suggestion: either add HEAD support to the `HTTPClient` abstraction
  and route through it, or add a comment documenting why `URLSession.shared` is
  deliberate. Do not change silently.

- **`dup-headrequest-fileinfo` (medium confidence).** The three HEAD methods are
  ~90% identical but differ in throw-vs-return-nil error behavior and log text.
  Deferred with the item above; a shared `headFileInfo(...throwOnMissing:)`
  helper is viable but must preserve `getGenomeFileInfo`'s throw semantics
  exactly.

- **Unstructured `Task` in `fetchBatch` AsyncThrowingStream not cancelled on
  early consumer termination (medium confidence).** Lines ~1045-1057: the
  producer `Task` is not registered with `continuation.onTermination`, so an
  abandoned consumer keeps hitting NCBI. Deferred because it changes the
  abandoned-consumer path and the same shape exists in ENAService /
  PathoplexusService (fix all three together for consistency). Suggestion:
  capture the task and `continuation.onTermination = { _ in task.cancel() }` plus
  `try Task.checkCancellation()` in the loop, applied across all three services.

- **`dup-querycomponents-builder` / `dup-retry-event-append` (medium
  confidence).** Repeated eutils URLComponents+api_key construction (~6 sites)
  and retry-event append+sleep (~4 sites) could be DRY'd, but retry-event
  contents/ordering are asserted by tests (`retryEventsSnapshot`) and URL query
  ordering could matter. Deferred to avoid perturbing test-observed behavior;
  extract only with those tests confirmed green before/after.

## BundleManifest.swift

- **F3 — collapse backward-compat initializer overloads (medium confidence).**
  Four `public init` overloads exist only to disambiguate old call sites by the
  presence/absence of `originBundlePath` / `browserSummary` labels. Two of them
  may be redundant now that the canonical init defaults those params. Deferred
  because there are ~289 call sites and removing an overload can silently change
  overload resolution for calls that omit both trailing params. Suggestion: try
  the removal behind a full cross-target compile; revert on any resolution
  breakage. Not safe to do blind.

- **F8 — larger extraction inside `mapVCFChromosomes` (low/medium confidence).**
  The 85-line, 7-strategy fallback function repeats the `chr`-prefix-toggle and
  `first(where:)` name/alias pairs. A helper (`chrToggle`, `matchByNameOrAlias`)
  would DRY it, but this function is correctness-sensitive and used across
  IO/Workflow/App/CLI. Deferred to avoid altering match precedence. Suggestion:
  extract only with the `mapVCFChromosomes` unit tests (version-suffix,
  chr-prefix, alias, fasta-description cases) confirmed green before and after.
  (The smaller, safe `needle` hoist F9 WAS applied.)

- **F11 — possibly-dead `BundleValidationError` cases (medium confidence).**
  `.fileNotFound` and `.invalidFileFormat` are never emitted by `validate()` in
  this file. Deferred because removing a `public` enum case is source-breaking
  cross-module and a producer may exist in IO/Workflow. Suggestion: grep all
  modules for constructors of these cases; remove only if zero external
  producers.
