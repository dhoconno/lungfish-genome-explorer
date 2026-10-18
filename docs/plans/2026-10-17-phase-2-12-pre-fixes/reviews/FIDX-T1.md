Verdict: Merge
Section 1. FIDX and FIDX-2, bd6923426dddcca80bc5d5813ec5c686a05c5b7a..7b6e696991b7175f190d8a15277d5896b960297c (FIDX head ab8b71d02565e3c971d093b2c49cc54396f8fde4).

Reviewer. lge-expert, field SWIFT (letter S), on sonnet (claude-sonnet-5-5) at effort max. Checks carried: SWIFT 1, 2, 5, 7, ARCH 6, QA 1, 2, 6. I read the review brief, `briefs/lane-FIDX.md`, ruling `SWIFT-fai.md` section 4.7, the FIDX, FIDX-2, P2-fix, P6 and T1 reports, both diffs and the touched code with git show at 7b6e69699. I built and ran nothing and started no agent. About 76 tool calls. Every `path:line` is at 7b6e69699 unless it names another commit.

## In brief

0 must fixes and 4 should fixes. The bundle, its chromosome name index and its sequence reader are built once, in the detached load, inside the work closure of the decode lane. That one instance travels through the payload, the route input and the embedded viewer to the display context and to the `BundleDataProvider`, so the open builds nothing on the main actor. Both new tests trap on a main-queue build and both fail at their bases in the lane logs. The display token guards are untouched. The should fixes cover lane time wasted on a cancelled open (fix 1), a missing pin of the lane bound (fix 2), a second provider that still builds its own bundle (fix 3) and two P6 classes the sets runs left out (fix 4).

## The questions of the task

1. Does the prepared bundle reach the viewer and its provider with no second build on main? Yes. The build is `decodeIndexedBundle` (`Sources/LungfishApp/Views/MainWindow/MainSplitViewController+BundleOpenLoading.swift:88-94`), called for a reference open at `:48-51` and for a mapping's viewer bundle at `:69-74`. The payloads carry it (`:14-17`, `:22-35`) and the commit sites pass it on (`Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift:817-819`, `:927-934`). `ReferenceBundleViewportInput.preparedBundle` holds it (`Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportInput.swift:33`). `loadViewerBundleIfNeeded` gives it to `displayBundle` (`Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift:830-836`), and `loadBundleDisplayContext` uses it for the context and the provider (`Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift:116`, `:124-125`). The provider keeps it and `ensureBundle()` returns it (`Sources/LungfishOperations/BundleDataProvider.swift:60-65`, `:211-214`). So `chromosomeInfo(named:)`, which the viewport calls on the main actor (`ReferenceBundleViewportController.swift:1101`, `:1147`), reads the prepared index.

2. Does the decode lane still hold one large decode at a time? Yes. `BundleDecodeLane.decode` runs its `work` inside the lane actor when the manifest is over 64 MB (`Sources/LungfishApp/Views/MainWindow/BundleDecodeLane.swift:71-84`), and `decodeIndexedBundle` sits in that closure, so a large open's decode and index builds are one turn. The size test reads the manifest, which lists every sequence, so it stands for the `.fai` as well. No test pins it (fix 2).

3. Does a superseded open drop its prepared bundle? Yes. The payload is the local `loaded` of the open task, and both commit guards return before `loaded.get()` (`MainSplitViewController+ContentDisplay.swift:812-816`, `:921-924`), so nothing keeps it. A cancel reaches the detached task (`BundleDecodeLane.swift:62-66`) and skips the decode and the builds only while the open still waits for the lane (`:82`). An open that is already decoding finishes the decode and then builds both indexes for a result that is dropped (fix 1). The existing `testSupersededOpenCommitsOnlyTheNewSelection` (`Tests/LungfishAppTests/ReferenceOpenManifestLoadTests.swift:100-142`) still shows only the new selection and passed in both sets runs.

4. Does the display token still guard the commit? Yes. `canCommitDisplayRequest(displayToken, identity:)` and `viewerAwaitsBundleOpen` run first at `ContentDisplay.swift:812-813` and `:921-922`, and neither diff touches them. The check that keeps a live mapping viewport on a re-announce (`:937-943`) returns before the route is displayed, so a bundle built for it drops with the payload (FIDX-2 finding 3, accepted).

5. The provider change the ruling did not name. Needed, and accepted. A provider built without a bundle makes its own at the first access (`BundleDataProvider.swift:211-219`), and `chromosomeInfo(named:)` then builds that second bundle's name index (`:101-104`). The viewport asks for it on the main actor (`ReferenceBundleViewportController.swift:1101`, `:1147`). A prepared bundle that the provider ignored would leave that build on main, and the open tests would trap. Sharing the instance is the smallest change.

## Numbered fixes

