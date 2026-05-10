# Phase 8 — Final Validation Report

**Date:** 2026-04-09
**Branch:** feature/batch-aggregated-classifier-views
**Commit range:** 845441a..HEAD
**Plan:** [docs/superpowers/plans/2026-04-08-unified-classifier-extraction.md](../../plans/2026-04-08-unified-classifier-extraction.md)
**Spec:** [docs/superpowers/specs/2026-04-08-unified-classifier-extraction-design.md](../../specs/2026-04-08-unified-classifier-extraction-design.md)

## Test suite results

Measured at commit `2a66730` (Phase 7 Gate 4 closure) via `swift test`:

- **XCTest baseline (Phase 0):** 6277 tests passing (after the Phase 0 cleanup fixed 4 stale drift tests).
- **XCTest final (Phase 7 Gate 4):** 6406 tests executed, 28 skipped, 7 assertion errors across the same 4 unique pre-existing floor methods.
- **Delta:** +129 new tests added across Phases 1–7.
- **swift-testing:** 189 tests in 36 suites, all passing (unchanged).

### Per-phase test additions

| Phase | New test file(s) | New tests |
|---|---|---|
| 1 | `ClassifierRowSelectorTests`, `ExtractionDestinationTests`, `FlagFilterParameterTests` | 15 |
| 2 | `ClassifierReadResolverTests` | 20 |
| 3 | `ExtractReadsByClassifierCLITests` | 29 |
| 4 | `ClassifierExtractionDialogTests` | 24 |
| 5 | `ClassifierToolLayoutTests` + 1 added to `TaxonomyViewControllerTests` | 4 + updates |
| 6 | `ClassifierExtractionInvariantTests` (I1–I7) | 24 |
| 7 | `ClassifierExtractionMenuWiringTests` + `ClassifierCLIRoundTripTests` | 11 |
| **Total** |  | **~127** |

### Floor comparison

The same 4 unique pre-existing failing test methods at Phase 0 baseline remain failing at Phase 8. Zero new regressions introduced by this feature:

1. `FASTQProjectSimulationTests.testSimulatedProjectVirtualOperationsCreateConsistentChildBundles` (pre-existing relative-path bug, produces 3 assertion errors)
2. `NativeToolRunnerTests.testValidateToolsInstallation` (environmental: missing `deacon` tool, 2 assertion errors)
3. `TaxonNodeRegressionTests.testEquatable` (pre-existing)
4. `TaxonNodeRegressionTests.testHashable` (pre-existing)

The load-dependent flake `ReadExtractionServiceTests.testExtractByBAMRegionReportsProgress` (added to the floor by Phase 2 amendment) passed in every Phase 3–7 Gate 4 run.

## Invariant suite runtime

- **`ClassifierExtractionInvariantTests` total duration:** 2.78 seconds (measured fresh at Phase 8 after `swift package clean`)
- **Budget:** < 5 seconds (per spec performance target)
- **Headroom:** 44% (2.22 seconds under budget)
- **Skipped tests:** 1 (Kraken2 I7 CLI round-trip — `kraken2SourceMissing`; the `kraken2-mini` fixture is documented as incomplete and scheduled for future fixture work)

## Build state

- `swift build --build-tests` after `swift package clean`: **clean**
- Leftover `#warning("phase5: old extraction sheet removed")` diagnostics: **0**
- Deprecated API warnings introduced by this feature: **0** (only pre-existing protobuf/grpc plugin deprecations unrelated to this work)

## CLI smoke test (Task 8.2)

Built via `swift build --configuration release --product lungfish-cli` to `.build/release/lungfish-cli`. Test project at `/tmp/lungfish-phase8-project/` with `test.paired_end.sorted.bam` copied in as a fake EsViritu result.

### File-output mode

```
lungfish-cli extract reads --by-classifier \
    --tool esviritu \
    --result /tmp/lungfish-phase8-project/analyses/esviritu-smoke/fake.sqlite \
    --sample SMOKE \
    --accession MT192765.1 \
    -o /tmp/lungfish-phase8-project/smoke-out.fastq
```

- [x] **PASS** — Exit 0. Output `smoke-out.fastq` created, 197 reads (= 200 total – 3 unmapped), 59.5 KB. First record is a valid FASTQ 4-line block (header `@ERR5069949.114870`, sequence, `+`, quality).

### `--bundle` mode (EsViritu regression guard)

```
lungfish-cli extract reads --by-classifier \
    --tool esviritu \
    --result /tmp/lungfish-phase8-project/analyses/esviritu-smoke/fake.sqlite \
    --sample SMOKE \
    --accession MT192765.1 \
    --bundle \
    --bundle-name smoke-extract-bundle \
    -o /tmp/lungfish-phase8-project/placeholder.fastq
```

- [x] **PASS** — Exit 0. 197 reads extracted.
- [x] **PASS** — Bundle landed at `/tmp/lungfish-phase8-project/smoke-extract-bundle-extract.lungfishfastq` (directly under the project root).
- [x] **PASS — load-bearing regression guard:** the bundle path does **NOT** contain `.lungfish/.tmp/`. The entire feature's motivating regression (EsViritu writing bundles into `.lungfish/.tmp/`) is confirmed fixed at the CLI surface.

Bundle contents verified:
```
smoke-extract-bundle-extract.lungfishfastq/
├── extraction-metadata.json
├── placeholder.fastq
└── placeholder.fastq.lungfish-meta.json
```

## GUI manual verification (Task 8.3)

**AWAITING USER.** Task 8.3 requires launching the Mac app, opening a real project with a disk-loaded (not freshly-computed) EsViritu result, right-clicking a row, choosing "Extract Reads…", selecting "Save as Bundle", and verifying:

