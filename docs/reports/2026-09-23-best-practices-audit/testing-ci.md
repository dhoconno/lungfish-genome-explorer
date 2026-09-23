# Test Suite Quality, Test Infrastructure and CI (TST)

Reviewer: principal QA / test architect. Date: 2026-09-23. HEAD `a1f439076` (Preview 2026.9.38).

## Scope

The Swift test suite (`Tests/`, 21 targets), its selection and gating machinery (`scripts/full-suite-gate.sh`, `scripts/test.py`, `config/test-catalog.json`, `scripts/release/gate_evidence.py`, `scripts/test-surface.sh`, `scripts/install-git-hooks.sh`, `config/release-contract.json`, `scripts/release/release.py`), the XCUITests, `.github/workflows/ci.yml`, and build-time health.

Owner decisions applied (binding on this report): GitHub Actions is paused on purpose and must stay paused. All automated gating must run **locally** on the maintainer's Mac: git hooks, the `full-suite-gate.sh` tiers, `release.py` gates, and optionally a local scheduled runner. This report proposes no hosted or self-hosted Actions job. The CI finding asks only for a clean disable.

## Method

What I ran. I was the only reviewer allowed to build. I ran one SwiftPM command at a time, always with `--skip-update`.

| Command | Result | Wall time |
|---|---|---|
| `swift build --build-tests --skip-update --package-path <repo>` (native engine, cold, empty `.build`) | Build complete, exit 0, 353 warning lines (251 unique) | 319 s total (244 s compile after package resolution) |
| `bash scripts/full-suite-gate.sh --tier unit --evidence-dir <scratch>/unit-gate` (the documented pre-push tier, swiftbuild engine, cold for that engine) | **GATE FAIL**, exit 1 | 1562 s total: about 5 min build and discovery, then 1289 s of tests, of which about 14 min was one hung test that I killed by hand (see TST-05) |
| `swift build --build-tests --skip-update --build-system swiftbuild …` (null incremental build) | Build complete | 9 s reported, 19 s wall |

Unit-tier counts from `gate.result.json`: XCTest selected 13,685, executed 13,618, skipped 67, **failed 115**, harness `completed: false`. Swift Testing selected 567, executed 567, **failed 2**. The gate also recorded `source changed during gate`, because other reviewers wrote untracked report files into `docs/reports/…` while it ran. That error is correct behaviour and does not affect the counts.

What I read or measured:
- The gate scripts, catalog, and release contract, end to end.
- `gh run list` for `ci.yml` (200 runs) and `gh run view`.
- The retained release-gate evidence in the primary checkout's `.build/gate-logs/` (283 directories).
- A stratified random sample of 60 test functions across 13 targets, each read by hand.
- A heuristic parse of all 15,583 test functions (name, body, assertion counts, sleeps, globals, skips, source reads).
- Line-count ratios per feature area, and grep inventories for the patterns cited below.

Limits:
- I did not run the integration, conformance, or full tiers, and I did not run the XCUITests. The XCUITests need an attended TCC grant.
- I did not measure code coverage.
- The failure root causes below are Traced from messages and source. I did not fix or re-run individual tests.
- The one hang was cut short by my `kill -9`, so its test is counted among the failures.
- Per the brief, I did not read the 2026-09-05 audit or plans.

## Executive summary

LGE has a large test suite, and much of it is real behavioural testing:
- 1,181 files, 473,640 lines (0.68 test lines per source line), 15,003 XCTest and 638 Swift Testing functions.
- Parsers, cancellation, atomic publication, provenance and malformed-input paths are all exercised with real temp files and fake processes.

The problem is not the tests. **Nothing runs them.** I reproduced this.

**The documented pre-push unit tier is red on HEAD.** It has 117 failures and one test that hangs indefinitely. Two changes in one commit caused most of them: `821ca701a` (2026-09-14, "Migrate to Swift Build and isolate Stable storage") moved the storage namespace and changed the build engine's resource layout.

Every release since then shipped anyway (2026.9.28 Stable through 2026.9.38 Preview):
- The release gate selects only 186 tests (about 1.4% of the suite).
- The pre-push hook is not installed in the primary checkout.
- The `ci.yml` workflow has been an invalid file on every push since the same commit.

Several of the failures are genuine signals the suite was built to raise, and they now go unheard:
- Production code calls `runModal` against policy.
- `.superpowers/` agent scratch is committed.
- README and menu drift.
- Manifest and registry drift.

The suite also carries real dead weight:
- About 300 tests grep production source text.
- About 200 ArgumentParser echo tests and 44 `testCommandName`/`testHelpTextIsNonEmpty` stubs.
- Tautological memberwise-init tests.
- 1,440 `testing*`/`*ForTesting` hooks compiled into shipping production code.
- 109K lines of tests for the Genotype/MHC area alone, tightly coupled to rendering internals.

The gate evidence machinery itself is excellent and fail-closed, and should be kept. What needs fixing is the policy around it:
1. Get the unit tier green.
2. Make a green unit tier at the release commit a precondition of `release.py`.
3. Install the hook automatically.
4. Add a local nightly full run.
5. Then prune.

## Preserve (do not "fix" these away)

- **`scripts/release/gate_evidence.py` fail-closed accounting.** It checks discovery against completion, and rejects missing or unexpected tests and empty selections. Retries are diagnostic only and never change the verdict. Swift Testing is checked through ABI-v0 events, and a failure is also inferred from the runner log. See [gate_evidence.py:208-221](scripts/release/gate_evidence.py:208), [gate_evidence.py:361-371](scripts/release/gate_evidence.py:361) and [gate_evidence.py:457-466](scripts/release/gate_evidence.py:457). This machinery caught the 117 failures correctly. A green verdict from it is trustworthy for the tests it selected.
- **`--require-tools` semantics.** Tool skips become failures in conformance runs ([full-suite-gate.sh:13-14](scripts/full-suite-gate.sh:13), [ToolVersionConformanceTests.swift:12-19](Tests/LungfishWorkflowTests/Conformance/ToolVersionConformanceTests.swift:12)).
- **Fake-process tests for cancellation and process-tree teardown.** Examples are [CLIMSAAlignmentRunnerTests.swift:157](Tests/LungfishAppTests/CLIMSAAlignmentRunnerTests.swift:157) and [GzipLineSourceBackpressureTests.swift:133](Tests/LungfishIOTests/GzipLineSourceBackpressureTests.swift:133). These are the right way to test subprocess orchestration without real tools.
- **Atomic-publication and failure-provenance tests.** Examples are [FullLengthONTMHCGenotypingPipelineTests.swift:2934](Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift:2934), [ClassificationPipelineProvenanceSourceTests.swift:839](Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineProvenanceSourceTests.swift:839) and [GenotypeManualHaplotypeEditorTests.swift:263](Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEditorTests.swift:263).
- **Real-format parser tests with inline fixtures.** Examples are [Primer3DesignPipelineTests.swift:79](Tests/LungfishWorkflowTests/Primer3DesignPipelineTests.swift:79), [GFF3ReaderTests.swift:76](Tests/LungfishIOTests/GFF3ReaderTests.swift:76) and [GenBankReaderTests.swift:68](Tests/LungfishIOTests/GenBankReaderTests.swift:68). Also keep the shared SARS-CoV-2 fixture set in `Tests/Fixtures/sarscov2` and the ivar parity fixtures.
- **Live-network tests are opt-in.** For example, [DatabaseServiceIntegrationTests.swift:160-161](Tests/LungfishCoreTests/Services/DatabaseServiceIntegrationTests.swift:160) is gated by an environment variable. Service tests otherwise use `MockHTTPClient`.
- **The serial quarantine list for parallel-unsafe suites**, with dated rationale ([full-suite-gate.sh:117-132](scripts/full-suite-gate.sh:117)). It is honest bookkeeping. Shrink it, but do not delete it blindly.
- **Null incremental build of about 9 s** and module-leaf isolation. Leaf test targets compile independently.

