Verdict: Merge
Section 1. P1 fix e9f6097ed552ad91abe744290427f95323ef665d..71b512b5ba72b3db1a5d596e2868fb808421f626, answering reviews/P1.md fixes 1, 2, 3, 5 and 6.

Reviewer. lge-expert, field SWIFT (letter S), on sonnet (claude-sonnet-5-5) at effort max. One agent wrote both sections. I read the two review files, the two fix reports and the two diffs, then the touched files with git show at each fix head. I built and ran nothing and started no agent. About 60 tool calls. Every `path:line` is at the head named in its section, and the few lines in test files that I derived from a diff hunk header are marked "per the hunk".

## In brief

All five fixes do what the review asked. The two must fixes of the review (1 and 2) each have a behavior test that failed at the lane head on assertion text and passes at the fix head. No hatch, process launch or baselined file grew. No must fix remains. Three should fixes follow, all about landing and evidence.

## Did each fix do what the review asked

- Fix 1, the exporter opts out of the walk's cancel. Done. `Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift:234-238` passes `isCancelled: { false }` (on `:237`). The exporter builds a resolver in one place only (`git grep`: `:236`, plus the view model default at `ProvenanceInspectorViewModel.swift:432`), so `exportBundle` and the pin gate, which both read the chain through `expandProvenanceChain`, are covered. The file is 1604 lines, equal to its baseline (`scripts/ratchets/file-size.baseline:191`, `wc -l` at the head). The compacted call is right, because the review's three-line layout broke that ratchet.
- Fix 1 test. `ProvenanceExporterTests.testExportIgnoresTaskCancellation` (`Tests/LungfishWorkflowTests/Provenance/ProvenanceExporterTests.swift:107-137`) cancels a detached task, runs `exportBundle` and `expandProvenanceChain` in it, decodes the written `provenance.json` and asserts the steps `["clumpify.sh", "minimap2", "bcftools"]` and three sidecar URLs. It reads outputs only.
- Fix 2, a read error is not a record. Done. `ProvenanceSidecarIndex.swift:175-196` adds `SidecarRead`, and the loop at `:99-110` does `continue` on `.unreadable` and stores nothing. I traced two cases. A sidecar that had an entry and now cannot be read keeps the old entry, but `makeSnapshot` refuses it because `matches` fails (`:143`), so no stale record is served, `complete` goes false and `keep` caches nothing (`:363`). A sidecar that stays unreadable costs one failed open and one pass over the entries per walk.
- Fix 2 test. `ProvenanceLineageResolverTests.testUnreadableSidecarIsReadAgainByTheNextWalk` (`:279-308`) sets mode 000, walks, restores 0o644 (same size and date), walks again, and asserts the whole chain and two reads of the import sidecar. The restore is in a `defer` (`:290`). The skip guard (`:291`) fires only for a user who can read a mode 000 file, and `final2.log:313-314` shows the test ran and passed.
- Fix 3, isolation. Done. Three lookup tests build the view model on `ProvenanceLineageResolver(sidecarIndex: ProvenanceSidecarIndex())` (`ProvenanceInspectorViewModelTests.swift:1163-1167`, `:1198`, `:1236-1238`, per the hunks) and `makeTempDirectory()` calls `TestTempDirectory.make` (`:1325`, per the hunk). This isolates the fold, because the fold reads the resolver's own index (`ProvenanceInspectorViewModel.swift:475` and `:491`) and not the shared one. The agent's departure at `ProvenanceLineageResolverTests.swift:201-207` (one private index for both walks) is right, since two fresh indexes would read six sidecars and break the once-per-project count.
- Fix 5, one resolve per distinct string. Done. `ProvenanceSidecarIndex.swift:408-420` memoizes inside `init(_ light:context:)`. Every path-bearing string goes through `resolved` (`:421-431`). The memo is a local that dies with the init, and the result depends only on the text and the fixed context, so the entry equals the old one.
- Fix 6, cheap `invalidate`. Done. `SidecarEntry.folder` is set in `store` (`:325-330`), `dropSidecars` collects only what it drops and returns before touching `version` when nothing drops (`:335-345`), and the closure at `:70-72` makes two set lookups with no `NSString` bridge. Worst case is 4 projects of 4,000 entries, about 32,000 lookups. My estimate is a few milliseconds on the main actor against tens before. I did not measure it. `testChangedSidecarIsReadAgainByTheNextWalk` (`:246-277`) covers a file report and a folder report and passed (`final2.log:305-306`).

