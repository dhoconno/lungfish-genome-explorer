Verdict: Merge after fixes

Reviewer. `lge-expert`, the UI and UX expert of the panel (field UX, letter U), ran at sonnet (Sonnet 5.5) at effort max.

Lane UB, head `2fcf513b3ecf11b4ea4dc732bdf3c6e91c0d464b`, base `65539ddcd2fbe756390d0890cda0b5181e77ffc0`. Every `path:line` is at the lane head. Checks carried. UX 1, UX 5, UX 6, UX 7, SWIFT 2, ARCH 6, QA 1, QA 2.

Method. I read the review brief, the lane brief, the ruling lines it names, the lane report and the whole diff (11 files), then the surrounding files with `git show`. I read the lane's five test logs under `.claude/worktrees/agent-a6275ba2ff08f6310/build/lane/`. I built and ran nothing.

Result. The lane builds Q-U1, Q-U2 and Q-U3 as ruled, in the files the ruling names, one commit per milestone item. Every ruled label, hint, help text, identifier and menu position matches (tables below). One must fix remains. On a real record, a Lineage step with a recorded stderr gives a Copy Step text that ends with a newline, and Copy All Steps then shows two blank lines after it, which breaks Q-U2 rules 1 and 7 (fix 1). Fixes 2 to 4 are should-level. The Document tab work, the part the owner reported, has no must.

## Numbered fixes

Agent for every fix. `lge-worker`, sonnet, effort max. After fixes 1 to 3 it runs `swift test --skip-update --filter ProvenanceStepCopyTests --filter MappingDocument --filter ProvenanceSectionSourceTests` and reports the counts.

### Fix 1 (must). The Provenance Copy Step text ends with the newline of a recorded stderr

Evidence.
- `ProvenanceInspectorViewModel.swift:1071-1074` writes a fact's value untrimmed, and `ProvenanceInspectorViewModel+StepTermination.swift:212` makes stderr the last line of a step.
- A recorded stderr ends in a newline. `Sources/LungfishCore/ProvenanceStderr.swift:11-14` keeps up to 10,240 characters whole, and the kraken2 golden record's stderr ends `(1.82%)\n"` at `Tests/Fixtures/golden/classifiers/kraken2/lungfish-provenance.json:658`.
- So `stepCopyText(of:)` (`ProvenanceInspectorViewModel+StepCopy.swift:12-16`) ends with `\n` for such a step. Q-U2 rule 1 says no trailing newline and rule 7 says one blank line between steps, yet `allStepsCopyText` (`:19-21`) joins with `\n\n` after it, which leaves two.
- The assertion at `ProvenanceStepCopyTests.swift:42` (`XCTAssertFalse(texts.contains { $0.hasSuffix("\n") })`) holds only because its fixture step has no stderr.

Change. Keep `stepCopyText(of:)` as it is, so the header's Copy text stays byte-identical (UX 5, no fixture moves). Give the clipboard routes a trimmed text.
1. `Sources/LungfishApp/Views/Inspector/InspectorStepCopyText.swift`, after line 39, add

```swift
    /// `text` without the line ends it finishes with, which a recorded stderr carries.
    static func withoutTrailingNewlines(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isNewline {
            end = text.index(before: end)
        }
        return String(text[..<end])
    }
```

2. `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel+StepCopy.swift`, after line 16, add

```swift
    /// A step's text for the clipboard. It is the step's block of the Copy text without the line ends a recorded stderr
    /// finishes with, so Copy Step ends without a newline and Copy All Steps joins by one blank line (Q-U2 rules 1 and 7).
    func stepClipboardText(of step: ProvenanceLineageStep) -> String {
        InspectorStepCopyText.withoutTrailingNewlines(stepCopyText(of: step))
    }
```

Then line 20 becomes `InspectorStepCopyText.allSteps(run.steps.map { stepClipboardText(of: $0) })` and line 28 becomes `.command("Copy Step") { self.writeStepCopy(self.stepClipboardText(of: step)) },`.
3. `Sources/LungfishApp/Views/Inspector/Sections/ProvenanceSection.swift:399` becomes `copyText: viewModel.stepClipboardText(of: step),`, so Command-C copies the same text.
4. A new test, below. Run it at the lane head first and see it fail (QA 1), then apply 1 to 3.