## Findings

| ID | Priority | Title | Confidence | Effort |
|---|---|---|---|---|
| TST-01 | P0 | Pre-push unit tier is red on HEAD: 117 failures plus 1 indefinite hang | Confirmed | M |
| TST-02 | P0 | No gate runs the broad suite: release selects 186 of about 14.2K tests, the hook is not installed, and 11 releases shipped over a red unit tier | Confirmed | S |
| TST-03 | P1 | Swift Build migration broke subpath `Bundle.module` fixtures, crashing tests with SIGTRAP | Confirmed | S |
| TST-04 | P1 | Stable-namespace change broke about 75 tests that hard-code `.lungfish` fake homes, and tests cannot inject an app identity | Confirmed (cause Traced) | M |
| TST-05 | P1 | No per-test or overall timeout: a cancellation test hung for 14+ min and stalls the gate forever | Confirmed | S |
| TST-06 | P1 | `ci.yml` has been an invalid workflow on every push since 2026-09-14 instead of being disabled cleanly | Confirmed | S |
| TST-07 | P2 | About 300 source-text-inspection tests, 591 assertions over production source strings | Traced | M |
| TST-08 | P2 | Low-value tests: tautologies, ArgumentParser echoes, constant re-assertions, vacuous conditionals (about 20% of the sample) | Traced | M |
| TST-09 | P2 | White-box over-testing: 1,440 test hooks shipped in production code, Genotype area 109K test lines | Traced | L |
| TST-10 | P2 | Flakiness sources: wall-clock budgets as tight as 0.1 s, global singletons and defaults, process-wide `setenv`, 27 quarantined suites | Traced | M |
| TST-11 | P2 | Silent skips: tool-gated app tests ignore `LUNGFISH_REQUIRE_TOOLS`, in-repo fixture misses skip, the conformance tier has no recent run | Traced | S |
| TST-12 | P2 | XCUITests (40) run nowhere automatically, `appSmokeRequired: false`, core scientific journeys uncovered | Traced | M |
| TST-13 | P3 | Build health: 251 unique warnings, including concurrency-isolation warnings in tests and use of deprecated cleanup APIs | Confirmed | S |
| TST-14 | P3 | Test effort is skewed toward release tooling and policy text over app behaviour | Traced | S |

---

### TST-01 (P0): Pre-push unit tier is red on HEAD: 117 failures plus 1 indefinite hang

**Evidence (Confirmed by running `scripts/full-suite-gate.sh --tier unit`):**
- XCTest had 115 failed tests across 58 classes, and Swift Testing had 2.
- One further test, `LungfishAppTests.CLIImportRunnerTests/testCancelTerminatesCLIProcessTree`, never finished (TST-05).

I grouped the failures by root cause, using the messages in `primary/runner.log`:

1. **About 75 tests: managed-storage namespace (TST-04).** Tests build fake homes under `.lungfish/conda/...`, but the test process now resolves `.lungfish-stable`. Examples:
   - [SRAServicePathTests.swift:23](Tests/LungfishCoreTests/SRAServicePathTests.swift:23) expected `.lungfish/conda/envs/sra-tools/bin/prefetch` but got `.lungfish-stable/...`.
   - `BuildDbCommandTests` failed with `managedSamtoolsUnavailable` in 10 tests.
   - `WorkflowEngineLaunchTests` fell back to `/Users/dho/miniforge3/bin/nextflow`. That result is machine-dependent.
   - Other classes failed on `toolNotFound("samtools"|"seqkit"|"cutadapt"|"fastp")`: `Minimap2ResultSidecarTests`, `ViralVariantCallingPipelineTests`, `OrientPipelineTests`, `TaxTriagePipelineProvenanceSourceTests`, `FASTQDerivativeServiceProvenanceTests`, `MetadataPresetStoreTests` ([FASTQSampleMetadataTests.swift:334](Tests/LungfishIOTests/FASTQSampleMetadataTests.swift:334)) and others.
2. **8 tests: resource layout under Swift Build (TST-03).** These are `PrimerSchemeResolverTests` (5 SIGTRAP crashes), `PrimerSchemesFolderTests` (1 crash) and `BAMPrimerTrimPipelineTests` (2 `XCTUnwrap` failures).
3. **About 12 tests: real drift that the suite correctly detects.**
   - `AppKitConcurrencyModalSafetyTests` found `runModal` in [ProjectLockResolutionDialog.swift:141](Sources/LungfishApp/App/ProjectLockResolutionDialog.swift:141) and `Primer3ResultsView.swift:154`.
   - `RepositoryHygieneTests` ([GUIRegressionTests.swift:1092](Tests/LungfishAppViewTests/GUIRegressionTests.swift:1092)) found `.superpowers/sdd/**` tracked in git. `git ls-files` confirms this.
   - `DocumentationAccuracyTests` found README drift.
   - `GUIRegressionTests` found two Tools-menu structure mismatches.
   - `WindowAppearanceTests` found `.foregroundStyle(.red)` in 3 views.
   - Manifest and registry drift appeared in `DependencyPlannerTests` (`primalscheme3` now preserves installs), `PackToolManifestConsistencyTests` and `PluginPackRegistryTests` (the `lge.5` wheel URL).
   - `ManualMetadataConsistencyTests`, `DocumentationFixtureThresholdTests` and `CondaPacksCommandTests` also failed.
4. **About 6 tests: cancellation and process timing.** These are `CLIImportRunnerTests` (hang), `CLIPrimerTrimRunnerTests` (a fake CLI deleted before launch: `status 127 … No such file`), `CLIEventRunnerCancellationTests`, `SRAServicePathTests.testDownloadFASTQCancellation…`, `MappingSummaryBuilderTests.testCancelling…` and two `PBAAClusteringPipelineTests` PID-file timeouts. Some of these are knock-on effects of the missing tools in group 1.
5. **About 10 other failures:**
   - Genotype Excel acceptance: a Python traceback at [GenotypeUnifiedExcelAcceptanceTests.swift:434](Tests/LungfishAppTests/GenotypeUnifiedExcelAcceptanceTests.swift:434).
   - `MainWindowBundleIndexTests`, `AnnotationDrawerSizingTests` (a persisted drawer height of 2482: state leaks from real defaults), `EsVirituResultViewControllerSmokeTests`, `SidebarBundleCapabilityTests`, `MappingViewportRoutingTests` and `DocumentTypeReferenceBundleTests`.
   - `AppleContainerRuntimeIntegrationTests.testContainerWithMount` (environmental: missing image digest).

