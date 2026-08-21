# Test Suite Review — 2026-08-21

Comprehensive audit of the Lungfish test suite: what it contains, where the hours go, what is redundant, and how to reorganize it into tiers so preview releases stop paying the full-suite cost.

## TL;DR

- The suite is **~14,200 test functions (~13,600 XCTest + ~600 swift-testing) across ~446K LOC in 17 SwiftPM targets** plus an Xcode-only XCUI target. That size is defensible for an app of this complexity; the problem is not coverage, it is that **everything runs serially in one process with no tiering between "smoke" and "everything."**
- **The single biggest lever is parallelism, not deletion.** No invocation anywhere passes `swift test --parallel`. All ~13,600 XCTest cases run serially; `LungfishAppTests` (4,300 tests) additionally pins 228 of its files to the main actor. Parallel per-class processes would attack both at once.
- **Roughly 18–22% of the suite is redundant or inert**: an 88K-LOC genotype test cluster duplicated across 5 targets, 671 assertions that grep source files for substrings instead of testing behavior, ~103 copy-pasted temp-dir helpers, and ~14 files whose tests never run on a clean checkout.
- **Network hygiene is already good — with one exception.** Every test that talks to NCBI/ENA/SRA is env-var-gated and skips offline. The one you noticed is worse than it looks: `testViewAccessionOnNCBIDoesNotCrashForMalformedAccession` calls the real `NSWorkspace.shared.open`, so it launches your actual default browser at the NCBI 404 page on every NaoMgs UI test run, asserts nothing, and has no guard.
- **You already own 80% of a tiering system.** `full-suite-gate.sh --filter`, `verify.sh --tier 1|2|3`, four de-facto CI tier regexes, drift-protection tests in `scripts/tests/`, and 17 per-module test targets. What's missing: named tiers for the Swift suite, per-test timing data (none exists anywhere), and a decision about what preview vs. stable releases must run.
- Best-practice answer to your question: **keep the full suite, stop running all of it all the time.** A monolithic *gate* for stable releases is correct; a monolithic *inner loop and preview gate* is not.

---

## 1. What the suite is

| Target | Files | Test funcs | LOC | Character |
|---|---|---|---|---|
| LungfishAppTests | 363 | ~4,330 | 124K | ViewModels + in-process AppKit; 564 `@MainActor` annotations |
| LungfishWorkflowTests | 222 | ~3,100 | 127K | Pipelines; includes 8 real-tool Conformance files |
| LungfishIOTests | 125 | ~2,650 | 56K | Parsers/readers; mostly pure |
| LungfishCLITests | 85 | ~1,080 | 36K | Includes real `lungfish-cli` process forks |
| LungfishCoreTests | 56 | ~1,400 | 23K | Pure + mocked services |
| LungfishGenotypeUITests | 32 | ~890 | 46K | One file is 25,955 LOC / 475 tests |
| LungfishIntegrationTests | 29 | ~280 | 11K | Cross-module + fixtures |
| 10 leaf-UI targets + Kit + AppWorkflow | ~110 | ~490 | ~30K | Small, healthy |
| LungfishXCUITests (Xcode-only) | 20 | 34 | 3.3K | **Not in Package.swift; never runs under `swift test`** |

Fixture data is small (6.4 MB total). Slowness is process-spawn-, sleep-, and serialization-driven, not data-driven.

## 2. Where the hours actually go

### 2a. The execution model is the root cause

Since the 2026-08-19 CI redesign, **no Swift test runs automatically on any push or PR** — the push gate is non-Swift checks only (~3 min, by design), and all Swift jobs are `workflow_dispatch`/release-gated. The entire Swift regression gate is the local, opt-in pre-push hook running an **unfiltered, serial `swift test`**. So "several hours" is one machine, one process, ~14K tests, no parallelism, plus real-tool conformance runs. There is no named tier between "zero Swift tests" and "all of them."

### 2b. Serialization

- **No `--parallel` anywhere** (Package.swift, scripts, CI — verified). `swift test` default runs XCTest cases serially in a single process. `--parallel` runs classes in separate `xctest` processes across cores — on an Apple Silicon machine this alone is plausibly a 4–8x wall-clock reduction for the CPU-bound majority.
- **`@MainActor` pinning**: 564 annotations across 228 files in LungfishAppTests serialize the largest target onto one queue. Per-class parallel processes each get their own main thread, so `--parallel` also mitigates this without code changes.
- Seven `--no-parallel` uses exist for the ProjectStorage suites — those stay serialized as their own invocation; everything else does not need to inherit that constraint.

### 2c. Wall-clock waste inside tests

