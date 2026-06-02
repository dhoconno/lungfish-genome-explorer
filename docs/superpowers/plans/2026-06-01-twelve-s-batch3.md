# 12S Batch 3 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** (1) default sort reads-desc, (2) hide rows with 0 reads across shown samples, (3) count-time abundance reassignment of cross-species identical-sequence reads (strict plurality), (4) right-click Learn More (NCBI) / View Photo (Wikipedia), (5) per-sample "% of sample 12S reads" column.

**Tech Stack:** Swift 6.2, AppKit+SwiftUI, strict concurrency, XCTest. Reuse `NSWorkspace.shared.open`, existing `TwelveSSampleMatrixColumns`, `ClassifiedReads`, `displayName`-based species grouping.

## Conventions
- Serialize `swift`; always `--skip-update`. Leaf: `swift test --skip-update --filter LungfishTwelveSUITests`. Workflow: `--filter LungfishWorkflowTests` (confirm target name on first run).
- GREEN = failures ⊆ environmental/skipped, swift-testing 0, `swift test` exit 0. Commit per task with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## Phase B3-1 — default sort + hide-zero + % column (leaf only)

### Task 1: default sort applied on every configure

**Files:** `TwelveSAmpliconResultViewController.swift`; test in `TwelveSTableViewTests.swift`.

- [ ] **Step 1: failing test** — after `configure`, the target table's first sort descriptor is `totalExactReads` ascending=false, even if a descriptor pre-existed.

```swift
    func testDefaultSortAlwaysReadsDescendingOnConfigure() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        // Pre-seed a different sort to prove configure re-asserts the default.
        vc.configure(result: TwelveSFixtures.twoSampleResult())
        vc.testingSetTargetSort(key: "scientificName", ascending: true)
        vc.configure(result: TwelveSFixtures.twoSampleResult())
        let d = vc.testingTargetSortDescriptor
        XCTAssertEqual(d?.key, "totalExactReads")
        XCTAssertEqual(d?.ascending, false)
    }
```

- [ ] **Step 2: run → fails** (`testingSetTargetSort`/`testingTargetSortDescriptor` missing).
- [ ] **Step 3: implement.** Rename `applyDefaultSortIfNeeded()` → `applyDefaultSort()`; drop the `isEmpty` guards (always set). Call it from `configure(result:)` after `applyFilters(notify:false)`. Add testing seams:
  ```swift
  var testingTargetSortDescriptor: NSSortDescriptor? { targetTable.tableView.sortDescriptors.first }
  func testingSetTargetSort(key: String, ascending: Bool) {
      targetTable.tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
  }
  ```
- [ ] **Step 4: run → pass** (full leaf suite — the existing `testDefaultTargetSortIsExactReadsDescending` must still pass).
- [ ] **Step 5: commit** `feat(12s): always default-sort targets by reads descending on load`.

### Task 2: hide rows with 0 reads across shown samples

**Files:** `TwelveSAmpliconResultViewController.swift`; test in `TwelveSTableViewTests.swift`.

- [ ] **Step 1: failing test** — a species with 0 reads in the shown sample is dropped, and reappears when the other sample is shown.

```swift
    func testRowsWithZeroReadsInShownSamplesAreHidden() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult() // human: A40/B5; chicken: A0/B15
        vc.configure(result: bundle)
        let entries = bundle.samples.map { TwelveSSampleEntry(id: $0.sampleID, displayName: $0.displayName, exactReads: $0.exactMatchReads) }
        vc.configureSamples(entries, state: ClassifierSamplePickerState(allSamples: Set(entries.map(\.id))))

        // Showing only SampleA: chicken (A=0) hidden → 1 row.
        vc.testingSetSelectedSamples(["SampleA"])
        XCTAssertEqual(vc.testingActiveTableRowCount, 1)
        XCTAssertEqual(vc.testingTargetText(row: 0, column: "scientificName"), "Homo sapiens")

        // Showing only SampleB: chicken has 15 → both human(B5) and chicken(B15) present → 2 rows.
        vc.testingSetSelectedSamples(["SampleB"])
        XCTAssertEqual(vc.testingActiveTableRowCount, 2)
    }
```

> NOTE: `twoSampleResult` must have a species that is zero in one sample. The current fixture has chicken A=0/B=15 and human A=40/B=5 — good. Verify before relying on it.

