# Batch Aggregated Classifier Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user clicks a batch group icon in the sidebar, display an aggregated flat table combining all samples with a Sample column, sample filtering, metadata columns, and detail pane — for Kraken2, EsViritu, and TaxTriage batch results.

**Architecture:** Each of the three classifier VCs (TaxonomyViewController, EsVirituResultViewController, TaxTriageResultViewController) gains a `configureBatch()` method that puts it into batch mode. In batch mode, a flat `NSTableView` replaces the hierarchical outline view, with a Sample column added. The existing `ClassifierSamplePickerState`, `MetadataColumnController`, and `ClassifierSamplePickerView` infrastructure is reused. The sidebar routing in MainSplitViewController is updated to dispatch `.batchGroup` items to the correct VC based on tool prefix. The Inspector shows collapsible sections for operation details, sample picker, metadata import, and source sample links.

**Tech Stack:** Swift 6.2, AppKit (NSTableView, NSSplitView), SwiftUI (Inspector sections), `@Observable` pattern

**Spec:** `docs/superpowers/specs/2026-04-06-batch-aggregated-classifier-views-design.md`

---

## File Map

### New Files
- `Sources/LungfishApp/Views/Metagenomics/BatchClassificationTableView.swift` — Flat NSTableView for Kraken2 batch mode
- `Sources/LungfishApp/Views/Metagenomics/BatchEsVirituTableView.swift` — Flat NSTableView for EsViritu batch mode
- `Sources/LungfishApp/Views/Metagenomics/BatchTaxTriageTableView.swift` — Flat NSTableView for TaxTriage batch mode (replaces segmented-control approach)
- `Sources/LungfishApp/Views/Inspector/Sections/BatchOperationDetailsSection.swift` — SwiftUI section for operation parameters
- `Sources/LungfishApp/Views/Inspector/Sections/SourceSamplesSection.swift` — SwiftUI section for clickable FASTQ links
- `Tests/LungfishAppTests/BatchAggregatedViewTests.swift` — Tests for batch row aggregation and table data

### Modified Files
- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` — Add `.batchGroup` routing in `displayContent(for:)` and `sidebarDidSelectItem`
- `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` — Add `configureBatch()`, batch mode flag, show/hide sunburst + flat table
- `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` — Add `configureBatch()`, batch mode flag, show/hide outline + flat table
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` — Add `configureBatch()`, replace segmented control with sample picker pattern
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` — Add batch operation details and source samples sections to `MetagenomicsResultSummarySection`
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` — Add `batchOperationDetails` and `sourceSampleURLs` to `DocumentSectionViewModel`

---

## Task 1: Batch Row Data Types

**Files:**
- Create: `Tests/LungfishAppTests/BatchAggregatedViewTests.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` (add struct at top)
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` (add struct at top)

### Step 1.1: Write batch row struct tests

- [ ] Create the test file with tests for the three batch row types and their construction from raw result data.

```swift
// Tests/LungfishAppTests/BatchAggregatedViewTests.swift
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class BatchAggregatedViewTests: XCTestCase {

    // MARK: - BatchClassificationRow

    func testBatchClassificationRowInit() {
        let row = BatchClassificationRow(
            sample: "sample1",
            taxonName: "Homo sapiens",
            taxId: 9606,
            rank: "S",
            rankDisplayName: "Species",
            readsDirect: 100,
            readsClade: 500,
            percentage: 12.5
        )
        XCTAssertEqual(row.sample, "sample1")
        XCTAssertEqual(row.taxonName, "Homo sapiens")
        XCTAssertEqual(row.taxId, 9606)
        XCTAssertEqual(row.rank, "S")
        XCTAssertEqual(row.rankDisplayName, "Species")
        XCTAssertEqual(row.readsDirect, 100)
        XCTAssertEqual(row.readsClade, 500)
        XCTAssertEqual(row.percentage, 12.5, accuracy: 0.001)
    }

    func testBatchClassificationRowsFromTree() {
        // Build a minimal TaxonTree by parsing a kreport string
        let kreport = """
        100.00\t1000\t0\tR\t1\troot
         50.00\t500\t0\tD\t2\t  Bacteria
         25.00\t250\t250\tS\t9606\t    Homo sapiens
         25.00\t250\t250\tS\t562\t    Escherichia coli
         50.00\t500\t500\tU\t0\tunclassified
        """
        let tree = try! KreportParser.parse(text: kreport)
        let rows = BatchClassificationRow.fromTree(tree, sampleId: "sampleA")

        // Should contain species-level nodes
        let speciesRows = rows.filter { $0.rank == "S" }
        XCTAssertEqual(speciesRows.count, 2)

        let homo = speciesRows.first { $0.taxonName == "Homo sapiens" }
        XCTAssertNotNil(homo)
        XCTAssertEqual(homo?.sample, "sampleA")
        XCTAssertEqual(homo?.readsDirect, 250)
        XCTAssertEqual(homo?.readsClade, 250)
    }

    // MARK: - BatchEsVirituRow

    func testBatchEsVirituRowInit() {
        let row = BatchEsVirituRow(
            sample: "sample2",
            virusName: "SARS-CoV-2",
            family: "Coronaviridae",
            assembly: "GCF_009858895.2",
            readCount: 1500,
            uniqueReads: 1200,
            rpkmf: 45.6,
            coverageBreadth: 0.95,
            coverageDepth: 12.3
        )
        XCTAssertEqual(row.sample, "sample2")
        XCTAssertEqual(row.virusName, "SARS-CoV-2")
        XCTAssertEqual(row.family, "Coronaviridae")
        XCTAssertEqual(row.readCount, 1500)
        XCTAssertEqual(row.uniqueReads, 1200)
    }

    func testBatchEsVirituRowsFromResult() {
        // Minimal EsVirituResult with one assembly containing one detection
        let detection = ViralDetection.makeStub(
            sampleId: "sampleB",
            name: "Influenza A",
            accession: "NC_007373",
            assembly: "GCF_000865725.1",
            readCount: 300,
            meanCoverage: 8.5,
            avgReadIdentity: 0.97
        )
        let assembly = ViralAssembly(
            assembly: "GCF_000865725.1",
            assemblyLength: 13500,
            name: "Influenza A",
            family: "Orthomyxoviridae",
            genus: "Alphainfluenzavirus",
            species: "Influenza A virus",
            totalReads: 300,
            rpkmf: 22.2,
            meanCoverage: 8.5,
            avgReadIdentity: 0.97,
            contigs: [detection]
        )
        let rows = BatchEsVirituRow.fromAssemblies([assembly], sampleId: "sampleB")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sample, "sampleB")
        XCTAssertEqual(rows[0].virusName, "Influenza A")
        XCTAssertEqual(rows[0].readCount, 300)
    }
}
```

- [ ] Run the test to verify it fails (structs don't exist yet).

Run: `swift test --filter BatchAggregatedViewTests 2>&1 | tail -5`
Expected: Compilation errors — `BatchClassificationRow`, `BatchEsVirituRow` not found.

### Step 1.2: Implement BatchClassificationRow

- [ ] Add the struct to TaxonomyViewController.swift (before the class declaration):

```swift
// Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift
// Add at the top of the file, after imports, before the class

/// A flat row for the batch aggregated classification table.
/// Each row represents one taxon from one sample's kreport.
struct BatchClassificationRow: Sendable {
    let sample: String
    let taxonName: String
    let taxId: Int
    let rank: String
    let rankDisplayName: String
    let readsDirect: Int
    let readsClade: Int
    let percentage: Double

