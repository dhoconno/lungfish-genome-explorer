# UX ruling: reference sequences left out of a mapping result (Q-B2)

Model and effort: Opus 5.5 (opus), effort max. Field UX, letter U. Code read at `65539ddcd2fbe756390d0890cda0b5181e77ffc0`, read only. Every `:line` without a file name is in `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift`.

## 1. Ruling

| Id | Ruling |
|---|---|
| Q-B2, the bar | A second label in the summary bar, after the summary text and before Focus, reads "94 of 905,628 reference sequences have alignments". It shows for a mapping result that records both counts, when at least one sequence was left out and the reference has two or more. The summary text itself keeps every frozen string. |
| Q-B2, VoiceOver | The new label is static text, read by its value in the same words as on screen, in the order summary text, count, Focus. Its help, which is also its tooltip, reads "905,534 reference sequences have no alignments in this mapping and are not listed." |
| Q-B2, the export | No line or column changes. The CSV and TSV keep their header and row format and write the stored rows, so only the number of data rows falls for a new result. The two counts appear only in the export record's `resolved` keys, which the Provenance tab lists under their raw names. |
| Q-B2, schema 1 | Nothing changes. No clause, no tooltip, no VoiceOver text, no "Not recorded", and the export keeps its bytes. An absent count means unknown, so nothing is derived from the rows. |
| Home | Lane P5 builds it with F4. The label reads the counts P5 adds to `MappingResult` and edits the controller P5 already edits. |

"Reference sequences", not "references". In LGE a reference is a `.lungfishref` bundle kept in the Reference Sequences folder (the SILVA path in the brief), so "905,628 references" can read as 905,628 bundles. The counts measure the sequences inside one bundle, the BAM's `@SQ` entries.

## 2. What the code does at 65539ddcd

The bar.

- The summary bar is one label and the Focus button, 32 pt tall (`:216-228`). The label is static text with only an identifier, so VoiceOver reads its string (`:100-107`).
- `updateSummaryBar()` has three branches (`:483-519`). A visible-track override shows the track name and read counts, with an orange warning when there is one (`:486-502`). With no result it shows the document title (`:504-513`). A result shows the mapper and read counts (`:515-518`).
- The override replaces the result text as soon as a visible track's rows arrive (`:1475-1480`), first from cached metadata and then from the exact summaries (`:1356-1373`, `:1411-1417`). The visible track of a mapping result is chosen at `:584-591`. The override clears only for a new document (`:555`), All Alignments (`:932`) and the original-rows path (`:1298`). A clause added only to the result branch would therefore show for a moment and then vanish.
- Three tests pin the bar text through `testSummaryText` (`:2024`): `Tests/LungfishAppViewTests/MappingResultViewControllerTests.swift:690` and `:707`, and `Tests/LungfishAppTests/MappingViewportLegacyReadCountTests.swift:75`.

The rows.

- The original-rows path puts every stored row in the table (`:1297-1303`), and `MappingContigTableView` filters only by search text (`Sources/LungfishApp/Views/Results/Mapping/MappingContigTableView.swift:181`). The track paths keep rows with `mappedReads > 0` (`:982`, `:1456`, `:1579`).
- The summary builder counts primary mapped reads per sequence (`Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift:39`, `:66-71`). Its view pass reads every record with no flag filter (`:198` of that file) and keeps any record whose CIGAR aligns query bases (`:633-646` of that file). So "has alignments" means at least one record with aligned bases, of any flag, which is what F4 keeps. "Mapped reads" would be wrong, because a kept row can hold only secondary or supplementary records.
- No field in the bundle types marks which alignment track the mapping run wrote. A search of `Sources/LungfishCore/Bundles` for derivation, origin and parent fields found only the manifest's `originBundlePath` (`Sources/LungfishCore/Bundles/BundleManifest.swift:131`). The clause therefore describes the mapping run, not the visible track, and its help says "in this mapping".

The export.