**Impact:**
- The last full-strength regression signal is gone.
- Any new regression lands among 117 existing reds and cannot be told apart from them.
- Group 3 contains real policy and documentation defects in the shipped product. `runModal` in particular was already declared forbidden.
- For triage, all failures are listed in `<scratch>/unit-gate/gate.result.json`. Anyone can reproduce them with the same command.

**Recommendation.** Work in one ordered package (WP-1):
1. Fix TST-03 (mechanical).
2. Fix TST-04 by injecting identity (below). Do not blindly rewrite `.lungfish` to `.lungfish-stable` in tests, because that just re-couples them to the new default.
3. Triage group 3. Fix the product for `runModal` and palette. Untrack `.superpowers/` and add it to `.gitignore`. Update the README and menu expectations only after confirming the menu change was intended.
4. Quarantine `AppleContainerRuntimeIntegrationTests` behind an environment variable, or move it to conformance.
5. Re-run until the tier is green.

**Acceptance test:** `scripts/full-suite-gate.sh --tier unit` exits 0 on a clean tree at the fix commit, with 0 failures, `completed: true`, and no manual intervention. Run it twice to show stability.

**Effort:** M.

### TST-02 (P0): No gate runs the broad suite, and 11 releases shipped over a red unit tier

**Evidence:**
- The release contract gates both channels on `tier: "release"` only ([release-contract.json:62-74](config/release-contract.json:62)).
- The `release` profile's filter is the eight-class "quick" sentinel regex. It covers `BundleManifestTests`, `GenomicRegionTests`, `RuntimeResourceLocatorTests`, `SequenceTests`, three provenance classes and `ScientificCLIProvenanceCoverageTests` (`config/test-catalog.json`, profile `release`).
- `release.py` runs exactly those steps ([release.py:1603-1611](scripts/release/release.py:1603)).
- The retained evidence for the 2026.9.38 release (`.build/gate-logs/release-7rhsqo6p/swift-0/gate.result.json` in the primary checkout) shows **159 XCTest plus 27 Swift Testing executed**, in 34 s.
- The 2026.9.38 commit changed `GenotypeHaplotypeAnalysis.swift`, `GenotypeHaplotypeDefinitionEditor.swift` and others, and added tests in `GenotypeHaplotypeAnalyzerTests` and `GenotypeHaplotypeDefinitionEditorTests`. **None of those tests were selected by the gate that authorized the release** (`git show --stat a1f439076`).
- The primary checkout's hooks directory contains only `*.sample` files. **The pre-push hook that [install-git-hooks.sh](scripts/install-git-hooks.sh:1) describes is not installed**, and `scripts/setup-worktree.sh` does not install it either.
- In the primary checkout's 283 evidence directories, the newest non-release gate run is `gate-20260906-164908-…`, a custom filter of 206 tests. I found no unit, full or headless tier evidence there after the evidence schema landed. That is evidence of absence only for that checkout, since worktrees have their own `.build`.
- `appSmokeRequired: false` ([release-contract.json:85](config/release-contract.json:85)), so no launch smoke is required either.

**Impact:**
- TST-01's red tier was introduced on 2026-09-14 and went unnoticed through the releases for 2026.9.28 Stable, 9.29, 9.31, 9.33 to 9.38.
- A green release verdict certifies about 1.4% of the suite, and that 1.4% is weighted toward provenance rather than toward the code that changed.

**Recommendation (all local):**
- **Release precondition.** Change the release contract so `release.py` requires authorized gate evidence for `--tier unit` (the catalog `headless` profile is equivalent) **bound to the exact release commit**. Reuse evidence from the maintainer's last pre-push or nightly run when `source.commit` matches, so the release is not slowed. The evidence format already records `source.commit` and `clean`.
- **Stable releases.** Additionally require integration evidence and `tool-conformance --require-tools` evidence no older than N days on an ancestor commit.
- **Hook installation.** Install the hook automatically. Have `scripts/setup-worktree.sh` and a `release.py doctor` check call `install-git-hooks.sh`. Make `release.py` refuse to run if the hook is missing, unless `--no-hook-check` is given.
- **Faster pre-push.** Keep pre-push fast by running `--tier unit` in the background after push (`--bg`). Write the verdict to `.build/gate-logs/latest-unit.json` and show a red banner in the next `release.py`/`doctor` run. Alternatively, run a changed-module subset synchronously. See the pyramid section.
- **Local nightly.** Add a local nightly via launchd (`~/Library/LaunchAgents/…lungfish-nightly.plist`) that runs `full-suite-gate.sh --tier unit`, then `--tier integration`, then `--profile tool-conformance --require-tools` on `origin/main` in a dedicated worktree. It should record the verdict and send a macOS notification on red.

**Acceptance test:**
- `release.py package` on a commit without authorized unit evidence exits non-zero, with a message naming the missing tier.
- With evidence present for that commit, it proceeds without re-running.
- A fresh `setup-worktree.sh` leaves `.git/hooks/pre-push` installed.

**Effort:** S (contract and plumbing). Depends on TST-01 being green first.

### TST-03 (P1): Swift Build migration broke subpath `Bundle.module` fixtures (SIGTRAP crashes)

**Evidence:**
- [PrimerSchemeResolverTests.swift:109-114](Tests/LungfishWorkflowTests/Primers/PrimerSchemeResolverTests.swift:109) force-unwraps `Bundle.module.url(forResource: "primerschemes/valid-simple.lungfishprimers", withExtension: nil)!`.
- Under the gate's engine (`--build-system swiftbuild`, [swiftpm_build.py:12](scripts/release/swiftpm_build.py:12)), the resource lands at `LungfishGenomeBrowser_LungfishWorkflowTests.bundle/Contents/Resources/Resources/primerschemes/…`.
- The `.copy("Resources")` directory is nested inside a bundle with a real `Contents/Resources` directory, so the lookup returns nil. The native engine's flat bundle resolves the old path.
- The same pattern appears at [BAMPrimerTrimPipelineTests.swift:41](Tests/LungfishWorkflowTests/Primers/BAMPrimerTrimPipelineTests.swift:41), [PrimerSchemesFolderTests.swift:29](Tests/LungfishIOTests/Bundles/PrimerSchemesFolderTests.swift:29) and [PrimerSchemeBundleTests.swift:12](Tests/LungfishIOTests/Bundles/PrimerSchemeBundleTests.swift:12).
- Six processes died with `unexpected signal code 5`.

**Impact:**
- A crash in a parallel per-test process loses the test's diagnostics. In serial mode, it would abort every later test in the bundle.
- Tests silently depend on the build engine.

**Recommendation:**
- Add one helper in `LungfishTestSupport`, `fixtureURL(_ relativePath:, in bundle:)`. It should try `bundle.resourceURL/relativePath` and `bundle.resourceURL/Resources/relativePath`, and throw `XCTSkip` never. Throw a descriptive error instead.
- Replace every `Bundle.module.url(...)!` with the helper (29 call sites).
- Add a Swift Testing check that enumerates the expected fixture roots of each test bundle.