    /// Extract all nodes from a TaxonTree as flat rows tagged with a sample ID.
    /// Includes all nodes in the tree (not just species), matching the single-sample outline view's content.
    static func fromTree(_ tree: TaxonTree, sampleId: String) -> [BatchClassificationRow] {
        tree.allNodes().compactMap { node in
            // Skip the root node and unclassified node
            guard node.taxId != 1, node.rank != .unclassified else { return nil }
            return BatchClassificationRow(
                sample: sampleId,
                taxonName: node.name,
                taxId: node.taxId,
                rank: node.rank.code,
                rankDisplayName: node.rank.displayName,
                readsDirect: node.readsDirect,
                readsClade: node.readsClade,
                percentage: node.fractionClade * 100.0
            )
        }
    }
}
```

### Step 1.3: Implement BatchEsVirituRow

- [ ] Add the struct to EsVirituResultViewController.swift (before the class declaration):

```swift
// Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift
// Add at the top of the file, after imports, before the class

/// A flat row for the batch aggregated EsViritu table.
/// Each row represents one viral assembly detection from one sample.
struct BatchEsVirituRow: Sendable {
    let sample: String
    let virusName: String
    let family: String?
    let assembly: String
    let readCount: Int
    let uniqueReads: Int
    let rpkmf: Double
    let coverageBreadth: Double
    let coverageDepth: Double

    /// Convert a list of viral assemblies into flat batch rows tagged with a sample ID.
    static func fromAssemblies(_ assemblies: [ViralAssembly], sampleId: String) -> [BatchEsVirituRow] {
        assemblies.map { asm in
            BatchEsVirituRow(
                sample: sampleId,
                virusName: asm.name,
                family: asm.family,
                assembly: asm.assembly,
                readCount: asm.totalReads,
                uniqueReads: 0, // Populated later from unique read computation
                rpkmf: asm.rpkmf,
                coverageBreadth: 0, // Computed from coverage windows
                coverageDepth: asm.meanCoverage
            )
        }
    }
}
```

### Step 1.4: Run tests to verify they pass

- [ ] Run: `swift test --filter BatchAggregatedViewTests 2>&1 | tail -10`

Expected: All tests pass. If `ViralDetection.makeStub` doesn't exist, add a test helper extension in the test file:

```swift
extension ViralDetection {
    static func makeStub(
        sampleId: String = "stub",
        name: String = "Stub Virus",
        accession: String = "NC_000001",
        assembly: String = "GCF_000000001.1",
        readCount: Int = 100,
        meanCoverage: Double = 5.0,
        avgReadIdentity: Double = 0.95
    ) -> ViralDetection {
        ViralDetection(
            sampleId: sampleId,
            name: name,
            description: "",
            length: 10000,
            segment: nil,
            accession: accession,
            assembly: assembly,
            assemblyLength: 30000,
            kingdom: nil, phylum: nil, tclass: nil, order: nil,
            family: "Testviridae", genus: "Testvirus", species: name, subspecies: nil,
            rpkmf: 10.0,
            readCount: readCount,
            coveredBases: 5000,
            meanCoverage: meanCoverage,
            avgReadIdentity: avgReadIdentity,
            pi: 0.01,
            filteredReadsInSample: 100000
        )
    }
}
```

### Step 1.5: Commit

- [ ] ```bash
git add Tests/LungfishAppTests/BatchAggregatedViewTests.swift \
      Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift \
      Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift
git commit -m "feat: add BatchClassificationRow and BatchEsVirituRow data types for batch aggregation"
```

---

## Task 2: BatchClassificationTableView (Kraken2 Flat Table)

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/BatchClassificationTableView.swift`

### Step 2.1: Create the flat table view

- [ ] Create `BatchClassificationTableView` — a flat `NSTableView` wrapper for batch Kraken2 results. Model it on the existing `TaxTriageBatchOverviewView` pattern (flat NSTableView with data source/delegate):

```swift
// Sources/LungfishApp/Views/Metagenomics/BatchClassificationTableView.swift
import AppKit

/// Flat table view for batch Kraken2 classification results.
/// Displays one row per (sample, taxon) pair with sortable columns.
@MainActor
final class BatchClassificationTableView: NSView {

    // MARK: - Column IDs

    private enum ColumnID {
        static let sample = NSUserInterfaceItemIdentifier("sample")
        static let name = NSUserInterfaceItemIdentifier("name")
        static let rank = NSUserInterfaceItemIdentifier("rank")
        static let readsDirect = NSUserInterfaceItemIdentifier("readsDirect")
        static let readsClade = NSUserInterfaceItemIdentifier("readsClade")
        static let percent = NSUserInterfaceItemIdentifier("percent")
    }

    // MARK: - Properties

    private(set) var tableView: NSTableView!
    private var scrollView: NSScrollView!
    var metadataColumns = MetadataColumnController()

    var displayedRows: [BatchClassificationRow] = [] {
        didSet { tableView.reloadData() }
    }

    /// Fired when a single row is selected. Provides the row.
    var onRowSelected: ((BatchClassificationRow) -> Void)?

    /// Fired when multiple rows are selected. Provides the count.
    var onMultipleRowsSelected: ((Int) -> Void)?

    /// Fired when selection is cleared.
    var onSelectionCleared: (() -> Void)?

    // MARK: - Sort State

    private var currentSortKey: String = "readsClade"
    private var currentSortAscending: Bool = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTableView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTableView()
    }

    // MARK: - Setup

    private func setupTableView() {
        let tv = NSTableView()
        tv.style = .inset
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsMultipleSelection = true
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tv.rowHeight = 22

        func addColumn(_ id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat = 60) {
            let col = NSTableColumn(identifier: id)
            col.title = title
            col.width = width
            col.minWidth = minWidth
            col.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
            tv.addTableColumn(col)
        }

        addColumn(ColumnID.sample, title: "Sample", width: 140)
        addColumn(ColumnID.name, title: "Taxon Name", width: 200, minWidth: 120)
        addColumn(ColumnID.rank, title: "Rank", width: 80)
        addColumn(ColumnID.readsDirect, title: "Reads (Direct)", width: 100)
        addColumn(ColumnID.readsClade, title: "Reads (Clade)", width: 100)
        addColumn(ColumnID.percent, title: "%", width: 70)

        tv.dataSource = self
        tv.delegate = self

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sv)

        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: topAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        self.tableView = tv
        self.scrollView = sv

        metadataColumns.install(on: tv)
    }

    // MARK: - Sort

    func sortRows() {
        switch currentSortKey {
        case "sample":
            displayedRows.sort { currentSortAscending ? $0.sample < $1.sample : $0.sample > $1.sample }
        case "name":
            displayedRows.sort { currentSortAscending ? $0.taxonName.localizedCaseInsensitiveCompare($1.taxonName) == .orderedAscending : $0.taxonName.localizedCaseInsensitiveCompare($1.taxonName) == .orderedDescending }
        case "rank":
            displayedRows.sort { currentSortAscending ? $0.rank < $1.rank : $0.rank > $1.rank }
        case "readsDirect":
            displayedRows.sort { currentSortAscending ? $0.readsDirect < $1.readsDirect : $0.readsDirect > $1.readsDirect }
        case "readsClade":
            displayedRows.sort { currentSortAscending ? $0.readsClade < $1.readsClade : $0.readsClade > $1.readsClade }
        case "percent":
            displayedRows.sort { currentSortAscending ? $0.percentage < $1.percentage : $0.percentage > $1.percentage }
        default:
            break
        }
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDataSource

extension BatchClassificationTableView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sort = tableView.sortDescriptors.first, let key = sort.key else { return }
        currentSortKey = key
        currentSortAscending = sort.ascending
        sortRows()
    }
}

// MARK: - NSTableViewDelegate

extension BatchClassificationTableView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < displayedRows.count else { return nil }
        let item = displayedRows[row]

        // Check metadata columns first
        if MetadataColumnController.isMetadataColumn(tableColumn.identifier) {
            return metadataColumns.cellForColumn(tableColumn, sampleId: item.sample)
        }

        let text: String
        let alignment: NSTextAlignment

        switch tableColumn.identifier {
        case ColumnID.sample:
            text = item.sample
            alignment = .left
        case ColumnID.name:
            text = item.taxonName
            alignment = .left
        case ColumnID.rank:
            text = item.rankDisplayName
            alignment = .left
        case ColumnID.readsDirect:
            text = NumberFormatter.localizedString(from: NSNumber(value: item.readsDirect), number: .decimal)
            alignment = .right
        case ColumnID.readsClade:
            text = NumberFormatter.localizedString(from: NSNumber(value: item.readsClade), number: .decimal)
            alignment = .right
        case ColumnID.percent:
            text = String(format: "%.2f%%", item.percentage)
            alignment = .right
        default:
            return nil
        }

        let cellId = NSUserInterfaceItemIdentifier("BatchClassCell")
        let cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = cellId
        cell.stringValue = text
        cell.alignment = alignment
        cell.font = .systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let indices = tableView.selectedRowIndexes
        if indices.count == 0 {
            onSelectionCleared?()
        } else if indices.count == 1, let idx = indices.first, idx < displayedRows.count {
            onRowSelected?(displayedRows[idx])
        } else {
            onMultipleRowsSelected?(indices.count)
        }
    }
}
```

