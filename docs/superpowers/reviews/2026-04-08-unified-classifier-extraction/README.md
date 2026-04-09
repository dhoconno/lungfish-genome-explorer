# Phase Review Reports — Unified Classifier Extraction

This directory holds the adversarial review reports and simplification notes
produced by the four-gate review architecture defined in the implementation plan
at `docs/superpowers/plans/2026-04-08-unified-classifier-extraction.md`.

Each phase produces:

- `phase-N-review-1.md` — First adversarial review (independent, pre-simplification)
- `phase-N-review-2.md` — Second adversarial review (independent, post-simplification)

Phase 0 has no review (it is pre-flight only). Phases 1–7 each produce both files.
Phase 8 is final validation and may produce a single `phase-8-validation.md` report.

Spec: `docs/superpowers/specs/2026-04-08-unified-classifier-extraction-design.md`

## Baseline (Phase 0, 2026-04-09)

Recorded after Phase 0 fixed 4 stale "drift" tests (3 `allCases` count
expectations and 1 URL allowlist) that were unrelated to this work.

- **XCTest:** 6277 tests, 25 skipped, 4 unique failing test methods (counted
  as 7 assertion errors by XCTest because two methods produce multiple errors).
- **swift-testing:** 189 tests in 36 suites, all passing.
- **Build:** clean (only pre-existing warnings in plugins and unrelated tests).

The 4 unique floor failures every Phase Gate 4 must respect (i.e. they may
remain failing but no NEW failures may be introduced):

1. `LungfishAppTests.FASTQProjectSimulationTests.testSimulatedProjectVirtualOperationsCreateConsistentChildBundles`
   — pre-existing relative-path bug in virtual FASTQ child bundles.
2. `LungfishWorkflowTests.NativeToolRunnerTests.testValidateToolsInstallation`
   — environmental: `deacon` is conda-installed and not present in the
   developer's tools directory; passes in CI.
3. `LungfishIOTests.TaxonNodeRegressionTests.testEquatable`
   — pre-existing TaxonNode equality regression (clade/direct counts not
   distinguishing).
4. `LungfishIOTests.TaxonNodeRegressionTests.testHashable`
   — same root cause as `testEquatable`.

Additionally, four NCBI/SRA network-dependent tests in
`LungfishCoreTests.DatabaseServiceIntegrationTests` are flaky and may flicker
red across runs (HTTP 500 / connection failures). They are documented in
MEMORY.md and are NOT counted as the floor — Phase Gate 4 ignores their state.