## Defect fixes and their failing-first runs (QA 1)

`build/lane/fail-first.log:8706-8714` in the fix worktree ran both new tests at e9f6097ed. Both failed on assertion text, not on a compile error. The exporter test saw `["bcftools"]` and no sidecar URL. The unreadable test saw the short chain and one read where two were expected. The tree of that run was the lane head plus the two tests and is not a commit, so the log is the only evidence, as it was for the lane review. `final2.log:274`, `:314` and the `exit=0` at `:1552` show both pass at the head.

## Numbered fixes

All three are should and none blocks the merge. The agent for each is lge-worker on sonnet at effort max.

1. should (QA 6, landing). Land `c3339a39a`, `98550002e` and `71b512b5b` as one unit, by merging the branch or by one squash. `c3339a39a` alone puts `ProvenanceExporter.swift` at 1607 lines against the 1604 baseline, as the report's deviation 1 says, so a one-by-one cherry-pick fails the file-size ratchet at the first commit.
2. should (SWIFT 7). Run the load pass of reviews/P1.md fix 8 after landing, with `ProvenanceExporterTests` added to its three filters, and put the exit codes in `lanes/P1/P1-fix.md`. The report ran nothing under load. By inspection both new tests use no clock, no wait and no ordering between tasks, so I expect a pass.
3. should (SWIFT 5, evidence). Take the measurement of reviews/P1.md fix 9 at 71b512b5b and not at e9f6097ed, so the numbers include fix 5. Keep that fix's 5 minute rule for the persisted index.

Still open from reviews/P1.md and outside this range, as the report's handoff says: fixes 4, 7, 8, 9 and 10. The baseline lowering of fix 10 (`ProvenanceInspectorViewModel.swift`, `file-size.baseline:24`) waits for the landing head.

## Checks

| Check | Result |
|---|---|
| SWIFT 1 | Pass. The source diff, read whole, adds no `@unchecked Sendable`, `nonisolated(unsafe)`, `assumeIsolated`, `Task.detached`, dispatch hop or process launch, so `concurrency-hatches` and `process-spawn` stay flat by inspection. I did not rerun the scripts. The lock bodies are unchanged. |
| SWIFT 2 | Pass. Fix 6 takes the `NSString` bridge and the dictionary copy out of the main-actor `invalidate`. Fixes 2 and 5 run in the detached walk. The older main-actor walks named in reviews/P1.md are unchanged and outside this range. |
| SWIFT 5 | Pass. Fix 5 cuts repeated file system checks per sidecar. The first-build time on the real project is still unmeasured (fix 3 above). |
| SWIFT 7 | Fix 2. |
| QA 1 | Pass. Fixes 1 and 2 show the failing run above. Fixes 3, 5 and 6 are not defect fixes and rely on existing tests. |
| QA 2 | Pass. Both new tests read written records, tool names, URL names and event counts. The test diff adds no `.contains("` over source text, so `source-text-assertions` does not rise by inspection. |
| QA 6 | Pass. `TestTempDirectory` in the new test and in `makeTempDirectory()`, no `UserDefaults`, no process wait, no clock, a private index in every test that counts reads. |
| ARCH 2 | Pass. The Inspector keeps the default `{ Task.isCancelled }` and the writer does not inherit it. |
| ARCH 6 | Pass. `ProvenanceExporter.swift` 1604 equals its baseline. `ProvenanceSidecarIndex.swift` is 569 lines and the new test file 138. No ratchet file is in the diff. |

Note with no fix. `indexedRecord(at:)` reads a legacy-layout sidecar twice, once in `Data(contentsOf:)` (`ProvenanceSidecarIndex.swift:189`) and again inside `readRecord` (`:194`). If only the second read fails, the result is still kept as `.noRecord`. The window is the gap between two reads of one file and the base had the same double read, so I do not ask for a change.

---