All four are should. None blocks the merge, and fixes 1 and 2 are best landed with the lane.

1. should. `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+BundleOpenLoading.swift:91-92`. A cancelled open still builds both indexes inside the lane. `BundleDecodeLane.offMain` forwards a cancel to the detached task (`BundleDecodeLane.swift:62-66`) and `run` checks it once, on entry (`:82`). Before FIDX a superseded open held the lane for its decode alone. Now it holds the lane for the decode, the name index (215 to 251 ms for SILVA by the ruling) and the `.fai` parse, and then the commit guard drops the result. Replace the comment and the `try?` at `:91-92` with:
```swift
        // A cancelled open cannot stop its decode, but it can skip the index builds, which would hold the lane for seconds more.
        try Task.checkCancellation()
        // A genome that cannot be read is reported by the first fetch, as before the indexes were built here.
        try? bundle.prepareSequenceAccess()
```
The throw returns `.failure(CancellationError())`, and both commit sites return at their guards before `loaded.get()`. In the mapping route the `try?` at `:71` turns it into a nil viewer bundle in a payload that is dropped. Test `ReferenceOpenManifestLoadTests.testSupersededOpenSkipsItsIndexBuilds`, built on `testSupersededOpenCommitsOnlyTheNewSelection` with `SequenceIndexBuildLog().install()` before the first open. After `await taskA?.value`, assert `builds.count(.nameIndex) == 1` and `builds.count(.reader) == 1`, which are B's. At 7b6e69699 both read 2, so run it there first and record the failure (QA 1). Agent: lge-worker, sonnet, effort max.

2. should. `Tests/LungfishAppTests/ReferenceOpenManifestLoadTests.swift:206` (after the last test, before the class brace at `:207`). Pin that the index builds hold the lane, which the brief asks to keep and no test shows. Test `testIndexBuildsHoldTheDecodeLane`. Call `BundleDecodeLane.overrideLargeFileBytes(0)` so every manifest counts as large, and `overrideLargeFileBytes(nil)` in `tearDown`. Give `SequenceIndexBuildLog` an `install(parkingFirstNameIndexOn gate: BundleDecodeGate)` whose observer records the build and then calls `gate.waitForRelease()` for the first `.nameIndex`. Start `Task { await MainSplitViewController.loadReferenceBundleOffMain(at: bundleA) }` and `waitUntil(timeout: .seconds(30)) { builds.count(.nameIndex) == 1 }`, so A sits in its index build with the lane held. Start the same for `bundleB` and `waitUntil` `BundleDecodeLane.waitingCount == 1`. Assert `decodes.count(.bundleManifest) == 1`. Release the gate, await both tasks, and assert both results are `.success`, `decodes.count(.bundleManifest) == 2` and `builds.count(.nameIndex) == 2`. If `prepareSequenceAccess()` ever leaves the lane's work closure, B's decode starts during A's build and the first count reads 2. Agent: lge-worker, sonnet, effort max.

3. should. `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift:615`. Copy Sequences builds a second bundle. The provider made here has no bundle, so its first fetch makes one (`BundleDataProvider.swift:216`) and builds a second name index and a second `.fai` parse for every Copy action. The ruling puts a SILVA bundle's name index near 64 MB and its reader index near 110 MB (`SWIFT-fai.md:266`). Replace the line with:
```swift
        let provider = BundleDataProvider(bundleURL: bundleURL, manifest: manifest, referenceBundle: input.preparedBundle)
```
`preparedBundle` is set for the direct input of an open and nil for any other input, which keeps today's behavior there. The file stays at its 1935 baseline. Run `--filter ReferenceBundleViewportControllerTests --filter ReferenceOpenManifestLoadTests`. Agent: lge-worker, sonnet, effort max.

4. should. A check, not a code change. Run `swift test --skip-update --filter IORegressionTests --filter BgzipReaderRegressionTests` at the landing head and record the exit code and counts in the landing note. The brief says to run the `--filter` sets of P6's report. P6.md line 27 names both classes in its M2 run, and neither `sets-run.log` mentions them (`grep -c` gives 0 in both). The risk is low, because the diff adds only an observer hook to `ReferenceBundle+SequenceAccess.swift`. Agent: lge-worker (landing), sonnet, effort max.

## Checks