**Acceptance test:** all four classes pass under both `swift test` (native) and the gate's swiftbuild engine. `grep -rn 'Bundle.module.url(.*)!' Tests` is empty.

**Effort:** S.

### TST-04 (P1): Storage-namespace change broke about 75 tests, and tests cannot inject an app identity

**Evidence:**
- [AppIdentity.swift:105-106](Sources/LungfishCore/AppIdentity.swift:105) derives `.lungfish` / `.lungfish-stable` / `.lungfish-debug` from `releaseChannel`.
- `AppIdentity.current` is a process-wide `static let` resolved from Info.plist ([AppIdentity.swift:119-122](Sources/LungfishCore/AppIdentity.swift:119)).
- In a `swift test` process, it resolves to Stable. Tests written before `821ca701a` hard-code `.lungfish`. For example, [SRAServicePathTests.swift:12-23](Tests/LungfishCoreTests/SRAServicePathTests.swift:12) passes a `homeDirectory` but not an identity, so the helper still reads the global channel.
- `WorkflowEngineLaunchTests` then fell through to the developer's real `/Users/dho/miniforge3/bin/nextflow`. The tests reach outside the sandbox when the managed path misses.

**Impact:**
- About 65% of the red tier comes from this cause.
- Worse, the tests' outcome depends on the executable's channel metadata and on what happens to be on the developer's `PATH`, so they are not hermetic.

**Recommendation:**
- Thread an `AppIdentity` (or just `managedStorageDirectoryName`) parameter through the managed-path resolvers that already take `homeDirectory`. Candidates are `SRAService.managedExecutableURL`, `BuildDbCommand` samtools lookup, `WorkflowEngineLaunch`, `NativeToolRunner` and `MetadataPresetStore`.
- Default the parameter to `.current`.
- Have tests pass an explicit `.preview` identity, or build fake homes from `identity.managedStorageDirectoryName`.
- Make PATH fallback injectable, so tests can assert "no fallback" without touching the real PATH.

**Acceptance test:**
- The affected classes pass.
- A new parameterized test runs the resolver under `.debug`, `.preview` and `.stable` identities and asserts the matching directory for each.
- Temporarily prepending a directory containing a fake `nextflow` to PATH does not change the outcome of any unit test.

**Effort:** M.

### TST-05 (P1): No per-test or overall timeout, so a cancellation test hung for 14+ minutes

**Evidence:**
- Process `xctest -XCTest LungfishAppTests.CLIImportRunnerTests/testCancelTerminatesCLIProcessTree` had been running for 16 min at 16:09.
- Its fake `lungfish-cli` shell (pid 80029) and the TERM-ignoring grandchild (pid 80128) were both still alive. `runner.cancel()` had not terminated even the direct child.
- The test then blocks forever on `_ = await runTask.value` ([CLIImportRunnerTests.swift:416-486](Tests/LungfishAppTests/CLIImportRunnerTests.swift:416)).
- The gate launches `swift test` with no deadline. The only bounded waits are for teardown ([gate_evidence.py:117-132](scripts/release/gate_evidence.py:117)).
- A code comment records an earlier 54-minute hang ([GzipLineSourceBackpressureTests.swift:130-132](Tests/LungfishIOTests/GzipLineSourceBackpressureTests.swift:130)), so this is recurrent.
- The test also mutates process-global state with `setenv("LUNGFISH_CLI_PATH", …)` ([CLIImportRunnerTests.swift:431-432](Tests/LungfishAppTests/CLIImportRunnerTests.swift:431)).

**Impact:**
- An unattended pre-push or nightly run never returns, and a hung gate reads as "still running", not as "red".
- **It is Suspected, not proven, that `CLIImportRunner.cancel()` can fail to terminate its child under load.** That would be a real product defect: a user cancels an import and the tool keeps running. It needs a focused repro.

**Recommendation:**
- Set `executionTimeAllowance` in a shared XCTestCase base, or pass `--xctest-timeout`-style bounds through `swift test` where supported.
- Also add an overall wall-clock budget per tier in `gate_evidence.py` (unit: 30 min). Kill the process group and mark the run `intervention: timeout`.
- Replace `await runTask.value` with a bounded wait in all process-tree cancellation tests.
- Stop using `setenv` for `LUNGFISH_CLI_PATH`. Inject the CLI URL into `CLIImportRunner`.
- File a product investigation of `CLIImportRunner.cancel()`.

**Acceptance test:**
- A deliberately hanging test (a fixture test under a debug env flag) makes the gate fail within the budget, with a named timeout.
- `CLIImportRunnerTests` passes 50 consecutive times under `--parallel`.

**Effort:** S (gate budget), M (cancel investigation).

### TST-06 (P1): `ci.yml` is an invalid workflow on every push instead of being cleanly disabled

**Evidence:**
- `gh run list --workflow ci.yml` shows every push run since `96ccddd48` (2026-09-15T02:32Z) as `failure` in 0 s. `gh run view 35871686435` reports "This run likely failed because of a workflow file issue", with 0 jobs created.
- The last success was 2026-09-14T17:27Z.
- The breaking commit `821ca701a` added job-level `env: LUNGFISH_STORAGE_ROOT: ${{ runner.temp }}/…` ([ci.yml:144-145](.github/workflows/ci.yml:144)). The `runner` context is not available in `jobs.<id>.env`, so this is the likely validation error. It is Suspected as the exact cause, because I could not run actionlint.
- The same commit changed all `runs-on` values to the label `xcode-27` ([ci.yml:37](.github/workflows/ci.yml:37)).
- Even when it worked, the automatic `fast` job compiled exactly one production Swift file, [SequenceLengthStatistics.swift](Sources/LungfishCore/Models/SequenceLengthStatistics.swift), against seven assertions ([ci-swift-smoke.py:2](scripts/ci-swift-smoke.py:2), [ci-swift-smoke.py:11-19](scripts/ci-swift-smoke.py:11)). It never compiled the package.

**Impact:**
- Every push produces a red X, which trains everyone to ignore status signals.
- Actions minutes are still spent on validation.
- The history is misleading: an intentional pause looks exactly like breakage.

**Recommendation (owner decision: stay paused, local only):** Disable the workflow cleanly with `gh workflow disable ci.yml`, or reduce `on:` to `workflow_dispatch` only. Also delete or park the job bodies, so a later dispatch cannot fail confusingly. `scripts/ci-swift-smoke.py` and the `fast`-job Python checks can be moved into the local pre-push hook. They take seconds, and the manifest byte-stability and `Package.resolved` consistency checks are worth keeping locally. Remove `scripts/tests/test_ci_workflow.py` pins that assert the live workflow shape, or re-point them at the disabled state.

**Acceptance test:**
- A push to `main` creates no failed workflow run.
- `gh workflow list` shows CI as disabled, or the workflow has only `workflow_dispatch`.
- The pre-push hook runs the manifest and `Package.resolved` checks.

**Effort:** S.

### TST-07 (P2): About 300 source-text-inspection tests