- **254 sleep call sites** (150 in AppTests alone). Worst unconditional ceilings: 60s sleeps in `SavontClusteringPipelineTests.swift:825` and `MetagenomicsDatabaseInstallerTests.swift:716`; 2x30s in `ProjectStorageSheetViewModelTests`; 10s+5s in `AlignmentScientificActionCoordinatorTests`; 10s in `FASTACollectionViewerRoutingTests`. Several are cancellation tests meant to exit early, but they set the worst-case ceiling whenever cancellation regresses.
- **`FileSystemWatcherTests`**: unconditional 500ms "settle" sleep in 10 tests (~5s floor), 20s poll windows, and `remainsTrue{}` helpers that must burn their full window by construction. This is also the suite that flakes under full-suite concurrency on this machine (known-environmental since 2026-08-18) — an event-driven redesign would fix both cost and flake.
- **Process overhead**: `ToolAvailability.ProcessRunner.run` busy-polls at 50ms instead of using `waitUntilExit`/`terminationHandler` (34 call sites in Conformance); `CLIExitCodeProcessTests` forks the CLI binary 29 times and re-resolves the binary path via a computed property on every call.
- **Real-tool conformance** (8 files): spades/megahit with `timeout: 1800`, fastp/seqkit at `timeout: 120` x8, etc. Legitimately slow — these belong in a tier, not in the default run.
- **164 files create temp dirs in per-test `setUp`** (3,188 `createDirectory` calls suite-wide); `GenotypeResultViewportTests` alone has 163.

### 2d. No evidence base

There is **no per-test timing data anywhere** — no xunit output, no retained `.xcresult`, gate logs are gitignored. The only committed numbers are three build-phase baselines (full suite 458s → 608s across the module reorg). Every claim above about relative cost is structural inference; the first optimization step must be to start measuring.

## 3. Redundancy and obsolescence (~18–22% of the suite)

1. **The genotype/ONT cluster** — 88.4K LOC (~20% of the suite) across 5 targets; `ONTGenotypeResultBundle` exercised in 6 targets; near-verbatim `makeCall`/`makeResult` builder copies in IO/GenotypeUI/CLI/App/Workflow; 6 of the 10 largest test files. One shared fixture in `LungfishTestSupport` is the highest-leverage consolidation (~15–20K LOC recoverable).
2. **`GenotypeResultViewportTests.swift`** — 25,955 LOC, 475 tests, one class. A mechanical split (no coverage change) removes a serialization and merge-conflict bottleneck.
3. **Source-text assertions** — 671 `source.contains(...)` assertions across 223 files (512 in AppTests) that read `.swift` files as text and assert on spelling (e.g. asserting the literal string `.disabled(!viewModel.hasVariantCallableAlignmentTracks)` appears). They break on reformats and pass on broken behavior. Largest false-signal maintenance load in the suite; retire progressively, checking each has (or gets) a behavioral equivalent.
4. **Helper duplication** — shared `LungfishTestSupport` is 2.3K LOC imported by only 44 of ~1,000 files; 4.5K LOC of private per-target helpers duplicate it; Core, GenotypeUI, Kit, and all leaf-UI targets aren't even wired to it in Package.swift.
5. **CLI double coverage** — command-string construction asserted in LungfishCLITests, LungfishAppTests (48 files reference the CLI), and WorkflowTests. Consolidate into CLITests; AppTests should assert delegation.
6. **Tests that never run on a clean checkout** — ~14 files where skips ≥ tests (AppleContainerRuntime, BundleBrowserLoader, StoragePerf, PBAA, ImportFastqE2E, PrimerTrim fixtures...). Not wrong, but they inflate the sense of coverage; they belong in an explicit `live` tier.
7. **Stale-name corrections** (do NOT delete): `ZhangArtifactCanaryTests` is fully remediated (synthetic fixtures, no external volume); `VCFRobustnessTests` is now env-gated via `LUNGFISH_REAL_VCF_DIR`; `GenBankReaderTests.testReadKF015279` already `XCTSkip`s cleanly when the local `test-data/KF015279.gb` is absent. The old "9 known-environmental failures" green-bar rule is obsolete — those tests skip now.
8. **A real production bug surfaced by duplicate tests**: the F44–F46 formatter consolidation into `LungfishKit/Formatters.swift` never completed — 7 private `formatBytes` copies survive in LungfishApp + 1 in the CLI, with duplicate tests on both sides masking the drift. Fix the source, then drop the duplicate test.

## 4. Network and environment coupling

- **All genuine network tests are guarded** by four env vars (`LUNGFISH_RUN_LIVE_DATABASE_TESTS`, `LUNGFISH_RUN_LIVE_SRA_TESTS`, `LUNGFISH_RUN_PBAA_RUNTIME_SMOKE`, `LUNGFISH_LIVE_BRACKEN_*`). A default `swift test` makes no network requests from test code.
- **The one exception is the test you found** — `NaoMgsResultViewControllerSmokeTests.testViewAccessionOnNCBIDoesNotCrashForMalformedAccession` (line ~1179). It drives `contextViewAccessionOnNCBI`, whose production code calls `NSWorkspace.shared.open` (NaoMgsResultViewController.swift:2373), launching the real system browser at the NCBI 404 URL. The test asserts nothing (can only fail by crashing) and modern Foundation accepts the spaced URL, so its regression intent is void. The correct pattern already exists in-repo: TwelveS injects `onOpenURL:` and asserts on captured URLs. NaoMgsUI and NvdUI (`NvdResultViewController.swift:2076,2083`) need the same seam.
- **The mock seam (`HTTPClient` protocol) is well adopted** (~280 mocked service tests) with two gaps: **ENAService has zero mocked tests** (its 7 live tests exist only because the mock was never written), and `DatabaseBrowserMockHTTPClient` is used by 1 of ~60 tests while the rest construct live-wired ViewModels (currently safe — they never trigger a search — but one `await search()` from a live call).
- Of the 10 guarded NCBI tests, 6 lack the transient-error-to-skip wrapper, so live-enabled runs fail hard on NCBI hiccups; `SRASearchIntegrationTests` has the best-in-class pattern to copy.

