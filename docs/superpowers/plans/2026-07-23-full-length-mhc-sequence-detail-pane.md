# Full-Length MHC Sequence Detail Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the full-length ONT MHC result viewport’s graphical allele detail with an empty-or-sequence-only pane that renders selected allele rows as GenBank, FASTA, or EMBL records.

**Architecture:** Normalize known-reference and generated-candidate records into one immutable UI record type when a result is configured. A single AppKit detail view owns one segmented format control and one read-only text view; selection changes only replace its immutable record array and rendered string. The result controller resolves row targets in viewport order and never touches BAM evidence or rebuilds per-record graphical views.

**Tech Stack:** Swift 6, AppKit, LungfishIO GenBank models/readers, XCTest, Swift Package Manager.

---

## File Structure

- Create `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceRecord.swift`
  - Own the immutable record presentation, candidate GenBank preload, FASTA formatting, and deterministic EMBL formatting.
- Create `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceDetailView.swift`
  - Own the segmented format control, read-only text view, empty state, and bounded rendering lifecycle.
- Create `Tests/LungfishGenotypeUITests/GenotypeAlleleSequenceRecordTests.swift`
  - Verify known/candidate normalization and exact GenBank, FASTA, and EMBL output.
- Create `Tests/LungfishGenotypeUITests/GenotypeAlleleSequenceDetailViewTests.swift`
  - Verify empty/default/toggle/multi-record behavior and bounded repeated updates.
- Modify `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
  - Replace this workflow’s known/candidate graphical detail mounting with the unified sequence viewer and row-only selection semantics.
- Modify `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
  - Return selected allele-row targets in the current viewport order.
- Modify `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
  - Verify controller integration, viewport ordering, mixed known/candidate rows, unavailable records, and non-row selections.

The existing `GenotypeKnownAlleleDetailView` and `GenotypeCandidateAlleleDetailView` remain available to other code and their unit tests, but this workflow surface will no longer mount them.

### Task 1: Normalize and Format Allele Records

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceRecord.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeAlleleSequenceRecordTests.swift`

- [ ] **Step 1: Write failing tests for known and candidate record normalization**

Add tests that construct an annotated `ONTMHCReferenceVisualizationRecord` and a temporary canonical candidate GenBank file, then require:

```swift
func testKnownRecordPreservesValidatedGenBankAndBuildsFASTAAndEMBL() throws {
    let source = makeKnownRecord(
        rawReferenceID: "NHP00001",
        alleleName: "Mafa-A1*001:01:01:01",
        sequence: "ATGAAATAG"
    )

    let record = GenotypeAlleleSequenceRecord.known(source)

    XCTAssertEqual(record.identity, "known:NHP00001:1")
    XCTAssertEqual(record.displayName, "Mafa-A1*001:01:01:01")
    XCTAssertEqual(record.genBankText, source.genBankText)
    XCTAssertEqual(
        record.fastaText,
        ">NHP00001 Mafa-A1*001:01:01:01\nATGAAATAG\n"
    )
    XCTAssertTrue(record.emblText.contains("ID   NHP00001;"))
    XCTAssertTrue(record.emblText.contains("FT   CDS"))
    XCTAssertTrue(record.emblText.hasSuffix("//\n"))
}

func testCandidateCatalogLoadsValidatedGenBankOnceAndKeysByStableClusterID() throws {
    let stableID = "11111111-2222-3333-4444-555555555555"
    let candidate = makeCandidate(
        stableClusterID: stableID,
        provisionalName: "Mafa-A1*001:01:01:01_1nt_nov"
    )
    let url = try writeCandidateGenBank(
        accession: stableID,
        definition: "\(candidate.provisionalName); test candidate",
        sequence: "ATGAAATAG"
    )

    let records = try GenotypeAlleleSequenceRecord.candidateCatalog(
        candidates: [candidate],
        genBankURL: url
    )

    let record = try XCTUnwrap(records[stableID])
    XCTAssertEqual(record.displayName, candidate.provisionalName)
    XCTAssertTrue(record.genBankText.contains("ACCESSION   \(stableID)"))
    XCTAssertEqual(
        record.fastaText,
        ">\(stableID) \(candidate.provisionalName)\nATGAAATAG\n"
    )
    XCTAssertTrue(record.emblText.contains("AC   \(stableID);"))
}
```

