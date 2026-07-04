# LungfishCore — deferred items

Items the expert audits flagged but that were NOT applied confidently during the
refactor. Each is a candidate for the downstream LLM or a future Opus pass. Every
entry names the file, the reason it was deferred, and a concrete suggestion.

## 2026-07-04 expert-review corrections

The downstream expert review agreed with the mechanical splits and most dead-code removals, but
reverted public API shrinkage that was too risky for a foundational module:
- `BlastService.submit`, `BlastService.checkStatus`, and `BlastService.getResults` remain
  `public`.
- `SequenceDiff.computeDetailed(from:to:)` remains `public` as a compatibility wrapper over the
  simplified implementation.
- `Version.computeHash(_:)` remains `public`.

Regression tests now source-scan these declarations so future behavior-preserving refactors do
not accidentally demote them again.

## 2026-07-04 maintainability-hardening updates

The follow-up review implemented several items that were deferred only because the
original refactor was constrained to behavior-preserving edits:

- `ProjectStore.storeSequence` and `recordVersion` now run their multi-statement
  writes inside SQLite transactions; tests force mid-write failures and verify
  rollback.
- `ProjectStore.bindParameter` now throws for unsupported parameter types instead
  of silently binding NULL.
- `ProjectStore.reconstructSequence` now rejects negative version indexes with
  `invalidVersionIndex` instead of trapping on a negative range.
- `ProjectStore` row decoders now throw `queryError` for corrupted UUID/text/blob
  columns instead of force-unwrapping DB-derived values.
- `NCBIService.fetchBatch` and `ENAService.fetchBatch` now cancel their producer
  tasks on stream termination and check cancellation before each fetch, matching
  the existing Pathoplexus pattern.
- `ProjectFile.saveMetadata` now writes `metadata.json` atomically.
- `VariantColorTheme.init(name:)` now preserves the caller-provided name.
- `SRAAccessionParser.parseCSV` now uses the same comma/tab/space/newline
  delimiter semantics as `parseAccessionList`.
- `VariantConverter.convertToBCF` and `ReferenceBundleBuilder` fail closed rather
  than writing fake BCF/CSI, BigWig, BigBed, or bgzip outputs. The Core builder
  accepts only uncompressed FASTA for copy/index builds, preserves annotation
  source extensions, copies only already-indexed BCF+CSI inputs, and points
  compressed/converted scientific outputs to `NativeBundleBuilder`/CLI tooling.
- `SRAService.downloadFASTQFromENA` now uses the shared `HTTPClient.download`
  contract so URLSession can stream ENA FASTQ payloads to temporary files before
  atomic publication; tests assert the download path does not fall back to
  response-buffer writes.
- `SRAService.runCommand` now drains stdout/stderr concurrently while SRA Toolkit
  subprocesses run, avoiding pipe-buffer deadlocks on verbose tools.
- `SRAService` now reuses POSIX/UTC run-info date formatters and accepts both
  timestamp and date-only NCBI run-info dates.
- `SRAService.search` now uses NCBI `esearchWithCount` so SRA search results
  report corpus totals and page boundaries instead of returned-page counts.

## ProjectStore.swift (remaining escalations)

- **RESOLVED — DB-derived row decoding no longer force-unwraps corrupted data.**
  Invalid UUID text and missing/invalid required blob/text payloads now throw
  `ProjectStoreError.queryError` with column context instead of crashing.
- **F8 — access-control demotion of checkpoint/setMetadata/getMetadata (medium
  conf).** Appear test-only; could be `internal`. Deferred pending a cross-module
  grep confirming no leaf/App caller.

## ReferenceBundleBuilder.swift

- **RESOLVED — Core fallback builder no longer fabricates converted scientific
  formats.** It fails closed for bgzip compression, VCF-to-BCF conversion, and
  non-BigWig signal conversion. Annotation inputs keep their source extension
  rather than being renamed to `.bb`. Variant inputs must already be `.bcf` with
  an adjacent `.bcf.csi`; otherwise callers must use the native workflow/CLI
  path that can run the real tools and write provenance.
- **F12 — progress-weight sum: audit premise was WRONG (resolved, no change).**
  The audit claimed the `BuildStep` weights sum to 1.05 and `.complete`'s 0.05 is
  unused. Zeroing it was attempted and REVERTED: the other 8 weights sum to 0.95
  and `.complete` carries the final 0.05 so the total is exactly 1.0, which
  `testBuildStepProgressWeights` asserts. Kept `.complete = 0.05` with a corrected
  comment. No further action.