Verdict: Merge
Section 2. P2 fix A d94b56573eec8c932017d7a07128207d515fc925..93e4b359890ce93980535b96b94b00177a2fb3e2, answering reviews/P2.md items 1, 2, 4, 5 and 6 (BundleManifest part).

Reviewer. Same agent, lge-expert on sonnet (claude-sonnet-5-5) at effort max, field SWIFT (letter S). Line numbers in logs are the logs' own, and a line derived from a diff hunk is marked.

## In brief

Every item does what the review asked. Item 5 departs from the review's sketch and the departure is right. A cancel of `bundleOpenTask` never reaches a `Task.detached`, so the sketch's `Task.checkCancellation()` inside the existing detached closure could not fire. The new helper forwards the cancel into the detached task instead. Items 1, 4 and 5 each have a failing run before the change. On the four checks the owner and the manager set for item 5, all four hold. Peak memory is bounded to one large decode in flight, no decode runs on the main actor, a cancel cannot leave the lane held, and a reference open and a mapping open cannot deadlock. No must fix remains and four should fixes follow.

## Did each item do what the review asked

- Item 1, the toast. The review's four lines, exactly (`Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift:808-813`). `hide()` now runs before the stale-token guard. `testOpenSupersededByAnotherItemHidesItsToast` (`Tests/LungfishAppTests/ReferenceOpenManifestLoadTests.swift`, assertion at `:151`) failed at d94b565 with "the superseded open left its Loading toast on screen" (`build/lane/head-run.log:165-167`) and passes at the head. The mapping route shows no toast (`ContentDisplay.swift:904-960` holds no `activityIndicator.show`), so it needs no hide.
- Item 2, the ruling's tests. Both added as the review wrote them. `testSupersededOpenCommitsOnlyTheNewSelection` also passed at the lane head (`head-run.log:170-171`), so it is a pin and not a defect test, which is what the review asked for. The probe gate holds only the manifest decode of one named bundle (`BundleDecodeLog.install(offMainOnly:holding:on:)`, `ReferenceOpenManifestLoadTests.swift:19-31`, per the hunk), as the review specified.
- Item 4. (a) `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportInput.swift:62` puts `lhs.name == rhs.name` first. (b) `MainSplitViewController+BundleOpenLoading.swift:41` reads `stamp` before the decode and `:56` passes it. `ReferenceViewportIdentityTests.swift:24-41` and `:46-73` both failed with the source reverted (`build/lane/fix4-head-run.log:233-236`) and pass at the head (`fix-final-run.log:7560-7563`).
- Item 6, the BundleManifest part. `Sources/LungfishCore/Bundles/BundleManifest.swift:582-583` reads with `.mappedIfSafe`. LGE does not truncate a mapped manifest in place. `save` goes through `DurableReplace` (`:812-820`) and every other manifest writer in my `git grep` uses `.atomic`. Two plain writes remain (`Sources/LungfishIO/Bundles/ReferenceSequenceFolder.swift:97`, `Sources/LungfishWorkflow/PrimerAnalysis/PrimerOrderExportService.swift:379`). I did not read them. Their names say a folder and an export, and neither is the save of an open reference bundle's manifest. The `MappingResult` half is already in P5 (below).

## Item 5, the decode lane

`BundleDecodeLane` (`Sources/LungfishApp/Views/MainWindow/BundleDecodeLane.swift`, 94 lines) is an actor with one synchronous method, so its executor is the gate.