Add a separate collision test proving two stable IDs with the same provisional display name remain two records.

- [ ] **Step 2: Run the record tests and verify RED**

Run:

```bash
swift test --filter GenotypeAlleleSequenceRecordTests
```

Expected: compilation fails because `GenotypeAlleleSequenceRecord` does not exist.

- [ ] **Step 3: Implement the immutable record and candidate catalog**

Create:

```swift
import Foundation
import LungfishCore
import LungfishIO

struct GenotypeAlleleSequenceRecord: Equatable {
    let identity: String
    let displayName: String
    let genBankText: String
    let fastaText: String
    let emblText: String

    static func known(
        _ source: ONTMHCReferenceVisualizationRecord
    ) -> GenotypeAlleleSequenceRecord {
        let normalizedSequence = source.sequence.uppercased()
        return GenotypeAlleleSequenceRecord(
            identity: "known:\(source.rawReferenceID):\(source.sourceOrdinal)",
            displayName: source.alleleName,
            genBankText: normalizedTrailingNewline(source.genBankText),
            fastaText: normalizedTrailingNewline(source.fastaText),
            emblText: EMBLFormatter.format(source)
        )
    }

    static func candidateCatalog(
        candidates: [ONTMHCCandidateRecord],
        genBankURL: URL?
    ) throws -> [String: GenotypeAlleleSequenceRecord] {
        guard let genBankURL else { return [:] }
        let candidatesByAccession = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.fastaRecordID, $0) }
        )
        var result: [String: GenotypeAlleleSequenceRecord] = [:]
        for parsed in try GenBankReader(url: genBankURL).readAllSync() {
            guard let accession = parsed.accession,
                  let candidate = candidatesByAccession[accession] else { continue }
            let sequence = parsed.sequence.asString().uppercased()
            result[candidate.stableClusterID] = GenotypeAlleleSequenceRecord(
                identity: "candidate:\(candidate.stableClusterID)",
                displayName: candidate.provisionalName,
                genBankText: GenBankWriter(url: genBankURL).format(parsed),
                fastaText: fasta(
                    identifier: candidate.fastaRecordID,
                    displayName: candidate.provisionalName,
                    sequence: sequence
                ),
                emblText: EMBLFormatter.format(
                    parsed,
                    identifier: candidate.fastaRecordID,
                    displayName: candidate.provisionalName
                )
            )
        }
        return result
    }
}
```

Implement private helpers in the same file:

- `normalizedTrailingNewline(_:)` trims surplus terminal blank lines and adds exactly one trailing newline.
- `fasta(identifier:displayName:sequence:)` wraps uppercase bases at 60 columns.
- `EMBLFormatter` emits `ID`, `AC`, `DE`, preserved source/organism fields, `FH`/`FT` annotations and qualifiers, `SQ`, 60-base sequence lines, and `//`.
- The known-record formatter consumes `ONTMHCReferenceVisualizationFeature`.
- The candidate formatter consumes `GenBankRecord.annotations`.
- Feature order is `sourceOrdinal`; qualifier keys and values are deterministic.
- Missing optional metadata is omitted instead of invented.

Reject duplicate candidate accessions or duplicate stable-ID output rather than conflating records:

```swift
enum CatalogError: Error, Equatable {
    case duplicateAccession(String)
    case duplicateStableClusterID(String)
}
```

Add `unavailable(identity:displayName:)`, which creates explicit zero-base
GenBank and EMBL entries plus a header-only FASTA entry. Each string identifies
the unresolved row and says that its validated allele record is unavailable;
it never substitutes a closest-reference or synthetic biological sequence.

- [ ] **Step 4: Run the record tests and verify GREEN**

Run:

```bash
swift test --filter GenotypeAlleleSequenceRecordTests
```

Expected: all record normalization, annotation, collision, and format tests pass.