**Evidence:**
- A heuristic parse found 299 test functions in 117 files that load production `.swift` (or script) text and assert with `.contains`/`range(of:)`.
- There are 591 `XCTAssertTrue/False(source….contains(…))` or `#expect(source.contains(...))` assertions.
- By target: LungfishAppTests 209, AppViewTests 16, WorkflowTests 12, AppWorkflowTests 12, GenotypeUITests 11 and the rest are small.
- The pattern is institutionalized. `LungfishTestSupport` ships `combinedMainSplitViewControllerSource()`, `combinedAppDelegateSource()`, `combinedSequenceViewerSource()` and `combinedAnnotationTableDrawerSource()`, used from 17 files.
- The helper's own header explains that when `MainSplitViewController.swift` was split for compile speed, tests had to be kept working by re-concatenating the files **in their original order**, so that range-slicing assertions still resolve ([MainSplitViewControllerSourceTestSupport.swift:1-12](Tests/Support/LungfishTestSupport/MainSplitViewControllerSourceTestSupport.swift:1)).

Examples:
- [ClassifierDisplayConcurrencyTests.swift:5-29](Tests/LungfishAppTests/ClassifierDisplayConcurrencyTests.swift:5) asserts the order of three literal source lines, and that a **code comment** string exists (`"Viewing no longer rewrites scientific bundle data automatically."`).
- [VariantCallingToolsMenuTests.swift:57-62](Tests/LungfishAppTests/VariantCallingToolsMenuTests.swift:57) asserts that `#selector(showBAMVariantCalling(_:))` appears in the source, not that the menu item routes.
- [GenotypeSampleDetailSheetTests.swift:138-148](Tests/LungfishGenotypeUITests/GenotypeSampleDetailSheetTests.swift:138) asserts the string `ViewThatFits(in: .horizontal)`.
- [ReleaseBuildConfigurationTests.swift:386](Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift:386) (`retiredStandaloneCutadaptBundlerIsRemoved`) and 29 other tombstone tests assert that retired names are absent.

**Impact:**
- These tests break on renames, reformatting and file splits while behaviour is unchanged, and they pass when the behaviour breaks but the string survives.
- They tax every refactor, and here they already dictated file-concatenation order.
- A subset are legitimate **policy lints**: no `runModal`, no hard-coded Homebrew or SwiftPM paths, palette colours, and no tracked agent scratch. As XCTests, they are expensive to run and easy to miss (TST-02).

**Recommendation:**
1. Move policy lints into one fast local script, `scripts/lint/source-policy.py`, run by the pre-push hook in about 1 s. Candidates:
   - `AppKitConcurrencyModalSafetyTests`
   - the "Production sources avoid…" tests in `ReleaseBuildConfigurationTests`
   - `WindowAppearanceTests.testSemanticDangerUI…`
   - `RepositoryHygieneTests`
   - the hard-coded-path checks
2. Delete tombstone tests older than one release.
3. Replace ordering and wiring tests with behavioural ones. Examples: drive the menu item and assert the dialog request is emitted, or open a NAO-MGS result on a read-only copy and assert `hits.sqlite` bytes are unchanged.
4. Delete the `combined*Source()` helpers once no test uses them.

**Acceptance test:**
- `grep -rlE 'combined\w*Source\(|repositoryRoot\(\).*Sources/' Tests` returns at most a documented allowlist.
- `scripts/lint/source-policy.py` fails on an injected `runModal` and passes on HEAD after the TST-01 fixes.

**Effort:** M (spread over time. Do the conversions opportunistically when touching an area).

### TST-08 (P2): Low-value tests (about 20% of a random sample)

**Evidence.** I hand-classified a stratified random sample of 60 tests (seed 20260923, proportional to target size):

| Class | Count | Examples |
|---|---|---|
| Behavioural unit (real logic, real temp files, fake processes) | 33 | Primer3 parser, GenBank streaming, Bracken stale output, atomic replacement, cancelled save |
| UI behavioural / layout (AppKit in-process) | 10 | TwelveS search filter, TaxTriage layout, genotype band geometry |
| Integration (real tool, skip-gated) or E2E | 2 | `FASTQOperationRoundTripTests` bbduk, XCUI SKESA |
| Mock-interaction (asserts recorded subcommands) | 2 | [ManagedMappingPipelineTests.swift:300](Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift:300), AI provider request shape |
| **Tautological / echo / constant** | 9 | see below |
| **Weak or vacuous assertions** | 3 | see below |
| Source-text inspection | 0 in sample (about 2% suite-wide, TST-07) | |

Low-value examples:
- [AIAssistantTests.swift:697](Tests/LungfishAppTests/AIAssistantTests.swift:697) (`testPreferredProviderPersists`) sets a property on `AppSettings.shared` and reads it back. It never reloads, and it mutates a global.
- [GUIRegressionTests.swift:463](Tests/LungfishAppViewTests/GUIRegressionTests.swift:463) builds a struct with `status: .ready` and asserts `.ready`.
- [BundlePipelineTests.swift:750](Tests/LungfishIntegrationTests/BundlePipelineTests.swift:750) and [TranslationToolTests.swift:170](Tests/LungfishAppTests/TranslationToolTests.swift:170) test memberwise init.
- `MappingResultViewControllerTests.testEmbeddedViewerDoesNotPublishGlobalViewportNotifications` reads a test-only flag.
- The ArgumentParser echo tests (four in the sample). Suite-wide, about 200 tests call `X.parse([...])` and only compare fields, with no `run`, `validate` or error path.
- There are 24 `testCommandName` and 20 `testHelpTextIsNonEmpty` copies, as in [CLIRegressionTests.swift:1770-1777](Tests/LungfishCLITests/CLIRegressionTests.swift:1770). There are also 9 `testRawValues` and 9 `testAllCases`.
- Vacuous assertions: [TaxaCollectionsDrawerTests.swift:209-229](Tests/LungfishAppTests/TaxaCollectionsDrawerTests.swift:209) nests every assertion inside `if let … if child.target.taxId == 11320`, so it passes with zero assertions if the ordering changes. [IORegressionTests.swift:167](Tests/LungfishIOTests/IORegressionTests.swift:167) only bounds the trim position to 0 to 10.
- 242 test functions contain no assertion call at all. Some rely on `throws` and are fine.

**Impact:** about 1,500 to 2,500 tests (my estimate from about 20% of the sample) add compile time, run time and maintenance cost without guarding behaviour. They also inflate the headline count, which masks the gaps in TST-12.

**Recommendation (pruning list, in order):**
- Delete every `testCommandName` and `testHelpTextIsNonEmpty`, and memberwise-init and enum `allCases`/`rawValues` tests that assert literals copied from the declaration. The exception is raw values that are persisted formats. Keep those as explicit Codable fixture tests.
- Collapse ArgumentParser echo tests into one table-driven test per command that covers **defaults, validation errors and the mapping to the config struct** that `run()` builds. That mapping is what breaks in practice.
- Rewrite conditional-assert tests to `XCTUnwrap` and hard assertions.
- Remove global-singleton "persists" tests, or make them reload from an isolated `UserDefaults(suiteName:)`.

**Acceptance test:**
- Test-function count drops by at least 800 with no drop in line coverage. Measure with `swift test --enable-code-coverage` before and after on the unit tier.
- `grep -c 'func testCommandName' -r Tests` returns 0.