| Id | Result |
|---|---|
| SWIFT 1 | Pass. The four patterns the hatch ratchet counts (`scripts/ratchets/concurrency-hatches.sh:31-37`) are in no added line of the Sources diff, which I scanned, and the seam's `OSAllocatedUnfairLock` is not one of them. No `Task.detached` or GCD hop is added. The new work runs inside P2's existing detached task (`BundleDecodeLane.swift:55`). Both open tasks read `self` after a weak guard and commit with no `await` after the guards (`ContentDisplay.swift:809-826`, `:920-955`). The seam calls the observer after its own lock is released (`ReferenceBundle+SequenceAccess.swift:50`), and the test observers take no cache lock. |
| SWIFT 2 | Pass. The bundle, the name index and the reader moved to the detached task, and the commit sites add no read, hash, query or load on the main actor. Two older main-actor loads on the same open are outside this range (Notes a). |
| SWIFT 5 | Pass, with fixes 1 and 3. One open builds one name index and one reader, and the tests count them (`nameIndexBuildCount == 1`, `readerBuildCount == 1` and one of each across all bundles). |
| SWIFT 7 | Pass. FIDX-2's `load-run.log` ran both classes with `cores=14` and `exit=0`, and 6 of 6 passed (`:126`, `:133`, `:143`). The two new tests took 2.21 s and 0.158 s there against 0.768 s and 0.099 s idle in `fix-run1.log:851`, `:858`, so the machine was loaded. The run covers FIDX's test too, which the FIDX report had not repeated under load. No test uses a time threshold, and every wait is a 30 s `waitUntil`. |
| ARCH 6 | Pass. `ContentDisplay.swift` is 1048 lines against a baseline row of 1048 (1047 after FIDX alone). `ReferenceBundleViewportController.swift` is 1935 against 1935 and `ViewerViewController+BundleDisplay.swift` is 871 against 871. No new file. `BundleOpenLoading` is 137 lines and `ReferenceBundle+SequenceAccess.swift` 267. No ratchet rises, and no public type is added, so the module map needs only the landing's line-count regeneration. |
| QA 1 | Pass. Each test fails at its base. FIDX `base-run.log:10601` and FIDX-2 `base-run2.log:107` end in "exited with unexpected signal code 5" at the named test, which is the `dispatchPrecondition` in the seam. Both tests pass at the FIDX-2 head (`fix-run1.log:850-858`, `load-run.log:126`, `:133`). The seam ships with the fix in one commit, which is allowed for a defect fix. |
| QA 2 | Pass. Both tests read bundle counters, build counts and the thread of each build. Neither reads a Sources file, and the diffs add no source-text assertion. |
| QA 6 | Pass, with a note. The tests use `TestTempDirectory`, 30 s `waitUntil` and no `UserDefaults.standard` write of their own, and both classes remove the process-wide observer in `tearDown`. The failure mode is a process trap, as the ruling asks, so a regression ends the whole test process at that test and hides the later ones. The counts are global over all bundles, so a stray background open from an earlier test could add a build in that window. I judge that very unlikely for fixtures this small, and no fix is needed. |

## Notes for the manager (no fix in this range)

a. Main-actor work that remains on a direct open (SWIFT 2, outside this lane). `configureDirectBundleRows` calls `BundleBrowserLoader().load` on the main actor (`ReferenceBundleViewportController.swift:654-661`). Unless the manifest carries a `browserSummary` (`Sources/LungfishOperations/BundleBrowserLoader.swift:48`), the call reads a SQLite mirror in the project (`:54`, `:70-72`), and when none exists it builds the summary from the manifest and writes it back (`:58-59`). Every track-adding manifest edit resets `browserSummary` (`Sources/LungfishCore/Bundles/BundleManifest.swift:639-768`). I did not check whether the SILVA bundle carries one. For record-store references, `loadRecordTableContent` makes a third bundle and reads the record store's SQLite on the main actor (`ReferenceBundleViewportController.swift:701-711`). It builds no index, so it does not undo this lane. The owner's open of the real SILVA bundle is the measure, as both reports say, and these are the first suspects if a stall remains.

b. FIDX-2 finding 4 and open question 2. `configure(result:resultDirectoryURL:)` (`ReferenceBundleViewportController.swift:1619-1641`) has no production caller. Its only route is `ViewerViewController.displayMappingResult(_:resultDirectoryURL:)` (`Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift:95-132`), and no file under `Sources` calls `displayMappingResult` (git grep at 7b6e69699). Leave it for Phase 3 or delete it as dead code.

c. FIDX open question 2 and FIDX-2 open question 1 are moot. `ContentDisplay.swift` is back at 1048, its baseline row, with no headroom, so a later lane that adds a line there must remove one. FIDX open question 1 was taken by FIDX-2.

d. Merge with T1. T1 edits the same two test files. Its hunks sit at base lines 60-62 and 76-78 of `ReferenceOpenManifestLoadTests.swift` and 39-41 and 54-56 of `MappingOpenManifestLoadTests.swift`. FIDX touches lines 6-14, 39-53 and 150-155 of the first file, and FIDX-2 lines 5-12, 17-24 and 52-56 of the second. The last pair is separated by one unchanged line, so a three-way merge should be clean. I judged this from hunk ranges and ran no merge.