- [ ] **Step 5: Commit the record layer**

```bash
git add Sources/LungfishGenotypeUI/GenotypeAlleleSequenceRecord.swift \
  Tests/LungfishGenotypeUITests/GenotypeAlleleSequenceRecordTests.swift
git commit -m "feat: format MHC allele sequence records"
```

### Task 2: Build the Sequence-Only Detail View

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceDetailView.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeAlleleSequenceDetailViewTests.swift`

- [ ] **Step 1: Write failing view tests**

Cover the default format, empty state, all toggles, multi-record order, format persistence, and bounded hierarchy:

```swift
@MainActor
func testStartsEmptyAndDefaultsToGenBankForFirstSelection() throws {
    let view = GenotypeAlleleSequenceDetailView()
    XCTAssertTrue(view.isEmpty)
    XCTAssertEqual(view.currentFormat, .genBank)
    XCTAssertEqual(view.renderedText, "")

    view.show(records: [makeRecord(name: "First")])

    XCTAssertFalse(view.isEmpty)
    XCTAssertEqual(view.currentFormat, .genBank)
    XCTAssertEqual(view.renderedText, makeRecord(name: "First").genBankText)
}

@MainActor
func testFormatPersistsAndMultipleRecordsFollowInputOrder() throws {
    let view = GenotypeAlleleSequenceDetailView()
    let first = makeRecord(name: "First")
    let second = makeRecord(name: "Second")
    view.show(records: [first])
    view.testingSelectFormat(.embl)
    view.show(records: [second, first])

    XCTAssertEqual(view.currentFormat, .embl)
    XCTAssertLessThan(
        try XCTUnwrap(view.renderedText.range(of: second.emblText)?.lowerBound),
        try XCTUnwrap(view.renderedText.range(of: first.emblText)?.lowerBound)
    )
}

@MainActor
func testRepeatedSelectionReusesOneControlAndOneTextView() {
    let view = GenotypeAlleleSequenceDetailView()
    for index in 0..<1_000 {
        view.show(records: [makeRecord(name: "Record \(index)")])
        view.testingSelectFormat(
            GenotypeAlleleSequenceDetailView.Format.allCases[index % 3]
        )
    }

    XCTAssertEqual(view.testingFormatControlCount, 1)
    XCTAssertEqual(view.testingTextViewCount, 1)
    XCTAssertEqual(view.testingSubviewCount, view.testingInitialSubviewCount)
}
```

- [ ] **Step 2: Run the view tests and verify RED**

Run:

```bash
swift test --filter GenotypeAlleleSequenceDetailViewTests
```

Expected: compilation fails because the detail view does not exist.

- [ ] **Step 3: Implement one stable AppKit hierarchy**

Create:

```swift
import AppKit

@MainActor
final class GenotypeAlleleSequenceDetailView: NSView {
    enum Format: Int, CaseIterable {
        case genBank
        case fasta
        case embl
    }

