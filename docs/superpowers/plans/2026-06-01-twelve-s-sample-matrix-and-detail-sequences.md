# 12S Per-Sample Matrix + Detail Reference Sequences — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add (1) a Reference Sequences disclosure to the 12S Inspector Detail tab (selectable + copyable), and (2) a per-sample comparison matrix (samples as columns, species as rows) with imported CSV/TSV metadata columns, sortable/filterable like NVD.

**Architecture:** Extend `TwelveSTargetTableView` (kernel `BatchTableView` subclass) with dynamic per-sample columns; build a lazy reference-FASTA provider in the leaf; extend `TwelveSDetailPayload` + the App Detail section. Reuse the shared metadata-import facility (`SampleMetadataStore`, `inspectorTextMetadataImportPanel`).

**Tech Stack:** Swift 6.2, AppKit+SwiftUI, strict concurrency, XCTest. Reused: `FASTAReader.readAllSync()`, `SampleMetadataStore` (`records`/`columnNames`/`matchedSampleIds`), `PasteboardWriting`, `FeatureFilePanelFactory.inspectorTextMetadataImportPanel()`.

## Conventions

- Serialize `swift` invocations; always `--skip-update`. Leaf tests: `swift test --skip-update --filter LungfishTwelveSUITests`.
- GREEN = XCTest failures ⊆ known-environmental (or skipped) AND swift-testing = 0; `swift test` exit 0.
- Commit per task, ending messages with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Confirmed APIs: `FASTAReader(url:).readAllSync()` → `[Sequence]` (`.name`, `.sequence`); `TwelveSScientificNameCountRow.count(forSample:)`, `.targetIDs`, `.sampleCounts`; `SampleMetadataStore.records[sampleID]?[field]`, `.columnNames`, `.matchedSampleIds`.

---

## Phase FP1 — Detail-tab reference sequences

### Task 1: `TwelveSReferenceSequence` + provider

**Files:**
- Create: `Sources/LungfishTwelveSUI/TwelveSReferenceSequenceProvider.swift`
- Test: `Tests/LungfishTwelveSUITests/TwelveSReferenceSequenceProviderTests.swift`

- [ ] **Step 1: Failing test** (writes a tiny FASTA to a temp dir, maps targetIDs):

```swift
import XCTest
import LungfishIO
@testable import LungfishTwelveSUI

final class TwelveSReferenceSequenceProviderTests: XCTestCase {
    private func writeFASTA(_ text: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("twelve-s-ref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("reference.fasta")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testMapsTargetIDsToSequences() throws {
        let url = try writeFASTA(">human-a desc\nACGTACGT\n>dog\nTTTTGGGG\n")
        let provider = TwelveSReferenceSequenceProvider(referenceURL: url)
        let seqs = provider.sequences(forTargetIDs: ["human-a", "dog"])
        XCTAssertEqual(seqs.map(\.targetID), ["human-a", "dog"])
        XCTAssertEqual(seqs.first?.sequence, "ACGTACGT")
    }

    func testMissingTargetOmittedAndMissingFileEmpty() throws {
        let url = try writeFASTA(">human-a\nACGT\n")
        let provider = TwelveSReferenceSequenceProvider(referenceURL: url)
        XCTAssertEqual(provider.sequences(forTargetIDs: ["nope"]).count, 0)

        let missing = TwelveSReferenceSequenceProvider(
            referenceURL: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).fasta"))
        XCTAssertEqual(missing.sequences(forTargetIDs: ["human-a"]).count, 0)
    }
}
```

- [ ] **Step 2: Run → fails** (`TwelveSReferenceSequenceProvider` not found).
- [ ] **Step 3: Implement.** `TwelveSReferenceSequence { public let targetID: String; public let sequence: String }` (Sendable, public, memberwise public init). `TwelveSReferenceSequenceProvider` (`@unchecked Sendable` or plain class):
  - `init(referenceURL: URL)`.
  - private cached `[String: String]` built lazily on first access via `FASTAReader(url:).readAllSync()`, keyed by the header's first whitespace-delimited token (`seq.name` already excludes the `>`; split on space and take first to drop any description). On any throw, cache an empty map.
  - `func sequences(forTargetIDs ids: [String]) -> [TwelveSReferenceSequence]` returns, in `ids` order, the entries present in the map (omit missing).
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** `feat(12s): reference-FASTA provider mapping targetID -> sequence`.