- [ ] **Step 2: run → fails.**
- [ ] **Step 3: implement** in `applyFilters`, after the existing sample-subset drop:
  ```swift
  // Hide species with no reads in the currently-shown samples (unconditional).
  let shown = isSampleSubset ? selectedSamples : allSampleIDs
  targetRows = targetRows.filter { row in
      shown.isEmpty ? row.totalExactReads > 0
                    : TwelveSRowAggregator.totalExactReads(row, selected: shown) > 0
  }
  ```
  (Unresolved rows keep their existing `minimumUnresolvedReads`/chimera filters; the request is about species rows.)
- [ ] **Step 4: run → pass** (full leaf suite — note `testActiveTableHostsRowsAndSwitchesWithMode` expects 2 target rows with all samples shown; both species are nonzero across A+B, so it stays 2. Confirm.)
- [ ] **Step 5: commit** `feat(12s): hide species rows with zero reads across shown samples`.

### Task 3: per-sample "% of sample" column

**Files:** `TwelveSSampleMatrixColumns.swift`, `TwelveSTargetTableView.swift`, `TwelveSAmpliconResultViewController.swift`; tests in `TwelveSSampleMatrixColumnsTests.swift` + `TwelveSTableViewTests.swift`.

- [ ] **Step 1: failing tests** (helpers + table):

```swift
// TwelveSSampleMatrixColumnsTests
    func testPctColumnIDRoundTripAndValue() {
        let id = TwelveSSampleMatrixColumns.pctColumnID(sampleID: "SampleA")
        XCTAssertEqual(id, "sample::SampleA::pct")
        XCTAssertEqual(TwelveSSampleMatrixColumns.parse(id), .pct(sampleID: "SampleA"))
        let row = TwelveSScientificNameCountRow(scientificName: "X", targetIDs: ["t"],
            sampleCounts: ["SampleA": 25], sampleExactReadTotals: ["SampleA": 100], taxids: [])
        XCTAssertEqual(TwelveSSampleMatrixColumns.pctValue(row, sampleID: "SampleA"), "25.0%")
        // zero denominator → 0.0%
        let z = TwelveSScientificNameCountRow(scientificName: "Y", targetIDs: ["t"],
            sampleCounts: ["SampleA": 0], sampleExactReadTotals: ["SampleA": 0], taxids: [])
        XCTAssertEqual(TwelveSSampleMatrixColumns.pctValue(z, sampleID: "SampleA"), "0.0%")
    }
```
```swift
// TwelveSTableViewTests
    func testPerSamplePercentColumnPresentAndNumeric() {
        let table = TwelveSTargetTableView()
        table.setSampleColumns(sampleIDs: ["SampleA"], displayNames: ["SampleA": "Sample A"],
                               showReads: true, showPercent: true, store: nil, metadataFields: [])
        XCTAssertTrue(table.tableView.tableColumns.map { $0.identifier.rawValue }.contains("sample::SampleA::pct"))
        XCTAssertEqual(table.columnTypeHints["sample::SampleA::pct"], true)
        let row = makeTargetRow(name: "X", sampleCounts: ["SampleA": 25], totals: ["SampleA": 100])
        XCTAssertEqual(table.cellContent(for: .init("sample::SampleA::pct"), row: row).text, "25.0%")
    }
```

- [ ] **Step 2: run → fails** (`pctColumnID`/`.pct`/`showPercent:` missing).
- [ ] **Step 3: implement.**
  - `TwelveSSampleMatrixColumns`: add `case pct(sampleID: String)`; `pctColumnID(sampleID:)` = `sample::<id>::pct`; parse `["sample", sid, "pct"]`; `pctValue(_:sampleID:)` = `count/total*100` formatted `"%.1f%%"` (0.0% when total 0).
  - `TwelveSTargetTableView.setSampleColumns` gains `showPercent: Bool`; when true add a `pct` column per sample titled `"<name> % of sample"`, width 95, ascending false. Route `.pct` in `cellContent`/`columnValue` (text = `pctValue`), `columnTypeHints` (numeric), and `compareRows` (numeric on the computed Double: `count/total`). **Update ALL existing `setSampleColumns` call sites/tests to pass `showPercent:`** (Task 6/7 tests from FP2 pass `showReads:` positionally — add the new label).
  - VC: add `showPercentColumnsOverride: Bool?` + `shouldShowPercentColumns` (same ≤8 auto rule), pass `showPercent:` in `rebuildSampleColumns`, and add a "Show Per-Sample % of Sample" item to the Sample Columns menu (mirror the reads toggle).