The test goes in `Tests/LungfishAppTests/ProvenanceStepCopyTests.swift` after line 93. It uses the file's own `element(_:in:)`, `windows` and `pasteboard`.

```swift
    /// Q-U2 rules 1 and 7. A tool's stderr ends with a newline, and neither Copy Step nor Copy All Steps may.
    func testCopyStepAndCopyAllStepsEndWithoutANewlineWhenStderrDoes() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ProvenanceStepCopyTests-\(UUID().uuidString)"))
        self.pasteboard = pasteboard
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.pasteboard = pasteboard
        func step(_ ordinal: Int) -> ProvenanceLineageStep {
            ProvenanceLineageStep(
                id: UUID(), ordinal: ordinal, toolName: "kraken2", toolVersion: "v2.1.3",
                command: "kraken2 --db db reads.fq", inputPaths: [], outputPaths: [],
                exitStatus: 0, wallTimeSeconds: nil, stderr: "55 sequences processed\n", dependsOn: []
            )
        }
        let run = ProvenanceLineageRun(id: UUID(), title: "classify", subtitle: "lungfish classify", steps: [step(1), step(2)])
        viewModel.lineageRuns = [run]
        XCTAssertTrue(viewModel.stepCopyText(of: run.steps[0]).hasSuffix("processed\n"), "the header's block keeps its newline")
        let window = AccessibilityTreeProbe.host(ProvenanceSection(viewModel: viewModel))
        windows.append(window)

        XCTAssertTrue(AccessibilityTreeProbe.press(try element("provenance-run-1", in: window)))
        let label = try element("provenance-run-1-step-1", in: window)
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Step", on: label))
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "1. kraken2 v2.1.3\nCommand: kraken2 --db db reads.fq\nExit Status: 0\nstderr: 55 sequences processed"
        )
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy All Steps", on: label))
        let all = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertFalse(all.hasSuffix("\n"))
        XCTAssertFalse(all.contains("\n\n\n"), "one blank line between steps")
    }
```

### Fix 2 (should). Make the new Provenance fixture wait for the lineage as well as the load

`Tests/LungfishAppTests/ProvenanceStepCopyTests.swift:136`. Lane P1 follows Q-S1, which lets the record show before the lineage ("Loading lineage…", `UX-copy.md` Q-S1 table). Today `apply` sets `isLoading` and `lineageRuns` in one main-actor turn, so the wait is enough. After P1 it may not be. Replace the line with

```swift
        let finished = await waitUntil(timeout: .seconds(30)) { !model.isLoading && !model.lineageRuns.isEmpty }
```

### Fix 3 (should). Pin the other Run Settings rows showing their values whole (Q-U3, "Other rows")

The lane dropped the line limit for every context row (`MappingDocumentSection.swift:305-321`) and no test covers it, so putting `.lineLimit(3)` back would pass every test (a QA 2 gap, not a violation). Add to `Tests/LungfishAppTests/MappingDocumentStepRowTests.swift` after `testExpandedStepGrowsAndClearsTheNextRow`. The worker runs it and adjusts the element lookup if a selectable text does not report its string as its AX value.

```swift
    /// Q-U3 "Other rows". A long Run Settings value shows whole, and the next row sits below it.
    func testLongRunSettingsValueShowsWholeAndClearsTheNextRow() throws {
        let long = Array(repeating: "--max-intron-len 5000", count: 20).joined(separator: " ")
        let state = MappingDocumentState(
            title: "Mapping", subtitle: nil, summary: nil, sourceData: [],
            contextRows: [("Extra arguments", long), ("Mapper Version", "2.31")], artifactRows: []
        )
        let window = hostSection(state, width: 320)
        func frame(ofValue value: String) -> NSRect? {
            AccessibilityTreeProbe.all(in: window).first { AccessibilityTreeProbe.value($0) == value }
                .map { AccessibilityTreeProbe.frame($0) }
        }
        AccessibilityTreeProbe.waitUntil { frame(ofValue: "2.31") != nil }
        let longRow = try XCTUnwrap(frame(ofValue: long), "tree:\n" + AccessibilityTreeProbe.dump(window))
        let nextRow = try XCTUnwrap(frame(ofValue: "2.31"))
        XCTAssertGreaterThan(longRow.height, 3 * nextRow.height, "more than three lines show")
        XCTAssertGreaterThanOrEqual(longRow.minY, nextRow.maxY, "the next row sits below the whole value")
    }
```