**Effort:** M.

### TST-09 (P2): White-box over-testing and test hooks shipped in production

**Evidence:**
- 1,440 declarations named `testing*`, `test[A-Z]*` or `*ForTesting` live in 128 production files, unguarded by `#if DEBUG` (grep over `Sources/`).
- The largest carriers are `GenotypeResultViewController.swift` (287) and `GenotypeComparisonMatrixView.swift` (237). An example is [GenotypeComparisonMatrixView.swift:7890](Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:7890) (`testingManualHaplotypeBandColumnFrames` runs a geometry update as a side effect of a getter).

Line ratios by feature (tests to source):

| Area | Ratio |
|---|---|
| Genotype/MHC/Haplotype | 109,018 / 121,475 (0.90). **23% of all test code** |
| ProjectStorage | 16,744 / 11,017 (1.52) |
| Menu/Layout/Typography/Styling files | 14,605 / 9,409 (1.55) |
| FASTQ | 30,083 / 50,119 (0.60) |
| Kraken/Classification | 19,218 / 28,493 (0.67) |

- Single test files reach 5,000 to 6,600 lines ([FullLengthONTMHCGenotypingPipelineTests.swift](Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift) has 6,593 lines).
- Test names in [GenotypeResultViewportStylingAndMiSeqE2ETests.swift](Tests/LungfishGenotypeUITests/GenotypeResultViewportStylingAndMiSeqE2ETests.swift) (77 tests) assert rendering mechanics: `…RedrawsOnlyAffectedSelection`, `…AppliesLayoutExactlyOnce`, `…SkipsAnchorConsumerAndLayoutRebuilds`, `…UseOneCachedDerivedPass…`.

**Impact:**
- The Genotype viewport cannot be restructured without rewriting hundreds of tests that pin internal redraw counts.
- Shipping test hooks enlarges the production API and binary.
- Hooks with side effects can mask bugs, because tests pass through code paths that users never take.
- Effort is lopsided. Genotype and storage-cleanup tests are abundant while FASTQ and classification, which are core paths, are relatively thinner.

**Recommendation:**
- Gate new hooks behind `#if DEBUG`, or move them into `@_spi(Testing)` so they are visibly segregated. Add a lint (TST-07 script) that fails when a new unguarded `testing*` member appears. Use a baseline file to avoid a big-bang change.
- For Genotype, keep observable-outcome tests: what is persisted, what the user sees, and what is exported. Retire redraw-count tests to a small set of performance-budget tests, run in the nightly tier and not pre-push.
- Do not split large test files for their own sake. Split only when they are touched.

**Acceptance test:** the unguarded hook count is recorded and non-increasing (the lint baseline). The Genotype test-line count trends down over releases while mutation or coverage of `GenotypeHaplotypeAnalysis` and the annotation store stays equal or better.

**Effort:** L (incremental).

### TST-10 (P2): Flakiness sources

**Evidence:**
- **Wall-clock budgets.** There are 28 `XCTAssertLessThan(elapsed…)` assertions, several at 0.1 to 0.25 s ([CLIEventRunnerCancellationTests.swift:31](Tests/LungfishAppTests/CLIEventRunnerCancellationTests.swift:31), [DownloadCenterTests.swift:712](Tests/LungfishAppTests/DownloadCenterTests.swift:712), [ViralReconWorkflowExecutionServiceTests.swift:938](Tests/LungfishAppTests/ViralReconWorkflowExecutionServiceTests.swift:938)).
- **Sleeps.** There are 269 `Task.sleep` and 15 `Thread.sleep`/`usleep` calls.
- **Load sensitivity.** The gate itself documents load-sensitive failures and keeps **27 suites quarantined** out of the parallel unit tier ([full-suite-gate.sh:117-132](scripts/full-suite-gate.sh:117)). The listed causes are shared `UserDefaults`, FSEvents, window-server layout and a fake-process three-second deadline.
- **Globals.** There are 163 `AppSettings.shared` and 103 `UserDefaults.standard` references in tests. [MSACanvasChromeVisibilityTests.swift:23-34](Tests/LungfishAppTests/MSACanvasChromeVisibilityTests.swift:23) mutates `UserDefaults.standard`. `AnnotationDrawerSizingTests` failed with a persisted height of 2482 (TST-01, group 5).
- **OperationCenter.** There are 135 `OperationCenter.shared` uses in 20 files. Most key by operation ID, which is fine. [AlignmentScientificActionCoordinatorTests.swift:406-440](Tests/LungfishAppViewTests/AlignmentScientificActionCoordinatorTests.swift:406) compares the global item-ID set before and after, which is fragile when an earlier test's async operation finishes late. `cancelAll()` in [MappingResultViewControllerTests.swift:29](Tests/LungfishAppViewTests/MappingResultViewControllerTests.swift:29) cancels anything in flight.
- **Environment.** Process-wide `setenv` appears in CLI runner tests (TST-05).
- **Temp directories.** Fixed temp filenames appear in [GenomeDownloadViewModelTests.swift:143](Tests/LungfishAppTests/GenomeDownloadViewModelTests.swift:143) and 15 other sites. Only 20 of 619 temp-using files use the `TestTempDirectory` helper.
- **Parallel mode.** It spawns **one xctest process per test** (13,685 processes in my run). That is safe for isolation but slow, and it hides order dependence rather than exposing it.

**Impact:** intermittent reds that erode trust in the gate, and the quarantine list grows instead of shrinking.

**Recommendation:**
- Replace elapsed-time assertions with event ordering. For example, assert that `cancel()` returns before a "tree-walk started" signal fires, using an injected clock or latch.
- Isolate defaults with a mandatory `AppSettings.isolateForTesting` in a shared base class. The API already exists ([GenotypeResultViewportSelectionAndComparisonTests.swift:438](Tests/LungfishGenotypeUITests/GenotypeResultViewportSelectionAndComparisonTests.swift:438)).
- Give `OperationCenter` an injectable instance for tests.
- Make `TestTempDirectory` the only way to get a temp dir, and add a lint.
- Each fix removes one entry from the quarantine list.

**Acceptance test:**
- The quarantine list is under 10 entries.
- `--tier unit` passes 5 consecutive runs on an idle machine and 1 run with a CPU stress process (`yes > /dev/null` ×8) in parallel.

**Effort:** M.

### TST-11 (P2): Silent skips

**Evidence:**
- App-level helpers skip unconditionally when a managed tool is missing, for example [FASTQBundleMergeServiceTests.swift:12-16](Tests/LungfishAppTests/FASTQBundleMergeServiceTests.swift:12) and [FASTQProjectSimulationTests.swift:68-74](Tests/LungfishAppTests/FASTQProjectSimulationTests.swift:68). These do not consult `LUNGFISH_REQUIRE_TOOLS`, unlike the conformance suites.
- In-repo fixture misses skip instead of failing: `throw XCTSkip("Fixtures not found")` / `"Test fixtures not found"` appears 18 times, for example [ImportFastqE2ETests.swift:63](Tests/LungfishCLITests/ImportFastqE2ETests.swift:63) and [RecipeIntegrationTests.swift:143](Tests/LungfishWorkflowTests/Recipes/RecipeIntegrationTests.swift:143).
- The unit run skipped 67 tests.
- I found no local `tool-conformance` evidence in the primary checkout, and its only automated home was the now-broken dispatch job.