### Step 2.2: Commit

- [ ] ```bash
git add Sources/LungfishApp/Views/Metagenomics/BatchClassificationTableView.swift
git commit -m "feat: add BatchClassificationTableView for Kraken2 batch mode"
```

---

## Task 3: BatchEsVirituTableView (EsViritu Flat Table)

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/BatchEsVirituTableView.swift`

### Step 3.1: Create the flat table view

- [ ] Create `BatchEsVirituTableView` — identical structure to `BatchClassificationTableView`, with EsViritu-specific columns:

```swift
// Sources/LungfishApp/Views/Metagenomics/BatchEsVirituTableView.swift
import AppKit

/// Flat table view for batch EsViritu viral detection results.
@MainActor
final class BatchEsVirituTableView: NSView {

    private enum ColumnID {
        static let sample = NSUserInterfaceItemIdentifier("sample")
        static let name = NSUserInterfaceItemIdentifier("name")
        static let family = NSUserInterfaceItemIdentifier("family")
        static let assembly = NSUserInterfaceItemIdentifier("assembly")
        static let reads = NSUserInterfaceItemIdentifier("reads")
        static let uniqueReads = NSUserInterfaceItemIdentifier("uniqueReads")
        static let rpkmf = NSUserInterfaceItemIdentifier("rpkmf")
        static let coverage = NSUserInterfaceItemIdentifier("coverage")
        static let identity = NSUserInterfaceItemIdentifier("identity")
    }

    private(set) var tableView: NSTableView!
    private var scrollView: NSScrollView!
    var metadataColumns = MetadataColumnController()

    var displayedRows: [BatchEsVirituRow] = [] {
        didSet { tableView.reloadData() }
    }

    var onRowSelected: ((BatchEsVirituRow) -> Void)?
    var onMultipleRowsSelected: ((Int) -> Void)?
    var onSelectionCleared: (() -> Void)?

    private var currentSortKey: String = "reads"
    private var currentSortAscending: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTableView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTableView()
    }

    private func setupTableView() {
        let tv = NSTableView()
        tv.style = .inset
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsMultipleSelection = true
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tv.rowHeight = 22

        func addColumn(_ id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat = 60) {
            let col = NSTableColumn(identifier: id)
            col.title = title
            col.width = width
            col.minWidth = minWidth
            col.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
            tv.addTableColumn(col)
        }

        addColumn(ColumnID.sample, title: "Sample", width: 140)
        addColumn(ColumnID.name, title: "Virus Name", width: 200, minWidth: 120)
        addColumn(ColumnID.family, title: "Family", width: 120)
        addColumn(ColumnID.assembly, title: "Assembly", width: 140)
        addColumn(ColumnID.reads, title: "Reads", width: 80)
        addColumn(ColumnID.uniqueReads, title: "Unique Reads", width: 100)
        addColumn(ColumnID.rpkmf, title: "RPKMF", width: 80)
        addColumn(ColumnID.coverage, title: "Coverage", width: 80)

        tv.dataSource = self
        tv.delegate = self

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sv)

        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: topAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        self.tableView = tv
        self.scrollView = sv

        metadataColumns.install(on: tv)
    }

    func sortRows() {
        switch currentSortKey {
        case "sample":
            displayedRows.sort { currentSortAscending ? $0.sample < $1.sample : $0.sample > $1.sample }
        case "name":
            displayedRows.sort { currentSortAscending ? $0.virusName.localizedCaseInsensitiveCompare($1.virusName) == .orderedAscending : $0.virusName.localizedCaseInsensitiveCompare($1.virusName) == .orderedDescending }
        case "family":
            displayedRows.sort { currentSortAscending ? ($0.family ?? "") < ($1.family ?? "") : ($0.family ?? "") > ($1.family ?? "") }
        case "reads":
            displayedRows.sort { currentSortAscending ? $0.readCount < $1.readCount : $0.readCount > $1.readCount }
        case "uniqueReads":
            displayedRows.sort { currentSortAscending ? $0.uniqueReads < $1.uniqueReads : $0.uniqueReads > $1.uniqueReads }
        case "rpkmf":
            displayedRows.sort { currentSortAscending ? $0.rpkmf < $1.rpkmf : $0.rpkmf > $1.rpkmf }
        case "coverage":
            displayedRows.sort { currentSortAscending ? $0.coverageDepth < $1.coverageDepth : $0.coverageDepth > $1.coverageDepth }
        default:
            break
        }
        tableView.reloadData()
    }
}

extension BatchEsVirituTableView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sort = tableView.sortDescriptors.first, let key = sort.key else { return }
        currentSortKey = key
        currentSortAscending = sort.ascending
        sortRows()
    }
}

extension BatchEsVirituTableView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < displayedRows.count else { return nil }
        let item = displayedRows[row]

        if MetadataColumnController.isMetadataColumn(tableColumn.identifier) {
            return metadataColumns.cellForColumn(tableColumn, sampleId: item.sample)
        }

        let text: String
        let alignment: NSTextAlignment

        switch tableColumn.identifier {
        case ColumnID.sample:
            text = item.sample; alignment = .left
        case ColumnID.name:
            text = item.virusName; alignment = .left
        case ColumnID.family:
            text = item.family ?? "—"; alignment = .left
        case ColumnID.assembly:
            text = item.assembly; alignment = .left
        case ColumnID.reads:
            text = NumberFormatter.localizedString(from: NSNumber(value: item.readCount), number: .decimal)
            alignment = .right
        case ColumnID.uniqueReads:
            text = item.uniqueReads > 0 ? NumberFormatter.localizedString(from: NSNumber(value: item.uniqueReads), number: .decimal) : "—"
            alignment = .right
        case ColumnID.rpkmf:
            text = String(format: "%.1f", item.rpkmf); alignment = .right
        case ColumnID.coverage:
            text = String(format: "%.1fx", item.coverageDepth); alignment = .right
        default:
            return nil
        }

        let cellId = NSUserInterfaceItemIdentifier("BatchEsVirituCell")
        let cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = cellId
        cell.stringValue = text
        cell.alignment = alignment
        cell.font = .systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let indices = tableView.selectedRowIndexes
        if indices.count == 0 {
            onSelectionCleared?()
        } else if indices.count == 1, let idx = indices.first, idx < displayedRows.count {
            onRowSelected?(displayedRows[idx])
        } else {
            onMultipleRowsSelected?(indices.count)
        }
    }
}
```

### Step 3.2: Commit

- [ ] ```bash
git add Sources/LungfishApp/Views/Metagenomics/BatchEsVirituTableView.swift
git commit -m "feat: add BatchEsVirituTableView for EsViritu batch mode"
```

---

## Task 4: BatchTaxTriageTableView (TaxTriage Flat Table)

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/BatchTaxTriageTableView.swift`