- **F9 — full-genome parse + file copy run on `@MainActor` (medium).** Blocks the
  UI for the whole build; per project rules long pipelines should be off-main
  with a thin `@MainActor` progress model. Deferred (significant restructuring,
  not behavior-preserving).

## SRAService.swift (remaining escalations)

- **RESOLVED F8 — SRA search totals now use the ESearch corpus `<Count>`.**
  `SRAService.search` calls `NCBIService.esearchWithCount` and computes
  `hasMore` from `offset + returnedIDs < totalCount`.
- **F5 — `parseRunInfoCSV` duplicated with NCBIService (low).** Two independent
  runinfo CSV parsers. Deferred cross-file consolidation into a shared
  `SRARunInfoCSVParser` with regression fixtures for both callers.

## VariantTrack.swift (notes — mostly clean)

- Audit confirmed the two hand-rolled Codable conformances (`VariantTrack`
  tolerant `displaySettings` default; `VariantTrackDisplaySettings` enum-keyed
  dict + Set serialization) are LOAD-BEARING and must NOT be collapsed to
  synthesized Codable. Access control is already correct (public model types are
  transitively reachable through `VariantTrack`'s public API; cannot demote).
- F2/F3/F4 — several unused public query/conversion helpers (`passedFilters`,
  `passingVariants`, `variants(ofType:/minQuality:/inRegion:)`, `infoInt`) and
  untested `.byQuality`/`.byFrequency` color paths. Left in place (plausibly
  intended public model API); flagged as public-surface-shrink candidates for the
  downstream LLM if desired.

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

- **RESOLVED BS-08 — gzip retry backoff no longer blocks the actor executor.**
  `extractMatchingSequences` is now async only at the retry wrapper boundary and
  uses cancellation-aware `Task.sleep` for gzip retry delays; the single-attempt
  FASTQ parsing path remains synchronous. Regression coverage cancels during the
  retry backoff and requires `CancellationError`.

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

- **RESOLVED — unstructured batch-stream producer tasks.** `NCBIService` and
  `ENAService` now capture the producer `Task`, cancel it from
  `continuation.onTermination`, and call `Task.checkCancellation()` before each
  fetch. This matches the existing Pathoplexus implementation and prevents
  abandoned consumers from continuing to issue network requests.

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

## Wave-2 cluster escalations (behavior-changing / cross-file — NOT applied)

### Translation + Versioning
- VersionHistory uses legacy `ObservableObject`/`@Published` in an otherwise
  `@Observable` codebase (F6). Migration changes view-update timing — not
  behavior-preserving. Defer to a deliberate observation-migration pass.
- `VersionHistory.fromJSON` swallows checkout failure with `try?` (F7), leaving
  index/sequence inconsistent on corrupt history. Changing to `try` alters the
  throwing contract. Defer (needs a test decision).
- Leave-alone (correctness-critical): codon tables + U→T normalization, diff
  apply/inverse round-trip, `genomicRangesForCodon` strand mapping, SHA-256 hex.

### Services/AI (3 providers + helpers)
- R1 — HTTP status→AIProviderError switch duplicated 5x across providers. A
  shared `mapNonSuccessStatus(...)` helper is the big DRY win but touches every
  provider's FAILURE PATH (401-vs-{401,403}, quota, context-length, retry-after).
  Defer: behavior-preserving only if parameterized exactly; needs provider
  error-mapping tests green before/after.
- E2 — Anthropic/Gemini call `httpClient.data(for:)` bare while OpenAI wraps
  transport errors into `.networkError`. Wrapping them changes the error TYPE
  surfaced on timeout/offline (inconsistent today). Defer (failure-path change).
- E1 — Gemini maps 403→`.missingAPIKey` (often really quota/billing). Defer.
- C1 — OpenAI `parseStructuredResponse` has two contradictory refusal guards
  (empty-string refusal allowed by branch 1, rejected by branch 2). Needs a
  decision on intended semantics. Defer.
- AC1 — 10 AI helper free functions sit at LungfishCore module scope with
  generic names (`parseErrorMessage`, `anyToJSONValue`). Namespacing under a
  caseless enum is clean but a wide mechanical rename. Defer.
- CN1 — structured send/parse skeleton near-identical OpenAI vs Anthropic; a
  generic `sendJSONRequest<T>` template crosses actor isolation (parse closures
  capture actor-isolated self). Defer to a dedicated pass.
- Hardcoded model defaults noted, NOT changed: Anthropic `claude-sonnet-4-5-20250929`,
  OpenAI `gpt-5.5`, Gemini `gemini-2.5-flash`.

### Network services (ENA / Pathoplexus / SRA parser)
- ENA date parsing omits `en_US_POSIX` locale (F10) — Pathoplexus sets it.
  Strictly-more-correct but a behavior change under exotic locales. Defer (pair
  with the DateFormatter caching that WAS applied).
- ENA `search` `hasMore`/`totalCount` are page-based, not corpus totals (F9) —
  false-positive `hasMore` when last page == limit. Needs an ENA count endpoint.
  Defer.
- ENA searchReads vs searchReadsByStudy empty/error handling has DRIFTED (F7):
  one checks `errorText.contains("error")`, the other does not. Reconciling is a
  failure-path change. Defer.
- makeRequest status-switch duplicated across ENA/Pathoplexus/NCBI (F8) — shared
  `RateLimitedHTTPRequester` is a cross-file design item. Defer.
- Int/Double-or-String decode helper duplicated 5x+ (F1) — a shared
  `KeyedDecodingContainer.decodeIntOrString/decodeDoubleOrString` is a clean win
  but spans ENA + PathoplexusModels (2 files); left for a decode-helper pass.

### Bundles/Converters
- VariantConverter `convertToBCF` no longer writes `##BCF_PLACEHOLDER` text or a
  text index. It validates/analyzes input and then fails closed with a clear
  bcftools/native-tool message until a real converter is wired in.
- ReferenceBundleBuilder keeps gzipped annotation payloads as copied source files but no longer
  treats unreadable gzip bytes as `0` features or emits a misleading "No annotations found"
  description. Unknown compressed feature counts are recorded as absent in the manifest.
- AnnotationConverter `ConversionOptions.mergeOverlapping` is a public option
  never consulted — silent no-op contract (CLARITY-04). Document-or-implement
  decision. Defer.

## Storage cluster (ProjectFile/ProjectLock/Keychain/ManagedStorage*)

- **F12/F13 access-control demotions — REJECTED after verification (do NOT do).**
  The audit suggested demoting `ManagedStorageConfigStore`, `ManagedStorageLocation`,
  `ProjectLockManager`, `ProjectLockRecord`, `ProjectLockStatus`,
  `ManagedStorageBootstrapConfig` from `public` to `internal`. A clean cross-module
  grep shows they ARE consumed outside LungfishCore (e.g. ManagedStorageConfigStore
  in 12 non-Core files across App/IO/Workflow/CLI; ManagedStorageLocation in 4;
  ProjectLockManager in App+CLI). Demoting would break downstream builds. Correctly
  keep them `public`. (Recorded so this is not re-attempted.)
- **RESOLVED F3 — ProjectFile.saveMetadata writes metadata.json atomically.**
- **F5/F6 — ProjectLock corrupt-lock throw + acquisition TOCTOU race (medium).**
  `writeLock` overwrites unconditionally (no O_EXCL), so two processes racing to
  acquire can both win. Real fix changes lock semantics; needs concurrency tests.
  Defer to a lock-robustness pass.
- **F9/F10 — KeychainSecretStorage query consistency + non-UTF8 retrieve returns
  nil (low/medium).** Do NOT change keychain security semantics. Defer.
- **F11 — ManagedStorageConfigStore mutable `@MainActor static var shared` on an
  `@unchecked Sendable` class (medium).** Read-modify sequences across threads are
  unsynchronized (individual writes are `.atomic`). `var`->`let` is only safe if no
  reassignment exists; grep found no `shared =` reassignment, but leaving as-is is
  safest without a concurrency-model decision. Defer.
- **F1 — stray orphan comment at ProjectFile.swift end — applied in the wave-3 cluster.**

## Wave-3 cluster notes (Models-rest, Editing/Extraction/Capabilities/Genotype)

### Applied (safe, behavior-preserving): Sequence F7 (collapse redundant
reverse-complement quality double-wrap), SequenceAppearance F14 (doc 50->20pt),
AlignedRead F5 (doc param-order), ProjectFile F1 (delete orphan comment).