## 5. Recommended target model

Keep the full suite as the **stable-release gate**. Stop running it for anything else. Five named tiers, defined once, enforced by the existing drift-test pattern in `scripts/tests/`:

| Tier | Contents | Runs when | Target time |
|---|---|---|---|
| **smoke** | Existing smoke regex + one representative suite per module | Every push (could return to CI), inner loop | < 5 min |
| **unit** | All targets except Conformance, Integration, CLI-fork, and storage suites — parallel | Pre-push hook default, preview releases | 10–20 min |
| **integration** | IntegrationTests + CLI E2E + `--no-parallel` storage suites | Preview releases, nightly | 15–30 min |
| **conformance** | The 8 real-tool Conformance files, `LUNGFISH_REQUIRE_TOOLS=1` | Stable releases, dependency sweeps (= today's tier 1) | 30–60 min |
| **live** | Everything env-gated: network, real bundles, perf, PBAA, XCUI | Manual, before stable release | as needed |

Mechanism: **per-target `--filter '^TargetName\.'` regexes wrapped in `full-suite-gate.sh --tier <name>`** — no tags needed, works today for XCTest and swift-testing alike. Do not mass-migrate to swift-testing for `.tags`; SwiftPM `--filter` can't select by tag anyway, and the 17-target split already is the taxonomy. Pin each tier's regex with a `scripts/tests/` assertion exactly as the tier-1/CI filters are pinned today.

Preview releases run smoke + unit + integration (~30–50 min, mostly parallel). Stable releases run everything including conformance + the live checklist — which is what the release process effectively demands anyway.

## 6. Action plan

### Phase 0 — mechanical wins, no coverage change (~1 day)

1. **Fix the browser-opening test**: add an `onOpenURL` injection seam to `NaoMgsResultViewController` (and `NvdResultViewController`), assert on the captured URL. Kills real browser launches and makes the test actually test something.
2. **Measure, then enable `--parallel`** in `full-suite-gate.sh` for everything except the known `--no-parallel` suites (run those as a second serial invocation). Add `--xunit-output` to the gate and stop discarding gate logs, so per-test timing accumulates from day one.
3. **`ProcessRunner`**: replace the 50ms busy-poll with `waitUntilExit`.
4. **Cache the CLI binary path** (`static let`) in `CLIExitCodeProcessTests` and the two private resolvers.
5. **Cap the worst sleeps**: the 60s/30s/10s unconditional ceilings become event-driven waits or short timeouts.

### Phase 1 — name the tiers (~2–3 days)

6. Add `--tier smoke|unit|integration|conformance|full` to `full-suite-gate.sh`; encode the regexes; add drift tests; point the pre-push hook at `unit`; document in the fast-iteration workflow doc which tier each event runs.
7. Decide XCUI's home: it currently runs never; give it an explicit slot in `live` (or wire `run-macos-xcui.sh` into the stable-release checklist).
8. Update the green-bar definition in one canonical place (the gate script), reflecting that the old 9 environmental failures now skip.

### Phase 2 — structural consolidation (incremental, weeks)

9. **Genotype fixture consolidation** into `LungfishTestSupport`; wire the missing targets to it; one shared temp-dir helper retires the ~103 private ones.
10. **Split `GenotypeResultViewportTests.swift`** into ~8 files by MARK-able concern.
11. **Retire source-text assertions** target-by-target, converting the ones that guard real behavior.
12. **Write the ENA mock** and convert its 7 live tests to mocked + 1 guarded live smoke; add the transient-skip wrapper to the 6 unwrapped NCBI tests.
13. **Fix `formatBytes` in production** (collapse the 7 App copies onto LungfishKit), then drop the duplicate test.
14. Longer-term: split `LungfishAppTests` (363 files) along the ViewModel / AppKit-view line so filtering also saves build time — the 2026-05-31 analysis's "test-speed problem = modularization problem" conclusion still holds; the leaf-module extraction did the sources, not the tests.

### Expected outcome

Without deleting a single behavioral assertion: preview-relevant runs drop from hours to tens of minutes (parallelism + tiering), the full serial gate remains available for stable releases, and Phase 2 removes ~55–65K LOC of duplicated test code over time. Every number here should be re-validated against the xunit timing data Phase 0 starts collecting.