**Impact:**
- A deleted fixture or a broken tool environment turns red into grey, and the gate stays green, because skips never fail outside `--require-tools` ([full-suite-gate.sh:31-32](scripts/full-suite-gate.sh:31)).
- Real-tool scientific behaviour (reads to variants, classification, MAFFT) is not verified by anything running today.

**Recommendation:**
- Route every tool skip through one `requireManagedTool` in `LungfishTestSupport` that honours `LUNGFISH_REQUIRE_TOOLS`.
- Make in-repo fixture lookups fail, not skip.
- Have the gate print a skip summary grouped by reason, and fail the unit tier if skips exceed a committed baseline (for example 70).
- Run `tool-conformance --require-tools` in the local nightly (TST-02).

**Acceptance test:**
- Removing `Tests/Fixtures/sarscov2/` makes the unit tier fail, not skip.
- Running the nightly with an empty conda root fails with named missing tools.

**Effort:** S.

### TST-12 (P2): XCUITests run nowhere, and core journeys are uncovered

**Evidence:**
- There are 40 XCUI tests in `Tests/LungfishXCUITests`, driven through Xcode. They are not SwiftPM targets.
- [run-macos-xcui.sh:1-16](scripts/testing/run-macos-xcui.sh:1) declares itself an attended diagnostic, because of TCC re-prompts.
- It points to `build/xcui-triage-report.md` for dispositions, and that file does not exist in the tree.
- The release contract lists 5 app-smoke XCUI tests but sets `appSmokeRequired: false` ([release-contract.json:76-85](config/release-contract.json:76)).
- Covered journeys:
  - project lifecycle (5)
  - bundle browser (2)
  - database search UI (6)
  - mapping deterministic runs (7)
  - assembly dialogs and deterministic runs (11)
  - Viral Recon (2)
  - primer trim and variant auto-confirm (3)
  - navigation and toolbar (4)
- **Not covered:**
  - FASTQ import to a result
  - Kraken2/EsViritu/TaxTriage result opening and read extraction
  - VCF import and variant inspection
  - MHC genotyping review, override and save, then Excel export. This is the most actively developed feature, with releases 2026.9.36 to 9.38.
  - 12S results
  - MSA/tree export
  - Sparkle update prompt

**Impact:** the in-process AppKit tests are extensive, but nothing verifies that a user can complete a real workflow in the shipped app. Several 2026.9.x regressions were drawing and chrome issues, per the comment in [MSACanvasChromeVisibilityTests.swift:10-16](Tests/LungfishAppTests/MSACanvasChromeVisibilityTests.swift:10), which only real rendering catches.

**Recommendation (local, attended, cheap):**
- Make the 5 release-candidate XCUI smoke tests **required for Stable** and optional for Preview. They run on the maintainer's Mac during `release.py`, which is already attended.
- Add 3 journeys using the existing robot and `deterministic` backend pattern:
  - genotype result: open, override one call, save, reopen, and check the value persists
  - classification result: open, then extract reads, and check an `Extractions/` bundle exists
  - VCF import: open the variant table and filter
- Delete or repair XCUI tests that are not in the smoke list. A test nobody runs rots.
- Commit the triage disposition into `docs/`, not `build/`.

**Acceptance test:** `release.py` for Stable refuses without XCUI smoke evidence for the candidate. The three new journeys pass under `scripts/testing/run-macos-xcui.sh --smoke`.

**Effort:** M.

### TST-13 (P3): Build health

**Evidence (cold native build log):**
- The cold `--build-tests` build took 244 s of compilation (319 s including resolution) on this M-series Mac. The swiftbuild engine's cold build plus test discovery took about 5 min. A null incremental build took 9 s.
- There are 251 unique warnings: 40 in `Sources/` and 117 in `Tests/`.
- Concurrency-isolation warnings (about 70) sit mostly in tests. `@MainActor` test classes override nonisolated `setUpWithError`, as in [MSACanvasChromeVisibilityTests.swift:23-34](Tests/LungfishAppTests/MSACanvasChromeVisibilityTests.swift:23). Swift 6 downgrades these to warnings only because XCTest is `@preconcurrency`, and the same code in production would be an error.
- In Sources, there is a real isolation warning in [GenotypeKnownAlleleDetailView.swift:512](Sources/LungfishGenotypeUI/GenotypeKnownAlleleDetailView.swift:512) (a main-actor property mutated from a nonisolated context).
- There are 48 "result unused" warnings, including `run(resultType:body:)` in `AppDelegate+Classification.swift`, and 3 unobserved throwing `Task`s in `DatabaseBrowserViewController.swift:2631`/`2960`.
- Tests still call deprecated cleanup APIs ("Use ProjectStorageAutomaticCleanupService…"), 16 warnings.

**Impact:** real concurrency issues and dropped errors hide in the noise. The concurrency and product-code warnings overlap other reviewers' areas and are noted here only as build-health signals.

**Recommendation:**
- Get `Sources/` to zero warnings and enforce it with `-warnings-as-errors` for production targets in the local gate build step.
- Convert `@MainActor` test classes to `override func setUp() async throws` with `@MainActor` bodies, or move them to Swift Testing `@MainActor` suites.
- Delete or migrate tests of deprecated storage APIs.

**Acceptance test:** `swift build` on the production products emits 0 warnings, and the test-target warning count is at or below a committed baseline.

**Effort:** S (Sources), M (tests).

### TST-14 (P3): Test effort skews toward release tooling and policy text

**Evidence:**
- `scripts/tests/` holds 49 Python test modules (22,791 lines) that test about 10,400 lines of release scripts.
- The CI fast job and the release gate always run the release-contract Python tests ([release-contract.json:54-61](config/release-contract.json:54)), while app tests are not required (TST-02).
- `ReleaseBuildConfigurationTests` puts about 40 build-script string checks inside the app test target ([ReleaseBuildConfigurationTests.swift:9-862](Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift:9)).

**Impact:** a solo maintainer's limited gate time is spent certifying the release machinery more strongly than the science.

**Recommendation:** keep the Python contract tests, since they are fast. Move the `ReleaseBuildConfigurationTests` script greps out of the Swift app target into the Python suite or the lint script. Rebalance the release gate as in TST-02.

**Acceptance test:** `LungfishAppTests` contains no test that reads files under `scripts/` or `*.xcodeproj`.

**Effort:** S.

---

## Missing high-value tests (add these, in order)