    private let formatControl = NSSegmentedControl(
        labels: ["GenBank", "FASTA", "EMBL"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var records: [GenotypeAlleleSequenceRecord] = []

    private(set) var currentFormat: Format = .genBank
    var isEmpty: Bool { records.isEmpty }
    var renderedText: String { textView.string }

    func resetForNewResult() {
        currentFormat = .genBank
        formatControl.selectedSegment = Format.genBank.rawValue
        clear()
    }

    func clear() {
        records = []
        textView.string = ""
        formatControl.isHidden = true
    }

    func show(records: [GenotypeAlleleSequenceRecord]) {
        guard !records.isEmpty else {
            clear()
            return
        }
        self.records = records
        formatControl.isHidden = false
        render()
    }
}
```

Build the hierarchy once in `init`:

- vertical stack with an 8-point inset;
- compact segmented control at the leading edge;
- vertically and horizontally scrollable text host;
- non-editable, selectable `NSTextView`;
- monospaced system font;
- accessibility identifiers `mhc-sequence-detail`, `mhc-sequence-format`, and `mhc-sequence-text`.

`render()` maps the immutable record array to the selected format and joins records with one blank line without changing the record text itself. The segmented action only updates `currentFormat` and calls `render()`.

- [ ] **Step 4: Run the view tests and verify GREEN**

Run:

```bash
swift test --filter GenotypeAlleleSequenceDetailViewTests
```

Expected: all view lifecycle and format tests pass.

- [ ] **Step 5: Commit the view**

```bash
git add Sources/LungfishGenotypeUI/GenotypeAlleleSequenceDetailView.swift \
  Tests/LungfishGenotypeUITests/GenotypeAlleleSequenceDetailViewTests.swift
git commit -m "feat: add MHC sequence detail viewer"
```

### Task 3: Wire Row Selection to Cached Sequence Records

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:100-102`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:500-575`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:2323-2580`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:6000-6500`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing empty and single-row controller tests**

Add tests using a `full-length-ont-mhc-genotype` result:

```swift
@MainActor
func testFullLengthMHCDetailIsEmptyUntilAnAlleleRowIsSelected() {
    let controller = makeFullLengthMHCController()

    XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
    XCTAssertEqual(controller.testingAlleleSequenceText, "")

    controller.testingSelectMatrixColumn(sample: "CR1178")
    XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)

    controller.testingSelectMatrixCell(
        genotype: "NHP00001",
        sample: "CR1178"
    )
    XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
}

@MainActor
func testKnownAlleleRowShowsGenBankByDefaultAndSupportsAllFormats() {
    let controller = makeFullLengthMHCController()
    controller.testingSelectMatrixRows(genotypes: ["NHP00001"], sample: nil)

    XCTAssertEqual(controller.testingAlleleSequenceFormat, .genBank)
    XCTAssertTrue(controller.testingAlleleSequenceText.contains("ACCESSION   NHP00001"))

    controller.testingSelectAlleleSequenceFormat(.fasta)
    XCTAssertTrue(controller.testingAlleleSequenceText.hasPrefix(">NHP00001 "))

    controller.testingSelectAlleleSequenceFormat(.embl)
    XCTAssertTrue(controller.testingAlleleSequenceText.contains("AC   NHP00001;"))
}
```

- [ ] **Step 2: Run the focused controller tests and verify RED**

Run:

```bash
swift test --filter 'GenotypeResultViewportTests/testFullLengthMHCDetailIsEmpty|GenotypeResultViewportTests/testKnownAlleleRowShowsGenBank'
```

Expected: tests fail because the current controller installs captions/graphical detail views and has no sequence-detail test hooks.

- [ ] **Step 3: Replace the mounted detail components and preload candidate records**

Replace:

```swift
private let knownAlleleDetailView = GenotypeKnownAlleleDetailView()
private let candidateAlleleDetailView = GenotypeCandidateAlleleDetailView()
```

with:

```swift
private let alleleSequenceDetailView = GenotypeAlleleSequenceDetailView()
private var candidateSequenceRecordsByStableClusterID:
    [String: GenotypeAlleleSequenceRecord] = [:]
```

During `configure(result:)`:

```swift
alleleSequenceDetailView.resetForNewResult()
candidateSequenceRecordsByStableClusterID = (
    try? GenotypeAlleleSequenceRecord.candidateCatalog(
        candidates: result.mhcCandidates?.candidates ?? [],
        genBankURL: result.mhcCandidateGenBankArtifactURLs.candidateAlleles
    )
) ?? [:]
showEmptySelection()
```

If catalog parsing fails, retain an empty catalog and surface the already validated row identity as an unavailable record when selected. Do not read BAMs or retry the file operation on selection.

Add:

```swift
private func installSequenceRecords(
    _ records: [GenotypeAlleleSequenceRecord]
) {
    removeArrangedSubviews(from: detailStack)
    guard !records.isEmpty else {
        alleleSequenceDetailView.clear()
        return
    }
    alleleSequenceDetailView.show(records: records)
    detailStack.addArrangedSubview(alleleSequenceDetailView)
}

private func unavailableSequenceRecord(
    identity: String,
    displayName: String
) -> GenotypeAlleleSequenceRecord {
    GenotypeAlleleSequenceRecord.unavailable(
        identity: identity,
        displayName: displayName
    )
}
```

`showEmptySelection()` must remove all arranged subviews and clear the sequence view without adding a caption.

- [ ] **Step 4: Resolve single known and candidate rows**

Change `showSharedCall` to resolve:

```swift
let record = result?.mhcReferenceVisualizations?
    .recordsByKnownCallGenotype[sharedCall.genotype]
    .map(GenotypeAlleleSequenceRecord.known)
    ?? unavailableSequenceRecord(
        identity: "known:\(sharedCall.genotype)",
        displayName: alleleDisplayLabel(for: sharedCall.genotype)
    )
installSequenceRecords([record])
```

Change `showCandidateRow` to resolve by stable cluster ID:

```swift
let record = candidateSequenceRecordsByStableClusterID[stableClusterID]
    ?? unavailableSequenceRecord(
        identity: "candidate:\(stableClusterID)",
        displayName: row.alleleName
    )
installSequenceRecords([record])
```

Retain existing `publishSelectionState` behavior for the Inspector, but remove graphical-detail configuration, comments, evidence facts, width constraints, and mount counters from this viewport path.

- [ ] **Step 5: Run single-row controller tests and verify GREEN**

Run:

```bash
swift test --filter 'GenotypeResultViewportTests/testFullLengthMHCDetailIsEmpty|GenotypeResultViewportTests/testKnownAlleleRowShowsGenBank'
```

Expected: all new empty and single-row tests pass.

- [ ] **Step 6: Write failing multi-row ordering and identity tests**

Add a mixed known/candidate test whose requested selection order differs from visible order:

```swift
@MainActor
func testMixedAlleleRowsRenderInViewportOrderAndKeepDuplicateLabelsDistinct() {
    let controller = makeFullLengthMHCControllerWithKnownAndCandidates(
        candidateDisplayNames: ["Mafa-A1*001_1nt_nov", "Mafa-A1*001_1nt_nov"]
    )

    controller.testingSelectMatrixRows(
        genotypes: ["candidate-b", "NHP00001", "candidate-a"],
        sample: nil
    )

    let text = controller.testingAlleleSequenceText
    let orderedIDs = controller.testingVisibleSelectedAlleleRecordIDs
    XCTAssertEqual(orderedIDs, ["NHP00001", "candidate-a", "candidate-b"])
    XCTAssertEqual(text.components(separatedBy: "\n//\n").count, 3)
}
```

Add a test that selects EMBL, changes the selected rows, and expects EMBL to remain active.

- [ ] **Step 7: Run the multi-row tests and verify RED**

Run:

```bash
swift test --filter 'GenotypeResultViewportTests/testMixedAlleleRowsRender|GenotypeResultViewportTests/testAlleleSequenceFormatPersists'
```

Expected: tests fail because `showAlleleRowSelection` still builds facts text and drops candidate row targets.

- [ ] **Step 8: Resolve row targets in viewport order**

Add a matrix helper that returns selected row targets in current visible row order:

```swift
func selectedAlleleRowTargetsInViewportOrder(
    from targets: [GenotypeAnnotationSidecar.MatrixTarget]
) -> [GenotypeAnnotationSidecar.MatrixTarget] {
    let selected = Set(targets.compactMap { target -> GenotypeCandidateMatrixRowID? in
        guard case let .row(locus, genotype, stableClusterID) = target else { return nil }
        if let stableClusterID {
            return .candidate(stableClusterID: stableClusterID)
        }
        return .known(locus: locus, genotype: genotype)
    })
    return visibleRows.compactMap { row in
        guard selected.contains(row.id) else { return nil }
        return matrixTarget(row: row, sample: nil)
    }
}
```

In `showMatrixTargetSelection`, extract row targets first:

```swift
let rows = comparisonMatrix.selectedAlleleRowTargetsInViewportOrder(
    from: uniqueTargets
)
if !rows.isEmpty {
    showAlleleRowSelection(rows)
    return
}
clearSequenceDetail()
```

Rewrite `showAlleleRowSelection` to map every row target independently:

- `stableClusterID == nil`: resolve the known visualization by genotype.
- `stableClusterID != nil`: resolve the candidate catalog by stable ID.
- unresolved: append one format-aware unavailable record.

Pass the resulting array directly to `installSequenceRecords`. Do not sort it again or deduplicate by display name.

Column-only, cell-only, and non-row mixed selections call `clearSequenceDetail()` while retaining their existing Inspector selection state.

- [ ] **Step 9: Add DEBUG-only view hooks**

Expose:

```swift
var testingAlleleSequenceText: String {
    alleleSequenceDetailView.renderedText
}

var testingAlleleSequenceFormat:
    GenotypeAlleleSequenceDetailView.Format {
    alleleSequenceDetailView.currentFormat
}

func testingSelectAlleleSequenceFormat(
    _ format: GenotypeAlleleSequenceDetailView.Format
) {
    alleleSequenceDetailView.testingSelectFormat(format)
}
```

Remove obsolete test hooks that only count mounted known/candidate graphical detail views once no production or test caller remains.

- [ ] **Step 10: Run the viewport suite and update obsolete expectations**

Run:

```bash
swift test --filter GenotypeResultViewportTests
```

Expected initially: older tests that assert graphical overviews, facts rails, or the empty instructional caption fail. Update only tests for the full-length MHC result surface so they assert the approved sequence-only behavior. Do not weaken tests for other workflows or Inspector behavior.

Run the command again.

Expected: all `GenotypeResultViewportTests` pass.

- [ ] **Step 11: Commit controller integration**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: show selected MHC allele records"
```

### Task 4: Regression, Performance, and Debug Build Verification

**Files:**
- Modify only if a regression requires a scoped fix:
  - `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceRecord.swift`
  - `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceDetailView.swift`
  - `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
  - their corresponding tests

- [ ] **Step 1: Run the focused sequence-detail suites**

```bash
swift test --filter 'GenotypeAlleleSequenceRecordTests|GenotypeAlleleSequenceDetailViewTests|GenotypeResultViewportTests'
```

Expected: zero failures.

- [ ] **Step 2: Run the affected result-bundle and workflow suites**

```bash
swift test --filter 'ONTGenotypeResultBundleTests|FullLengthONTMHCGenotypingPipelineTests|GenotypeResultViewportTests'
```

Expected: zero failures.

- [ ] **Step 3: Verify code and worktree hygiene**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only intentional changes remain.

- [ ] **Step 4: Perform independent specification and code-quality review**

Review against:

```text
docs/superpowers/specs/2026-07-23-full-length-mhc-sequence-detail-pane-design.md
```

Block completion for:

- any BAM or on-selection disk access;
- any retained graphical/facts detail on this workflow surface;
- non-empty content without a selected row;
- record conflation by display name;
- selection order differing from viewport order;
- unbounded view/caching growth;
- incorrect or annotation-free EMBL output.

- [ ] **Step 5: Build the Debug app**

```bash
./scripts/build-app.sh --configuration debug --log-dir .superpowers/build-logs
```

Expected: successful build at:

```text
build/Debug/Lungfish.app
```

- [ ] **Step 6: Verify Debug identity and signature**

```bash
APP="$PWD/build/Debug/Lungfish.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
```

Expected:

```text
Lungfish Debug
Lungfish Debug
com.lungfish.browser.debug
```

and a valid signature.

- [ ] **Step 7: Relaunch only the exact Debug bundle**

Terminate only running Lungfish GUI executables, then:

```bash
open -n "$PWD/build/Debug/Lungfish.app"
```

Verify the live process command points to this worktree’s `build/Debug/Lungfish.app/Contents/MacOS/Lungfish` and the live bundle identifier is `com.lungfish.browser.debug`.

- [ ] **Step 8: Commit any verification-driven scoped fixes**

If verification required changes:

```bash
git add Sources/LungfishGenotypeUI Tests/LungfishGenotypeUITests
git commit -m "fix: finalize MHC sequence detail pane"
```

If no changes were required, do not create an empty commit.