### Task 2: `referenceSequences` on the payload + Copy-All FASTA

**Files:**
- Modify: `Sources/LungfishTwelveSUI/TwelveSDetailPayload.swift`
- Modify: `Sources/LungfishTwelveSUI/TwelveSCopyMenuProvider.swift` (add reference-FASTA formatter)
- Test: append to `TwelveSDetailPayloadTests.swift`

- [ ] **Step 1: Failing test:**

```swift
    func testTargetDetailCarriesReferenceSequencesAndFASTA() {
        let detail = TwelveSDetailPayload.TargetDetail(
            scientificName: "Homo sapiens", totalExactReads: 1, referenceTargetCount: 2,
            sampleEvidence: [], alternateTexts: [],
            referenceSequences: [
                .init(targetID: "human-a", sequence: "ACGT"),
                .init(targetID: "human-b", sequence: "TTTT"),
            ])
        XCTAssertEqual(detail.referenceSequences.count, 2)
        XCTAssertEqual(
            TwelveSCopyFormatting.referenceFASTA(detail.referenceSequences),
            ">human-a\nACGT\n>human-b\nTTTT")
    }
```

- [ ] **Step 2: Run → fails** (extra `referenceSequences:` arg / `referenceFASTA` missing).
- [ ] **Step 3: Implement.**
  - Add `public let referenceSequences: [TwelveSReferenceSequence]` to `TargetDetail` (default `[]` in the memberwise init used by tests; update the row-based `init(targetRow:sampleDisplayNames:)` to pass `referenceSequences: []` — the VC fills them in asynchronously, see Task 3).
  - Add `static func referenceFASTA(_ seqs: [TwelveSReferenceSequence]) -> String` to `TwelveSCopyFormatting`: `seqs.map { ">\($0.targetID)\n\($0.sequence)" }.joined(separator: "\n")`.
- [ ] **Step 4: Run → pass** (full leaf suite).
- [ ] **Step 5: Commit** `feat(12s): payload carries reference sequences + FASTA copy formatting`.

### Task 3: VC populates reference sequences asynchronously

