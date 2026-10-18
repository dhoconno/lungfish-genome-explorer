# Landing 3 report. Lanes P1, P2, P5 and P4 and the owner's two commits onto the program branch

Model and effort. `lge-worker` on sonnet (Claude Sonnet 5.5), effort max.

| Item | Value |
|---|---|
| Program worktree and branch | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/laptop-golden-runner-setup-e5434b`, `claude/2-12-pre-launch-issues-1b3490` |
| Start checks | Branch matched, `git status --short` empty, `git rev-parse HEAD` printed `f1f53dca3275e838a7fbba5a3c3cc54fddc5f405`. Start step 3 was not run, as the prompt says |
| Program head before | `f1f53dca3275e838a7fbba5a3c3cc54fddc5f405` |
| Program head after | `bd6923426dddcca80bc5d5813ec5c686a05c5b7a` |
| Commits added | 23 (17 cherry-picks, 5 folds, 1 golden capture) |
| Working tree | Clean. Every background command has ended |
| Calls | 111 by my count when the report was finished, this edit being the last (stop line 170) |

## Ranges landed

Every range was linear. Every pick used `git cherry-pick -x`, so each new commit carries its `(cherry picked from commit ...)` line. Ranges 1 to 4 each ran as one pick command. Range 1 was one contiguous pick, as the prompt asks, so the intermediate state that exceeds the `ProvenanceExporter.swift` baseline was never a stopping point and the final tree passes the file-size ratchet.

Range 1, lane P1 with its fix, `65539ddcd..71b512b5b`:

| Lane commit | New commit |
|---|---|
| `e9f6097ed` Stop runaway provenance lineage lookups (F1) | `4f0728562` (MODULES.md conflict) |
| `c3339a39a` Keep a cancelled task from cutting a provenance export short (P1 fix 1) | `3b5c16b87` |
| `98550002e` Read a sidecar again after a read error instead of caching it as no record (P1 fix 2) | `9888aec98` |
| `71b512b5b` Isolate the lineage tests, resolve each string once per sidecar and keep invalidate cheap (P1 fixes 3, 5 and 6) | `ac6c37a3d` |

Range 2, lane P2 with fix A, `65539ddcd..93e4b3598`:

| Lane commit | New commit |
|---|---|
| `d94b56573` Open large references with one manifest decode, off the main actor (P2) | `59a3871df` (MODULES.md conflict) |
| `ea1b6427e` Hide a superseded reference open's toast and pin superseded opens (P2 fixes 1, 2) | `4d8328794` |
| `346deae64` Harden the viewport identity compare and map the manifest read (P2 fixes 4, 6) | `e0ae6f178` |
| `93e4b3598` Run large bundle decodes one at a time (P2 fix 5) | `044c4525c` |

Range 3, lane P5, `d94b56573..f344ac21e`:

| Lane commit | New commit |
|---|---|
| `32b485b41` Pin the mapping summary rows, schema-1 results and their export before F4 (P5 freeze) | `581884627` |
| `7c6fb694a` Stop cancelled All Alignments builds and announce the mapping table after its refresh (P2 review items 6R, 7, 8, 10) | `8dc77e3fd` |
| `ea51832df` Leave references with no alignment out of new mapping results and record both counts in schema 2 (F4 item 1) | `79aaabf16` (MODULES.md conflict) |
| `8f92ea038` Say in the mapping summary bar how many reference sequences have alignments and record both counts in the export (F4 item 2) | `179c9c908` (MODULES.md conflict) |
| `f344ac21e` Document mapping-result.json schemas 1 and 2 in the analyses layout (F4 item 3) | `e7e02520b` |

Range 4, lane P4, `185cc2372..d78e8c82f`:

| Lane commit | New commit |
|---|---|
| `8c2094e38` Keep only each EsViritu BAM's own lineage in its build-db sidecar | `548e2c43b` (MODULES.md auto-merged) |
| `d78e8c82f` Test that each EsViritu BAM sidecar holds only its own sample's steps | `a3583a48c` |

Range 5, the owner's two commits from local main, each with `git cherry-pick -x`. Neither conflicted, so nothing was aborted or skipped.

| Source commit | New commit |
|---|---|
| `77cdb0964` Pass the BAM index to TaxTriage and EsViritu BLAST Verify | `d4bed54e0` |
| `c59241ace` Add the X01 TaxTriage walkthrough screencast | `e1f575906` |

## Conflicts and resolutions

Four picks stopped on `docs/architecture/MODULES.md` and nothing else (`e9f6097ed`, `d94b56573`, `ea51832df`, `8f92ea038`). Each time I took the program branch's side with `git checkout --ours docs/architecture/MODULES.md`, added it and continued the pick. The P1 conflict was resolved by hand with `git checkout`, `git add` and `git cherry-pick --continue`. Then I wrote `SCR/land/resolve-modules.sh`, which does the same three steps and refuses to go on when any other file is still unmerged. The P2 conflict and both P5 conflicts went through it. `docs/architecture/MODULES.md` is regenerated once at the end (commit `f5a0a1da0`), so the side taken does not matter. P1's pick auto-merged `ProvenanceInspectorViewModel.swift` against lane UB's earlier hunk with no conflict. P4's pick auto-merged MODULES.md. No other file conflicted, so there was no resolution to keep both lanes' behavior.

## Folded fixes, each in its own commit

| Commit | What |
|---|---|
| `e068b972d` | P2 review item 14, exactly as written. `Sources/LungfishApp/Views/Viewer/ChromosomeNaturalOrder.swift` builds its key with `chromosomeSortKey($0.name)` (internal since P3, `ChromosomeNavigatorView.swift:25`) and the private copy (`scaffoldSeparators`, `naturalOrderKey`) is deleted, 5 insertions and 32 deletions. I read `chromosomeSortKey` first. It is the deleted copy line for line, same tuple type. The doc comment now says the key is the one `naturalChromosomeSort` uses. `ChromosomeNaturalOrderTests` (1 test) passes with `ChromosomeNavigatorSortTests` (2) and `ChromosomeNavigatorSelectionTests` (11) |
| `fe267f889` | P1 review fix 10, the landing part. `scripts/ratchets/file-size.baseline:24` for `ProvenanceInspectorViewModel.swift` goes from 1337 to 1330, its real count after P1 and the UB shrink (`wc -l` printed 1330). Landings 1 and 2 had left this entry on purpose. The other two parts of fix 10 correct the P1 lane report and are not repository files. I edited `SCR/lanes/P1/P1.md` in place. The test count now reads "eight in all (four view model, three resolver, one coordinator)", and finding 1 now says `Mutex` follows `CLIRunCancellation.swift`, `DurableReplace.swift` and `ToolProcessRun.swift` and that the playbook names `OSAllocatedUnfairLock` |
| `7bea625ae` | P5 review fix 4a. The `map` entry of `docs/user-manual/features.yaml` gains the review's notes sentence (anchored on the closing text "so a script reads the complete line."), the three sources (`MappingSummaryBuilder.swift`, `MappingReferenceCountText.swift`, `MappingResultExportBuilder.swift`) and the two tests (`MappingResultTests.swift`, `MappingReferenceCountTextTests.swift`). `features-yaml-entry-points.py` prints 235 entry points all resolving and `features-yaml-sources.py` prints 1067 values all resolving |
| `4d368d78c` | P5 review fix 6c with P2 review answer 1. `file-size.sh --update` and `concurrency-hatches.sh --update` ran once on the landed tree and I read the diff, which holds decreases only. File sizes: `AppDelegate.swift` 2690 to 2660, `InspectorViewController+PublicAPI.swift` 992 to 991, `MainSplitViewController+ContentDisplay.swift` 1050 to 1048, `ReferenceBundleViewportController.swift` 2155 to 1935, `ViewerViewController+BundleDisplay.swift` 872 to 871, `BundleManifest.swift` 823 to 822 and `ManagedMappingPipeline.swift` 1211 to 1210. Hatches: `MainActor.assumeIsolated` 296 to 295. The review names only the last two file entries for P5. I lowered the P2 entries too because the P2 review (answer 1) says to lower both baselines once at the end of the landing series and to read the diff for decreases only. The `ProvenanceInspectorViewModel.swift` entry was already done in `fe267f889` |
| `f5a0a1da0` | P4 landing note and P5 review fix 6a. `python3 scripts/index/generate-module-map.py` once, after the last source commit, in place of merging text. New public types are `BundleLoadProbe` (LungfishCore), `ProvenanceSidecarIndex` and `MappingContigSummaryTable` (LungfishWorkflow). Counts move for LungfishApp (617 to 625 files, 217553 to 218181 lines), LungfishCore, LungfishOperations, LungfishWorkflow (845 to 846 files) and five test targets. `module-map-current.py` prints "current" |

Not folded, as the prompt says. P5 review fix 4b (the release-note line) and 4c (the punchlist row) are written into this report and nowhere else, see the section after Golden.

## Build

`(swift build --skip-update --build-tests; echo "exit=$?") > build/land3/build.log 2>&1`, run at `f5a0a1da0` after every source commit. Exit 0, "Build complete! (128.46 sec)". No `error:` line.

Warnings in files this landing touches. The log holds ANSI color codes, so a plain search for `.swift:N:M: warning` finds nothing. Searching with the codes in the pattern finds warnings in five touched files, and every one of them is in landing 1's cold build log (`build/land/build.log`, head `326b20c67`) at the same text, with line numbers moved by this landing's edits. None is new.

| File | Warning, as before |
|---|---|
| `MappingSummaryBuilder.swift` (6 places) | `NativeProcessCancellationHandle` is deprecated, use ToolProcess (was `:227`, `:228`, `:256`, `:257`, `:393`, `:496`, now `:254`, `:255`, `:283`, `:284`, `:420`, `:523`) |
| `ViewerViewController+BundleDisplay.swift:851` | result of call to `run(resultType:body:)` is unused (was `:852`) |
| `MappingViewportRoutingTests.swift:131` | immutable value `split` was never used |
| `PrimerTrimInspectorAfterRevealTests.swift:25-36` and `WorkflowCompletionBundleDisplayTests.swift:24-34` | main actor-isolated properties used from a nonisolated context in `setUp` and `tearDown` |

## Tests

Four `swift test --skip-update` runs, one at a time, logs in the program worktree under `build/land3/`. Every foreground wait used timeout 270000 and every background start used 600000. The subshell wrapper always exits 0, so the recorded value is the `exit=` line in each log. `ProvenanceEnvelopeStatusTests` is a Swift Testing suite, so its tests count on the "Test run with" line and not on the XCTest "Executed" lines. All four logs end `exit=0` with no `error:` line and no Swift Testing issue.

Totals: 953 tests (930 XCTest and 23 Swift Testing), 10 skipped, 0 failures.

Run T1, `build/land3/t1.log`, `exit=0`. The sets of lanes/P1/P1.md and lanes/P1/P1-fix.md, 26 filters: `ProjectFilesystemRefreshCoordinatorTests`, `ProvenanceInspectorViewModel`, `ProvenanceLineageResolverTests`, `ProvenanceNotRecordedDisplayTests`, `ProvenanceRawJSONDisplayTests`, `ProvenanceSectionAccessibilityTests`, `InspectorProvenanceTabTests`, `ProvenanceRunStatusDisplayTests`, `PrimerAnalysisInspectorTests`, `InspectorSpinnerSizeTests`, `ManualScreenshotProductFixTests`, `LooseFileProvenanceSelectionTests`, `ProvenanceLegacyDisplayTests`, `ProvenanceSectionSourceTests`, `ProvenanceStepToolsDisplayTests`, `ProvenanceStepTerminationDisplayTests`, `ProvenanceReadOnlyTests`, `ProvenanceOlderRecordFormatTests`, `ProvenanceHonestRuntimeTests`, `ProvenanceCompatReader`, `DemoProjectProvenance`, `ProvenanceExporter`, `ProvenanceExportPinGateTests`, `PortableProvenanceTests`, `ProvenanceEnvelopeCopySitesTests`, `MappingProvenanceTests`. Result 289 XCTest tests, 2 skipped, 0 failures, plus 10 Swift Testing tests in 1 suite. The bundles report LungfishWorkflowTests 82 (1 skip), LungfishOperationsTests 11 and LungfishAppTests 196 (1 skip). These three counts equal the P1 fix report's final run. The two skips are the ones that report names (`DemoProjectProvenanceSweepTests` and `PrimerAnalysisInspectorTests.testRenderNativePrimerInspectorTabs`, each needing an environment folder).

| Class | Tests | Class | Tests |
|---|---|---|---|
| ProvenanceExporterTests (P1 fix 1) | 1 | ProvenanceInspectorViewModelTests | 23 |
| ProvenanceLineageResolverTests (P1 fix 2) | 9 | ProvenanceInspectorViewModelOffMainTests | 3 |
| ProjectFilesystemRefreshCoordinatorTests | 11 | InspectorProvenanceTabTests | 12 |
| ProvenanceExportPinGateTests | 28 | ProvenanceRunStatusDisplayTests | 26 |
| MappingProvenanceTests | 10 | ProvenanceStepToolsDisplayTests | 27 |
| PortableProvenanceTests | 9 | ProvenanceStepTerminationDisplayTests | 21 |
| ProvenanceEnvelopeCopySitesTests | 9 | ProvenanceRawJSONDisplayTests | 17 |
| ProvenanceHonestRuntimeTests | 8 | ProvenanceReadOnlyTests | 15 |
| DemoProjectProvenanceLoadTests | 7 | ProvenanceOlderRecordFormatTests | 14 |

Run T2, `build/land3/t2.log`, `exit=0`. The sets of lanes/P2/P2.md and lanes/P2/P2-fix.md plus item 14 and the P3 sort key tests: `ReferenceOpenManifestLoadTests`, `MappingOpenManifestLoadTests`, `AppDelegateMenuValidationTests`, `ReferenceOpenProgressTests`, `MappingRowsRefreshCancellationTests`, `ChromosomeNaturalOrder`, `ChromosomeNavigator`, `AlignmentMetadataDatabaseTests`, `ReferenceBundleViewportControllerTests`, `MappingViewportRoutingTests`, `ReferenceBundleViewportInputTests`, `AppDelegateReferenceBundleResolutionTests`, `MappingInspectorProvenanceTests`, `MappingViewportLegacyReadCountTests`, `WorkflowCompletionBundleDisplayTests`, `WindowProjectSwitchResetTests`, `PrimerTrimInspectorAfterRevealTests`, `MHCReferenceBundleViewportTests`, `BundleDecodeLaneTests`, `ReferenceViewportIdentityTests`, `BundleManifest`. Result 257 tests, 2 skipped, 0 failures. The bundles report LungfishAppTests 118, LungfishCoreTests 56 (1 skip, `BundleManifestDurabilityTests`), LungfishIOTests 49, LungfishAppViewTests 21, LungfishWorkflowTests 9, LungfishOperationsTests 2 (1 skip, `ViralReconRealResultsIngestSmokeTests`), LungfishCLITests 1 and LungfishIntegrationTests 1. The counts equal the P2 fix report's final run, with one more in `ReferenceBundleViewportControllerTests` (20, where P5 adds `testReferenceCountLabelOrderAndDirectBundle` to the 19).

| Class | Tests | Class | Tests |
|---|---|---|---|
| BundleDecodeLaneTests (P2 fix 5) | 2 | MappingViewportRoutingTests | 46 |
| ReferenceViewportIdentityTests (P2 fix 4) | 2 | ReferenceBundleViewportInputTests | 3 |
| ReferenceOpenManifestLoadTests (P2 fixes 1, 2) | 3 | AppDelegateReferenceBundleResolutionTests | 5 |
| MappingOpenManifestLoadTests | 1 | MappingInspectorProvenanceTests | 4 |
| AppDelegateMenuValidationTests | 1 | MappingViewportLegacyReadCountTests | 1 |
| ReferenceOpenProgressTests | 1 | WorkflowCompletionBundleDisplayTests | 2 |
| MappingRowsRefreshCancellationTests | 1 | WindowProjectSwitchResetTests | 4 |
| ChromosomeNaturalOrderTests (item 14) | 1 | PrimerTrimInspectorAfterRevealTests | 2 |
| ChromosomeNavigatorSortTests and SelectionTests (P3) | 2 and 11 | MHCReferenceBundleViewportTests | 5 |
| AlignmentMetadataDatabaseTests | 48 | BundleManifestTests (Core 42, App 16), EscapeRootTests 8, DurabilityTests 6 | 72 |
| ReferenceBundleViewportControllerTests | 20 | | |

Run T3, `build/land3/t3.log`, `exit=0`. The sets of lanes/P5/P5.md, which names classes and no `--filter` line, so I took its New tests list and the filters of its exfat and m1 runs: `MappingResult` (matches every `MappingResult*` class), `MappingSummaryBuilder`, `ManagedMappingPipelineTests`, `MappingReferenceCountTextTests`, `MappingViewerBundle`. Result 221 XCTest tests, 6 skipped, 0 failures, plus 1 Swift Testing test. The bundles report LungfishWorkflowTests 121 (5 skips), LungfishAppViewTests 64, LungfishAppTests 31 (1 skip), LungfishCLITests 4 and LungfishIntegrationTests 1. The skips are the self-skipping real-volume and environment tests (`MappingResultDurabilityTests` 1, `MappingViewerBundleProvenanceFinalizerTests` 4 as in landing 2, `MappingViewerBundlePreparerTests` 1).

| Class | Tests | Class | Tests |
|---|---|---|---|
| MappingResultTests (schemas 1 and 2) | 6 | ManagedMappingPipelineTests | 35 |
| MappingResultDurabilityTests | 5 | MappingResultViewControllerTests | 59 |
| MappingResultExportTests | 1 | MappingViewerBundleProvenanceFinalizerTests | 39 |
| MappingSummaryBuilderTests | 15 | MappingResultSidecarTests | 8 |
| MappingReferenceCountTextTests | 3 | MappingResultLayoutServiceTests | 6 |

Run T4, `build/land3/t4.log`, `exit=0`. The set of lanes/P4/P4.md plus the owner's first commit: `ProvenanceEnvelopeLineageFocusTests`, `BuildDb`, `EsVirituBatchRootRunLevelTests`, `EsVirituDetectExecutorTests`, `SidebarCopyOfBuiltClassifierResultsReplayTests`, `ProvenanceWriterBundleOutputsTests`, `ProvenanceEnvelopeStatusTests`, `ClassifierBlastExtractionConfigTests`. Result 163 XCTest tests, 0 failures, plus 12 Swift Testing tests in 1 suite (`ProvenanceEnvelopeStatusTests`). LungfishWorkflowTests 12, LungfishCLITests 143 and LungfishAppTests 8. The P4 classes equal the lane report (5 `ProvenanceEnvelopeLineageFocusTests`, 5 `BuildDbEsVirituRunLevelTests`, 1 `BuildDbEsVirituRunLevelLiveConformanceTests`, 15 `EsVirituDetectExecutorTests`, 143 CLI). `ClassifierBlastExtractionConfigTests` ran 2 tests and passed, so the owner's first commit holds.

## Golden

The environment verified and `python3 scripts/golden/golden.py compare` ran on all captures at program head `f5a0a1da0`. It built the CLI itself (`swift build --product lungfish-cli`) and used `.build/out/Products/Debug/lungfish-cli` (version 2026.10.10), scratch root `/Users/Shared/lungfish-golden/run`.

Compare 1, `build/land3/golden-compare-1.log`, exit 1 as expected in 55.6 s.

| Capture | Result |
|---|---|
| cli-help | matches (296 files) |
| mapping | DIFFERS, one file of 9, `mapping-result.json`, exactly the three keys of reviews/P5.md |
| classifiers | matches (24 files) |
| genotype | matches (133 files) |

The diff, in the encoder's sorted order: `schemaVersion` 1 to 2, `referenceCount` added as 1 and `unalignedReferenceCount` added as 0. No other key and no other capture moved, so I captured.

- `python3 scripts/golden/golden.py capture --only mapping` printed "captured 9 files". `git status --short` listed only ` M Tests/Fixtures/golden/mapping/mapping-result.json`, and `git diff --stat` showed 3 insertions and 1 deletion.
- `python3 scripts/golden/predictions.py check .../lanes/P5/predictions.json -v` listed the three predicted rows and printed `OK: 3 changes in 1 files, 0 unpredicted, 0 with a wrong value, 0 of 3 predictions unfulfilled, 0 ignored`.
- Commit `bd6923426dddcca80bc5d5813ec5c686a05c5b7a` holds that one file. Its message names program head `f5a0a1da033adca56e6c417dce9a0f36b29d8201`, the head whose CLI made it.
- Compare 2, `build/land3/golden-compare-2.log`, exit 0 in 44.5 s. cli-help (296), mapping (9), classifiers (24) and genotype (133) all match.

Not done from P5 review fix 1. The compare at the landing parent (a clean base compare) did not run, since the prompt asks for one compare at the end. The first compare, with only the three predicted keys moving, covers what that step checks.

## P5 release note and punchlist row (report only, as the prompt says)

Release-note line, from the P5 report, verbatim, for whoever writes the release notes (P5 review fix 4b).

> Mapping results against references with many sequences, such as SILVA, now list only the reference sequences that have alignments, and the bar above the list says how many, for example 94 of 905,628. Results made by earlier versions show as before.

Screenshot punchlist row, in the three-column format of section A of `~/Documents/lungfish-branch-archive/screenshot-punchlist.md` (P5 review fix 4c). The manager decides the section. It needs a window capture only, no full-screen control.

| Shot id | Chapter | App state |
|---|---|---|
| mapping-summary-bar-reference-count | 04-alignments/01-mapping-reads-to-a-reference | Mapping result window for a new (schema 2) mapping onto a many-sequence reference such as SILVA, with the summary bar above the sequence list showing its count label, for example 94 of 905,628. Added by lane P5 (program head `bd6923426`). Docs fact: the label shows only for a mapping result that records both counts, when at least one sequence was left out, the reference has two or more sequences and the counts agree with the rows. A result made by an earlier version shows no label. Window capture, no full-screen control |

## Ratchets and checks

`SCR/land/run-ratchets.sh` (landing 1's loop over every `scripts/ratchets/*.sh` with python3) reports `ratchets-failed=0` of 12. I ran it twice, at `f5a0a1da0` and again on the final head `bd6923426`, with the same result both times.

| Ratchet | Result |
|---|---|
| cli-parity-gaps | 11 gaps, at the baseline |
| concurrency-hatches | 295, 161, 46, 22, at the recorded baseline (295 is the lowered `MainActor.assumeIsolated`) |
| file-size | 199 files over 800 lines, at the recorded baseline, no entry shrunk |
| native-tool-runner-in-app | 0, at the baseline |
| path-helpers | 39, 16, 11, at the baseline |
| process-spawn | 45 and 14, at the baseline |
| provenance-writers | 23, 0, 15, 13, 177, at the baseline |
| shared-slider-control | OK |
| source-text-assertions | 1426, at the baseline |
| tool-identity | 77, 0, 35, 5, at the baseline |
| unchecked-operation-start | 0, at the baseline |
| volume-portability | 0, 1, 1, 0, at the baseline |

`python3 scripts/checks/features-yaml-entry-points.py` prints "235 entry point string(s) checked, all resolve" and `features-yaml-sources.py` prints "1067 value(s) checked, all resolve". `python3 scripts/checks/module-map-current.py` prints "current" (after the regeneration and again on the final head).

## Notes and deviations

1. Commit trailer. `lane-rules.md` End step 1 sets the last line to `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` for sonnet agents too, and my six commits carry it. The attribution reminder of this session named Sonnet 5.5. I followed the lane rules, as landings 1 and 2 did. The 17 cherry-picks keep their authors' trailers.
2. The P2 folds beyond item 14. I lowered the six P2 file-size entries and the `MainActor.assumeIsolated` hatch in `4d368d78c` on the strength of the P2 review's answer 1. The prompt names the P5 chores and the P1 entry. If the manager wants only those, the P2 lines are the first six in the commit's diff.
3. Test counts. A plain `Executed N tests` search misses a Swift Testing suite and a suite that skips a test (`with 1 test skipped and 0 failures`). I read the `Test run with` lines too.
4. No test failed and no pick had a conflict beyond MODULES.md, so the brief's run of a failing test alone on the program head before the picks was not needed.
5. A pre-commit hook printed nothing on the six commits.

## Handoff

State. The program branch is at `bd6923426dddcca80bc5d5813ec5c686a05c5b7a`, tree clean, build and four test runs green, 12 of 12 ratchets pass, the golden comparison clean on all four captures, nothing running and nothing pushed.

Remaining steps, for the manager. Each is `lge-worker`, sonnet, effort max unless said.
- P4 review fixes 1 to 5 (test edits in `ProvenanceEnvelopeStatusTests.swift`, `BuildDbEsVirituRunLevelTests.swift` and `ProvenanceEnvelopeLineageFocusTests.swift`, one commit) and fix 6 (`LUNGFISH_REQUIRE_TOOLS=1` run of `ClassifierCLIGUIParityReplayTests/testE3EsVirituBatchOfTheSubsetBundleAndThePair` with `LUNGFISH_PARITY_DUMP` set to a scratch folder).
- P1 review fixes 4, 7, 8 (load pass, add `ProvenanceExporterTests` as the P1-P2 check asks) and 9 (measure the first build at the landed head, which includes fix 5).
- P2 review fixes 3, 9, 11, 12, 13 and 15 (tests and runs) and the P1-P2 fix-check items for fix A (the `testMappingAndReferenceOpensShareTheLane` test, the load pass with the three new classes, and the footprint and FASTQ toast looks in the GUI check). The P2 fix report leaves fixes 3 and 12 to whoever takes them (fix 12 edits `testReferenceOpenDecodesOnceOffMain` beside the fix A tests, so keep both sides).
- P5 review fix 2 (ONT filtered result pin), fix 3 (`bash scripts/testing/exfat-tests.sh --simulate "ManagedMappingPipelineTests|ONTGenotypingPipelineTests|MappingResultSidecarTests|AppUITestMappingBackendTests"`) and fix 5 (two width looks in the GUI check).
- One GUI check with Computer Use on a Debug build, as the reviews group it: P2 fix 16, P5 fix 5, the P2 fix A looks, and the Q-U9 check from landings 1 and 2.
- Release note line and punchlist row above go to the notes and `screenshot-punchlist.md`.
- Push. Run `python3 scripts/release/gate_evidence.py unit-evidence --root . --commit HEAD` and ask the owner before the unit tier. A push to `main` starts the Golden workflow on the Mac Studio, and the mapping fixture is already recaptured here.

Files to read, at the head.
- `Sources/LungfishApp/Views/Viewer/ChromosomeNaturalOrder.swift:1-22`
- `scripts/ratchets/file-size.baseline:6`, `:23`, `:24`, `:30`, `:47`, `:71`, `:85`, `:162` and `scripts/ratchets/concurrency-hatches.baseline:2`
- `docs/user-manual/features.yaml:182-240`
- `Tests/Fixtures/golden/mapping/mapping-result.json:18-30`
- `docs/architecture/MODULES.md:14-29`, `:494`, `:2619-2640`, `:3055`
- `SCR/land/resolve-modules.sh`
- `build/land3/build.log`, `t1.log` to `t4.log`, `golden-compare-1.log` and `golden-compare-2.log` in the program worktree

Next command for the P4 test fixes, from the program worktree, in the background with a log.

```text
swift test --skip-update --filter ProvenanceEnvelopeLineageFocusTests --filter BuildDbEsVirituRunLevel --filter ProvenanceEnvelopeStatusTests
```