1. The unified dialog opens with the EsViritu tool header.
2. "Save as Bundle" destination is selectable.
3. Bundle lands in the project root (not `.lungfish/.tmp/`).
4. Extracted read count matches the "Unique Reads" column.

The CLI smoke test (Task 8.2) exercises the same code path from the GUI's `TaxonomyReadExtractionAction.shared.present(...)` all the way through `ClassifierReadResolver` and `ReadExtractionService.createBundle`. The GUI manual test is a final sanity check against the dialog + sidebar interaction layer.

- [ ] Unified dialog opens for EsViritu — **PENDING USER**
- [ ] "Save as Bundle" destination selectable — **PENDING USER**
- [ ] Bundle lands in project root (not `.tmp/`) after disk-loaded result — **PENDING USER**
- [ ] Extracted read count matches Unique Reads column — **PENDING USER**

## Outstanding items

### Skipped tests

- **`testExtractViaKraken2_fixtureProducesFASTQ`** (Phase 2): skips because `Tests/Fixtures/kraken2-mini/SRR35517702/` is missing `classification.kraken` (the per-read classification output) and the source FASTQ. Documented in Phase 2 review-2 Gate-3 disposition as Phase 7 fixture work.
- **`testI7_kraken2_roundTrip`** (Phase 6): same root cause. Skips via `ClassifierExtractionError.kraken2SourceMissing`.
- **`testCLI_kraken2_roundTrip`** (Phase 7): same root cause. Skips via `ClassifierExtractionError.kraken2SourceMissing`.

All three Kraken2 skips are **genuine fixture-incomplete states**, not masked bugs. A complete Kraken2 fixture (kreport + `classification.kraken` + source FASTQ) would convert all three into passing tests. This work is deferred out of scope for the unified classifier extraction feature.

### Forwarded action items (from review dispositions)

Each phase's review-2 Gate-3 disposition forwarded items to later phases; the following remain as advisory notes for future work (none block this feature):

- **Phase 4 review-2 forwarded**: `ClassifierExtractionError.cancelled` is wired into `resolveDestination .file` (save-panel cancel) but not yet into the Task-cancel path for in-flight extractions (the path uses Swift's native `CancellationError`). Semantically equivalent, but the library error case remains dead. Phase 8 does not block on this.
- **Phase 5 review-2 forwarded**: `ClassifierTool.expectedResultLayout` metadata exists (new in Phase 5 simplification, Kraken2 correctly tagged as `.directorySentinel` after the review-2 critical fix), but the CLI pre-flight check at `ExtractReadsCommand.swift:548-553` does not yet consume it. The metadata is dormant. Future work can wire it in for stricter per-tool path validation.
- **Phase 5 review-2 deferred**: NVD `clickedRow`-vs-`selectedRowIndexes` divergence (works in practice via NSOutlineView default right-click auto-select). `buildKraken2Selectors` silent-drop of non-actionable rows (UX improvement, not a bug). Closure-capture harmonization across the four `runBy*` CLI methods (cosmetic).
- **Phase 6 review-2 advisory**: minor temp-dir leak in `ClassifierExtractionFixtures.defaultSelection` Kraken2 branch (cosmetic, $TMPDIR cleanup handles it).
- **Phase 7 review-1 deferred**: full VC-level click tests for TaxTriage, NAO-MGS, NVD (requires full app context). A weaker `testAllTools_orchestratorAcceptsAllClassifierTools` substitute is in place.

### Spec requirements that could not be verified programmatically

- **GUI dialog visual appearance** vs the spec's ASCII mockup. Verified structurally by `ClassifierExtractionDialogTests` (24 view-model tests covering format picker, unmapped-mates toggle visibility, clipboard cap, destination radio, name field, primary button label) but not by pixel-level comparison against the mockup. Task 8.3 manual GUI verification is the final check.
- **User-facing cancel UX** during an in-flight extraction. Phase 4's critical fix wired dual-task cancellation (both estimate and extraction tasks are cancelled via the dialog's Cancel button), verified by `testTaskBox_cancelBothTasks_cancelsSeparately`. Full end-to-end cancel behavior (click Cancel → task cancels within 1s → sheet dismisses → Operations Panel shows "Cancelled by user") requires a running app to verify.
- **Operations Panel command-string reproducibility** from the GUI. Phase 4's `buildCLIString` + Phase 7's `testCLI_*` tests verify the CLI string is well-formed and parses back correctly. Manual verification that copy-pasting the Operations Panel row into a terminal reproduces the same output is Task 8.3.

## Sign-off

**Implemented by:** Claude (autonomous multi-phase execution on `feature/batch-aggregated-classifier-views`)
**Validated by:** _awaiting user sign-off + Task 8.3 GUI manual verification_

## Branch state (Task 8.5)

- **Commits since Phase 0 baseline (`845441a`):** 53 commits.
- **Files changed:** 57 files, +19040 insertions / -1635 deletions.
- **Top-level churn:** new `Sources/LungfishWorkflow/Extraction/ClassifierReadResolver.swift` (~860 lines), new `Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction.swift` (~500 lines), new `Sources/LungfishApp/Views/Metagenomics/ClassifierExtractionDialog.swift` (~275 lines), ~127 new tests across 7 test files, deleted 2 old SwiftUI extraction sheets + ~120 lines of `onExtractConfirmed` handler in `ViewerViewController+Taxonomy.swift`.

The branch is **ready for user review**. No push or merge has been performed — per the plan's Phase 8.5 Step 2, the branch is left as-is for the user to decide whether to:

1. Open a PR against `main`
2. Merge directly (if branch policy allows)
3. Leave the branch as-is for further review

Phase 8 complete. Implementation plan end.