- [ ] **Step 4: run → pass** (full leaf suite; fix any `setSampleColumns` call sites missing the new arg).
- [ ] **Step 5: commit** `feat(12s): per-sample "% of sample 12S reads" column`.

---

## Phase B3-2 — species links (leaf + browser)

### Task 4: `TwelveSSpeciesLinks` URL builders

**Files:** `Sources/LungfishTwelveSUI/TwelveSSpeciesLinks.swift` (new); test `Tests/LungfishTwelveSUITests/TwelveSSpeciesLinksTests.swift`.

- [ ] **Step 1: failing tests:**

```swift
import XCTest
@testable import LungfishTwelveSUI

final class TwelveSSpeciesLinksTests: XCTestCase {
    func testNCBIWithTaxid() {
        XCTAssertEqual(TwelveSSpeciesLinks.ncbiTaxonomyURL(taxid: "9606", scientificName: "Homo sapiens").absoluteString,
                       "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/9606/")
    }
    func testNCBINameSearchFallback() {
        XCTAssertEqual(TwelveSSpeciesLinks.ncbiTaxonomyURL(taxid: nil, scientificName: "Gallus gallus").absoluteString,
                       "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/?term=Gallus%20gallus")
    }
    func testNCBIEmptyTaxidFallsBackToName() {
        XCTAssertEqual(TwelveSSpeciesLinks.ncbiTaxonomyURL(taxid: "", scientificName: "Canis lupus").absoluteString,
                       "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/?term=Canis%20lupus")
    }
    func testWikipediaUnderscoresAndEncoding() {
        XCTAssertEqual(TwelveSSpeciesLinks.wikipediaURL(scientificName: "Homo sapiens").absoluteString,
                       "https://en.wikipedia.org/wiki/Homo_sapiens")
    }
}
```

- [ ] **Step 2: run → fails.**
- [ ] **Step 3: implement** `enum TwelveSSpeciesLinks` with the two static funcs. NCBI: trim taxid; if nonempty use `/datasets/taxonomy/<taxid>/`, else `/datasets/taxonomy/?term=<encoded>` (encode with `.urlQueryAllowed`, space→`%20` — note `addingPercentEncoding` leaves space as `%20` only if space not in the allowed set; use a charset that encodes space). Wikipedia: replace spaces with `_` then percent-encode with `.urlPathAllowed`. Force-unwrap is acceptable for these fixed templates, but guard and fall back to a Google search URL if construction ever fails (so it never traps).
- [ ] **Step 4: run → pass.**
- [ ] **Step 5: commit** `feat(12s): species link URL builders (NCBI taxonomy + Wikipedia)`.

### Task 5: context-menu items + open

**Files:** `TwelveSCopyMenuProvider.swift`, `TwelveSAmpliconResultViewController.swift`; test `TwelveSCopyMenuTests.swift`.

- [ ] **Step 1: failing test** — single-row target menu includes the two species items with the right URLs; multi-row omits them. Use a spy for the open callback.

```swift
    func testTargetMenuIncludesSpeciesLinksForSingleSelection() {
        var opened: [URL] = []
        let menu = NSMenu()
        let row = target("Homo sapiens", taxid: "9606", reads: 5)
        TwelveSCopyMenuProvider.populateTargetMenu(menu, rows: [row], pasteboard: SpyPasteboard(),
                                                   onOpenURL: { opened.append($0) })
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Learn More About Homo sapiens"))
        XCTAssertTrue(titles.contains("View Photo of Homo sapiens"))
        menu.performActionForItem(at: titles.firstIndex(of: "Learn More About Homo sapiens")!)
        XCTAssertEqual(opened.first?.absoluteString, "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/9606/")
    }
    func testSpeciesLinksOmittedForMultiSelection() {
        let menu = NSMenu()
        let rows = [target("Homo sapiens", taxid: "9606", reads: 5), target("Gallus gallus", taxid: "9031", reads: 4)]
        TwelveSCopyMenuProvider.populateTargetMenu(menu, rows: rows, pasteboard: SpyPasteboard(), onOpenURL: { _ in })
        XCTAssertFalse(menu.items.map(\.title).contains { $0.hasPrefix("Learn More") })
    }
```

> The existing `populateTargetMenu` signature gains `onOpenURL: (URL) -> Void`. Update the VC call site and any other tests calling `populateTargetMenu`.