- `exportResults` writes `MappingResultExportBuilder.delimitedContent` for CSV and TSV (`:1862-1879`), a fixed header (`:1797-1806`) and one line per stored row (`:1807-1819`). The record's `resolved` holds `contigCount`, `mappedReads`, `sourceCount` and `totalReads` (`:1906-1911`), stored as resolved defaults (`Sources/LungfishWorkflow/Provenance/ScientificFileExportProvenance.swift:278`). The Provenance tab lists them as Resolved Default rows by raw key, sorted (`Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift:920-936`).
- Nothing in `Sources` calls `exportResults(to:format:)`. Only `Tests/LungfishAppViewTests/MappingResultViewControllerTests.swift` does, and `Sources/LungfishKit/ResultViewportController.swift:15` declares only the format enum. No user reads this CSV at this commit, so the bar's help does not mention an export.

Words F4 does not touch, because they list no per-reference rows.

- The CLI Results table (`Sources/LungfishCLI/Commands/MapCommand.swift:572-591`), the completion message "Mapping complete: 197/200 reads mapped" (`Tests/Fixtures/golden/mapping/cli-report.json:3`), the history summary (`Tests/LungfishWorkflowTests/Mapping/MappingResultLayoutServiceTests.swift:206`) and the debug log's `contigs=` (`Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift:957`), which keeps meaning rows written.
- The contig table copies one cell and has no export (`MappingContigTableView.swift:69`, `:292`).

The file. The controller is 2155 lines, exactly its baseline (`scripts/ratchets/file-size.baseline:47`).

## 3. Strings

`aligned` is `referenceCount - unalignedReferenceCount`. Numbers use `Int.formatted()`, as the bar already does (`:494`, `:518`).

| Surface | Case | Exact text |
|---|---|---|
| Count label, on screen and as the VoiceOver value | `aligned == 1` | `1 of 905,628 reference sequences has alignments` |
| Count label, on screen and as the VoiceOver value | `aligned` is 0 or 2 or more | `94 of 905,628 reference sequences have alignments`, and `0 of 905,628 reference sequences have alignments` |
| Tooltip and VoiceOver help | `unalignedReferenceCount == 1` | `1 reference sequence has no alignments in this mapping and is not listed.` |
| Tooltip and VoiceOver help | `unalignedReferenceCount` 2 or more | `905,534 reference sequences have no alignments in this mapping and are not listed.` |
| Accessibility identifier | always | `reference-bundle-reference-count-label` |
| Accessibility label | always | none set, so VoiceOver speaks the value once |
| Summary text | every case | unchanged (`:494`, `:496`, `:507`, `:511`, `:518`) |
| Export CSV and TSV | every case | unchanged header (`:1797-1806`) and row format (`:1807-1819`), no comment or footer line |
| Export record, schema 2 | both counts present | BIO fix 5 adds `referenceCount` and `unalignedReferenceCount` to `resolved`, shown as those raw names. No new label strings. |
| Schema 1, or one count missing | every surface | nothing new, label hidden with an empty string, no help, no record keys |

Display rules, all of which must hold for the label to show.