### Fix 4 (should). A fourth selectable and truncated site sits on the same tab

`Sources/LungfishApp/Views/Inspector/Sections/ProvenancePathCaption.swift:25-27` has `.textSelection(.enabled)`, `.lineLimit(2)` and `.truncationMode(.middle)`. It draws the path under every Run Inputs and Output Files row of this section (`MappingDocumentSection.swift:153, 168, 176, 274, 281`). The ruling's I5 names three latent sites and not this one, so Q-U6 never covered it. A long project-relative path, such as the 92 characters of `Analyses/minimap2-2026-10-16T20-46-08/SRR35517702-lengthFilter-subsampleCount.sorted.bam.bai`, wraps past two lines at a narrow Inspector or a large Content Text Size. By the I3 mechanism, selecting it would draw the rest over the row below. The lane did not confirm I3 on a Debug build (report finding 11), so GUI check B confirms it for this site too. Two routes.
- Minimum. Add this site to the Moved out list under Q-U6 with the other three (manager, no agent).
- Better for 2.12, since it is the same tab and one line. `lge-worker`, sonnet, effort max changes line 25 to `.textSelection(.disabled)`. The tooltip and the AX value at `:29` already hold the whole recorded path, so nothing is lost. No unit test can show it (Q-U10), so it joins GUI check B below. The `Copy Path` context command of the Q-U6 pattern stays with the follow-up.

## Steps and checks I call for

| Id | Agent, model, effort | What | When |
|---|---|---|---|
| A | `code-cartographer`, sonnet, effort max | Write the features.yaml notes (UX 7) | After UA and UB land |
| B | `lge-worker`, sonnet, effort max | The Q-U9 GUI check on `build/Debug/Lungfish Debug.app` in a scratch project, never the owner's 32616 project (`UX-copy.md:292`) | After landing |
| C | `lge-worker`, sonnet, effort max | Landing checks | After every lane lands |
| D | `manual-fidelity-reviewer`, sonnet, effort max | Fact-check the features.yaml notes and release note lines 2 and 3 (`UX-copy.md:276-278`) | After A |

A. The lane left features.yaml alone because the ruling gives it to the cartographer (`UX-copy.md:229-232`), so the last clause of UX 7 is met at landing and not at this head. Notes are the ruling's (`UX-copy.md:260-268`). For `map`, sources add `MappingDocumentStateBuilder.swift`, `Sections/MappingDocumentSection.swift`, `Sections/MappingDocumentStepRow.swift` and `InspectorStepCopyText.swift`, and tests add `Tests/LungfishAppTests/MappingDocumentStateBuilderTests.swift` and `Tests/LungfishAppTests/MappingDocumentStepRowTests.swift`. The ruling names `InspectorSectionAccessibilityTests.swift`, but the lane put its new tests in the step row file and left that one unchanged. For `provenance.inspector`, sources add `ProvenanceInspectorViewModel+StepCopy.swift` and tests add `Tests/LungfishAppTests/ProvenanceStepCopyTests.swift`. Then run `python3 scripts/checks/features-yaml-entry-points.py` and `python3 scripts/checks/features-yaml-sources.py`.

B. The lane's six Q-U5 points (report, "Q-U5") plus five more.
7. Chevron hit area. The glyph frame is the only mouse route to collapse a step (`MappingDocumentStepRow.swift:90-96`). Read its frame in the Accessibility Inspector. If it is under about 14 pt wide, add `.padding(.horizontal, 3)` before `.contentShape(Rectangle())` at line 96.
8. Output Files path caption (fix 4). Drag across a path that wraps past two lines and see whether anything draws outside its row.
9. A Lineage step with a stderr (a kraken2 or EsViritu result). Copy Step and Copy All Steps, paste into TextEdit, and see no trailing blank line (fix 1).
10. VoiceOver reads "Command" and then the text once, collapsed and expanded (Q-UB-1). VO-Right crosses five step rows without a trap, and the group's Actions menu lists the three commands (Q-UB-2).
11. View > Content Text Size at its smallest and largest. Label, chevron, first command line and copy icon keep one baseline, and the wrapped command stays inside its row.