- [ ] **Step 2: run → fails** (signature mismatch / items absent).
- [ ] **Step 3: implement.**
  - `populateTargetMenu(_:rows:pasteboard:onOpenURL:)`: after the copy items, if `rows.count == 1`, add separator + "Learn More About \(name)" (→ `onOpenURL(TwelveSSpeciesLinks.ncbiTaxonomyURL(taxid: row.taxids.first, scientificName: name))`) and "View Photo of \(name)" (→ Wikipedia URL), via the existing `TwelveSCopyActionTarget` closure mechanism.
  - VC: `public var onOpenURLRequested: ((URL) -> Void)?`; in `populateCopyContextMenu` pass `onOpenURL: { [weak self] url in (self?.onOpenURLRequested ?? { NSWorkspace.shared.open($0) })(url) }` — default opens immediately; App may override. Add `testingTriggerOpenURL`-style seam only if needed.
- [ ] **Step 4: run → pass** (full leaf suite).
- [ ] **Step 5: commit** `feat(12s): right-click Learn More (NCBI) / View Photo (Wikipedia) for a species`.

---

## Phase B3-3 — count-time abundance reassignment (workflow)

### Task 6: `TwelveSAbundanceReassigner` (pure)

**Files:** `Sources/LungfishWorkflow/TwelveS/TwelveSAbundanceReassigner.swift` (new); test `Tests/LungfishWorkflowTests/TwelveSAbundanceReassignerTests.swift` (confirm the workflow test dir name first).

- [ ] **Step 1: failing tests:**

```swift
import XCTest
@testable import LungfishWorkflow

final class TwelveSAbundanceReassignerTests: XCTestCase {
    // species("human") has 1000 unambiguous reads via target tH; pan has 0.
    // ambiguous seq S (candidates tH, tP) has 7 reads in SampleA.
    func testHumanWinsStrictPlurality() {
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ["S": ["tH", "tP"]],
            unresolvedCounts: ["S": ["SampleA": 7]],
            countsByTarget: ["tH": ["SampleA": 1000]],
            speciesForTarget: ["tH": "human", "tP": "pan"],
            canonicalTargetForSpecies: ["human": "tH", "pan": "tP"]
        )
        XCTAssertEqual(result.countsByTarget["tH"]?["SampleA"], 1007)
        XCTAssertNil(result.unresolvedCounts["S"]) // moved out entirely
        XCTAssertEqual(result.moves.count, 1)
        XCTAssertEqual(result.moves.first?.toSpecies, "human")
    }
    func testExactTieStaysAmbiguous() {
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ["S": ["tH", "tP"]],
            unresolvedCounts: ["S": ["SampleA": 7]],
            countsByTarget: ["tH": ["SampleA": 500], "tP": ["SampleA": 500]],
            speciesForTarget: ["tH": "human", "tP": "pan"],
            canonicalTargetForSpecies: ["human": "tH", "pan": "tP"]
        )
        XCTAssertEqual(result.unresolvedCounts["S"]?["SampleA"], 7)
        XCTAssertTrue(result.moves.isEmpty)
    }
    func testAllZeroStaysAmbiguous() {
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ["S": ["tH", "tP"]],
            unresolvedCounts: ["S": ["SampleA": 7]],
            countsByTarget: [:],
            speciesForTarget: ["tH": "human", "tP": "pan"],
            canonicalTargetForSpecies: ["human": "tH", "pan": "tP"]
        )
        XCTAssertEqual(result.unresolvedCounts["S"]?["SampleA"], 7)
        XCTAssertTrue(result.moves.isEmpty)
    }
    func testReadConservation() {
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ["S": ["tH", "tP"]],
            unresolvedCounts: ["S": ["SampleA": 7, "SampleB": 3]],
            countsByTarget: ["tH": ["SampleA": 10]],
            speciesForTarget: ["tH": "human", "tP": "pan"],
            canonicalTargetForSpecies: ["human": "tH", "pan": "tP"]
        )
        let totalIn = 7 + 3 + 10
        let totalOut = (result.countsByTarget.values.flatMap { $0.values }.reduce(0,+))
                     + (result.unresolvedCounts.values.flatMap { $0.values }.reduce(0,+))
        XCTAssertEqual(totalIn, totalOut)
    }
}
```