### Deferred / leave-alone:
- **RESOLVED — VariantColorTheme.init(name:) preserves the supplied name.**
- Sequence 2-bit packing, AlignedRead CIGAR walk (`forEachAlignedBase`/`insertions`
  with the I-P-I merge), SequenceExtractor coordinate/flank/RC/CDS math, EditableSequence
  /EditOperation undo-redo invariants — all correctness-sensitive, LEAVE ALONE.
- Three near-identical color value types (`HexColor`/`AnnotationColor`/`ThemeColor`)
  are NOT consolidated: they're embedded in distinct Codable schemas (r/g/b vs
  red/green/blue keys); merging breaks on-disk decode. Intentional duplication.
- `BundleAttachmentStore` / `ClassifierSamplePickerState` are `@Observable
  @unchecked Sendable` mutable classes doing sync FileManager I/O with no
  `@MainActor` (F10). Adding `@MainActor` is the right fix but ripples to App call
  sites — defer to a concurrency-model pass with a build.
- `GenomicDocument`'s `nonisolated var capabilities { .none }` stub (F3) makes
  protocol-routed capability checks silently return empty. Load-bearing (lets the
  type conform without MainActor); fixing means not conforming directly or making
  the protocol `@MainActor`. Defer with a compile.
- `AIProviderHelpers`: 10 generically-named free functions at module scope (F9)
  — namespacing under a caseless enum is a wide cross-file rename. Defer.