C. Three checks.
- `python3 scripts/index/generate-module-map.py` once after the last lane lands, then `python3 scripts/checks/module-map-current.py`. The pre-push hook runs that check (`scripts/install-git-hooks.sh:231`), and the UB head fails it because five new Swift files move the file and line counts, as the report says.
- `python3 scripts/ratchets/file-size.sh`. UB takes `ProvenanceInspectorViewModel.swift` from 1337 to 1336 (`scripts/ratchets/file-size.baseline:24`), so it reports one shrunk. Run `--update` once, after P1 lands, so the two lanes do not both edit that baseline line. `ProvenanceSection.swift` has no baseline and stands at 779 lines, so P1 and later lanes have 21 lines before the 800 limit.
- `swift test --skip-update --filter GenotypeInspectorPresentationTests --filter InspectorSpinnerSizeTests --filter ManualScreenshotProductFixTests --filter WorkflowCompletionBundleDisplayTests --filter PrimerTrimInspectorAfterRevealTests --filter ViralReconDocumentSectionTests`. The lane's item 3 filter (`LungfishAppTests.Provenance`) cannot match these classes, yet they host `ProvenanceSection` or `MappingDocumentState`.

## Rulings on the lane's open questions

Q-UB-1, "Command" as the AX label of the command text with the whole command as its value. Accept. It equals the visible label of the Provenance tab's Command row and the `Command:` line of the copy text, and a SwiftUI text's default label is its own text, which VoiceOver would read twice (`MappingDocumentStepRow.swift:127-128, 142-143`). Point 10 of check B confirms it reads once.

Q-UB-2, a VoiceOver group per step row. Accept. SwiftUI spreads a container's actions onto its children, so the ruling's two requirements (three copy actions on the row, only Expand or Collapse on the control) can both hold only with a container (`MappingDocumentStepRow.swift:64-67`), and tests pin both (`MappingDocumentStepRowTests.swift:78, 89` for the control and `:154-157` for the row). Grouping a row's parts under one named element is the usual way to give a row its own actions, and the visible copy button inside the group stays reachable on its own. The cost is one step into the group to reach the control, and point 10 of check B confirms that is not a trap. The alternative gives four actions to the control and three to each other child.

Q-U10, whether the pair of a base failure and the GUI check meets QA 1. Closed, as the lane brief says. `build/lane/base-test.log:10407` shows `testExpandedStepGrowsAndClearsTheNextRow` failing at the base with "no step disclosure control", and `item1-test.log:7635-7636` shows it passing at the head. The base failure is the missing control and not a geometry fact, because the defect shows only while text is selected and no unit test can select. GUI check 1 of Q-U9 stays on the list as the other half.

## Conformance to the ruling

### Q-U1, labels, identifiers and menu order

| Ruled item | Code at the lane head | Result |
|---|---|---|
| Row is a group named by the step label with the actions Copy Step, Copy Command (off when the command is empty), divider, Copy All Steps | `MappingDocumentStepRow.swift:64-67`, `:72-79`, pinned by `MappingDocumentStepRowTests.swift:152-170` | Match |
| Control. Chevron right or down, focusable, Right, Left and Return through `ProvenanceDisclosureKeyCommand`, Space left to the button | `MappingDocumentStepRow.swift:90-107`, as `ProvenanceSection.swift:743-758` | Match, Space as on the Provenance tab |
| Control label "<label> command", value Collapsed or Expanded, hint "Shows or hides the full command.", id `mapping-step-<n>-toggle`, action Expand or Collapse | `MappingDocumentStepRow.swift:109-115` | Match |
| Command text. A click expands, value is the whole command in both states, id `-command` | `MappingDocumentStepRow.swift:121-129`, `:131-144` | Match |
| Copy icon `doc.on.doc`, borderless, help "Copy this step", label "Copy <label> step", id `-copy`, checkmark for one second in the same frame | `MappingDocumentStepRow.swift:55-61`, `:153-201` | Match |
| Command-C through `copyable` on the control | `MappingDocumentStepRow.swift:108` | Match, GUI check decides whether it fires (Q-U5) |
| Copy All Steps button with title "Copy All Steps", help "Copy every step of this run", label "Copy all steps", id `mapping-steps-copy-all`, drawn only with steps, leading edge on the value column | `MappingDocumentSection.swift:210-220` | Match |
| Provenance part. Label and Command row carry the same three-item menu, Command-C copies the step, no new icon | `ProvenanceSection.swift:395-410`, `:766`, `ProvenanceInspectorViewModel+StepCopy.swift:26-33`, `:45-50` | Match |