- One large decode at a time. `run` (`:80-84`) calls `work()` synchronously on the actor. A second `run` waits in the actor's queue, suspended, and holds no thread. Files of 64 MB or less skip the lane (`:23`, `:75`, `:86-93`). By the review's ratio (2.3 GB for 706 MB) such a decode peaks near 3.3 times its size, about 210 MB at the cut, so five quick clicks on small bundles cost about 1 GB at most.
- Bounded peak. At most one decode is in flight. Beyond that the process holds the displayed document's manifest and the finished results waiting for the main actor to drop them. That is normally one result, because `run` returns, and frees the lane, before the open's task hops to the main actor. A mapping open keeps its decoded result while its viewer manifest takes the lane (`MainSplitViewController+BundleOpenLoading.swift:42-50`), so its peak is that result plus one manifest decode. The 2.3 GB figure is the review's and I did not re-measure it. Of that figure, 676 MB was the resident `Data` that item 6 now maps. Before the lane, five clicks held five peaks at once, which the agent's scratch run showed as three overlapping decodes (`head-run.log:176`).
- No decode on the main actor. Both open bodies run in `Task.detached` (`BundleDecodeLane.swift:55`), and the `isLarge` stat runs there too (`:75`, `:88`). `Package.swift` enables no upcoming feature (my grep for `enableUpcomingFeature` and `NonisolatedNonsending` found none), so a `nonisolated async` function does not inherit the caller's actor. Every lane test installs a probe that traps with `dispatchPrecondition(.notOnQueue(.main))` (`ReferenceOpenManifestLoadTests.swift:22-24`).
- A cancel cannot leave the lane held. The lane keeps no state past a call, so `run` frees the executor on return, on throw and on cancel. The waiting counter is symmetric. It rises before the hop (`:76`) and falls on the first line of `run` (`:81`), ahead of the cancel check (`:82`). A cancelled caller still reaches `run`, because an actor hop is not skipped by cancellation. `BundleDecodeLaneTests.swift:65-66` drains it to zero. `offMain` forwards the open's cancel to the detached task (`:62-66`), so a queued decode throws `CancellationError` at `:82` and never starts. A decode already running cannot be stopped. Its open drops the result, as the comment at `:15-18` says.
- No deadlock when a reference open and a mapping open overlap. A mapping open takes the lane for the result, lets go, and takes it again for the viewer manifest (`MainSplitViewController+BundleOpenLoading.swift:42-44`, `:48-50`). It holds the lane across neither wait. The `work` closures are synchronous (`@Sendable () throws -> T`), so none can await the lane. The main actor never waits on it, and the two unfair locks are never nested (`:25`, `:28`). There is no hold-and-wait, so no cycle. One lane serves both kinds and `bundleOpenTask` is shared (`MainSplitViewController.swift:473`), so the later open cancels the earlier open's queued decode whichever kind each is. No test overlaps the two kinds (fix 1 below).

## Rulings on the report's findings

1. Wider hide (finding 1). Accept as shipped. The review accepted an early hide for a newer reference open, and every pane carries its own progress under Q-S1. Fix 4 below puts it in the GUI check.
2. MSA and MHC toasts (finding 2). Agree it is outside this range and older.
3. A show swallowed during a hide animation (finding 3). Agree. `show` sets the label but leaves `isVisible` true until the 0.25 s completion (`ActivityIndicatorView.swift:154-181`, `:199-216`). It predates P2.
4. `CancellationError` (finding 4). No change. `try?` at `BundleOpenLoading.swift:48` turns a cancelled wait for the viewer manifest into a nil manifest, and a cancelled first decode becomes `.failure(CancellationError)`, which a route's catch block would show as "Unable to load". Both are dropped by the stale-token guard today. Ten of the 12 call sites in my `git grep` of the two routes pass no token and so begin a newer one. The other two pass the token `displayContent(for:)` made for that selection (`ContentDisplay.swift:81`, `:183`, made at `:37-38` by the report's account, which I did not read).
5. `beginDisplayRequest` does not cancel `bundleOpenTask` (finding 5). Accept. The bound holds without it. The cost is one useless queued decode when the user leaves for another kind of item and never opens another reference or mapping.
6. P5 and the file list (finding 6). Checked below, and it holds.
7. Mapped read and an outside writer (finding 7). Accept. See item 6 above.

Costs accepted, no fix. (a) An open that follows a running large decode now waits for the rest of it, where the base ran the two at once. A mapping opened onto a reference whose decode is still running is the plain case. The review asked for this trade for a 16 GB Mac. Only the slim manifest work of 2.12 removes it. (b) A read that hangs on a dead volume holds the lane until it returns, and every later large open waits. (c) Other sites still call `BundleManifest.load(from:)` outside the lane (`ReferenceBundleViewportController.swift:645` and `:1661`, `InspectorViewController+PublicAPI.swift:292`, `ViewerViewController+BundleDisplay.swift:787`, `MainSplitViewController+NakedBundleReference.swift:70`, `MainSplitViewController+ClassifierDisplay.swift:55`, `AppDelegate+ReferenceBundleResolution.swift:83`, `SidebarViewController+MenuDelegate.swift:468`, `:481` and `:603`). They predate this range and I did not trace which run on the main actor or when. The lane bounds the open path and not these.