- [ ] **Step 2: run → fails.**
- [ ] **Step 3: implement** `enum TwelveSAbundanceReassigner`:
  ```swift
  struct Move: Equatable { let sequence: String; let toSpecies: String; let toTarget: String; let reads: Int }
  struct Result { var countsByTarget: [String:[String:Int]]; var unresolvedCounts: [String:[String:Int]]; var moves: [Move] }
  static func reassign(ambiguousCandidates: [String:[String]],
                       unresolvedCounts: [String:[String:Int]],
                       countsByTarget: [String:[String:Int]],
                       speciesForTarget: [String:String],
                       canonicalTargetForSpecies: [String:String]) -> Result
  ```
  Logic: per ambiguous sequence, map candidate targetIDs → distinct species; total each species' reads = sum over its targets in `countsByTarget` (all samples). Find the strict max (>0, unique). If found, move that sequence's per-sample `unresolvedCounts[seq]` into `countsByTarget[canonicalTargetForSpecies[winner]]` (add per sample), delete `unresolvedCounts[seq]`, record a `Move`. Else leave untouched. Deterministic iteration (sort sequence keys; sort species for tie detection).
- [ ] **Step 4: run → pass.**
- [ ] **Step 5: commit** `feat(12s): pure abundance reassigner for cross-species identical sequences`.

### Task 7: wire reassigner into the workflow + provenance

**Files:** `TwelveSAmpliconMatchingWorkflow.swift`; test additions (a workflow-level test if a lightweight harness exists; otherwise rely on Task 6 + a focused `classifyInputs` test using a fake reader — confirm feasibility, else document the integration is covered by the pure test + GUI smoke re-run).

- [ ] **Step 1:** In `classifyInputs`, change the `.ambiguous` case to also record candidates: keep a local `var ambiguousCandidates: [String:[String]] = [:]`, and in the loop `case let .ambiguous(targetIDs): ambiguousCandidates[normalizedSequence] = targetIDs` (in addition to the existing unresolved accumulation). Build `speciesForTarget` (targetID→displayName) and `canonicalTargetForSpecies` (displayName→the longest-sequence/smallest-ID target) from the references the workflow already holds. After Pass A, call `TwelveSAbundanceReassigner.reassign(...)`, assign the returned `countsByTarget`/`unresolvedCounts` back onto `classified`, adjust `exactReadsBySample`/`ambiguousReadsBySample` by the moved per-sample sums, and log each move via the workflow's provenance/log channel (count of reads, from-species→to-species). 
- [ ] **Step 2:** Build the package + run the workflow tests + full leaf suite.

Run: `swift build --skip-update 2>&1 | grep -E "error:" || echo OK`
Run: `swift test --skip-update --filter LungfishWorkflowTests 2>&1 | tail -20`
Expected: build OK; workflow tests green.

- [ ] **Step 3: commit** `feat(12s): reassign cross-species identical-sequence reads to the abundant species at count time`.

---

## Phase B3-4 — full suite + GUI smoke

### Task 8: full regression
- [ ] `swift build --skip-update` clean; `swift test --skip-update > /tmp/12s-b3.log 2>&1; echo SWIFT_EXIT=$?` → exit 0, failures ⊆ environmental/skipped, swift-testing 0.

### Task 9: GUI smoke (needs computer-use MCP)
- [ ] Launch `.build/debug/Lungfish`; open `/Users/dho/Downloads/12S.lungfish`; select a 12S bundle. Verify: default sort reads-desc; no all-zero rows; per-sample `% of sample` column (toggle via Sample Columns); right-click → Learn More opens NCBI taxonomy, View Photo opens Wikipedia. If a bundle can be re-profiled, confirm an also_matches case folds into the abundant species (or note this needs a fresh 12S run to observe).

## Self-Review
- **Spec coverage:** #1→Task1, #2→Task2, #5→Task3, #4→Tasks4–5, #3→Tasks6–7, smoke→Tasks8–9. All five covered.
- **Placeholders:** none — code/tests shown; the one "confirm workflow test dir/harness" note is a lookup, not unspecified logic.
- **Type consistency:** `TwelveSSampleMatrixColumns.pct`/`pctColumnID`/`pctValue`, `showPercent:`, `TwelveSSpeciesLinks.{ncbiTaxonomyURL,wikipediaURL}`, `onOpenURLRequested`, `populateTargetMenu(...onOpenURL:)`, `TwelveSAbundanceReassigner.reassign`/`Move`/`Result` used consistently across tasks. NOTE: Task 3 changes `setSampleColumns` and Task 5 changes `populateTargetMenu` signatures — update ALL call sites and prior tests in the same task.