### Q-U2, the clipboard text

| Rule | Code | Result |
|---|---|---|
| 1. Plain text, `\n` line ends, no trailing newline | `InspectorStepCopyText.swift:26`, `:38` and `ProvenanceInspectorViewModel+StepCopy.swift:15` | Document tab yes. Provenance tab no for a step with stderr (fix 1) |
| 2. Title is the label and the run's version for the tool (Mapper Version for index 0, Samtools Version for a base name of samtools, none otherwise), trailing white space trimmed | `MappingDocumentStateBuilder.swift:199-226`, `InspectorStepCopyText.swift:43-50` | Match. `testStepsComeFromTheInvocationsWithTheirRunVersions` and `testStepVersionIsLeftOutForAToolWithoutARunVersion` |
| 3 and 4. `Recorded:` then `Command:`, a fact the record lacks is left out, no exit status, wall time, inputs or outputs | `InspectorStepCopyText.swift:18-27` | Match |
| 5. The command is `commandLine`, whole | `MappingDocumentStateBuilder.swift:205` | Match, a spaced path stays one quoted word (`MappingDocumentStepRowTests.swift:112-123`) |
| 6. Copy Command is the command alone | `MappingDocumentStepRow.swift:75`, `ProvenanceInspectorViewModel+StepCopy.swift:29` | Match |
| 7. Copy All Steps is every Copy Step text joined by one blank line | `InspectorStepCopyText.swift:37-39` | Match on the Document tab, fix 1 on the Provenance tab |

The ruled minimap2 example (`minimap2 2.31`, `Recorded: …`, `Command: …`) is what `testCopyStepWritesTheTitleRecordedAndTheWholeCommand` compares, with the builder's own Recorded string so the U+202F before PM cannot trip it. The Provenance tab keeps the header's Copy text byte-identical, because the old two lines at `ProvenanceInspectorViewModel.swift:1023-1024` became one call that joins the same lines with the same `\n`.

### Q-U3, the expanded layout

| Aspect | Code | Result |
|---|---|---|
| Collapsed by default, state per step, never saved, cleared for each result | `MappingDocumentSection.swift:69-72`, `:97-99`. The section is also rebuilt when `mappingDocument` goes nil (`DocumentSection.swift:709`) | Match |
| Collapsed. Three lines, middle truncation, monospaced, not selectable, whole command as help and value | `MappingDocumentStepRow.swift:131-144` | Match |
| Expanded. `lineLimit(nil)`, `fixedSize(horizontal: false, vertical: true)`, selectable, same font, the row grows, no inner scroll | `MappingDocumentStepRow.swift:121-129` | Match. `testExpandedStepGrowsAndClearsTheNextRow` |
| Soft wrap only, no inserted break | The text is `step.command` verbatim (`:121`, `:131`) | Match |
| Monospaced and following Content Text Size | `MappingDocumentStepRow.swift:40` | Match |
| Paths as recorded | `MappingDocumentStateBuilder.swift:205` | Match (Q-U7 moved out) |
| Other rows drop the line limit and truncation, keep selection | `MappingDocumentSection.swift:313-319` | Match, unpinned (fix 3) |
| Builder returns `steps`, Recorded stays a context row, `==` compares steps | `MappingDocumentStateBuilder.swift:84`, `:192`, `:199-210`, `MappingDocumentSection.swift:41-56` | Match |

## Overlap with lane P1 and the other lanes

