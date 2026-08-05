# FASTA Selection Detail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the shared multi-FASTA table's Mini Map column and metadata footer with a collapsible, resizable pane that displays complete FASTA records for the selected rows.

**Architecture:** Keep `FASTACollectionViewController` as the sole route for ordinary and Savont-produced multi-record FASTA files. Add a pure formatter for canonical selection text and a focused AppKit detail view; the controller owns selection ordering and split visibility while the detail view owns sequence-text presentation and typography.

**Tech Stack:** Swift 6, AppKit (`NSTableView`, `NSSplitView`, `NSTextView`), LungfishCore `Sequence`, LungfishKit `ContentTypography`, XCTest

## Global Constraints

- This is presentation-only; Savont output and provenance remain unchanged.
- Selected records appear in current visible table order.
- FASTA sequence lines wrap at exactly 80 characters.
- The detail is read-only, selectable, scrollable, and collapsed with no selection.
- Existing search, sort, contextual actions, and Open in Browser remain available.
- Do not add a Savont-specific result controller or route.

---

### Task 1: Selection FASTA formatting

**Files:**
- Create: `Sources/LungfishApp/Views/Viewer/FASTASelectionDetailFormatter.swift`
- Create: `Tests/LungfishAppTests/FASTASelectionDetailFormatterTests.swift`

**Interfaces:**
- Consumes: `Sequence.name`, `.description`, and `.asString()`.
- Produces: `FASTASelectionDetailFormatter.text(for:) -> String` and `record(for:) -> String`.

- [ ] **Step 1: Write failing formatter tests**

```swift
func testRecordPreservesDescriptionAndWrapsAtEightyColumns() throws {
    let sequence = try Sequence(
        name: "cluster_ReadCount-12",
        description: "Savont consensus",
        alphabet: .dna,
        bases: String(repeating: "A", count: 85)
    )
    XCTAssertEqual(
        FASTASelectionDetailFormatter.record(for: sequence),
        ">cluster_ReadCount-12 Savont consensus\n"
            + String(repeating: "A", count: 80) + "\nAAAAA\n"
    )
}

func testTextJoinsRecordsWithOneBlankLine() throws {
    let first = try Sequence(name: "first", alphabet: .dna, bases: "ACGT")
    let second = try Sequence(name: "second", alphabet: .dna, bases: "TGCA")
    XCTAssertEqual(
        FASTASelectionDetailFormatter.text(for: [first, second]),
        ">first\nACGT\n\n>second\nTGCA\n"
    )
}

func testEmptySelectionProducesEmptyText() {
    XCTAssertEqual(FASTASelectionDetailFormatter.text(for: []), "")
}

func testEmptySequenceBodyStillProducesHeader() throws {
    let sequence = try Sequence(name: "empty", alphabet: .dna, bases: "")
    XCTAssertEqual(FASTASelectionDetailFormatter.record(for: sequence), ">empty\n")
}
```

- [ ] **Step 2: Run the focused tests and confirm the formatter is missing**

Run: `swift test --filter FASTASelectionDetailFormatterTests`

Expected: compilation fails because `FASTASelectionDetailFormatter` does not exist.

- [ ] **Step 3: Implement the pure formatter**

```swift
enum FASTASelectionDetailFormatter {
    static let lineWidth = 80

    static func text(for sequences: [Sequence]) -> String {
        sequences.map(record(for:)).joined(separator: "\n")
    }

    static func record(for sequence: Sequence) -> String {
        let description = sequence.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = [sequence.name, description]
            .compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
            .joined(separator: " ")
        let bases = sequence.asString()
        let lines = stride(from: 0, to: bases.count, by: lineWidth).map { offset -> String in
            let start = bases.index(bases.startIndex, offsetBy: offset)
            let end = bases.index(start, offsetBy: min(lineWidth, bases.count - offset))
            return String(bases[start..<end])
        }
        return ([">\(header)"] + lines).joined(separator: "\n") + "\n"
    }
}
```