### Step 4.1: Create the flat table view

- [ ] Create `BatchTaxTriageTableView` — flat table for TaxTriage batch mode. Columns match existing TaxTriage organism table but add Sample column. Uses existing `TaxTriageMetric` as the row type (it already has a `sample` field):

```swift
// Sources/LungfishApp/Views/Metagenomics/BatchTaxTriageTableView.swift
import AppKit

/// Flat table view for batch TaxTriage results.
/// Each row is one (sample, organism) pair from TaxTriageMetric.
@MainActor
final class BatchTaxTriageTableView: NSView {

    private enum ColumnID {
        static let sample = NSUserInterfaceItemIdentifier("sample")
        static let organism = NSUserInterfaceItemIdentifier("organism")
        static let tassScore = NSUserInterfaceItemIdentifier("tassScore")
        static let reads = NSUserInterfaceItemIdentifier("reads")
        static let confidence = NSUserInterfaceItemIdentifier("confidence")
        static let coverageBreadth = NSUserInterfaceItemIdentifier("coverageBreadth")
        static let coverageDepth = NSUserInterfaceItemIdentifier("coverageDepth")
        static let abundance = NSUserInterfaceItemIdentifier("abundance")
    }

    private(set) var tableView: NSTableView!
    private var scrollView: NSScrollView!
    var metadataColumns = MetadataColumnController()

    var displayedRows: [TaxTriageMetric] = [] {
        didSet { tableView.reloadData() }
    }

    var onRowSelected: ((TaxTriageMetric) -> Void)?
    var onMultipleRowsSelected: ((Int) -> Void)?
    var onSelectionCleared: (() -> Void)?

    private var currentSortKey: String = "tassScore"
    private var currentSortAscending: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTableView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTableView()
    }

    private func setupTableView() {
        let tv = NSTableView()
        tv.style = .inset
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsMultipleSelection = true
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tv.rowHeight = 22

        func addColumn(_ id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat = 60) {
            let col = NSTableColumn(identifier: id)
            col.title = title
            col.width = width
            col.minWidth = minWidth
            col.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
            tv.addTableColumn(col)
        }

        addColumn(ColumnID.sample, title: "Sample", width: 140)
        addColumn(ColumnID.organism, title: "Organism", width: 200, minWidth: 120)
        addColumn(ColumnID.tassScore, title: "TASS", width: 70)
        addColumn(ColumnID.reads, title: "Reads", width: 80)
        addColumn(ColumnID.confidence, title: "Confidence", width: 90)
        addColumn(ColumnID.coverageBreadth, title: "Breadth", width: 80)
        addColumn(ColumnID.coverageDepth, title: "Depth", width: 70)
        addColumn(ColumnID.abundance, title: "Abundance", width: 80)

        tv.dataSource = self
        tv.delegate = self

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sv)

        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: topAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        self.tableView = tv
        self.scrollView = sv

        metadataColumns.install(on: tv)
    }

    func sortRows() {
        switch currentSortKey {
        case "sample":
            displayedRows.sort { currentSortAscending ? ($0.sample ?? "") < ($1.sample ?? "") : ($0.sample ?? "") > ($1.sample ?? "") }
        case "organism":
            displayedRows.sort { currentSortAscending ? $0.organism.localizedCaseInsensitiveCompare($1.organism) == .orderedAscending : $0.organism.localizedCaseInsensitiveCompare($1.organism) == .orderedDescending }
        case "tassScore":
            displayedRows.sort { currentSortAscending ? $0.tassScore < $1.tassScore : $0.tassScore > $1.tassScore }
        case "reads":
            displayedRows.sort { currentSortAscending ? $0.reads < $1.reads : $0.reads > $1.reads }
        case "confidence":
            displayedRows.sort { currentSortAscending ? ($0.confidence ?? "") < ($1.confidence ?? "") : ($0.confidence ?? "") > ($1.confidence ?? "") }
        case "coverageBreadth":
            displayedRows.sort { currentSortAscending ? ($0.coverageBreadth ?? 0) < ($1.coverageBreadth ?? 0) : ($0.coverageBreadth ?? 0) > ($1.coverageBreadth ?? 0) }
        case "coverageDepth":
            displayedRows.sort { currentSortAscending ? ($0.coverageDepth ?? 0) < ($1.coverageDepth ?? 0) : ($0.coverageDepth ?? 0) > ($1.coverageDepth ?? 0) }
        case "abundance":
            displayedRows.sort { currentSortAscending ? ($0.abundance ?? 0) < ($1.abundance ?? 0) : ($0.abundance ?? 0) > ($1.abundance ?? 0) }
        default:
            break
        }
        tableView.reloadData()
    }
}

extension BatchTaxTriageTableView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sort = tableView.sortDescriptors.first, let key = sort.key else { return }
        currentSortKey = key
        currentSortAscending = sort.ascending
        sortRows()
    }
}

extension BatchTaxTriageTableView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < displayedRows.count else { return nil }
        let item = displayedRows[row]

        if MetadataColumnController.isMetadataColumn(tableColumn.identifier) {
            return metadataColumns.cellForColumn(tableColumn, sampleId: item.sample)
        }

        let text: String
        let alignment: NSTextAlignment

        switch tableColumn.identifier {
        case ColumnID.sample:
            text = item.sample ?? "—"; alignment = .left
        case ColumnID.organism:
            text = item.organism; alignment = .left
        case ColumnID.tassScore:
            text = String(format: "%.3f", item.tassScore); alignment = .right
        case ColumnID.reads:
            text = NumberFormatter.localizedString(from: NSNumber(value: item.reads), number: .decimal)
            alignment = .right
        case ColumnID.confidence:
            text = item.confidence ?? "—"; alignment = .left
        case ColumnID.coverageBreadth:
            text = item.coverageBreadth.map { String(format: "%.1f%%", $0) } ?? "—"; alignment = .right
        case ColumnID.coverageDepth:
            text = item.coverageDepth.map { String(format: "%.1fx", $0) } ?? "—"; alignment = .right
        case ColumnID.abundance:
            text = item.abundance.map { String(format: "%.2f%%", $0 * 100) } ?? "—"; alignment = .right
        default:
            return nil
        }

        let cellId = NSUserInterfaceItemIdentifier("BatchTaxTriageCell")
        let cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = cellId
        cell.stringValue = text
        cell.alignment = alignment
        cell.font = .systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let indices = tableView.selectedRowIndexes
        if indices.count == 0 {
            onSelectionCleared?()
        } else if indices.count == 1, let idx = indices.first, idx < displayedRows.count {
            onRowSelected?(displayedRows[idx])
        } else {
            onMultipleRowsSelected?(indices.count)
        }
    }
}
```

### Step 4.2: Commit

- [ ] ```bash
git add Sources/LungfishApp/Views/Metagenomics/BatchTaxTriageTableView.swift
git commit -m "feat: add BatchTaxTriageTableView for TaxTriage batch mode"
```

---