1. **Identity-parameterized storage resolution.** For each of Debug, Preview and Stable, every managed-tool resolver should return the namespaced path, and none should fall back to PATH (TST-04). This would have caught the regression that caused 65% of today's reds.
2. **Fixture-resolvability test per test bundle**, run under both build engines (TST-03).
3. **Parser robustness (property or fuzz) tests** for VCF, GFF3, GTF, BED, FASTQ, GenBank, Kraken2 report and Bracken. I found no fuzz or property-based tests (grep for fuzz, randomized or seeded-generator patterns hits only UI allocators and BLAST). Use a seeded generator of truncations, random byte flips and CRLF or no-trailing-newline variants. Assert "throws a typed error or returns a valid model, never crashes or hangs". Run 200 cases per format in the unit tier and 10,000 in the nightly.
4. **Scientific golden tests that run without conda.** The reads-to-variants and classification paths are verified only by conformance suites that need real tools, and those run nowhere today. Add committed golden outputs (VCF, Kraken report, BAM idxstats) for the `sarscov2` fixture and compare parsers and post-processing against them in the unit tier. Keep the real-tool run in the nightly.
5. **Cancellation contract test for every CLI-backed runner** (`CLIImportRunner`, `CLIPrimerTrimRunner`, `CLIMSAAlignmentRunner`, viral recon). One shared, parameterized, **bounded** harness asserts that the whole process tree is gone within 2 s of `cancel()` (TST-05).
6. **Three XCUI journeys**: genotype override and persistence, classification extraction, and VCF open and filter (TST-12).
7. **Bundle backward-compatibility tests.** Check in one bundle per kind created by an old release (for example 2026.8.x) and assert it opens and its manifest migrates. Some legacy tests exist (for example [MHCReferenceBundleViewportTests.swift:88](Tests/LungfishAppTests/MHCReferenceBundleViewportTests.swift:88)). Make it systematic, one per bundle kind.

## Right-sized test pyramid for LGE (solo maintainer, local only)

| Layer | What | Target size | Where it runs | Budget |
|---|---|---|---|---|
| Lint | source-policy script (runModal, hard-coded paths, palette, tracked scratch, unguarded test hooks), manifest byte-stability, `Package.resolved` consistency, shell `bash -n` | about 20 rules | pre-push (sync) | under 5 s |
| Unit (headless) | Core, IO, Workflow, CLI behaviour with fakes and inline fixtures, plus golden parser tests | about 8K tests after pruning | pre-push (background `--bg`, verdict file) and release precondition | under 8 min |
| In-process UI | AppKit/SwiftUI view-model and observable-outcome tests, no redraw counts | about 2K tests | same run as unit | included |
| Integration | `LungfishIntegrationTests`, CLI process-fork suites, storage suites, quarantined serial suites | about 1K | local nightly (launchd) | under 25 min |
| Conformance | real tools, `--require-tools` | as today | local nightly, Stable release precondition (at most 7 days old) | under 60 min |
| XCUI | 5 smoke plus 3 journeys | 8 | attended, at Stable release and weekly | under 10 min |

Rationale:
- The unit tier already fits the pre-push budget, at about 7.5 min of tests without the hang.
- The weakness is policy, not speed. The table therefore adds only two things: a release precondition, and a nightly that the maintainer does not have to remember.

## Local gating plan (replaces hosted CI)

1. **Pre-push hook, installed automatically** by `setup-worktree.sh` and checked by `release.py doctor`:
   - run the lint layer synchronously
   - start `full-suite-gate.sh --tier unit --bg`
   - write `.build/gate-logs/latest-unit.json` keyed by commit
   - honour `--no-verify`
2. **Local nightly** (`launchd` agent, 02:00): in a dedicated worktree at `origin/main`, run unit, integration and `tool-conformance --require-tools`. Write `~/Library/Logs/Lungfish/nightly-<sha>.json`, send a macOS notification on red, and apply a gate budget (TST-05) so a hang cannot silently stall it.
3. **`release.py` preconditions:**
   - Preview requires authorized unit evidence for the exact commit. It reuses the pre-push or nightly evidence, and runs the unit tier itself if none exists.
   - Stable additionally requires integration and conformance evidence at most 7 days old on an ancestor, plus XCUI smoke.
4. **`ci.yml`:** disable cleanly (TST-06).

## Proposed work packages

**WP-1: Restore a green unit tier.** Covers TST-01, TST-03, TST-04 and the group 3 drift. Must land first.
- Files: `Tests/Support/LungfishTestSupport/` (fixture helper), the 29 `Bundle.module` call sites, the managed-path resolvers in `LungfishCore`/`LungfishWorkflow`/`LungfishCLI` (identity parameter) and their tests.
- Product fixes: `ProjectLockResolutionDialog.swift`, `Primer3ResultsView.swift` (`runModal`), and 3 palette sites.
- Repo hygiene: `.gitignore` plus `git rm --cached -r .superpowers`, and README and menu expectations after confirming intent.
- Risk: medium. The identity parameter touches many resolvers, and each must default to `.current` so behaviour is unchanged.

**WP-2: Make the gate bounded and non-hermetic-proof.** Covers TST-05 and part of TST-10.
- Files: `scripts/release/gate_evidence.py` (tier wall-clock budget, process-group kill), a shared XCTestCase base with `executionTimeAllowance`, the `CLIImportRunner`/`CLIPrimerTrimRunner` tests (inject the CLI URL, bounded waits), and a product investigation of `CLIImportRunner.cancel()`.
- Risk: low for the gate. The cancel investigation may uncover a product defect.

**WP-3: Local gating policy.** Covers TST-02, TST-06 and TST-11. Depends on WP-1.
- Files: `config/release-contract.json`, `scripts/release/release.py` (evidence reuse by commit), `scripts/install-git-hooks.sh`, `scripts/setup-worktree.sh`, a new launchd plist template under `scripts/`, `.github/workflows/ci.yml` (dispatch-only or disabled), the skip-baseline check in `gate_evidence.py`, and a unified `requireManagedTool`.
- Risk: low. It slows a release only when evidence is missing.

**WP-4: Lint extraction and pruning.** Covers TST-07, TST-08 and TST-14. Can run in parallel with WP-5 after WP-1.
- Files: new `scripts/lint/source-policy.py`. Delete the `combined*Source` helpers, tombstone tests, `testCommandName`/`testHelpTextIsNonEmpty`, and memberwise tests. Build table-driven CLI parse tests.
- Risk: low. Measure coverage before and after to prove nothing behavioural was lost.

**WP-5: Missing high-value tests.** Items 3 to 7 of the list above, plus the XCUI journeys (TST-12). The goldens and fuzzing need WP-1. The XCUI work is independent.
- Risk: low.

**WP-6: Hook hygiene and flake reduction.** Covers TST-09, the rest of TST-10, and TST-13.
- Incremental: an `@_spi(Testing)` or `#if DEBUG` baseline lint, defaults and OperationCenter isolation, shrinking the quarantine list, and warnings to zero in Sources.
- Risk: medium in the Genotype area because of test coupling, so do it opportunistically.

**Do not fix / accept:**
- **Per-test process parallelism** (13,685 processes). It is slower than per-class, but it gives the isolation the suite currently depends on. Revisit only after WP-6 shrinks the quarantine list.
- **Swift Testing migration** as a goal in itself. Mixed XCTest and Swift Testing is fine, and a mass port is churn.
- **Large test files.** Size alone is not a defect. Split only when edited.
- **`AppleContainerRuntimeIntegrationTests.testContainerWithMount`.** It is environmental (a missing image digest). Gate it behind an environment variable rather than chase it.
- **The ceremonial compile-error control in `ci-swift-smoke.py`.** Do not port it to the local hook. The real local build replaces it.
