# Lane UA fix report. Fixes 1 to 4, 6 and 7 of the UA review

| Field | Value |
|---|---|
| Model and effort | lge-worker on sonnet (Sonnet 5.5), effort max |
| Started from | lane head 51828961c981c68340182fcae2f15cadf61e2539 (`git reset --hard`, then `git rev-parse HEAD` printed it). Branch `worktree-agent-ac13990e5702ab6ca`, status empty before the reset |
| Head | 64e70e086a1688ffc7d2a3a33fcf82a59c793ab8 |
| Worktree | /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/agent-ac13990e5702ab6ca, clean at the head |
| Tool calls | 97 at commit 1, 99 at commit 2, 101 at commit 3, 116 with this report (stop line 120) |

## One line per fix

| Fix | Result | Commit |
|---|---|---|
| 1 (must) | Done. `isAppStateFile(at:)` also accepts the declared name followed by a dot, with the review's body and doc sentence. Three tests written first and red at the lane head | 71febab97 |
| 7 (nit) | Done. The seam comment on `onFolderIndexed` says "each folder `upsertArtifact(at:)` reads". Folded into Fix 1 | 71febab97 |
| 2 (must) | Done. `import LungfishIO` and the third filter term in `FileSystemWatcher.classify`. The real-FSEvents test was red at the lane head. One change to the test's setup, see change 1 below | 5e210e5e8 |
| 3 | Done. Seam `SidebarViewController.onManifestCheck`, the new menu validation test, the corrected comment. Red check by reverting the gate, see change 2 | 64e70e086 |
| 4 | Done. Entry added to the Moved out list of `SCR/notes.md` (line 64, after the "Moved out for the 2.12 plan" line). The 2.12 plan file has no Moved out section yet, so that list is where it lives. Text below | not a repo file |
| 5 | Report only, as instructed. The line is below | none |
| 6 | Done at my head. `FeaturesYAMLMenuPathTests` passed, 7 tests, 0 failures. The landing agent still runs it once at the landed head | none |

Fix 4 entry as written: on exFAT, SMB and NFS the watcher asks for directory-level events (`FileSystemWatcher.StreamPolicy.foreignVolume`, 10 second latency), so an event names the bundle folder and neither `BundleKindRegistry.isAppStateFile` nor the watcher filter can tell a view state save from a manifest change. The bundle is still indexed again there, at most once per 10 second latency. Candidate for a later session: compare the manifest's size and modification date with the indexed row before decoding.

## Fix 5 release-note line (report only, words for the notes)

> Panning and zooming in a large reference or mapping result no longer makes the sidebar and the project search read the project again after each pause. On a project stored on an exFAT, SMB or NFS volume the search can still read the bundle again after a save.

## Changes to the review's text, for the manager

1. **Fix 2 test, a one second wait before the watcher starts.** The test as the review wrote it failed on the fixed tree, five runs out of five in 0.63 to 0.72 seconds, with `received == ["Ref.lungfishref"]`. The view state paths were already gone. The folder name was the creation of `Ref.lungfishref` itself, made a few milliseconds before the stream started, which fseventsd sent to the new stream. Evidence that it is that race and not an effect of the save. After I added `try await Task.sleep(for: .seconds(1))` between creating the folder and `startWatching`, five of five runs passed (5.6 seconds each, `build/lane/watch2.log`). The first red run at the lane head took 13 seconds and did not list the folder. My reading, not measured, is that the stream registered long after the folder was created on that cold first run. The wait keeps the test on its subject, a save in an already-open project, and the red result at the lane head is unchanged. Nothing about the code fix changes.
2. **Fix 3 red check.** At the lane head the gate is already in place, so the new test passes with the seam alone. To show it red I set `readsManifest = true` (the base behaviour) in the working tree, ran the test, saw it fail, restored the gate and committed only the restored form. The reverted form was never committed. I also reset the counter between the two halves of the test so the second half reads exactly 1 on its own.
3. **Fix 1 test placement.** The review's "after the loop" assertion for `manifest.json.sb-e7881877-TeusD9` sits after the outer loop over descriptors. `ProjectUniversalSearchIndexTests` keeps the original single-path call and adds the two-path call, so it is a superset of the review's instruction.
4. **Commit trailer.** I used `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` as lane-rules.md says for sonnet agents too, which matches the lane's own two commits.