## Task 5: TaxonomyViewController Batch Mode

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`

### Step 5.1: Add batch mode properties and the flat table view

- [ ] Add these properties to the `TaxonomyViewController` class (after the existing stored properties):

```swift
// Add to TaxonomyViewController class body, after existing properties

// MARK: - Batch Mode

var isBatchMode: Bool = false
var batchRows: [BatchClassificationRow] = []
var allBatchRows: [BatchClassificationRow] = [] // Before sample filtering
private(set) var batchTableView = BatchClassificationTableView()
var batchURL: URL?
```

### Step 5.2: Add configureBatch method

- [ ] Add the batch configuration method:

```swift
// Add to TaxonomyViewController class body

/// Configure the view controller in batch mode, showing an aggregated flat table
/// combining all samples' classification results from a batch directory.
public func configureBatch(
    batchURL: URL,
    manifest: ClassificationBatchResultManifest,
    projectURL: URL?
) {
    isBatchMode = true
    self.batchURL = batchURL

    // Build flat rows from each sample's kreport
    var rows: [BatchClassificationRow] = []
    for sample in manifest.samples {
        let sampleDir = batchURL.appendingPathComponent(sample.resultDirectory)
        // Look for kreport file in the sample result directory
        let kreportCandidates = try? FileManager.default.contentsOfDirectory(at: sampleDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kreport" || $0.lastPathComponent.contains("kreport") }
        guard let kreportURL = kreportCandidates?.first,
              let tree = try? KreportParser.parse(url: kreportURL) else {
            continue
        }
        let sampleRows = BatchClassificationRow.fromTree(tree, sampleId: sample.sampleId)
        rows.append(contentsOf: sampleRows)
    }

    allBatchRows = rows

    // Build sample entries for the picker
    let sampleIds = manifest.samples.map(\.sampleId)
    let sampleIdSet = Set(sampleIds)
    sampleEntries = sampleIds.map { sid in
        let readCount = rows.filter { $0.sample == sid }.reduce(0) { $0 + $1.readsDirect }
        return Kraken2SampleEntry(
            id: sid,
            displayName: FASTQDisplayNameResolver.resolveDisplayName(sampleId: sid, projectURL: projectURL),
            classifiedReads: readCount
        )
    }
    strippedPrefix = FASTQDisplayNameResolver.commonPrefix(sampleIds)
    samplePickerState = ClassifierSamplePickerState(allSamples: sampleIdSet)

    // Apply initial display
    applyBatchSampleFilter()

    // Hide sunburst, show flat table
    sunburstView.isHidden = true
    taxonomyTableView.isHidden = true
    batchTableView.isHidden = false

    // Wire batch table callbacks
    batchTableView.onRowSelected = { [weak self] row in
        self?.hideMultiSelectionPlaceholder()
        self?.selectedTaxonNode = self?.findNodeForBatchRow(row)
        // Update action bar with selected taxon info
    }
    batchTableView.onMultipleRowsSelected = { [weak self] count in
        self?.showMultiSelectionPlaceholder(count: count)
    }
    batchTableView.onSelectionCleared = { [weak self] in
        self?.hideMultiSelectionPlaceholder()
        self?.selectedTaxonNode = nil
    }

    // Update summary bar for batch
    summaryBar.updateBatch(
        sampleCount: manifest.samples.count,
        totalRows: allBatchRows.count,
        databaseName: manifest.databaseName
    )

    // Set metadata columns to multi-sample mode
    batchTableView.metadataColumns.isMultiSampleMode = true
}

/// Filter batch rows based on the current sample picker selection.
private func applyBatchSampleFilter() {
    guard isBatchMode else { return }
    let selected = samplePickerState.selectedSamples
    batchRows = allBatchRows.filter { selected.contains($0.sample) }
    batchTableView.displayedRows = batchRows
}

/// Look up a TaxonNode by taxId from the first matching sample's tree (for detail pane).
private func findNodeForBatchRow(_ row: BatchClassificationRow) -> TaxonNode? {
    // In batch mode we don't have a single tree; return nil for now.
    // Detail pane will show row data directly.
    return nil
}
```

### Step 5.3: Add batch table to the view hierarchy in loadView/layoutSubviews

- [ ] In `loadView()`, after the existing `setupSplitView()` call, add the batch table view to the split view's right pane (or as an overlay sibling). The batch table should be hidden by default:

```swift
// In loadView(), after the split view setup:
batchTableView.translatesAutoresizingMaskIntoConstraints = false
batchTableView.isHidden = true
// Add batchTableView to the same container as the split view
let container = view // or the content container
container.addSubview(batchTableView)

// Constrain batchTableView to fill the same area as the split view
NSLayoutConstraint.activate([
    batchTableView.topAnchor.constraint(equalTo: splitView.topAnchor),
    batchTableView.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),
    batchTableView.leadingAnchor.constraint(equalTo: splitView.leadingAnchor),
    batchTableView.trailingAnchor.constraint(equalTo: splitView.trailingAnchor),
])
```

### Step 5.4: Wire sample selection notification to applyBatchSampleFilter

- [ ] Add a notification observer for `.metagenomicsSampleSelectionChanged`:

```swift
// In loadView() or setupNotifications():
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleSampleSelectionChanged),
    name: .metagenomicsSampleSelectionChanged,
    object: nil
)

@objc private func handleSampleSelectionChanged(_ notification: Notification) {
    guard isBatchMode else { return }
    applyBatchSampleFilter()
}
```

### Step 5.5: Commit

- [ ] ```bash
git add Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift
git commit -m "feat: add batch mode to TaxonomyViewController with configureBatch and flat table"
```

---

## Task 6: EsVirituResultViewController Batch Mode

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`

### Step 6.1: Add batch mode properties

- [ ] Add these properties after existing stored properties:

```swift
// MARK: - Batch Mode

var isBatchMode: Bool = false
var allBatchRows: [BatchEsVirituRow] = []
private(set) var batchTableView = BatchEsVirituTableView()
var batchURL: URL?
```

### Step 6.2: Add configureBatch method

- [ ] Add the batch configuration method. Pattern matches TaxonomyViewController but loads EsViritu results:

```swift
public func configureBatch(
    batchURL: URL,
    manifest: EsVirituBatchResultManifest,
    projectURL: URL?
) {
    isBatchMode = true
    self.batchURL = batchURL

    var rows: [BatchEsVirituRow] = []
    for sample in manifest.samples {
        let sampleDir = batchURL.appendingPathComponent(sample.resultDirectory)
        guard let result = try? LungfishIO.EsVirituResult.load(from: sampleDir) else { continue }
        let sampleRows = BatchEsVirituRow.fromAssemblies(result.assemblies, sampleId: sample.sampleId)
        rows.append(contentsOf: sampleRows)
    }

    allBatchRows = rows

    let sampleIds = manifest.samples.map(\.sampleId)
    let sampleIdSet = Set(sampleIds)
    sampleEntries = sampleIds.map { sid in
        let virusCount = rows.filter { $0.sample == sid }.count
        return EsVirituSampleEntry(
            id: sid,
            displayName: FASTQDisplayNameResolver.resolveDisplayName(sampleId: sid, projectURL: projectURL),
            detectedVirusCount: virusCount
        )
    }
    strippedPrefix = FASTQDisplayNameResolver.commonPrefix(sampleIds)
    samplePickerState = ClassifierSamplePickerState(allSamples: sampleIdSet)

    applyBatchSampleFilter()

    // Hide outline, show flat table
    detectionTableView.isHidden = true
    batchTableView.isHidden = false

    batchTableView.onRowSelected = { [weak self] row in
        self?.hideMultiSelectionPlaceholder()
        // Show detail for this virus+sample
    }
    batchTableView.onMultipleRowsSelected = { [weak self] count in
        self?.showMultiSelectionPlaceholder(count: count)
    }
    batchTableView.onSelectionCleared = { [weak self] in
        self?.hideMultiSelectionPlaceholder()
    }

    summaryBar.updateBatch(sampleCount: manifest.samples.count, totalDetections: allBatchRows.count)

    batchTableView.metadataColumns.isMultiSampleMode = true
}

private func applyBatchSampleFilter() {
    guard isBatchMode else { return }
    let selected = samplePickerState.selectedSamples
    let filtered = allBatchRows.filter { selected.contains($0.sample) }
    batchTableView.displayedRows = filtered
}
```