**Files:**
- Modify: `TwelveSAmpliconResultViewController.swift`
- Test: append to `TwelveSTableViewTests.swift` (use the existing fixture's bundle; reference FASTA may be absent in fixtures → sequences empty, so assert the emit happens and is empty without a real FASTA, and add a temp-FASTA-backed bundle case if feasible).

- [ ] **Step 1: Failing test** — after configuring with a bundle whose `artifacts.referenceURL` points at a temp FASTA containing the fixture's target IDs, selecting that species emits a payload whose `referenceSequences` is non-empty.

> Build the bundle via `TwelveSFixtures.twoSampleResult()` but override `artifacts.referenceURL` to a temp FASTA you write containing `>human` and `>chicken` records (the fixture's targetIDs are `human`, `chicken`). If overriding the artifacts URL on the existing fixture is awkward, add a `TwelveSFixtures.twoSampleResult(referenceURL:)` parameter.

- [ ] **Step 2: Run → fails.**
- [ ] **Step 3: Implement.**
  - VC stores `private var referenceProvider: TwelveSReferenceSequenceProvider?`; set in `configure(result:)` from `result.artifacts.referenceURL`.
  - In `handleTargetSelection` single-row path: build the base payload (no sequences) and emit immediately; then asynchronously load sequences off-main and re-emit an updated payload:
    ```swift
    let targetIDs = row.targetIDs
    let provider = referenceProvider
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let seqs = provider?.sequences(forTargetIDs: targetIDs) ?? []
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case let .target(d)? = self.lastDetailPayload?.kind,
                      d.scientificName == row.scientificName else { return }
                self.emitDetail(TwelveSDetailPayload(kind: .target(d.withReferenceSequences(seqs))))
            }
        }
    }
    ```
    Add `func withReferenceSequences(_:) -> TargetDetail` (returns a copy). Guard re-emit against stale selection by comparing the current payload's species.
  - `TwelveSReferenceSequenceProvider` must be safe to call off-main (plain class, `@unchecked Sendable`, internal locking around the lazy cache).
- [ ] **Step 4: Run → pass** (full leaf suite).
- [ ] **Step 5: Commit** `feat(12s): VC loads matched reference sequences into the detail payload`.

### Task 4: Detail section renders the disclosure + copy

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/TwelveSDetailSection.swift`
- Test: append to `InspectorTwelveSModeTests.swift`

- [ ] **Step 1: Failing test** — `TwelveSDetailSectionViewModel.apply` with a target payload carrying 2 reference sequences exposes them (add a read-only `referenceSequences` passthrough on the VM for testing):

```swift
    func testDetailViewModelExposesReferenceSequences() {
        let vm = TwelveSDetailSectionViewModel()
        vm.apply(TwelveSDetailPayload(kind: .target(.init(
            scientificName: "Homo sapiens", totalExactReads: 1, referenceTargetCount: 2,
            sampleEvidence: [], alternateTexts: [],
            referenceSequences: [.init(targetID: "a", sequence: "ACGT"), .init(targetID: "b", sequence: "TTTT")]))))
        XCTAssertEqual(vm.referenceSequences.map(\.targetID), ["a", "b"])
    }
```

- [ ] **Step 2: Run → fails** (`referenceSequences` not on VM).
- [ ] **Step 3: Implement.**
  - VM: computed `var referenceSequences: [TwelveSReferenceSequence] { if case let .target(d) = payload?.kind { d.referenceSequences } else { [] } }`.
  - View: in `targetDetail`, add a `DisclosureGroup("Reference Sequences (\(detail.referenceSequences.count))", isExpanded: $isReferenceExpanded)` with `@State private var isReferenceExpanded = false` (collapsed default). Inside: `ForEach(detail.referenceSequences, id: \.targetID)` rendering `targetID` + monospaced `.textSelection(.enabled)` bases + a small **Copy** button per row (writes `seq.sequence`); plus a **Copy All as FASTA** button writing `TwelveSCopyFormatting.referenceFASTA(detail.referenceSequences)`. When empty, show "No reference sequences available." Copy via a `PasteboardWriting` (use `DefaultPasteboard()`; the section is App-side and not unit-tested for the actual clipboard, so a direct `NSPasteboard` write through `DefaultPasteboard` is fine).
- [ ] **Step 4: Run → pass** (filter `InspectorTwelveSModeTests`).
- [ ] **Step 5: Commit** `feat(inspector): 12S Detail tab shows collapsible reference sequences with copy`.

---

## Phase FP2 — Per-sample reads matrix columns

### Task 5: `TwelveSSampleMatrixColumns` pure helpers

**Files:**
- Create: `Sources/LungfishTwelveSUI/TwelveSSampleMatrixColumns.swift`
- Test: `Tests/LungfishTwelveSUITests/TwelveSSampleMatrixColumnsTests.swift`

Column-ID scheme (stable, parseable):
- reads column: `sample::<sampleID>::reads`
- metadata column: `sample::<sampleID>::meta::<field>`

- [ ] **Step 1: Failing tests:**

```swift
import XCTest
import LungfishIO
@testable import LungfishTwelveSUI

final class TwelveSSampleMatrixColumnsTests: XCTestCase {
    func testReadsColumnIDRoundTrip() {
        let id = TwelveSSampleMatrixColumns.readsColumnID(sampleID: "SampleA")
        XCTAssertEqual(id, "sample::SampleA::reads")
        let parsed = TwelveSSampleMatrixColumns.parse(id)
        XCTAssertEqual(parsed, .reads(sampleID: "SampleA"))
    }
    func testMetaColumnIDRoundTrip() {
        let id = TwelveSSampleMatrixColumns.metaColumnID(sampleID: "SampleA", field: "site")
        XCTAssertEqual(id, "sample::SampleA::meta::site")
        XCTAssertEqual(TwelveSSampleMatrixColumns.parse(id), .meta(sampleID: "SampleA", field: "site"))
    }
    func testNonMatrixIDParsesNil() {
        XCTAssertNil(TwelveSSampleMatrixColumns.parse("scientificName"))
    }
    func testReadsValueAndCompare() {
        let row = TwelveSScientificNameCountRow(scientificName: "X", targetIDs: ["t"],
            sampleCounts: ["SampleA": 12, "SampleB": 3], sampleExactReadTotals: ["SampleA": 100, "SampleB": 50], taxids: [])
        XCTAssertEqual(TwelveSSampleMatrixColumns.readsValue(row, sampleID: "SampleA"), "12")
        XCTAssertEqual(TwelveSSampleMatrixColumns.readsValue(row, sampleID: "SampleZ"), "0")
    }
}
```

- [ ] **Step 2: Run → fails.**
- [ ] **Step 3: Implement** `enum TwelveSSampleMatrixColumns`:
  - `enum Parsed: Equatable { case reads(sampleID: String); case meta(sampleID: String, field: String) }`
  - `static func readsColumnID(sampleID:) -> String` / `metaColumnID(sampleID:field:) -> String`
  - `static func parse(_ id: String) -> Parsed?` (split on `"::"`; `["sample", sid, "reads"]` → reads; `["sample", sid, "meta", field…]` → meta with field re-joined on `"::"` to tolerate fields containing the delimiter; else nil)
  - `static func readsValue(_ row: TwelveSScientificNameCountRow, sampleID:) -> String { String(row.count(forSample: sampleID)) }`
  - `static func metaValue(store: SampleMetadataStore?, sampleID:, field:) -> String { store?.records[sampleID]?[field] ?? "" }`
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** `feat(12s): sample-matrix column id scheme + value helpers`.

### Task 6: dynamic reads columns on `TwelveSTargetTableView`

**Files:**
- Modify: `TwelveSTargetTableView.swift`
- Test: `Tests/LungfishTwelveSUITests/TwelveSTableViewTests.swift`

- [ ] **Step 1: Failing test:**

```swift
    func testTargetTableAddsPerSampleReadsColumns() {
        let table = TwelveSTargetTableView()
        table.setSampleColumns(sampleIDs: ["SampleA", "SampleB"],
                               displayNames: ["SampleA": "Sample A", "SampleB": "Sample B"],
                               showReads: true, store: nil, metadataFields: [])
        let ids = table.tableView.tableColumns.map { $0.identifier.rawValue }
        XCTAssertTrue(ids.contains("sample::SampleA::reads"))
        XCTAssertTrue(ids.contains("sample::SampleB::reads"))
        // value + compare route through the dynamic id
        let row = TwelveSScientificNameCountRow(scientificName: "X", targetIDs: ["t"],
            sampleCounts: ["SampleA": 9], sampleExactReadTotals: ["SampleA": 100], taxids: [])
        XCTAssertEqual(table.cellContent(for: .init("sample::SampleA::reads"), row: row).text, "9")
        XCTAssertEqual(table.columnTypeHints["sample::SampleA::reads"], true)
    }
```

- [ ] **Step 2: Run → fails** (`setSampleColumns` missing).
- [ ] **Step 3: Implement** on `TwelveSTargetTableView`:
  - Store `private var sampleColumnIDs: [String] = []`, `private var sampleDisplayNames: [String: String] = [:]`, `private var metadataStore: SampleMetadataStore?`.
  - `func setSampleColumns(sampleIDs:[String], displayNames:[String:String], showReads:Bool, store:SampleMetadataStore?, metadataFields:[String])`:
    - remove existing `sample::`-prefixed columns from `tableView`.
    - if `showReads`, for each sampleID add an `NSTableColumn(identifier: readsColumnID)` titled `"\(name) reads"`, width 80, `sortDescriptorPrototype` ascending false.
    - for each metadata field × sampleID add `metaColumnID` column titled `"\(name) · \(field)"`, width 110.
    - store the active ID list + names + store; `reloadData()`.
  - Extend `cellContent(for:row:)`: if `TwelveSSampleMatrixColumns.parse(id)` is `.reads(sid)` → `(readsValue, .right, nil)`; `.meta(sid,field)` → `(metaValue(store,sid,field), .left, nil)`.
  - Extend `columnValue(for:row:)` similarly.
  - Extend `columnTypeHints`: include each reads column id → `true`; meta column id → `true` iff every present value parses numeric (cheap heuristic: mark numeric, the kernel falls back to string compare when parse fails) — simplest: reads numeric, meta text. (Document the choice.)
  - Extend `compareRows(by:)`: handle `.reads` numeric (`count(forSample:)`) and `.meta` string (`localizedStandardCompare`).
- [ ] **Step 4: Run → pass** (full leaf suite — ensure the `testDoesNotCreatePerSampleColumnsForLargeCohorts` invariant still holds: that test never calls `setSampleColumns`, so no `sample::` columns appear; confirm green).
- [ ] **Step 5: Commit** `feat(12s): per-sample reads columns on the target table (sortable/filterable)`.

### Task 7: VC drives sample columns (≤8 auto-show + toggle + note)

**Files:**
- Modify: `TwelveSAmpliconResultViewController.swift`
- Test: append to `TwelveSTableViewTests.swift`

- [ ] **Step 1: Failing test** — after `configureSamples` with 2 samples, reads columns auto-appear; with a (simulated) >8 selection they're suppressed unless toggled.

```swift
    func testReadsColumnsAutoShowForSmallCohortAndToggle() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult()
        vc.configure(result: bundle)
        let entries = bundle.samples.map { TwelveSSampleEntry(id: $0.sampleID, displayName: $0.displayName, exactReads: $0.exactMatchReads) }
        vc.configureSamples(entries, state: ClassifierSamplePickerState(allSamples: Set(entries.map(\.id))))
        XCTAssertTrue(vc.testingTargetColumnIDs.contains("sample::SampleA::reads"))

        vc.testingSetSampleColumnsForced(showReads: false)
        XCTAssertFalse(vc.testingTargetColumnIDs.contains("sample::SampleA::reads"))
    }
```

- [ ] **Step 2: Run → fails.**
- [ ] **Step 3: Implement.**
  - VC computes the ordered selected-sample list (preserve `sampleEntries` order, filtered to `selectedSamples`).
  - `private var showSampleReadsColumns: Bool` defaulting to `selectedSamples.count <= 8`; a "Sample Columns" menu (button in the header, e.g. an `NSButton` with a pull-down `NSMenu`) toggles `showReads` and per-metadata-field visibility.
  - `private func rebuildSampleColumns()` calls `targetTable.setSampleColumns(...)` with the current selection, names, `showSampleReadsColumns`, the store, and the chosen metadata fields. Called from `configureSamples`, the sample-selection observer, and `applyMetadataStore`.
  - When reads columns are auto-suppressed (selection > 8 and not forced on), set the action-bar/summary note: `"Per-sample columns hidden for N samples — use Sample Columns to show"`.
  - Testing seams: `var testingTargetColumnIDs: [String]` (the table's column ids), `func testingSetSampleColumnsForced(showReads:)`.
- [ ] **Step 4: Run → pass** (full leaf suite).
- [ ] **Step 5: Commit** `feat(12s): auto-show per-sample reads columns for <=8 samples with toggle + note`.

---

## Phase FP3 — Metadata import glue + metadata columns

### Task 8: VC metadata-store API + metadata columns

**Files:**
- Modify: `TwelveSAmpliconResultViewController.swift`
- Test: append to `TwelveSTableViewTests.swift`

- [ ] **Step 1: Failing test:**

```swift
    func testApplyMetadataStoreAddsPerSampleMetadataColumns() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult()
        vc.configure(result: bundle)
        let entries = bundle.samples.map { TwelveSSampleEntry(id: $0.sampleID, displayName: $0.displayName, exactReads: $0.exactMatchReads) }
        vc.configureSamples(entries, state: ClassifierSamplePickerState(allSamples: Set(entries.map(\.id))))

        let store = SampleMetadataStore(
            columnNames: ["site"],
            records: ["SampleA": ["site": "Hilo"], "SampleB": ["site": "Kona"]],
            matchedSampleIds: ["SampleA", "SampleB"])
        vc.applyMetadataStore(store)
        XCTAssertTrue(vc.testingTargetColumnIDs.contains("sample::SampleA::meta::site"))
        XCTAssertEqual(vc.testingTargetText(row: 0, column: "sample::SampleA::meta::site"), "Hilo")
    }
