# Tests

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named variable.

## Layout

Each Sources target has a test target named `<Target>Tests` in Tests/<Target>Tests, with a few differences. LungfishApp has three (LungfishAppTests, LungfishAppViewTests, LungfishAppWorkflowTests). The two executables have none. LungfishIntegrationTests spans modules. Shared helpers are the `LungfishTestSupport` library in Tests/Support/LungfishTestSupport, which depends on Core, IO and Workflow and must not depend on ViewInspector. Shared data is in Tests/Fixtures (the SARS-CoV-2 set is described in Tests/Fixtures/README.md and wrapped by Tests/LungfishIntegrationTests/TestFixtures.swift). Tests/LungfishXCUITests runs only from Lungfish.xcodeproj, never under `swift test`.

## Running tests

Run one target with `swift test --skip-update --filter <Target>Tests`, or one suite with `--filter <Target>Tests.<SuiteName>`. From a worktree add `--package-path <worktree>` since `swift` has no `-C`. Only one SwiftPM process may use a checkout's .build at a time (memory file reference_swiftpm_tooling_gotchas.md).

The gate is `bash scripts/full-suite-gate.sh --tier unit --quiet`, run from the primary checkout only, never two at once. The pre-push hook runs it (scripts/install-git-hooks.sh). A run is green only when the gate exits 0.

## Tiers in scripts/full-suite-gate.sh

| Tier | What it selects | Defined at |
|---|---|---|
| smoke | Provenance and core-model spot checks | `SMOKE_FILTER`, line 129 |
| unit | Everything except integration and conformance, always with `--parallel` (one xctest process per class) | `unit)` case, line 184 |
| integration | LungfishIntegrationTests, CLI process-fork suites, ProjectStorage suites and PARALLEL_HAZARD_SUITES, run serially | `INTEGRATION_FILTER`, line 175 |
| conformance | Real-tool suites. Add `--require-tools` to fail on any skip | `CONFORMANCE_FILTER`, line 130 |
| full | The whole suite, serially | default with no `--tier` |

scripts/tests/test_full_suite_gate_tiers.py pins these regexes, so change them together.

## The PARALLEL_HAZARD rule

`PARALLEL_HAZARD_SUITES` (line 151) lists suites that fail under per-class parallel processes but pass serially, because they share state across processes (UserDefaults, FSEvents delivery, window-server layout, fixed fixture paths, tight readiness deadlines). They leave the parallel unit tier and run serially in the integration tier, with every case still executed. A suite earns its way back by fixing its isolation (per-process defaults suite names, `TestTempDirectory`, a deadline instead of a fixed budget), then its name is removed from the list with a dated comment, as ClassificationPipelineProvenanceSourceTests was on 2026-09-29. Add a suite only with serial-pass evidence. Phase 0 changes neither the tiers nor this list.

## Rules for new tests

- Wait with `waitUntil` from Tests/Support/LungfishTestSupport/XCTestAsyncAssertions.swift (line 44). Never assert after a fixed number of yields or a sub-second sleep (memory file feedback_test_waits_and_gate_time.md).
- Use `TestTempDirectory` (Tests/Support/LungfishTestSupport/TestTempDirectory.swift line 13) for scratch files.
- Do not add assertions that read Swift source text with `.contains("...")`. 94 files already hold 658 of them and a ratchet will freeze the count (REVIEW.md R11).
- Put a test in the target of the module it tests. Tests/LungfishAppTests holds 515 files, many for other modules (R11).
- Inject URL openers and presenters, or a test can open the real browser or block on a modal (memory file project_test_suite_review.md).

## Known traps

| Trap | Evidence |
|---|---|
| A serial run with a large `--filter` or `--skip` dies with "Argument list too long" | memory file reference_swiftpm_tooling_gotchas.md, comment in the `unit)` case of full-suite-gate.sh |
| Under heavy load an xctest process can sit idle mid-suite. Kill it and rerun the batch in smaller pieces | memory file project_test_baseline.md |
| After adding a stored property to a public struct, a stale test object can crash in `outlined init with copy` | memory file project_test_baseline.md |
| FileSystemWatcherTests can fail in the full swift-testing phase on one machine while passing alone | memory file project_test_baseline.md |
| GenBankReaderTests.testReadKF015279 skips unless the untracked test-data/KF015279.gb exists | memory file MEMORY.md (Environment section) |