## Numbered fixes

All four are should and none blocks the merge. The agent for each is lge-worker on sonnet at effort max.

1. should (QA 1, QA 2, SWIFT 1). Add `BundleDecodeLaneTests.testMappingAndReferenceOpensShareTheLane` after `Tests/LungfishAppTests/BundleDecodeLaneTests.swift:105`. No test overlaps a mapping open with a reference open, and none sends a mapping result through the lane, so the file list in `savedMappingResultFiles` (`MainSplitViewController+BundleOpenLoading.swift:61-65`) has no pin. Steps. Call `BundleDecodeLane.overrideLargeFileBytes(0)`. Build reference bundles R and V and a mapping result folder M onto V with `MappingRoutingFixture.makeMappingResult(resultDirectory:viewerBundleURL:)`, as `ReferenceViewportIdentityTests.swift:49-56` does. Install a `BundleLoadProbe` closure that records each decode with its kind and waits on a `BundleDecodeGate` when the kind is `.mappingResult`. Display M and wait until its decode is recorded. Display R and wait for `BundleDecodeLane.waitingCount == 1`. Assert that no `.bundleManifest` decode is recorded yet, since R must queue behind the held result decode. Release the gate and wait for the viewport to show R's rows. Assert `waitingCount == 0` and that the manifest decodes recorded are R's alone, because R's open cancelled M's, whose viewer manifest then throws at `BundleDecodeLane.swift:82`. Optional, in the landing commit of whichever of P2 and P5 lands second. Add `static func savedResultFileURLs(in:)` beside `savedResultModificationDate` (`MappingResult.swift:261` at f344ac21e), returning the two file names as URLs. Call it at `BundleOpenLoading.swift:42` and delete `:61-65`, so the two lists cannot drift.
2. should (SWIFT 7). Add `BundleDecodeLaneTests`, `ReferenceViewportIdentityTests` and the two new methods of `ReferenceOpenManifestLoadTests` to the load pass of reviews/P2.md fix 15. The report ran them on an idle machine. The gate's wait ends at 30 s (`ReferenceOpenProgressTests.swift:16`), so under extreme load a hold that outlasts it would release the decode early and change the order the tests assert. With 14 busy loops the margin is wide, and any failure is a defect of the test.
3. should (SWIFT 5, check). The memory bound above is argued from the code, and the figures are the review's. Add a reading to the GUI check of reviews/P2.md fix 16, run with Computer Use. On the 905,628-sequence scratch project, click three large references in quick succession and run `footprint` on the Lungfish Debug process when each decode ends. A footprint that climbs by a whole decode per click means a site bypasses the lane. Put the three numbers in the lane report.
4. should (UX, GUI). Add one line to that same check. Start a FASTQ load while a stale reference decode is still running, and see whether the FASTQ's toast survives the stale decode's end, because `ContentDisplay.swift:811` hides whatever toast is up. If it is lost, the fix is `hide(ifMessage:)` on `ActivityIndicatorView` (`hide()` at `:199` takes none) and one call in `BundleOpenLoading.swift`, so `ContentDisplay.swift` does not grow past its baseline.

## Checks