```

> Confirm the public `SampleMetadataStore(columnNames:records:matchedSampleIds:)` init exists (it does, per exploration). If `testingTargetText` reads `targetTable.displayedRows[row]`, ensure row 0 is *Homo sapiens* (human) which has `SampleA` reads in the fixture.

- [ ] **Step 2: Run → fails** (`applyMetadataStore` missing).
- [ ] **Step 3: Implement.**
  - `public func applyMetadataStore(_ store: SampleMetadataStore?)`: store it; set the Sample Columns menu's available metadata fields to `store?.columnNames ?? []` (default new fields visible); `rebuildSampleColumns()`.
  - `rebuildSampleColumns()` passes `metadataFields:` = the visible subset of `store.columnNames`.
- [ ] **Step 4: Run → pass** (full leaf suite).
- [ ] **Step 5: Commit** `feat(12s): apply imported metadata as per-sample columns`.

### Task 9: Import affordance + App glue

**Files:**
- Modify: `TwelveSAmpliconResultViewController.swift` (add `public var onMetadataImportRequested: (() -> Void)?` + an "Import Metadata…" item in the Sample Columns menu or action bar)
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift` (12S display path)
- Test: leaf test that firing the affordance calls the callback; App side verified by build + GUI smoke.

- [ ] **Step 1: Failing test** (leaf):