e. Not traced, for the owner check list. `reloadViewerBundleForInspectorChanges` (`ReferenceBundleViewportController.swift:841-847`) re-displays from the input's held manifest and, since FIDX, its held bundle (`:830-836`). Callers write a track to the bundle and then reload (`Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift:534-551`). FIDX adds no new staleness, because the bundle and its manifest come from one open, and the held-manifest rule is P2's. An owner check of adding an annotation to an open reference and seeing it appear covers it.

## Not verified

I ran no build, test, ratchet script or GUI. I read the lane logs only for the lines cited above. The ratchet scripts scan the working tree, which sits at the base, so I took sizes from `git grep -c` at the heads against `file-size.baseline` and the hatch patterns from the added lines. The reports ran file-size, concurrency-hatches, source-text-assertions and process-spawn. The other ratchets (`path-helpers`, `volume-portability`, `provenance-writers`, `tool-identity`, `native-tool-runner-in-app`, `cli-parity-gaps`, `unchecked-operation-start`, `shared-slider-control`) count subjects that the added lines do not contain, such as helper declarations, renames, writers and tool launches. The real stall time for SILVA is unmeasured, as in both reports.

Verdict: Merge
Section 2. Test batch T1, the Sources hunk only, bd6923426dddcca80bc5d5813ec5c686a05c5b7a..4ff7a6fa73eb4b912edb685a2c96d8722264d498 (commit 180fe34e8: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` and `Sources/LungfishApp/Views/Inspector/InspectorViewController+Notifications.swift`).

Reviewer. The same agent as section 1: lge-expert, field SWIFT (letter S), on sonnet (claude-sonnet-5-5) at effort max. Checks carried: SWIFT 1, SWIFT 2, ARCH 6, QA 2. I read the T1 report, the Sources diff, `reviews/P1.md` Fix 7 and the new test in the diff, and the touched code with git show and git grep at 4ff7a6fa7. I built and ran nothing. Every `path:line` is at 4ff7a6fa7.

## In brief

0 must fixes and 0 should fixes. The hunk is the seam that `reviews/P1.md` Fix 7 prescribes, built as written. A stored closure `lineageReadyAnnouncer` holds the VoiceOver post and the guarded method calls it. The post is the same call with the same keys. The only text that moved is the literal "Lineage ready", which the caller now passes.

## What the hunk does

- `InspectorViewController.swift:133-144` adds `var lineageReadyAnnouncer: (String) -> Void`. Its default posts `NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])`. The file goes from 582 to 595 lines.
- `InspectorViewController+Notifications.swift:495-498` keeps the guard (Provenance tab selected, view loaded, in a window, not hidden) and replaces the inline post with `lineageReadyAnnouncer("Lineage ready")`. The file goes from 589 to 582 lines.
- The announcement is raised from `onLineageReady` (`Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift:509`), which `+Notifications.swift:466-467` points at the method.

## Checks

| Id | Result |
|---|---|
| SWIFT 1 | Pass. None of the four counted hatch patterns is in the hunk. The default closure is formed in the property initializer of a class that inherits `NSViewController`'s main-actor isolation, and its only caller is the main-actor method at `+Notifications.swift:495-498`. It captures nothing, so there is no cycle with `self`, and the property is per instance, so a test's recorder cannot leak into another test. |
| SWIFT 2 | Pass. The post still happens on the main thread, once per `onLineageReady`, behind the same guard. The seam adds no read, hash, query or wait. |
| ARCH 6 | Pass. Both files are under 800 lines and neither is a row of `scripts/ratchets/file-size.baseline`, whose Inspector rows are `+MetadataImport` (1062) and `+PublicAPI` (991). No new file, hatch, process spawn or public type. |
| QA 2 | Pass. The seam lets `InspectorProvenanceTabTests.testLineageReadyIsAnnouncedOnlyWhileTheProvenanceTabShows` (read in the diff, not rerun) assert the recorded strings: `[]` after the lookup, with another tab, outside a window and hidden, then `["Lineage ready"]` once. That reads output, not source text. No test runs the default closure, as before the change. |

## Numbered fixes

None.

## Notes

- Fit with the item. P1.md Fix 7 asks for a stored property in `InspectorViewController.swift`, a default that posts as now (`element: NSApp as Any`, `.announcementRequested`, medium priority) and a call after the guard. The hunk matches. T1 added a hidden-view clause to the test, which matches the last term of the guard.
- QA 1, not among the checks asked here. The seam is in the same commit as the pins, and QA 1 asks a pin commit to leave `Sources` alone. Fix 7 names the seam and T1's finding 1 says the same, so I accept it. A landing that wants a strict split can cherry-pick the two Inspector files first.
- Conflicts. The hunk touches no file of section 1. The test files that both ranges edit merge as note d of section 1 says.