- `ProvenanceInspectorViewModel.swift`. UB's one hunk is at base lines 1020-1027 (lines 1023-1024 become one call at 1023). P1 edits 485-544 (`load(item:)` and the lookup). No shared line and no shared hunk, so the textual merge is clean in either order. P1's added lines only shift UB's hunk down.
- Coupling that is not textual. (a) `ProvenanceInspectorViewModel+StepCopy.swift` reads `lineageRuns`, `pasteboard` (`ProvenanceInspectorViewModel.swift:427`) and `appendStepLines`, which P1 must not rename. (b) The new fixture waits on `isLoading` only (fix 2). (c) The size baseline for this file is 1337 and UB gives one line back, so any growth in P1 must be paid for inside the file.
- `ProvenanceSection.swift`. UB's hunks are at 264-268, 395-412 and 728-768. P1's Q-S1 work reaches the header's loading text and disabled Copy (`:145-153`, `:186`) and the Lineage group's spinner, which belongs in `lineageContent` (`:253-282`) around UB's first hunk (the call at `:267`). If P1 edits lines 262 to 270, expect a small conflict and keep UB's call `stepDisclosure(step, in: run, runOrdinal: index + 1)`.
- UA, P2 and P3 share no file with UB (I read their reports' file lists). P2 edits `InspectorViewController+PublicAPI.swift` and `MainSplitViewController+ContentDisplay.swift`, which holds the only call of `MappingDocumentStateBuilder.build` (`:947`), but UB leaves that signature as it was. `AccessibilityTreeProbe.swift` is changed by UB alone.

## Check ids

- UX 1. Pass. Step labels (`invocation.label`), the Run Settings empty message, the Provenance run and step names, and the Copy Command name and text are unchanged. The changes are the ruled ones, steps leaving `contextRows`, monospaced commands, the three-item menu and long values shown whole.
- UX 5. Pass with fix 1. Step rows follow display and VoiceOver order (label, control, command, copy icon) and Recorded precedes them as ruled. A record with no invocations shows no step rows and the same context rows. The header's Copy text is byte-identical. No display fixture file changed, and the one edited expectation, `MappingDocumentStateBuilderTests.swift:115`, moved `samtools index` from `contextRows` to `steps`.
- UX 6. Pass. The pasteboard is written only on a user action (`MappingDocumentSection.swift:229-232`, `ProvenanceInspectorViewModel+StepCopy.swift:35-38`). No file, bundle or defaults write was added, and the tests use temp folders and private pasteboards.
- UX 7. Pass for strings, open for features.yaml until step A. Controls are title case as the design system sets (`docs/design/design-system/README.md:22`), AX labels and help are sentence case, and no added line holds an em dash, a semicolon or a mid-sentence colon in a user-facing string. Release note lines 2 and 3 are the manager's (`UX-copy.md:272-278`).
- SWIFT 2. Pass. The builder adds string work only (`NSString.lastPathComponent`, `MappingDocumentStateBuilder.swift:223`) and still runs at `MainSplitViewController+ContentDisplay.swift:947` with the file checks it had. The Provenance rows build `stepCopyText` in the body for each shown step, which is pure string work bounded by `ProvenanceStderr.maxLength` (10,240 characters) per step. The checkmark timer is a `.task(id:)` sleep that ends with the view (`MappingDocumentStepRow.swift:186-191`).
- ARCH 6. Pass. `ProvenanceInspectorViewModel.swift` 1337 to 1336 (baseline line 24). `ProvenanceSection.swift` 776 to 779, no baseline, under 800. `MappingDocumentSection.swift` 259 to 329. `MappingDocumentStateBuilder.swift` 250 to 278. New files 201, 51 and 52 lines. The largest test file is 770. The seven ratchets the report did not run (cli-parity-gaps, native-tool-runner-in-app, process-spawn, provenance-writers, shared-slider-control, tool-identity, unchecked-operation-start) cannot move, since nothing here touches a CLI, a runner, a spawn, a provenance writer, a slider or an operation start. The one new tool literal, `"samtools"` at `MappingDocumentStateBuilder.swift:223`, is not among the 23 ids that tool-identity counts. MODULES.md is stale until step C, as the report says.
- QA 1. Pass. `testExpandedStepGrowsAndClearsTheNextRow` fails at the base (`base-test.log:10407`, exit=1, one test, one failure) and passes at the head (`item1-test.log:7635-7636`). Q-U10 is closed above. The test for fix 1 must be shown failing before the change.
- QA 2. Pass, with fix 3 for an unpinned behaviour. The 8 step row tests, 2 builder tests and 2 Provenance tests read pasteboard strings, AX labels, values, actions and frames. None reads source text, and the report shows the source-text ratchet at its baseline.

Noted outside my checks. `MappingDocumentStepRowTests.swift:20-22` makes its folder with `FileManager.default.temporaryDirectory` and not `TestTempDirectory` (QA 6, for the QA expert).

Count. Must fixes 1 (fix 1). Should fixes 3 (fixes 2, 3 and 4).