### Step 6.3: Add batch table to view hierarchy and wire notification

- [ ] Same pattern as Task 5.3 and 5.4 — add `batchTableView` to the split view area (hidden by default) and observe `.metagenomicsSampleSelectionChanged`.

### Step 6.4: Commit

- [ ] ```bash
git add Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift
git commit -m "feat: add batch mode to EsVirituResultViewController with configureBatch and flat table"
```

---

## Task 7: TaxTriageResultViewController Batch Mode Refactor

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`

### Step 7.1: Add batch flat table alongside existing batch infrastructure

- [ ] TaxTriage already has `allTableRows`, `sampleIds`, `batchOverviewView`, and `sampleFilterControl`. Add the new flat table and a flag to distinguish "new batch mode" (from batch group click) from "existing internal batch" (from configure with multi-sample result):

```swift
// Add to TaxTriageResultViewController class body

// MARK: - Batch Aggregated Mode (from sidebar batch group click)

var isBatchGroupMode: Bool = false
private(set) var batchFlatTableView = BatchTaxTriageTableView()
var batchURL: URL?
```

### Step 7.2: Add configureBatch method

- [ ] Add the batch group configuration method. This is distinct from the existing `configure(result:config:)` which handles the per-run multi-sample case:

```swift
public func configureBatch(
    batchURL: URL,
    manifest: ClassificationBatchResultManifest, // TaxTriage uses same manifest structure
    projectURL: URL?
) {
    isBatchGroupMode = true
    self.batchURL = batchURL

    // Load metrics from each sample's result directory
    var allMetrics: [TaxTriageMetric] = []
    for sample in manifest.samples {
        let sampleDir = batchURL.appendingPathComponent(sample.resultDirectory)
        // Parse metrics files in the sample directory
        let metricsFiles = (try? FileManager.default.contentsOfDirectory(at: sampleDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tsv" && $0.lastPathComponent.contains("confidence") }) ?? []
        for file in metricsFiles {
            if let parsed = try? TaxTriageMetricParser.parse(url: file) {
                // Tag with sample ID if not already present
                let tagged = parsed.map { metric in
                    if metric.sample == nil {
                        return TaxTriageMetric(
                            sample: sample.sampleId,
                            taxId: metric.taxId, organism: metric.organism, rank: metric.rank,
                            reads: metric.reads, abundance: metric.abundance,
                            coverageBreadth: metric.coverageBreadth, coverageDepth: metric.coverageDepth,
                            tassScore: metric.tassScore, confidence: metric.confidence,
                            additionalFields: metric.additionalFields, sourceLineNumber: metric.sourceLineNumber
                        )
                    }
                    return metric
                }
                allMetrics.append(contentsOf: tagged)
            }
        }
    }

    metrics = allMetrics
    sampleIds = Array(Set(allMetrics.compactMap(\.sample))).sorted()

    let sampleIdSet = Set(sampleIds)
    sampleEntries = sampleIds.map { sid in
        let count = allMetrics.filter { $0.sample == sid }.count
        return TaxTriageSampleEntry(
            id: sid,
            displayName: FASTQDisplayNameResolver.resolveDisplayName(sampleId: sid, projectURL: projectURL),
            organismCount: count
        )
    }
    strippedPrefix = FASTQDisplayNameResolver.commonPrefix(sampleIds)
    samplePickerState = ClassifierSamplePickerState(allSamples: sampleIdSet)

    // Hide segmented control and existing views, show flat table
    sampleFilterControl.isHidden = true
    organismTableView.isHidden = true
    batchOverviewView.isHidden = true
    batchFlatTableView.isHidden = false

    applyBatchGroupFilter()

    batchFlatTableView.onRowSelected = { [weak self] metric in
        self?.hideMultiSelectionPlaceholder()
        self?.handleBatchRowSelected(metric)
    }
    batchFlatTableView.onMultipleRowsSelected = { [weak self] count in
        self?.showMultiSelectionPlaceholder(count: count)
    }
    batchFlatTableView.onSelectionCleared = { [weak self] in
        self?.hideMultiSelectionPlaceholder()
    }

    summaryBar.updateBatch(sampleCount: sampleIds.count, totalOrganisms: allMetrics.count)

    batchFlatTableView.metadataColumns.isMultiSampleMode = true
}

private func applyBatchGroupFilter() {
    guard isBatchGroupMode else { return }
    let selected = samplePickerState.selectedSamples
    let filtered = metrics.filter { selected.contains($0.sample ?? "") }
    batchFlatTableView.displayedRows = filtered
}

private func handleBatchRowSelected(_ metric: TaxTriageMetric) {
    selectedOrganismName = metric.organism
    selectedReadCount = metric.reads
    // Show BAM detail for this organism+sample if BAM exists
    if let sampleId = metric.sample, let bamURL = bamFilesBySample[sampleId] {
        self.bamURL = bamURL
        // Load BAM detail for selected organism
    }
}
```

### Step 7.3: Add batchFlatTableView to view hierarchy and wire notification

- [ ] Same pattern as Tasks 5 and 6 — add to view, hide by default, observe `.metagenomicsSampleSelectionChanged` to call `applyBatchGroupFilter()`.

### Step 7.4: Commit

- [ ] ```bash
git add Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift
git commit -m "feat: add batch group mode to TaxTriageResultViewController with flat table"
```

---

## Task 8: Sidebar Routing for Batch Groups

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`

### Step 8.1: Remove .batchGroup from the skip list in sidebarDidSelectItem

- [ ] In `sidebarDidSelectItem(_:)`, the guard clause at line 1585 skips `.batchGroup`. Change it to allow `.batchGroup` through:

```swift
// BEFORE (line 1585):
guard item.type != .folder && item.type != .project && item.type != .group && item.type != .batchGroup else {

// AFTER:
guard item.type != .folder && item.type != .project && item.type != .group else {
```

### Step 8.2: Remove .batchGroup from the filter in sidebarDidSelectItems

- [ ] At line 1539, remove `.batchGroup` from the filter:

```swift
// BEFORE:
let displayableItems = items.filter { item in
    item.type != .folder && item.type != .project && item.type != .group && item.type != .batchGroup
}

// AFTER:
let displayableItems = items.filter { item in
    item.type != .folder && item.type != .project && item.type != .group
}
```

### Step 8.3: Add .batchGroup routing in displayContent

- [ ] In `displayContent(for:)`, add a case for `.batchGroup` that detects the tool from the batch directory name prefix and routes to the correct VC. Add this before the existing type routing (around line 1590):

```swift
// Add after the guard clause, before the existing routing logic:

if item.type == .batchGroup, let batchURL = item.url {
    displayBatchGroup(at: batchURL, projectURL: projectURL)
    return
}
```

### Step 8.4: Add the displayBatchGroup method

- [ ] Add this new method to MainSplitViewController:

```swift
private func displayBatchGroup(at batchURL: URL, projectURL: URL?) {
    let dirName = batchURL.lastPathComponent.lowercased()

    if dirName.hasPrefix("kraken2") {
        guard let manifest = MetagenomicsBatchResultStore.loadClassification(from: batchURL) else {
            logger.warning("Failed to load classification batch manifest from \(batchURL.path)")
            return
        }
        let taxonomyVC = TaxonomyViewController()
        viewerController.displayTaxonomyBatch(taxonomyVC)
        taxonomyVC.configureBatch(batchURL: batchURL, manifest: manifest, projectURL: projectURL)

        // Wire Inspector
        inspectorController?.updateClassifierSampleState(
            pickerState: taxonomyVC.samplePickerState,
            entries: taxonomyVC.sampleEntries,
            strippedPrefix: taxonomyVC.strippedPrefix
        )
        inspectorController?.updateBatchOperationDetails(
            manifest: manifest, batchURL: batchURL
        )

    } else if dirName.hasPrefix("esviritu") {
        guard let manifest = MetagenomicsBatchResultStore.loadEsViritu(from: batchURL) else {
            logger.warning("Failed to load EsViritu batch manifest from \(batchURL.path)")
            return
        }
        let esVirituVC = EsVirituResultViewController()
        viewerController.displayEsVirituBatch(esVirituVC)
        esVirituVC.configureBatch(batchURL: batchURL, manifest: manifest, projectURL: projectURL)

        inspectorController?.updateClassifierSampleState(
            pickerState: esVirituVC.samplePickerState,
            entries: esVirituVC.sampleEntries,
            strippedPrefix: esVirituVC.strippedPrefix
        )
        inspectorController?.updateBatchOperationDetails(
            manifest: manifest, batchURL: batchURL
        )

    } else if dirName.hasPrefix("taxtriage") {
        // TaxTriage batch manifests use a different discovery pattern
        // Load all TaxTriage cross-refs or construct a manifest from the directory
        let taxTriageVC = TaxTriageResultViewController()
        viewerController.displayTaxTriageBatch(taxTriageVC)
        // TaxTriage batch configuration requires discovering sample results in subdirectories
        // This will need to match the existing TaxTriage batch discovery pattern

        inspectorController?.updateClassifierSampleState(
            pickerState: taxTriageVC.samplePickerState,
            entries: taxTriageVC.sampleEntries,
            strippedPrefix: taxTriageVC.strippedPrefix
        )
    }
}
```

### Step 8.5: Add displayTaxonomyBatch, displayEsVirituBatch, displayTaxTriageBatch to ViewerViewController

- [ ] These methods install the batch-mode VC into the viewer, setting the content mode to `.metagenomics`. Pattern follows existing `displayTaxonomyResult`, `displayEsVirituResult`, etc. — they swap the current child VC for the new one and post `.contentModeChanged` with `"metagenomics"`.

### Step 8.6: Commit

- [ ] ```bash
git add Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift \
      Sources/LungfishApp/Views/Metagenomics/ViewerViewController.swift
git commit -m "feat: route .batchGroup sidebar selection to classifier VCs in batch mode"
```

---

## Task 9: Inspector — Batch Operation Details Section

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/Sections/BatchOperationDetailsSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`

### Step 9.1: Add batch operation state to DocumentSectionViewModel

- [ ] Add properties to `DocumentSectionViewModel`:

```swift
// In DocumentSectionViewModel, add:
var batchOperationTool: String?
var batchOperationParameters: [String: String] = [:]
var batchOperationTimestamp: Date?
var batchSourceSampleURLs: [(sampleId: String, bundleURL: URL?)] = []
```

### Step 9.2: Create BatchOperationDetailsSection SwiftUI view

- [ ] Create the collapsible section showing operation parameters:

```swift
// Sources/LungfishApp/Views/Inspector/Sections/BatchOperationDetailsSection.swift
import SwiftUI

/// Collapsible Inspector section showing batch operation details:
/// tool name, version, database, parameters, and timestamp.
struct BatchOperationDetailsSection: View {
    let tool: String
    let parameters: [String: String]
    let timestamp: Date?
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Operation Details", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                metadataRow("Tool", value: tool)
                if let timestamp {
                    metadataRow("Run Date", value: formatDate(timestamp))
                }
                ForEach(parameters.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    metadataRow(key, value: value)
                }
            }
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}
```

### Step 9.3: Create SourceSamplesSection SwiftUI view

- [ ] Create the collapsible section showing clickable FASTQ bundle links:

```swift
// Sources/LungfishApp/Views/Inspector/Sections/SourceSamplesSection.swift
import SwiftUI

/// Collapsible Inspector section showing source FASTQ bundles
/// included in the batch, each as a clickable link.
struct SourceSamplesSection: View {
    let samples: [(sampleId: String, bundleURL: URL?)]
    var onNavigateToBundle: ((URL) -> Void)?
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Source Samples", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(samples, id: \.sampleId) { sample in
                    if let bundleURL = sample.bundleURL {
                        Button(action: { onNavigateToBundle?(bundleURL) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.zipper")
                                    .font(.system(size: 10))
                                Text(sample.sampleId)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.link)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.zipper")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(sample.sampleId)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .font(.caption.weight(.semibold))
    }
}
```

### Step 9.4: Add updateBatchOperationDetails to InspectorViewController

- [ ] Add a method to `InspectorViewController`:

```swift
public func updateBatchOperationDetails(
    manifest: Any, // ClassificationBatchResultManifest or EsVirituBatchResultManifest
    batchURL: URL
) {
    if let classManifest = manifest as? ClassificationBatchResultManifest {
        viewModel.documentSectionViewModel.batchOperationTool = "Kraken2"
        viewModel.documentSectionViewModel.batchOperationTimestamp = classManifest.header.createdAt
        viewModel.documentSectionViewModel.batchOperationParameters = [
            "Database": classManifest.databaseName,
            "Database Version": classManifest.databaseVersion,
            "Samples": "\(classManifest.header.sampleCount)",
        ]
        // Resolve source bundle URLs from sample IDs
        viewModel.documentSectionViewModel.batchSourceSampleURLs = classManifest.samples.map { sample in
            let bundleURL = resolveSourceBundle(sampleId: sample.sampleId, inputFiles: sample.inputFiles)
            return (sampleId: sample.sampleId, bundleURL: bundleURL)
        }
    } else if let esManifest = manifest as? EsVirituBatchResultManifest {
        viewModel.documentSectionViewModel.batchOperationTool = "EsViritu"
        viewModel.documentSectionViewModel.batchOperationTimestamp = esManifest.header.createdAt
        viewModel.documentSectionViewModel.batchOperationParameters = [
            "Samples": "\(esManifest.header.sampleCount)",
        ]
        viewModel.documentSectionViewModel.batchSourceSampleURLs = esManifest.samples.map { sample in
            let bundleURL = resolveSourceBundle(sampleId: sample.sampleId, inputFiles: sample.inputFiles)
            return (sampleId: sample.sampleId, bundleURL: bundleURL)
        }
    }
}

private func resolveSourceBundle(sampleId: String, inputFiles: [String]) -> URL? {
    // Try to resolve the FASTQ bundle URL from the input file paths
    guard let firstInput = inputFiles.first else { return nil }
    let inputURL = URL(fileURLWithPath: firstInput)
    // Walk up to find the .lungfishfastq bundle
    var candidate = inputURL.deletingLastPathComponent()
    while candidate.path != "/" {
        if candidate.pathExtension == "lungfishfastq" {
            return candidate
        }
        candidate = candidate.deletingLastPathComponent()
    }
    return nil
}
```

### Step 9.5: Integrate sections into MetagenomicsResultSummarySection

- [ ] In the `MetagenomicsResultSummarySection` view body, add the batch sections before the existing "Samples & Metadata" DisclosureGroup:

```swift
// Add before the DisclosureGroup("Samples & Metadata", ...) block:

// Batch Operation Details (shown when batch mode is active)
if let tool = viewModel.batchOperationTool {
    BatchOperationDetailsSection(
        tool: tool,
        parameters: viewModel.batchOperationParameters,
        timestamp: viewModel.batchOperationTimestamp
    )
    Divider().padding(.vertical, 4)
}

// Source Samples (shown when batch mode, at the bottom)
// Move this AFTER the Samples & Metadata DisclosureGroup
```

And after the "Samples & Metadata" DisclosureGroup, add:

```swift
if !viewModel.batchSourceSampleURLs.isEmpty {
    Divider().padding(.vertical, 4)
    SourceSamplesSection(
        samples: viewModel.batchSourceSampleURLs,
        onNavigateToBundle: { url in
            NotificationCenter.default.post(
                name: .navigateToSidebarItem,
                object: nil,
                userInfo: ["url": url]
            )
        }
    )
}
```

### Step 9.6: Commit

- [ ] ```bash
git add Sources/LungfishApp/Views/Inspector/Sections/BatchOperationDetailsSection.swift \
      Sources/LungfishApp/Views/Inspector/Sections/SourceSamplesSection.swift \
      Sources/LungfishApp/Views/Inspector/InspectorViewController.swift
git commit -m "feat: add batch operation details and source samples to Inspector"
```

---

## Task 10: Summary Bar Updates

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomySummaryBar.swift` (or wherever it's defined)
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituSummaryBar.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageSummaryBar.swift`

### Step 10.1: Add updateBatch methods to each summary bar

- [ ] Each summary bar needs a `updateBatch(...)` method that displays batch-specific stats (sample count, total rows, database name). The implementation follows the existing `update(...)` pattern but shows batch context:

For `TaxonomySummaryBar`:
```swift
func updateBatch(sampleCount: Int, totalRows: Int, databaseName: String) {
    // Display: "Batch: N samples · M taxa · DatabaseName"
    let text = "Batch: \(sampleCount) samples \u{00B7} \(NumberFormatter.localizedString(from: NSNumber(value: totalRows), number: .decimal)) taxa \u{00B7} \(databaseName)"
    updateText(text)
}
```

For `EsVirituSummaryBar`:
```swift
func updateBatch(sampleCount: Int, totalDetections: Int) {
    let text = "Batch: \(sampleCount) samples \u{00B7} \(NumberFormatter.localizedString(from: NSNumber(value: totalDetections), number: .decimal)) viral detections"
    updateText(text)
}
```

For `TaxTriageSummaryBar`:
```swift
func updateBatch(sampleCount: Int, totalOrganisms: Int) {
    let text = "Batch: \(sampleCount) samples \u{00B7} \(NumberFormatter.localizedString(from: NSNumber(value: totalOrganisms), number: .decimal)) organisms"
    updateText(text)
}
```

### Step 10.2: Commit

- [ ] ```bash
git add Sources/LungfishApp/Views/Metagenomics/TaxonomySummaryBar.swift \
      Sources/LungfishApp/Views/Metagenomics/EsVirituSummaryBar.swift \
      Sources/LungfishApp/Views/Metagenomics/TaxTriageSummaryBar.swift
git commit -m "feat: add updateBatch methods to classifier summary bars"
```

---

## Task 11: Build and Integration Test

**Files:**
- Modify: `Tests/LungfishAppTests/BatchAggregatedViewTests.swift`

### Step 11.1: Add integration-level tests for batch configuration

- [ ] Add tests that verify the batch configuration flow end-to-end:

```swift
// Add to BatchAggregatedViewTests.swift

func testTaxonomyViewControllerBatchModeFlag() {
    let vc = TaxonomyViewController()
    XCTAssertFalse(vc.isBatchMode)
    // After configureBatch, isBatchMode should be true
    // (Full test requires a mock batch directory with kreport files)
}

func testEsVirituViewControllerBatchModeFlag() {
    let vc = EsVirituResultViewController()
    XCTAssertFalse(vc.isBatchMode)
}

func testTaxTriageViewControllerBatchGroupModeFlag() {
    let vc = TaxTriageResultViewController()
    XCTAssertFalse(vc.isBatchGroupMode)
}

func testBatchClassificationRowSortBySample() {
    let rows = [
        BatchClassificationRow(sample: "sampleB", taxonName: "E. coli", taxId: 562, rank: "S", rankDisplayName: "Species", readsDirect: 100, readsClade: 100, percentage: 10.0),
        BatchClassificationRow(sample: "sampleA", taxonName: "E. coli", taxId: 562, rank: "S", rankDisplayName: "Species", readsDirect: 200, readsClade: 200, percentage: 20.0),
    ]
    let sorted = rows.sorted { $0.sample < $1.sample }
    XCTAssertEqual(sorted[0].sample, "sampleA")
    XCTAssertEqual(sorted[1].sample, "sampleB")
}

func testBatchClassificationRowSortByReads() {
    let rows = [
        BatchClassificationRow(sample: "s1", taxonName: "A", taxId: 1, rank: "S", rankDisplayName: "Species", readsDirect: 50, readsClade: 50, percentage: 5.0),
        BatchClassificationRow(sample: "s2", taxonName: "B", taxId: 2, rank: "S", rankDisplayName: "Species", readsDirect: 200, readsClade: 200, percentage: 20.0),
    ]
    let sorted = rows.sorted { $0.readsClade > $1.readsClade }
    XCTAssertEqual(sorted[0].taxonName, "B")
}

func testBatchEsVirituRowSortByVirusName() {
    let rows = [
        BatchEsVirituRow(sample: "s1", virusName: "Zika", family: "Flaviviridae", assembly: "GCF_1", readCount: 100, uniqueReads: 80, rpkmf: 10, coverageBreadth: 0.5, coverageDepth: 5.0),
        BatchEsVirituRow(sample: "s1", virusName: "Adenovirus", family: "Adenoviridae", assembly: "GCF_2", readCount: 200, uniqueReads: 150, rpkmf: 20, coverageBreadth: 0.8, coverageDepth: 12.0),
    ]
    let sorted = rows.sorted { $0.virusName < $1.virusName }
    XCTAssertEqual(sorted[0].virusName, "Adenovirus")
}
```

### Step 11.2: Run full test suite

- [ ] Run: `swift build --build-tests 2>&1 | tail -20`

Expected: Build succeeds with no errors.

- [ ] Run: `swift test --filter BatchAggregatedViewTests 2>&1 | tail -10`

Expected: All tests pass.

### Step 11.3: Commit

- [ ] ```bash
git add Tests/LungfishAppTests/BatchAggregatedViewTests.swift
git commit -m "test: add integration tests for batch aggregated view configuration and sorting"
```

---

## Task 12: Full Build Verification

### Step 12.1: Run the complete test suite

- [ ] Run: `swift test 2>&1 | tail -20`

Expected: All existing tests continue to pass. No regressions in the 1397+ test suite.

### Step 12.2: Fix any compilation errors

- [ ] If there are compilation errors, fix them. Common issues:
  - Missing imports (ensure `@testable import LungfishWorkflow` for `KreportParser`)
  - Missing `FASTQDisplayNameResolver` — check if it exists or needs a different call
  - `EsVirituResult.load(from:)` — verify the exact method signature on `LungfishIO.EsVirituResult`
  - `TaxTriageMetricParser.parse(url:)` — verify the exact parser API name

### Step 12.3: Final commit

- [ ] ```bash
git add -A
git commit -m "fix: resolve any compilation issues from batch aggregated views integration"
```