1. The input is a mapping result (`currentInput?.kind == .mappingResult`) and `currentResult` records both counts.
2. `unalignedReferenceCount > 0`. When nothing was left out the table is complete and the bar stays as it is today.
3. `referenceCount >= 2`, so the noun is always plural. A one-sequence reference with nothing aligned already reads "0 / N reads mapped".
4. The counts agree with the rows, `contigs.count + unalignedReferenceCount == referenceCount` (BIO's invariant). Otherwise the label stays hidden, so it never states a number the stored rows contradict.
5. It shows in every bar branch for a mapping result, including the visible-track override and All Alignments. It hides for a direct bundle and, with the whole bar, in focus mode (`:426`).
6. Secondary label color always, regular weight, and it truncates at the tail before the summary text does. The orange warning stays on the summary text (`:497`).

Why a second label and not a segment appended to the summary text.

- The override replaces the summary text (`:1475-1480`). A separate label keeps the clause across all three branches with one update.
- The frozen strings and their three tests stay exactly as they are (UX 1).
- Appending would need a new " — " separator in a new string, against UX 7's prose rules.
- VoiceOver reads it as its own item with its own help, and the warning's orange color cannot spill onto it.

## 4. Fixes for lane P5

Lines are at `65539ddcd`. P5 starts after P2 lands, so anchor on the quoted text. The update reads only the in-memory result and writes nothing (UX 6).

F-U1. New file `Sources/LungfishApp/Views/Results/Reference/MappingReferenceCountText.swift`.

```swift
// MappingReferenceCountText.swift - The summary-bar clause for reference sequences a mapping left out
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

/// The clause the mapping summary bar shows when a result left out reference
/// sequences with no alignments (Q-B2). An absent count means unknown, so a
/// schema-1 result shows nothing.
enum MappingReferenceCountText {
    struct Text: Equatable {
        let label: String
        let help: String
    }

    static func make(referenceCount: Int?, unalignedReferenceCount: Int?, storedRowCount: Int) -> Text? {
        guard let total = referenceCount,
              let unaligned = unalignedReferenceCount,
              total >= 2,
              unaligned > 0,
              unaligned <= total,
              storedRowCount + unaligned == total
        else { return nil }
        let aligned = total - unaligned
        let label = "\(aligned.formatted()) of \(total.formatted()) reference sequences \(aligned == 1 ? "has" : "have") alignments"
        let help = unaligned == 1
            ? "1 reference sequence has no alignments in this mapping and is not listed."
            : "\(unaligned.formatted()) reference sequences have no alignments in this mapping and are not listed."
        return Text(label: label, help: help)
    }

    @MainActor
    static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)
        label.setAccessibilityIdentifier("reference-bundle-reference-count-label")
        return label
    }

    /// Shows the clause for `result`, or hides the label when there is none.
    @MainActor
    static func apply(to label: NSTextField, result: MappingResult?) {
        let text = result.flatMap {
            make(
                referenceCount: $0.referenceCount,
                unalignedReferenceCount: $0.unalignedReferenceCount,
                storedRowCount: $0.contigs.count
            )
        }
        label.stringValue = text?.label ?? ""
        label.toolTip = text?.help
        label.setAccessibilityHelp(text?.help)
        label.isHidden = text == nil
    }
}
```

F-U2. `:107`, after the `summaryLabel` closure's `}()`, add one line.

```swift
    private let referenceCountLabel = MappingReferenceCountText.makeLabel()
```

F-U3. `:217-218`, add the label between the two, so the subview order and VoiceOver order are summary text, count, Focus.

```swift
        summaryBar.addSubview(summaryLabel)
        summaryBar.addSubview(referenceCountLabel)
        summaryBar.addSubview(focusButton)
```

Then replace `:221` (`summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: focusButton.leadingAnchor, constant: -12),`) with these three lines, which imply it.

```swift
            referenceCountLabel.leadingAnchor.constraint(equalTo: summaryLabel.trailingAnchor, constant: 12),
            referenceCountLabel.trailingAnchor.constraint(lessThanOrEqualTo: focusButton.leadingAnchor, constant: -12),
            referenceCountLabel.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),
```

F-U4. `:485`, after `summaryLabel.toolTip = nil` and before the first `return`, add one line, so all three branches refresh the label.

```swift
        MappingReferenceCountText.apply(to: referenceCountLabel, result: currentInput?.kind == .mappingResult ? currentResult : nil)
```

F-U5. `:2024`, after `var testSummaryText: String { summaryLabel.stringValue }`, add the test hook.

```swift
    var testReferenceCountLabel: NSTextField { referenceCountLabel }
```

F-U6, the ratchet. F-U2 to F-U5 add 6 lines to a file at its 2155-line baseline, and P5's fixes 4 and 5 add more. A pure move frees about 50 lines. Move `MappingResultExportError` (`:1779-1791`) and `MappingResultExportBuilder` (`:1793` to its closing brace) unchanged into a new `Sources/LungfishApp/Views/Results/Reference/MappingResultExportBuilder.swift`, and drop `private` from both type declarations so `exportResults` (`:1862-1879`) still sees them. The lane may choose another offset, but the controller must end at or under `file-size.baseline:47`.

Shared files. `ReferenceBundleViewportController.swift` is shared with P2 (the mapping viewport refresh) and with P5's fixes 4 and 5. `MappingResult.swift` is shared with P5's fix 3, which adds the two properties F-U1 reads.

## 5. Tests

- `MappingReferenceCountTextTests.testStatesAlignedOfTotalWhenSequencesWereLeftOut`. `make(referenceCount: 905_628, unalignedReferenceCount: 905_534, storedRowCount: 94)` gives label `94 of 905,628 reference sequences have alignments` and help `905,534 reference sequences have no alignments in this mapping and are not listed.`
- `MappingReferenceCountTextTests.testSingularAndZeroForms`. `(3, 2, 1)` gives `1 of 3 reference sequences has alignments` and `2 reference sequences have no alignments in this mapping and are not listed.` `(3, 1, 2)` gives `2 of 3 reference sequences have alignments` and `1 reference sequence has no alignments in this mapping and is not listed.` `(3, 3, 0)` gives `0 of 3 reference sequences have alignments` and `3 reference sequences have no alignments in this mapping and are not listed.`
- `MappingReferenceCountTextTests.testNoClauseWithoutCountsOrOmissions`. `nil` for `(nil, nil, 905_628)`, `(3, nil, 3)`, `(nil, 1, 2)`, `(3, 0, 3)`, `(1, 1, 0)`, `(5, 2, 2)` and `(3, 4, 0)`.
- `MappingResultViewControllerTests.testSummaryBarStatesReferenceSequencesLeftOut`. The `:707` fixture rebuilt as schema 2 with two contigs, `referenceCount: 3` and `unalignedReferenceCount: 1`. `testSummaryText == "minimap2 Mapping — 198 / 200 reads mapped (99.0%)"`, unchanged. `testReferenceCountLabel` is not hidden, its `stringValue` is `2 of 3 reference sequences have alignments`, its `toolTip` and `accessibilityHelp()` are `1 reference sequence has no alignments in this mapping and is not listed.`, and its `accessibilityRole()` is `.staticText`.
- `MappingResultViewControllerTests.testSummaryBarUnchangedWithoutReferenceCounts`. The `:707` fixture as it is. `testSummaryText` is unchanged, and `testReferenceCountLabel` is hidden with `stringValue == ""`, `toolTip == nil` and `accessibilityHelp() == nil`.
- `MappingResultViewControllerTests.testReferenceCountLabelStaysWhenTrackRowsArrive`. The `:690` scenario given two counts that agree with its rows. After `testSummaryText` reads `Exact matches — 4 / 4 reads mapped (100.0%)`, the label is still shown and its `stringValue` equals `MappingReferenceCountText.make(...)!.label` for those counts.
- `ReferenceBundleViewportControllerTests.testReferenceCountLabelOrderAndDirectBundle`. `vc.summaryBarView.subviews.map { $0.accessibilityIdentifier() }` equals `["reference-bundle-summary-label", "reference-bundle-reference-count-label", "reference-viewport-focus-button"]`, and after configuring a direct bundle the label is hidden.
- Add to BIO's `MappingResultExportTests.testExportWritesStoredRowsAndRecordsCounts`, for both schemas. The first line is `Contig,Length,Mapped Reads,% Mapped,Mean Depth,Coverage Breadth,Median MAPQ,Mean Identity` and the content has exactly `1 + result.contigs.count` lines.

## 6. Release notes and docs

Release notes line (UX 7): "Mapping results against references with many sequences, such as SILVA, now list only the reference sequences that have alignments, and the bar above the list says how many, for example 94 of 905,628. Results made by earlier versions show as before."

`docs/user-manual/features.yaml` gets its UX 7 entry from the landing agent. The manual text and the screenshot wait for the end-of-program docs pass, so this session records a docs fact, which is the rule in section 3, and a screenshot punchlist row for the bar on a SILVA mapping.

## 7. Lanes, checks and the open question

| Id | What | Agent |
|---|---|---|
| P5 fold-in | F-U1 to F-U6 and the section 5 tests, with BIO's F4 fixes | lge-worker, opus, effort max |
| R-U | UX review of P5's diff against UX 1, UX 5, UX 6 and UX 7 | lge-expert, opus, effort max |
| G-U1 | GUI check with Computer Use on the debug app (`python3 scripts/release/release.py debug`) in a scratch project. Map reads to a three-sequence reference where one sequence gets no reads, read the bar, hover for the tooltip and walk the VoiceOver order with Accessibility Inspector. Then open a result made before F4 and see the bar unchanged. Project 32616 stays read only. Owner-attended if Computer Use is denied. | lge-worker, sonnet, effort max |

| Id | Field | Question |
|---|---|---|
| Q-U1 | ARCH | Should an alignment track record that the mapping run wrote it, so the clause can hide for other tracks in the same viewer bundle? Until then the clause describes the run, and its help says "in this mapping". Not blocking. |