## Red at the lane head (QA 1), `build/lane/red.log`

The new tests plus the Fix 3 seam, with the Fix 3 gate temporarily reverted. Exit 1.

| Test | Result at the lane head |
|---|---|
| `BundleKindRegistryTests.testIsAppStateFileNamesOnlyTheDeclaredFileDirectlyInsideItsKind` | failed twice, for the reference and the genotype-result temporary file (log line 10588) |
| `ProjectUniversalSearchIndexTests.testViewStateChangeDoesNotReindexBundle` | failed. `["Ref.lungfishref"]` was not `[]` after the temporary path, and the control then saw two re-indexes (log line 10613) |
| `UniversalProjectSearchServiceTests.testScheduledUpdateDropsAppStateChanges` | failed. The batch held `.viewstate.json.sb-e7881877-TeusD9` beside the FASTQ bundle (log line 10532) |
| `UniversalProjectSearchServiceTests.testIgnoresChangeNamesTheIndexFilesAndAppStateOnly` | failed at the temporary path (log line 10525) |
| `FileSystemWatcherTests.testBundleViewStateSaveDeliversNoPaths` | failed with `[".viewstate.json.sb-e7881877-Mdfz31", ".viewstate.json.sb-e7881877-IK7kDe", ".viewstate.json", ".viewstate.json"]` (log line 10519). This is the review's prediction, now shown on the app's own `Data.write(options: .atomic)` |
| `SidebarItemActionAccessibilityTests.testMenuValidationReadsNoManifestExceptForDeleteVariantTracksAndReassemble` | failed with the gate reverted. 23 manifest reads in all, one for Edit > Copy and one for each of 22 other menu items, then a count of 24 where 1 was expected because the counter was not yet reset (log lines 10668 to 10670) |

## Green at the head 64e70e086 (`build/lane/final.log`, exit 0)

One command, run on the committed tree.

`swift test --skip-update --filter BundleKindRegistryTests --filter ProjectUniversalSearch --filter UniversalProjectSearchServiceTests --filter FileSystemWatcherTests --filter SidebarItemActionAccessibilityTests --filter SelectionMenuTests --filter SidebarBackstopRescanTests --filter SidebarScanSnapshotParityTests --filter FeaturesYAMLMenuPathTests --filter MainSplitSelectionCoordinatorTests/testBundleHiddenAtomicWriteDoesNotRefreshSelectedBundle`

| Class | Tests | Failures |
|---|---|---|
| FileSystemWatcherTests (whole class, includes the new test) | 28 | 0 |
| UniversalProjectSearchServiceTests | 8 | 0 |
| BundleKindRegistryTests | 16 | 0 |
| ProjectUniversalSearchIndexTests | 1 | 0 |
| ProjectUniversalSearchIncrementalTests | 3 | 0 |
| ProjectUniversalSearchKindAliasTests | 24 | 0 |
| ProjectUniversalSearchTests | 11 | 0 |
| FeaturesYAMLMenuPathTests (Fix 6) | 7 | 0 |
| SelectionMenuTests | 17 | 0 |
| MainSplitSelectionCoordinatorTests (the one atomic write test) | 1 | 0 |
| SidebarBackstopRescanTests | 7 | 0 |
| SidebarItemActionAccessibilityTests (includes the new test) | 20 | 0 |
| SidebarScanSnapshotParityTests | 12 | 0 |

An earlier green run of the same set, before the one second wait, failed only the Fix 2 test (`build/lane/green.log`, change 1). The new test then passed five of five alone (`build/lane/watch2.log`). The unit tier, the golden comparison and anything under `scripts/release/` were not run. Nothing was pushed. No compiler warning names a touched file in `red.log`, `green.log` or `watch2.log`, the three logs that include a build. `final.log` rebuilt nothing.