An empty sequence emits its header and final newline. Parsed biological sequences contain ASCII symbols, so integer offsets are safe.

- [ ] **Step 4: Run formatter tests**

Run: `swift test --filter FASTASelectionDetailFormatterTests`

Expected: 4 tests pass.

- [ ] **Step 5: Commit the formatter**

```bash
git add Sources/LungfishApp/Views/Viewer/FASTASelectionDetailFormatter.swift Tests/LungfishAppTests/FASTASelectionDetailFormatterTests.swift
git commit -m "feat: format selected FASTA records"
```

---

### Task 2: Resizable FASTA selection detail pane

**Files:**
- Create: `Sources/LungfishApp/Views/Viewer/FASTASelectionDetailView.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift`
- Modify: `Tests/LungfishAppTests/FASTACollectionViewControllerTests.swift`

**Interfaces:**
- Consumes: `FASTASelectionDetailFormatter.text(for:)` and `displayedSequences`.
- Produces: `FASTASelectionDetailView.setSequences(_:)` plus controller debug inspection hooks.

- [ ] **Step 1: Write failing controller tests**

```swift
func testCollectionOmitsMiniMapAndStartsWithCollapsedDetail() throws {
    let vc = FASTACollectionViewController()
    _ = vc.view
    vc.configure(
        sequences: [try makeSequence(name: "seq1", bases: "AACCGGTT")],
        annotations: [], sourceNames: [:]
    )
    XCTAssertFalse(vc.testColumnIdentifiers.contains("minimap"))
    XCTAssertTrue(vc.testDetailIsCollapsed)
    XCTAssertEqual(vc.testDetailText, "")
}

func testDetailShowsMultipleSelectedRecordsInVisibleOrder() throws {
    let vc = FASTACollectionViewController()
    _ = vc.view
    vc.configure(
        sequences: [
            try makeSequence(name: "seq1", bases: "AACCGGTT"),
            try makeSequence(name: "seq2", bases: "ATATAT")
        ],
        annotations: [], sourceNames: [:]
    )
    vc.testSelectRows([0, 1])
    XCTAssertFalse(vc.testDetailIsCollapsed)
    XCTAssertEqual(vc.testDetailText, ">seq1\nAACCGGTT\n\n>seq2\nATATAT\n")
}

func testDetailFollowsFilteredAndSortedVisibleOrder() throws {
    let vc = FASTACollectionViewController()
    _ = vc.view
    vc.configure(
        sequences: [
            try makeSequence(name: "seq1", bases: "AAAA"),
            try makeSequence(name: "excluded", bases: "CCCC"),
            try makeSequence(name: "seq2", bases: "TTTT")
        ],
        annotations: [], sourceNames: [:]
    )
    vc.testFilter("seq")
    vc.testSort(column: "name", ascending: false)
    vc.testSelectRows([0, 1])
    XCTAssertEqual(vc.testDetailText, ">seq2\nTTTT\n\n>seq1\nAAAA\n")
}

func testClearingSelectionRestoresPreviousDetailHeight() throws {
    let vc = FASTACollectionViewController()
    _ = vc.view
    vc.configure(
        sequences: [try makeSequence(name: "seq1", bases: "AACCGGTT")],
        annotations: [], sourceNames: [:]
    )
    vc.testSelectRows([0])
    vc.testSetDetailHeight(180)
    vc.testSelectRows([])
    XCTAssertTrue(vc.testDetailIsCollapsed)
    vc.testSelectRows([0])
    XCTAssertEqual(vc.testDetailHeight, 180, accuracy: 1)
}
```

- [ ] **Step 2: Run controller tests and confirm new hooks are absent**

Run: `swift test --filter FASTACollectionViewControllerTests`

Expected: compilation fails because the new debug hooks do not exist.

- [ ] **Step 3: Build the focused detail view**

Create `FASTASelectionDetailView` with a borderless `NSScrollView` and `NSTextView` configured as follows:

```swift
textView.isEditable = false
textView.isSelectable = true
textView.isRichText = false
textView.usesFindPanel = true
textView.textContainerInset = NSSize(width: 10, height: 8)
textView.font = ContentTypography.current().font(for: .monospaced)
setAccessibilityLabel("Selected FASTA sequences")
```

Observe `.contentTextSizeDidChange` with `ContentTypographyViewObservation`. `setSequences(_:)` formats once and replaces `textView.string` only when text changes, preserving the text selection during font-only changes.

- [ ] **Step 4: Replace the fixed footer with a split view**

In `FASTACollectionViewController`:

1. Remove the fixed metadata footer and Mini Map column/cell branch.
2. Add a horizontal `NSSplitView` between the search bar and bottom edge.
3. Put the table scroll/empty state in its first arranged subview and `FASTASelectionDetailView` second.
4. Build selected sequences from `tableView.selectedRowIndexes` so records retain visible order.
5. Collapse detail on empty selection after remembering its nonzero height. Restore it on selection, clamped from 120 points through one third of available height.
6. On `configure`, clear selection, text, and detail visibility.
7. Use `FASTASelectionDetailFormatter.record(for:)` for Copy FASTA and viewer navigation helpers so headers and wrapping match.
8. Keep double-click Open in Browser and context actions unchanged; remove only the old footer button.

- [ ] **Step 5: Add deterministic debug hooks**

```swift
var testColumnIdentifiers: [String] { tableView.tableColumns.map(\.identifier.rawValue) }
var testDetailText: String { selectionDetailView.text }
var testDetailIsCollapsed: Bool { selectionDetailView.isHidden }
var testDetailHeight: CGFloat { selectionDetailView.frame.height }
func testSetDetailHeight(_ height: CGFloat) { setDetailHeightForTesting(height) }
func testFilter(_ text: String) { setFilterForTesting(text) }
func testSort(column: String, ascending: Bool) {
    setSortForTesting(column: column, ascending: ascending)
}
```

- [ ] **Step 6: Run focused integration tests**

Run:

```bash
swift test --filter FASTACollectionViewControllerTests
swift test --filter SequenceMenuOperationTests
swift test --filter ContentTypographyTests
swift test --filter ViewerRegressionTests
```

Expected: all tests pass.

- [ ] **Step 7: Commit the shared viewport change**

```bash
git add Sources/LungfishApp/Views/Viewer/FASTASelectionDetailView.swift Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift Tests/LungfishAppTests/FASTACollectionViewControllerTests.swift
git commit -m "feat: show selected records in FASTA viewport"
```

---

### Task 3: Integrated verification and debug build

**Files:**
- Modify only if verification finds a focused defect.

**Interfaces:**
- Consumes: shared FASTA selection behavior from Tasks 1-2.
- Produces: a verified, code-signed debug application.

- [ ] **Step 1: Run the complete relevant suite**

```bash
swift test --filter FASTACollection
swift test --filter FASTQOperationExecutionServiceTests/testSavont
swift test --filter SavontClusteringPipelineTests
git diff --check
```

Expected: all tests pass and `git diff --check` emits no output.

- [ ] **Step 2: Build and validate the debug app**

```bash
./scripts/build-app.sh --configuration debug
codesign --verify --deep --strict build/Debug/Lungfish.app
build/Debug/Lungfish.app/Contents/MacOS/lungfish-cli --version
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' build/Debug/Lungfish.app/Contents/Info.plist
```

Expected: signing succeeds, CLI reports `0.5.0-beta20`, and display name is `Lungfish Debug`.

- [ ] **Step 3: Replace the running worktree debug app**

Identify only the process using this worktree's `build/Debug/Lungfish.app/Contents/MacOS/Lungfish`, terminate it, launch the rebuilt app, and verify the new process uses that exact path. Do not quit unrelated release builds.

- [ ] **Step 4: Commit verification corrections only if needed**

If verification required a correction, stage only its focused files and commit with a message describing that correction. Otherwise, retain the two task commits unchanged.