- **RESOLVED F12 — `SRAAccessionParser.parseCSV` delegates to accession-list
  delimiter semantics after removing an optional one-column header.**
- TempFileManager scans `/` on launch (TCC-fragile, best-effort) and may double-scan
  /tmp vs /private/tmp (F1/F2); RuntimeResourceLocator repeats a `0..<12` hop cap
  (F11) — trivial, deferred.
- Genotype color palettes (HaplotypeColorToken) are scientifically load-bearing
  ("must never be reordered or recolored") — LEAVE ALONE except a harmless dead
  local alias (F14, deferred as not worth the reviewer alarm).

## File-split pass (partial — access-level-blocked portions deferred)

The 3 largest Core files were split into focused same-directory files (pure
relocation). Three portions were NOT split because doing so would require
promoting `private` members to `internal`/`fileprivate` (an API-surface change,
not pure relocation) — left intact and recorded here:

- **BundleManifest+Mutations.swift NOT created.** The `copy(...)` builder,
  `synthesizedBrowserSummary()`, and `equivalentBrowserSummary` are `private` and
  shared between the mutators and the base-file `==`. Splitting the mutators out
  would need `copy` (and likely `synthesizedBrowserSummary`) to become
  `internal`/`fileprivate`. The whole I/O + mutations extension stays in
  BundleManifest.swift. Suggestion: if a split is wanted, promote `copy` to
  `internal` (it is a pure builder) and move the mutators.
- **URLSessionDownloadTaskBox stayed in NCBIService.swift.** It is `private final
  class` used by the actor's `downloadGenomeFile` (stays). Co-locating it with the
  moved `ContinuationDownloadDelegate` would need `internal`.
- **Several Blast private helpers stayed in BlastService.swift**
  (`extractQBlastValue`, `decompressZIPResponse`, `validateHTTPResponse`,
  `formEncode`) — each `private` and used by base-file methods that stay. Only the
  self-contained JSON2 parsing chain (reachable via the `internal`
  `parseJSON2Results`) split cleanly into BlastService+Parsing.swift.

Also fixed during the split: NCBIDownloadDelegate.swift needed `import os` (for
`OSAllocatedUnfairLock`), and `NCBIDownloadCancellationSourceTests` — a
source-scanning regression test hard-coded to NCBIService.swift — was updated to
scan the combined NCBIService.swift + NCBIDownloadDelegate.swift source so its
`resumeOnce` assertion (that token moved to the delegate file) still holds. All 9
assertions preserved.

## Environmental test flake observed (NOT a regression)

During the final Core-boundary full-suite run, `LungfishWorkflowTests.
ONTBarcodeDemuxGenotypingPipelineTests.testHaplotypeDropoutEvaluatorUsesMinSupportWithoutPercentThresholds`
DEADLOCKED under concurrent full-suite load (the process sat at ~1:43 CPU for 4
hours with no progress). The test passes in 0.004s when run in isolation, and this
is a LungfishWorkflow test untouched by the Core refactor. Root cause is almost
certainly the subprocess/pipe-wait hazard the SRAService/BlastService audits
flagged (waitUntilExit before draining pipes). The final Core green-bar was
therefore run with `--skip ONTBarcodeDemuxGenotypingPipelineTests` (9531 XCTest, 0
failures) and that suite verified separately in isolation. ACTION for a future
pass: harden the ONT pipeline test's subprocess handling (drain pipes concurrently
/ add a timeout) so it is safe under parallel test execution.