| Check | Result |
|---|---|
| SWIFT 1 | Pass. The lane holds no actor state across an `await`, since its only state is two unfair locks that are never nested. `Task.detached` at `BundleDecodeLane.swift:55` sits in no task-local scope, as the base's detached call did. The diff adds no `assumeIsolated`, `@unchecked Sendable`, `nonisolated(unsafe)`, `Process()` or `.terminate()`, so the ratchets stay flat by inspection. I did not rerun them. |
| SWIFT 2 | Pass for the helper and both routes. The stat, the decode, the provenance read and the stamp all run in the detached body. Residual sites are under costs accepted (c). |
| SWIFT 5 | Pass with fix 3. One large decode in flight, a mapped read, and no second decode of the same manifest on the open path. |
| SWIFT 7 | Fix 2. |
| QA 1 | Pass. Items 1 and 4 have the failing runs cited above. The committed lane tests of item 5 cannot compile at d94b565, since they use `BundleDecodeLane`, so the agent's uncommitted scratch test ran at the lane head and failed with the overlap (`head-run.log:175-176`). I accept that. Item 6 has no test, being an allocation change. Item 2 is a pin. |
| QA 2 | Pass. Assertions read decode paths and counts, displayed names, the viewport object, the indicator state and the input's date. No `.contains("` over source text is added. |
| QA 3 | Pass for both sections. No test catalog names the new classes (`git grep` of three test class names over `scripts`, `docs`, `Tests/Support` and `Package.swift` found none), and no test here is a real-tool test. |
| QA 6 | Pass. `TestTempDirectory` in every new test, 30 second waits, no `UserDefaults`. The DEBUG override and the probe reset in `tearDown` (`BundleDecodeLaneTests.swift:17-21`) and every gate has a `defer { gate.release() }`. |
| ARCH 1 | Pass. The lane is internal to LungfishApp and the LungfishCore change is one read option. Nothing public is added, so `docs/architecture/MODULES.md` needs no row. |
| ARCH 6 | Pass. `MainSplitViewController+ContentDisplay.swift` is 1048 lines against a baseline of 1050 (`scripts/ratchets/file-size.baseline:30`) and `BundleManifest.swift` is 822 against 823 (`:85`), both by `wc -l` at the head. New files are 94, 106 and 74 lines. Each of the two grew one line over the lane head and stays under its baseline, so lower the baselines once at the end of the series, as reviews/P2.md answered. |
| UX 4 | Pass. A superseded or cancelled open ends with no alert and now takes its toast down. |

## Lane P5 (f344ac21ea8ea030baf256c6e52049af347130d8)

No conflict with P2 fix A by file or by line. P5 changes 17 files against d94b565 and fix A changes eight, and the two sets share none (`git diff d94b565 f344ac21e --stat` against the fix A stat). P5's sources are `MappingResult.swift`, `ReferenceBundleViewportController.swift`, its `+OpenProgress` extension, `MappingSummaryBuilder.swift`, `ManagedMappingPipeline.swift` and two new builders. Both lanes start from d94b565, so they merge in either order. Four things hold at the P5 head and I read each.

- `MappingResult.load` still opens with `BundleLoadProbe.willDecode(.mappingResult, at:)` (`Sources/LungfishWorkflow/Mapping/MappingResult.swift:268-269`), so the result decode count in `MappingOpenManifestLoadTests` and the stamp test keep their hook.
- The two names that `savedMappingResultFiles` repeats (`Sources/LungfishApp/Views/MainWindow/MainSplitViewController+BundleOpenLoading.swift:63-65`) are unchanged at `MappingResult.swift:178-179`, in the order `load` reads them (`:273`, then the legacy file). Schema 2 keeps `mapping-result.json`, so a large schema 2 result still takes the lane.
- P5 already maps its read (`:276`, `.mappedIfSafe`), which completes item 6. Its saves go through `DurableReplace.replace` (`:255`), so a mapped read is never truncated, and each save gives the file a new date, which the identity compare and the stamp test depend on.
- `referenceCount` and `unalignedReferenceCount` join the synthesized `Equatable` of `MappingResult`. Only the in-memory branch of `==` reads it (`ReferenceBundleViewportInput.swift:54`), so a saved result is still compared by its date.

One pointer that is not about fix A. P5 also changes `MappingSummaryBuilder.swift` (41 lines) and `MappingSummaryBuilderTests.swift` (160 lines), the two files that the other P2 fix agent's item 8 edits (`MappingSummaryBuilder.swift:386`). I did not diff those two, so the check of that fix agent should look for a conflict there.

## Not verified

I built and ran nothing. Every claim about run-time behavior comes from reading the code at the two fix heads and from the agents' logs. I did not measure peak memory. I did not check which volumes Foundation maps under `.mappedIfSafe`, so on a volume it judges unsafe, such as an external drive, the read may be an ordinary one with no saving. I did not trace which main-actor sites call `BundleManifest.load(from:)`. Some test-file line numbers come from diff hunks or logs and are marked where they do.