```swift
    func testImportMetadataAffordanceFiresCallback() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        var fired = false
        vc.onMetadataImportRequested = { fired = true }
        vc.testingTriggerMetadataImport()
        XCTAssertTrue(fired)
    }
```

- [ ] **Step 2: Run → fails.**
- [ ] **Step 3: Implement.**
  - VC: `public var onMetadataImportRequested: (() -> Void)?`; an "Import Metadata…" control (menu item) calls it; `func testingTriggerMetadataImport() { onMetadataImportRequested?() }`.
  - App glue (`displayTwelveSAmpliconResultBundleFromSidebar`): set `controller.onMetadataImportRequested = { [weak self, weak controller] in self?.presentTwelveSMetadataImport(into: controller, sampleIDs: Set(result.samples.map(\.sampleID))) }`. Implement `presentTwelveSMetadataImport` reusing the same panel + `SampleMetadataStore.scanForSampleColumn(csvData:knownSampleIds:)` + sample-column-selection flow NVD uses (read `InspectorViewController+MetadataImport.swift` and NVD's apply path and mirror the smallest equivalent), then `controller.applyMetadataStore(store)`.
- [ ] **Step 4: Run → pass** (leaf) + `swift build --skip-update` clean.
- [ ] **Step 5: Commit** `feat(12s): Import Metadata… affordance + App glue reusing shared importer`.

---

## Phase FP4 — Full suite + GUI smoke

### Task 10: Full regression sweep
- [ ] `swift build --skip-update` clean; `swift test --skip-update > /tmp/12s-fp.log 2>&1; echo SWIFT_EXIT=$?` → exit 0, failures ⊆ environmental/skipped, swift-testing 0.

### Task 11: GUI smoke (binding; needs computer-use MCP)
- [ ] Launch `.build/debug/Lungfish`; open `/Users/dho/Downloads/12S.lungfish`; select a 12S bundle. Verify ALL:
  1. Original: Inspector Detail tab, column sort/filter, copy menu, sample picker.
  2. **Reference Sequences** disclosure in Detail (collapsed) → expand → select + Copy a sequence + Copy All as FASTA.
  3. **Per-sample reads columns** appear (≤8 samples), are sortable/filterable; Sample Columns toggle works; large-cohort note shows when applicable.
  4. **Import Metadata…** → pick a CSV/TSV → per-sample metadata columns appear and sort/filter.

## Self-Review

- **Spec coverage:** reference sequences → FP1 (Tasks 1–4); per-sample matrix reads → FP2 (Tasks 5–7); metadata import + columns → FP3 (Tasks 8–9); smoke → FP4. All spec sections covered.
- **Placeholders:** none — code shown per step; the two "mirror NVD's apply path" notes point at concrete files.
- **Type consistency:** `TwelveSReferenceSequence`, `TwelveSReferenceSequenceProvider`, `TwelveSSampleMatrixColumns.{readsColumnID,metaColumnID,parse,readsValue,metaValue}`, column-ID scheme `sample::<id>::reads` / `sample::<id>::meta::<field>`, `setSampleColumns`, `applyMetadataStore`, `onMetadataImportRequested`, and the `testing*` seams are used consistently across tasks.