## Ratchets and checks (run at the head)

| Check | Result |
|---|---|
| `scripts/ratchets/file-size.sh` | passes, 200 files over 800 lines, 1 shrunk (the lane's `SidebarViewController+MenuDelegate.swift`). `FileSystemWatcherTests.swift` is 799 lines, not baselined |
| `scripts/ratchets/concurrency-hatches.sh` | at baseline (the seam is a plain static var, not a hatch) |
| `scripts/ratchets/source-text-assertions.sh` | 1426, at baseline |
| `scripts/ratchets/path-helpers.sh` | at baseline |
| `scripts/ratchets/volume-portability.sh` | at baseline |
| `docs/architecture/MODULES.md` | not regenerated, as the brief says. No public type, target or source folder was added. Line counts of LungfishIO, LungfishOperations, LungfishApp and three test targets moved again, so the landing agent regenerates once |

## Files changed

Sources. `LungfishIO/Bundles/BundleKindRegistry.swift`, `LungfishIO/Search/ProjectUniversalSearchIndex.swift` (one comment), `LungfishOperations/FileSystemWatcher.swift`, `LungfishApp/Views/Sidebar/SidebarViewController+ItemActions.swift`.
Tests. `BundleKindRegistryTests.swift`, `ProjectUniversalSearchIndexTests.swift`, `UniversalProjectSearchServiceTests.swift`, `FileSystemWatcherTests.swift`, `SidebarItemActionAccessibilityTests.swift`.
Outside the repo. `SCR/notes.md` (the Fix 4 entry).

## Findings

1. The Swift atomic write does name its temporary file `.viewstate.json.sb-e7881877-<six characters>`. The review had run only Foundation through `osascript`, so this settles the open point on the app's own write.
2. A silent-delivery test that creates a folder just before it starts the watcher needs the wait of change 1, or the creation is delivered to the new stream. `FileSystemWatcherTests.swift` has one line of room left under the ratchet, so the next watcher test goes in a new file.
3. The new test saves twice, so it covers the creation of `.viewstate.json` and an overwrite of it, and both temporary names. It does not cover a foreign volume (Fix 4) or the sidebar's reload path in the running app.
4. Still open and not mine. The Q-U9 GUI check on a Debug build: pan and zoom a mapping result for 30 seconds with `log stream --level debug --predicate 'category == "ProjectUniversalSearch"'` running, expecting no `upsertArtifact` line and no sidebar reload.

## Handoff

State. Fixes 1, 2, 3, 4, 6 and 7 are done and committed in three commits. Fix 5 is the line above. The worktree is clean and every test and ratchet above is green.

Remaining steps, none for this worker.
1. Recheck of Fixes 1 and 2 by a fresh lge-expert (sonnet, effort max), reading the three commits and the red and green logs.
2. The landing agent (lge-worker, sonnet, effort max) regenerates `MODULES.md` once and runs `FeaturesYAMLMenuPathTests` at the landed head.
3. The Q-U9 GUI agent (lge-worker, sonnet, effort max, Computer Use) runs finding 4.
4. The manager pastes the Fix 5 line into the notes.

Files to read.
- `Sources/LungfishIO/Bundles/BundleKindRegistry.swift` lines 274 to 288
- `Sources/LungfishOperations/FileSystemWatcher.swift` lines 5 to 10 and 595 to 603
- `Tests/LungfishOperationsTests/FileSystemWatcherTests.swift` lines 743 to 772
- `Sources/LungfishApp/Views/Sidebar/SidebarViewController+ItemActions.swift` lines 11 to 16, 87 to 93 and 145 to 158
- `Tests/LungfishAppTests/SidebarItemActionAccessibilityTests.swift` lines 272 to 305
- Logs in the worktree under `build/lane/`: `red.log`, `green.log`, `watch2.log`, `final.log`

Next command, from the worktree.
`swift test --skip-update --filter FileSystemWatcherTests/testBundleViewStateSaveDeliversNoPaths`
