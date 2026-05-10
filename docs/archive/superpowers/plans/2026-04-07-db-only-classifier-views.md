# DB-Only Classifier Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all legacy JSON/file-parsing classifier display paths with SQLite DB-only loading, extending DB schemas where needed, creating a centralized router, and removing all legacy batch and per-sample file-based code.

**Architecture:** A single `ClassifierDatabaseRouter` decides every classifier display: DB exists → load from it; no DB but is classifier dir → auto-build via `lungfish-cli build-db`; not a classifier dir → skip. Each VC's `configureFromDatabase(db:sampleId:)` handles both batch (sampleId=nil) and per-sample (sampleId=non-nil) modes. All legacy `configureBatchGroup`, `configure(result:)`, and file-enumeration code is removed.

**Tech Stack:** Swift 6.2, raw sqlite3 C API (`import SQLite3`), ArgumentParser CLI, AppKit VCs, `@MainActor` isolation

**Spec:** `docs/superpowers/specs/2026-04-07-sqlite-backed-classifier-views-design.md`

**Predecessor plan:** `docs/superpowers/plans/2026-04-07-sqlite-backed-classifier-views.md` (created the DB classes, CLI commands, and initial VC wiring — but legacy code was not removed and routing was broken)

---

## File Map

### New Files
- `Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift` — centralized routing logic
- `Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift` — router unit tests

### Modified Files — Schema Extensions
- `Sources/LungfishIO/Formats/Kraken2/Kraken2Database.swift` — add `parent_tax_id`, `depth`, `fraction_direct` columns; add `fetchTree(sample:)` method
- `Sources/LungfishIO/Formats/EsViritu/EsVirituDatabase.swift` — add `coverage_windows` table; add `fetchCoverageWindows(sample:accession:)` method
- `Sources/LungfishIO/Formats/TaxTriage/TaxTriageDatabase.swift` — add `accession_map` table; add `fetchAccessions(sample:organism:)` method
- `Tests/LungfishIOTests/Kraken2DatabaseTests.swift` — tree reconstruction tests
- `Tests/LungfishIOTests/EsVirituDatabaseTests.swift` — coverage windows tests
- `Tests/LungfishIOTests/TaxTriageDatabaseTests.swift` — accession map tests

### Modified Files — CLI Extensions
- `Sources/LungfishCLI/Commands/BuildDbCommand.swift` — Kraken2Subcommand populates parent_tax_id/depth; EsVirituSubcommand populates coverage_windows; TaxTriageSubcommand populates accession_map

### Modified Files — VC Refactoring
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` — expand `configureFromDatabase` to handle single-sample mode; remove `configureBatchGroup` and `configure(result:config:)`
- `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` — expand `configureFromDatabase` to handle single-sample mode; remove legacy configure methods
- `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` — expand `configureFromDatabase` to handle single-sample mode with tree reconstruction; remove legacy configure methods
- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` — replace all classifier handlers with router; remove legacy display methods
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift` — remove `displayTaxTriageBatch`, `displayTaxTriageResult`; keep `displayTaxTriageFromDatabase`
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift` — remove `displayEsVirituBatch`, `displayEsVirituResult`; keep `displayEsVirituFromDatabase`
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift` — remove legacy display methods; keep `displayTaxonomyFromDatabase`

### Modified Files — Test Updates
- `Tests/LungfishCLITests/BuildDbCommandTests.swift` — test schema extensions
- `Tests/LungfishCLITests/NewCommandTests.swift` — update if subcommand count changes

---

## Phase 1: Schema Extensions

### Task 1: Extend Kraken2Database with Tree Structure

The sunburst and hierarchical table need `parent_tax_id` and `depth` to reconstruct a `TaxonTree` from flat DB rows. The kreport parser already computes both via indentation counting and a depth-indexed stack.

**Files:**
- Modify: `Sources/LungfishIO/Formats/Kraken2/Kraken2Database.swift`
- Modify: `Tests/LungfishIOTests/Kraken2DatabaseTests.swift`

- [ ] **Step 1: Write failing tests for tree columns and fetchTree**

Add to `Tests/LungfishIOTests/Kraken2DatabaseTests.swift`:

```swift
func testParentTaxIdAndDepthStored() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appendingPathComponent("test.sqlite")

    let rows = [
        makeTestRow(sample: "s1", taxonName: "root", taxId: 1, rank: "R",
                    readsDirect: 10, readsClade: 1000, percentage: 100.0,
                    parentTaxId: nil, depth: 0, fractionDirect: 0.01),
        makeTestRow(sample: "s1", taxonName: "Bacteria", taxId: 2, rank: "D",
                    readsDirect: 500, readsClade: 800, percentage: 80.0,
                    parentTaxId: 1, depth: 1, fractionDirect: 0.5),
        makeTestRow(sample: "s1", taxonName: "Firmicutes", taxId: 1239, rank: "P",
                    readsDirect: 200, readsClade: 300, percentage: 30.0,
                    parentTaxId: 2, depth: 2, fractionDirect: 0.2),
    ]
    let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [
        "total_reads": "1000",
        "classified_reads": "900",
        "unclassified_reads": "100",
        "species_count": "5",
    ])

    let fetched = try db.fetchRows(samples: ["s1"])
    XCTAssertEqual(fetched.count, 3)

    let bacteria = fetched.first { $0.taxId == 2 }!
    XCTAssertEqual(bacteria.parentTaxId, 1)
    XCTAssertEqual(bacteria.depth, 1)
    XCTAssertEqual(bacteria.fractionDirect, 0.5, accuracy: 0.001)
}

func testFetchTree() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appendingPathComponent("test.sqlite")

    let rows = [
        makeTestRow(sample: "s1", taxonName: "root", taxId: 1, rank: "R",
                    readsDirect: 10, readsClade: 1000, percentage: 100.0,
                    parentTaxId: nil, depth: 0, fractionDirect: 0.01),
        makeTestRow(sample: "s1", taxonName: "Bacteria", taxId: 2, rank: "D",
                    readsDirect: 500, readsClade: 800, percentage: 80.0,
                    parentTaxId: 1, depth: 1, fractionDirect: 0.5),
        makeTestRow(sample: "s1", taxonName: "Viruses", taxId: 10239, rank: "D",
                    readsDirect: 100, readsClade: 200, percentage: 20.0,
                    parentTaxId: 1, depth: 1, fractionDirect: 0.1),
    ]
    let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [
        "total_reads": "1100",
        "classified_reads": "1000",
        "unclassified_reads": "100",
        "species_count": "5",
    ])

    let tree = try db.fetchTree(sample: "s1")
    XCTAssertEqual(tree.root.taxId, 1)
    XCTAssertEqual(tree.root.children.count, 2)
    XCTAssertEqual(tree.totalReads, 1100)
    XCTAssertEqual(tree.classifiedReads, 1000)
    XCTAssertEqual(tree.unclassifiedReads, 100)

    let bacteria = tree.root.children.first { $0.taxId == 2 }!
    XCTAssertEqual(bacteria.name, "Bacteria")
    XCTAssertEqual(bacteria.readsClade, 800)
    XCTAssertEqual(bacteria.parent?.taxId, 1)
}
```

Update `makeTestRow` helper to include new fields:

```swift
private func makeTestRow(
    sample: String, taxonName: String, taxId: Int, rank: String,
    readsDirect: Int, readsClade: Int, percentage: Double,
    parentTaxId: Int? = nil, depth: Int = 0, fractionDirect: Double = 0.0
) -> Kraken2ClassificationRow {
    Kraken2ClassificationRow(
        sample: sample, taxonName: taxonName, taxId: taxId,
        rank: rank, rankDisplayName: rank,
        readsDirect: readsDirect, readsClade: readsClade,
        percentage: percentage,
        parentTaxId: parentTaxId, depth: depth, fractionDirect: fractionDirect
    )
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter Kraken2DatabaseTests`
Expected: compilation error — `Kraken2ClassificationRow` doesn't have `parentTaxId`/`depth`/`fractionDirect` fields yet.

- [ ] **Step 3: Add fields to Kraken2ClassificationRow**

In `Sources/LungfishIO/Formats/Kraken2/Kraken2Database.swift`, add to `Kraken2ClassificationRow`:

```swift
public struct Kraken2ClassificationRow: Sendable {
    public let sample: String
    public let taxonName: String
    public let taxId: Int
    public let rank: String?
    public let rankDisplayName: String?
    public let readsDirect: Int
    public let readsClade: Int
    public let percentage: Double
    public let parentTaxId: Int?       // NEW
    public let depth: Int              // NEW
    public let fractionDirect: Double  // NEW

    public init(
        sample: String, taxonName: String, taxId: Int,
        rank: String?, rankDisplayName: String?,
        readsDirect: Int, readsClade: Int, percentage: Double,
        parentTaxId: Int? = nil, depth: Int = 0, fractionDirect: Double = 0.0
    ) {
        self.sample = sample
        self.taxonName = taxonName
        self.taxId = taxId
        self.rank = rank
        self.rankDisplayName = rankDisplayName
        self.readsDirect = readsDirect
        self.readsClade = readsClade
        self.percentage = percentage
        self.parentTaxId = parentTaxId
        self.depth = depth
        self.fractionDirect = fractionDirect
    }
}
```

- [ ] **Step 4: Update schema, insert, and read**

In `createSchema`, change `classification_rows` table:

```sql
CREATE TABLE classification_rows (
    rowid INTEGER PRIMARY KEY,
    sample TEXT NOT NULL,
    taxon_name TEXT NOT NULL,
    tax_id INTEGER NOT NULL,
    rank TEXT,
    rank_display_name TEXT,
    reads_direct INTEGER NOT NULL,
    reads_clade INTEGER NOT NULL,
    percentage REAL NOT NULL,
    parent_tax_id INTEGER,
    depth INTEGER NOT NULL DEFAULT 0,
    fraction_direct REAL NOT NULL DEFAULT 0.0,
    UNIQUE(sample, tax_id)
);
```

Update `bulkInsertRows` INSERT SQL to include 3 new columns and bind them.

Update `collectRows` to read `parent_tax_id` (optional int), `depth` (int), `fraction_direct` (double) from the new column positions.

- [ ] **Step 5: Implement fetchTree(sample:)**

Add to `Kraken2Database`:

```swift
/// Reconstructs a `TaxonTree` for a single sample from DB rows.
///
/// Requires `total_reads`, `classified_reads`, `unclassified_reads` in the metadata table.
public func fetchTree(sample: String) throws -> TaxonTree {
    let rows = try fetchRows(samples: [sample])
    let meta = try fetchMetadata()
    let totalReads = Int(meta["total_reads"] ?? "0") ?? 0
    let classifiedReads = Int(meta["classified_reads"] ?? "0") ?? 0
    let unclassifiedReads = Int(meta["unclassified_reads"] ?? "0") ?? 0

    // Build nodes indexed by taxId
    var nodesByTaxId: [Int: TaxonNode] = [:]
    for row in rows {
        let node = TaxonNode(
            taxId: row.taxId,
            name: row.taxonName,
            rank: TaxonomicRank(code: row.rank ?? "no rank"),
            depth: row.depth,
            readsDirect: row.readsDirect,
            readsClade: row.readsClade,
            fractionClade: row.percentage / 100.0,
            fractionDirect: row.fractionDirect,
            parentTaxId: row.parentTaxId
        )
        nodesByTaxId[row.taxId] = node
    }

    // Link parent-child relationships
    for (_, node) in nodesByTaxId {
        if let parentId = node.parentTaxId, let parent = nodesByTaxId[parentId] {
            node.parent = parent
            parent.children.append(node)
        }
    }

    // Sort children by readsClade descending at each level
    for (_, node) in nodesByTaxId {
        node.children.sort { $0.readsClade > $1.readsClade }
    }

    // Find root (depth 0, or taxId 1)
    guard let root = nodesByTaxId.values.first(where: { $0.depth == 0 })
            ?? nodesByTaxId[1] else {
        throw Kraken2DatabaseError.queryFailed("No root node found for sample \(sample)")
    }

    // Build unclassified node
    let unclassifiedNode = TaxonNode(
        taxId: 0,
        name: "unclassified",
        rank: .unclassified,
        depth: 0,
        readsDirect: unclassifiedReads,
        readsClade: unclassifiedReads,
        fractionClade: totalReads > 0 ? Double(unclassifiedReads) / Double(totalReads) : 0,
        fractionDirect: totalReads > 0 ? Double(unclassifiedReads) / Double(totalReads) : 0,
        parentTaxId: nil
    )

    return TaxonTree(
        root: root,
        unclassifiedNode: unclassifiedNode,
        totalReads: totalReads,
        classifiedReads: classifiedReads,
        unclassifiedReads: unclassifiedReads
    )
}
```

Note: Check `TaxonNode.init` signature — it may use positional parameters or have a different parameter name for `parentTaxId`. Read the actual init in `Sources/LungfishIO/Formats/Kraken/TaxonNode.swift` and match it exactly. Also check `TaxonTree.init` — it may compute `classifiedReads` from `root.readsClade` rather than accepting it as a parameter. The implementation above is pseudocode; adapt to the actual initializers.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter Kraken2DatabaseTests`
Expected: all tests pass including the 2 new ones.

- [ ] **Step 7: Update Kraken2 CLI subcommand**

In `Sources/LungfishCLI/Commands/BuildDbCommand.swift`, in `parseKreport(at:sampleId:)`:

The existing code does:
```swift
Kraken2ClassificationRow(
    sample: sampleId,
    taxonName: node.name,
    taxId: node.taxId,
    rank: node.rank.code,
    rankDisplayName: node.rank.displayName,
    readsDirect: node.readsDirect,
    readsClade: node.readsClade,
    percentage: node.fractionClade * 100.0
)
```

Add the new fields:
```swift
Kraken2ClassificationRow(
    sample: sampleId,
    taxonName: node.name,
    taxId: node.taxId,
    rank: node.rank.code,
    rankDisplayName: node.rank.displayName,
    readsDirect: node.readsDirect,
    readsClade: node.readsClade,
    percentage: node.fractionClade * 100.0,
    parentTaxId: node.parent?.taxId,      // NEW — from tree linkage
    depth: node.depth,                     // NEW — from kreport indentation
    fractionDirect: node.fractionDirect    // NEW — from kreport parsing
)
```

Also add summary metadata from the tree:
```swift
let metadata: [String: String] = [
    "tool": "kraken2",
    "created_at": ISO8601DateFormatter().string(from: Date()),
    "source_dir": resultURL.path,
    "total_reads": "\(tree.totalReads)",
    "classified_reads": "\(tree.classifiedReads)",
    "unclassified_reads": "\(tree.unclassifiedReads)",
    "species_count": "\(tree.speciesCount)",
]
```

Check that `tree.speciesCount` exists on `TaxonTree`. If not, compute it: `rows.filter { $0.rank == "S" }.count`.

- [ ] **Step 8: Run CLI test, verify, commit**

Run: `swift test --filter BuildDbCommandTests`

```bash
git add Sources/LungfishIO/Formats/Kraken2/Kraken2Database.swift \
      Sources/LungfishCLI/Commands/BuildDbCommand.swift \
      Tests/LungfishIOTests/Kraken2DatabaseTests.swift
git commit -m "feat: extend Kraken2Database with tree structure (parent_tax_id, depth, fractionDirect)"
```

---

### Task 2: Extend EsVirituDatabase with Coverage Windows

**Files:**
- Modify: `Sources/LungfishIO/Formats/EsViritu/EsVirituDatabase.swift`
- Modify: `Tests/LungfishIOTests/EsVirituDatabaseTests.swift`
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift`

- [ ] **Step 1: Write failing test for coverage windows**

Add to `Tests/LungfishIOTests/EsVirituDatabaseTests.swift`:

```swift
func testCoverageWindowsRoundTrip() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appendingPathComponent("test.sqlite")

    let rows = [makeTestRow(sample: "s1", virusName: "Virus A",
                            accession: "NC_001", assembly: "GCA_001", readCount: 100)]
    let windows = [
        EsVirituCoverageWindow(sample: "s1", accession: "NC_001",
                               windowIndex: 0, windowStart: 0, windowEnd: 100, averageCoverage: 5.0),
        EsVirituCoverageWindow(sample: "s1", accession: "NC_001",
                               windowIndex: 1, windowStart: 100, windowEnd: 200, averageCoverage: 12.5),
    ]
    let db = try EsVirituDatabase.create(at: dbURL, rows: rows, coverageWindows: windows, metadata: [:])

    let fetched = try db.fetchCoverageWindows(sample: "s1", accession: "NC_001")
    XCTAssertEqual(fetched.count, 2)
    XCTAssertEqual(fetched[0].windowIndex, 0)
    XCTAssertEqual(fetched[0].averageCoverage, 5.0, accuracy: 0.01)
    XCTAssertEqual(fetched[1].windowStart, 100)
}

func testCoverageWindowsEmptyForMissingSample() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appendingPathComponent("test.sqlite")

    let db = try EsVirituDatabase.create(at: dbURL, rows: [], coverageWindows: [], metadata: [:])
    let fetched = try db.fetchCoverageWindows(sample: "s1", accession: "NC_001")
    XCTAssertEqual(fetched.count, 0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EsVirituDatabaseTests`

- [ ] **Step 3: Add coverage_windows table and struct**

Add to `EsVirituDatabase.swift`:

```swift
/// A single coverage window from the `coverage_windows` table.
public struct EsVirituCoverageWindow: Sendable {
    public let sample: String
    public let accession: String
    public let windowIndex: Int
    public let windowStart: Int
    public let windowEnd: Int
    public let averageCoverage: Double

    public init(sample: String, accession: String, windowIndex: Int,
                windowStart: Int, windowEnd: Int, averageCoverage: Double) {
        self.sample = sample
        self.accession = accession
        self.windowIndex = windowIndex
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.averageCoverage = averageCoverage
    }
}
```

Add to `createSchema`:
```sql
CREATE TABLE coverage_windows (
    rowid INTEGER PRIMARY KEY,
    sample TEXT NOT NULL,
    accession TEXT NOT NULL,
    window_index INTEGER NOT NULL,
    window_start INTEGER NOT NULL,
    window_end INTEGER NOT NULL,
    average_coverage REAL NOT NULL,
    UNIQUE(sample, accession, window_index)
);
```

Add index: `CREATE INDEX idx_cw_sample_acc ON coverage_windows(sample, accession);`

Update `create(at:rows:metadata:progress:)` signature to accept `coverageWindows: [EsVirituCoverageWindow] = []` and bulk-insert them in a separate transaction.

Add `fetchCoverageWindows(sample:accession:)`:
```swift
public func fetchCoverageWindows(sample: String, accession: String) throws -> [EsVirituCoverageWindow] {
    let sql = "SELECT sample, accession, window_index, window_start, window_end, average_coverage FROM coverage_windows WHERE sample = ? AND accession = ? ORDER BY window_index"
    // Prepare, bind sample and accession, step through results
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EsVirituDatabaseTests`

- [ ] **Step 5: Update EsViritu CLI subcommand**

In `BuildDbCommand.swift`, in `EsVirituSubcommand.run()`, after parsing detection TSVs:

```swift
// Parse coverage windows from virus_coverage_windows.tsv files
var allWindows: [EsVirituCoverageWindow] = []
for sampleDir in sampleDirs {
    let sampleName = sampleDir.lastPathComponent
    let cwURL = sampleDir.appendingPathComponent("\(sampleName).virus_coverage_windows.tsv")
    if FileManager.default.fileExists(atPath: cwURL.path) {
        let parsed = try EsVirituCoverageParser.parse(url: cwURL)
        let dbWindows = parsed.map { w in
            EsVirituCoverageWindow(
                sample: sampleName, accession: w.accession,
                windowIndex: w.windowIndex, windowStart: w.windowStart,
                windowEnd: w.windowEnd, averageCoverage: w.averageCoverage
            )
        }
        allWindows.append(contentsOf: dbWindows)
    }
}

_ = try EsVirituDatabase.create(at: dbURL, rows: rows, coverageWindows: allWindows, metadata: metadata)
```

Note: `EsVirituCoverageParser.parse(url:)` returns `[ViralCoverageWindow]` (from `LungfishIO`). The `ViralCoverageWindow` struct has `accession`, `windowIndex`, `windowStart`, `windowEnd`, `averageCoverage` but no `sample` field. The sample name must be added during conversion.

- [ ] **Step 6: Run CLI tests, verify, commit**

Run: `swift test --filter BuildDbCommandTests`

```bash
git add Sources/LungfishIO/Formats/EsViritu/EsVirituDatabase.swift \
      Sources/LungfishCLI/Commands/BuildDbCommand.swift \
      Tests/LungfishIOTests/EsVirituDatabaseTests.swift
git commit -m "feat: extend EsVirituDatabase with coverage_windows table"
```

---

### Task 3: Extend TaxTriageDatabase with Accession Map

**Files:**
- Modify: `Sources/LungfishIO/Formats/TaxTriage/TaxTriageDatabase.swift`
- Modify: `Tests/LungfishIOTests/TaxTriageDatabaseTests.swift`
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift`

- [ ] **Step 1: Write failing test for accession map**

Add to `Tests/LungfishIOTests/TaxTriageDatabaseTests.swift`:

```swift
func testAccessionMapRoundTrip() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appendingPathComponent("test.sqlite")

    let rows = [makeTestRow(sample: "s1", organism: "Influenza A", tassScore: 0.9, readsAligned: 100,
                            primaryAccession: "NC_004905.2")]
    let accessionMap = [
        TaxTriageAccessionEntry(sample: "s1", organism: "Influenza A",
                                accession: "NC_004905.2", description: "segment 5"),
        TaxTriageAccessionEntry(sample: "s1", organism: "Influenza A",
                                accession: "NC_004906.1", description: "segment 8"),
        TaxTriageAccessionEntry(sample: "s1", organism: "Influenza A",
                                accession: "NC_004907.1", description: "segment 7"),
    ]
    let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, accessionMap: accessionMap, metadata: [:])

    let accessions = try db.fetchAccessions(sample: "s1", organism: "Influenza A")
    XCTAssertEqual(accessions.count, 3)
    XCTAssertTrue(accessions.contains { $0.accession == "NC_004905.2" })
    XCTAssertTrue(accessions.contains { $0.accession == "NC_004906.1" })
}

func testAccessionMapEmptyForUnknownOrganism() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appendingPathComponent("test.sqlite")

    let db = try TaxTriageDatabase.create(at: dbURL, rows: [], accessionMap: [], metadata: [:])
    let accessions = try db.fetchAccessions(sample: "s1", organism: "Unknown")
    XCTAssertEqual(accessions.count, 0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TaxTriageDatabaseTests`

- [ ] **Step 3: Add accession_map table and struct**

Add to `TaxTriageDatabase.swift`:

```swift
/// An entry in the accession_map table linking organisms to their reference accessions.
public struct TaxTriageAccessionEntry: Sendable {
    public let sample: String
    public let organism: String
    public let accession: String
    public let description: String?

    public init(sample: String, organism: String, accession: String, description: String? = nil) {
        self.sample = sample
        self.organism = organism
        self.accession = accession
        self.description = description
    }
}
```

Add to `createSchema`:
```sql
CREATE TABLE accession_map (
    rowid INTEGER PRIMARY KEY,
    sample TEXT NOT NULL,
    organism TEXT NOT NULL,
    accession TEXT NOT NULL,
    description TEXT
);
```

Add index: `CREATE INDEX idx_accmap_sample_organism ON accession_map(sample, organism);`

Update `create(at:rows:metadata:progress:)` signature to accept `accessionMap: [TaxTriageAccessionEntry] = []` and bulk-insert them.

Add `fetchAccessions(sample:organism:)`:
```swift
public func fetchAccessions(sample: String, organism: String) throws -> [TaxTriageAccessionEntry] {
    let sql = "SELECT sample, organism, accession, description FROM accession_map WHERE sample = ? AND organism = ? ORDER BY accession"
    // Prepare, bind, step through results
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TaxTriageDatabaseTests`

- [ ] **Step 5: Update TaxTriage CLI subcommand**

In `BuildDbCommand.swift`, in `parseConfidenceTSV(at:resultURL:)`, already loads gcfmap per sample. After building `TaxTriageTaxonomyRow` array, also build accession map entries:

```swift
// After the existing gcfmap loading, build full accession map
var accessionEntries: [TaxTriageAccessionEntry] = []
for (sampleId, gcfEntries) in gcfmapCache {
    // Group by organism name
    var orgToAccessions: [String: [(accession: String, description: String?)]] = [:]
    for entry in gcfEntries {
        let cleanedOrg = cleanOrganismName(entry.organism)
        orgToAccessions[cleanedOrg, default: []].append(
            (accession: entry.accession, description: nil)
        )
    }
    for (org, accessions) in orgToAccessions {
        for acc in accessions {
            accessionEntries.append(TaxTriageAccessionEntry(
                sample: sampleId, organism: org,
                accession: acc.accession, description: acc.description
            ))
        }
    }
}
```

Then pass to `create()`:
```swift
try TaxTriageDatabase.create(at: dbURL, rows: rows, accessionMap: accessionEntries, metadata: metadata)
```

Note: The gcfmap organism names may not exactly match the confidence TSV organism names (e.g., `Influenza A virus (A/Hong Kong/1073/99(H9N2))` in gcfmap vs `Influenza A virus (A/Hong Kong/1073/99(H9N2))°` in TSV before cleaning). The `cleanOrganismName` function strips the `°`, so the organisms should match. However, the gcfmap `cols[2]` value includes the full strain name while the TSV `Detected Organism` may be truncated. The `findAccession` function already handles this with prefix matching — the accession_map table stores the gcfmap organism names, and the VC lookup should use the same fuzzy matching. For now, store the exact gcfmap organism name in the `organism` column of `accession_map`.

- [ ] **Step 6: Run CLI tests, verify, commit**

Run: `swift test --filter BuildDbCommandTests`

```bash
git add Sources/LungfishIO/Formats/TaxTriage/TaxTriageDatabase.swift \
      Sources/LungfishCLI/Commands/BuildDbCommand.swift \
      Tests/LungfishIOTests/TaxTriageDatabaseTests.swift
git commit -m "feat: extend TaxTriageDatabase with accession_map table"
```

---

## Phase 2: Centralized Router

### Task 4: Create ClassifierDatabaseRouter with Tests

**Files:**
- Create: `Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift`
- Create: `Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift`

- [ ] **Step 1: Write all router tests first**

```swift
// Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift
import XCTest
@testable import LungfishApp

final class ClassifierDatabaseRoutingTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - TaxTriage

    func testRoute_taxTriageWithDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("taxtriage-2026-04-06T20-46-18")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("taxtriage.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "taxtriage")
        XCTAssertEqual(route?.displayName, "TaxTriage")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_taxTriageWithoutDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("taxtriage-2026-04-06T20-46-18")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "taxtriage")
        XCTAssertNil(route?.databaseURL)
    }

    // MARK: - Kraken2

    func testRoute_kraken2WithDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("kraken2-batch-2026-04-06T20-45-49")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("kraken2.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_kraken2WithoutDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("kraken2-batch-2026-04-06T20-45-49")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNil(route?.databaseURL)
    }

    // MARK: - EsViritu

    func testRoute_esVirituWithDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("esviritu.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "esviritu")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_esVirituWithoutDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "esviritu")
        XCTAssertNil(route?.databaseURL)
    }

    // MARK: - Non-classifier directories

    func testRoute_perSampleSubdir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("SRR35517702")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNil(route)
    }

    func testRoute_unrelatedDir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("spades-2026-04-06T10-00-00")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNil(route)
    }

    func testRoute_classificationPrefix() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("classification-batch-2026-04-06")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("kraken2.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNotNil(route?.databaseURL)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClassifierDatabaseRoutingTests`
Expected: compilation error — `ClassifierDatabaseRouter` doesn't exist.

- [ ] **Step 3: Implement ClassifierDatabaseRouter**

```swift
// Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift

import Foundation

/// Centralized routing logic for classifier result directories.
///
/// Determines whether a directory is a classifier result and whether it has
/// a pre-built SQLite database. Used by `MainSplitViewController` to decide
/// between DB-backed display, auto-build, or non-classifier handling.
enum ClassifierDatabaseRouter {

    /// A routing decision for a classifier result directory.
    struct Route {
        /// Tool identifier used by the CLI (e.g. "taxtriage", "esviritu", "kraken2").
        let tool: String
        /// Human-readable tool name for UI display (e.g. "TaxTriage", "EsViritu", "Kraken2").
        let displayName: String
        /// URL of the SQLite database file, or `nil` if no DB exists yet.
        let databaseURL: URL?
    }

    private static let toolDefinitions: [(prefix: String, dbName: String, tool: String, displayName: String)] = [
        ("taxtriage",      "taxtriage.sqlite", "taxtriage", "TaxTriage"),
        ("esviritu",       "esviritu.sqlite",  "esviritu",  "EsViritu"),
        ("kraken2",        "kraken2.sqlite",   "kraken2",   "Kraken2"),
        ("classification", "kraken2.sqlite",   "kraken2",   "Kraken2"),
    ]

    /// Checks whether `url` is a classifier result directory.
    ///
    /// - Returns: `Route` with `databaseURL` set if the DB exists, `databaseURL=nil`
    ///   if the directory is a classifier result but has no DB yet, or `nil` if the
    ///   directory is not a classifier result at all.
    static func route(for url: URL) -> Route? {
        let dirName = url.lastPathComponent
        for def in toolDefinitions {
            guard dirName.hasPrefix(def.prefix) else { continue }
            let dbURL = url.appendingPathComponent(def.dbName)
            if FileManager.default.fileExists(atPath: dbURL.path) {
                return Route(tool: def.tool, displayName: def.displayName, databaseURL: dbURL)
            } else {
                return Route(tool: def.tool, displayName: def.displayName, databaseURL: nil)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClassifierDatabaseRoutingTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift \
      Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift
git commit -m "feat: add ClassifierDatabaseRouter with 9 routing tests"
```

---

## Phase 3: Wire Router + Remove Legacy

**IMPORTANT:** This phase is large. Each task should be done carefully with a build check after each step. The compiler will catch most broken references when legacy methods are removed.

### Task 5: Wire Router into MainSplitViewController + Remove Legacy Display Methods

This is the critical wiring task. Replace all sidebar classifier handlers with the router pattern. Remove legacy display methods that are no longer called.

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift`

- [ ] **Step 1: Replace sidebar handlers in `displayContent(for:)`**

Find the `.classificationResult` handler (around line 1618) and replace:

```swift
// OLD:
if item.type == .classificationResult, let url = item.url {
    displayClassificationResult(at: url)
    return
}

// NEW:
if item.type == .classificationResult, let url = item.url {
    if let route = ClassifierDatabaseRouter.route(for: url) {
        if route.databaseURL != nil {
            displayBatchGroup(at: url)
        } else {
            showDatabaseBuildPlaceholder(tool: route.displayName, resultURL: url)
        }
    }
    return
}
```

Find the `.esvirituResult` handler and replace:

```swift
// OLD:
if item.type == .esvirituResult, let url = item.url {
    displayEsVirituResult(at: url)
    return
}

// NEW:
if item.type == .esvirituResult, let url = item.url {
    if let route = ClassifierDatabaseRouter.route(for: url) {
        if route.databaseURL != nil {
            displayBatchGroup(at: url)
        } else {
            showDatabaseBuildPlaceholder(tool: route.displayName, resultURL: url)
        }
    }
    return
}
```

Find the `.taxTriageResult` handler and replace:

```swift
// OLD:
if item.type == .taxTriageResult, let url = item.url {
    let sampleId = item.userInfo["sampleId"]
    if sampleId == nil {
        let dbURL = url.appendingPathComponent("taxtriage.sqlite")
        if FileManager.default.fileExists(atPath: dbURL.path) {
            displayBatchGroup(at: url)
            return
        }
    }
    displayTaxTriageResultFromSidebar(at: url, sampleId: sampleId)
    return
}

// NEW:
if item.type == .taxTriageResult, let url = item.url {
    if let route = ClassifierDatabaseRouter.route(for: url) {
        if route.databaseURL != nil {
            displayBatchGroup(at: url)
        } else {
            showDatabaseBuildPlaceholder(tool: route.displayName, resultURL: url)
        }
    }
    return
}
```

Find the `.analysisResult` handler and replace the classifier-prefix checks:

```swift
// OLD (classifier prefixes manually checked):
if item.type == .analysisResult, let url = item.url {
    let dirName = url.lastPathComponent
    if dirName.hasPrefix("esviritu") {
        displayBatchGroup(at: url)
    } else if dirName.hasPrefix("kraken2") || dirName.hasPrefix("classification") {
        displayBatchGroup(at: url)
    } else if dirName.hasPrefix("taxtriage") {
        displayBatchGroup(at: url)
    } else if dirName.hasPrefix("naomgs") { ... }
    ...
}

// NEW:
if item.type == .analysisResult, let url = item.url {
    if let route = ClassifierDatabaseRouter.route(for: url) {
        if route.databaseURL != nil {
            displayBatchGroup(at: url)
        } else {
            showDatabaseBuildPlaceholder(tool: route.displayName, resultURL: url)
        }
        return
    }
    // Non-classifier analysis results fall through to existing handling
    let dirName = url.lastPathComponent
    if dirName.hasPrefix("naomgs") {
        displayNaoMgsResultFromSidebar(at: url)
    } else if dirName.hasPrefix("nvd") {
        displayNvdResultFromSidebar(at: url)
    } else if ... {
        // keep existing non-classifier handling
    }
    return
}
```

- [ ] **Step 2: Update `navigateToRelatedAnalysis`**

```swift
func navigateToRelatedAnalysis(type: String, url: URL) {
    if let route = ClassifierDatabaseRouter.route(for: url) {
        if route.databaseURL != nil {
            displayBatchGroup(at: url)
        } else {
            showDatabaseBuildPlaceholder(tool: route.displayName, resultURL: url)
        }
        return
    }
    logger.warning("navigateToRelatedAnalysis: No route for \(type, privacy: .public)")
}
```

- [ ] **Step 3: Delete legacy display methods from MainSplitViewController**

Delete these private methods entirely:
- `displayClassificationResult(at:)` — was legacy Kraken2 single-result display
- `displayEsVirituResult(at:)` — was legacy EsViritu single-result display
- `displayTaxTriageResultFromSidebar(at:sampleId:)` — was legacy TaxTriage display
- `wireTaxTriageInspector(resultURL:)` — was called only from `displayTaxTriageResultFromSidebar`

The compiler will flag any remaining callers — fix them to use the router pattern.

- [ ] **Step 4: Delete legacy display methods from ViewerViewController extensions**

In `ViewerViewController+TaxTriage.swift`, delete:
- `displayTaxTriageBatch(batchURL:projectURL:)` — replaced by `displayTaxTriageFromDatabase`
- `displayTaxTriageResult(_:config:sampleId:)` — replaced by `displayTaxTriageFromDatabase`

In `ViewerViewController+EsViritu.swift`, delete:
- `displayEsVirituBatch(batchURL:projectURL:)` — replaced by `displayEsVirituFromDatabase`
- `displayEsVirituResult(_:config:)` — replaced by `displayEsVirituFromDatabase`

In `ViewerViewController+Taxonomy.swift`, delete any legacy display methods — keep only `displayTaxonomyFromDatabase`.

The compiler will flag any remaining callers.

- [ ] **Step 5: Build to verify**

Run: `swift build --build-tests`

Fix any compilation errors — they will be references to deleted methods. Each reference should be replaced with the router pattern.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift \
      Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift \
      Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift \
      Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift
git commit -m "refactor: replace all classifier sidebar handlers with ClassifierDatabaseRouter"
```

---

### Task 6: Remove Legacy VC Configuration Methods

Remove `configureBatchGroup`, `configure(result:)`, and all associated helpers from each classifier VC. Expand `configureFromDatabase` to handle single-sample mode.

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`

This task is large and should be broken into sub-steps per VC. The key change for each:

1. `configureFromDatabase` gains an optional `sampleId: String? = nil` parameter
2. When `sampleId` is nil → batch mode (existing behavior)
3. When `sampleId` is non-nil → single-sample mode (filter DB by sample, show single-sample UI)
4. Set `didLoadFromManifestCache = true` in all cases
5. Delete `configureBatchGroup` and `configure(result:config:)` and all their private helpers

- [ ] **Step 1: Update `configureFromDatabase` signature on all three VCs**

Add `sampleId: String? = nil` parameter. When non-nil, filter the DB query to that single sample and show the single-sample UI (organism table for TaxTriage, detection table for EsViritu, sunburst+tree for Kraken2).

- [ ] **Step 2: Set `didLoadFromManifestCache = true` in all `configureFromDatabase` methods**

This fixes the "Building manifest..." Inspector bug for all three tools.

- [ ] **Step 3: Delete legacy configuration methods**

From `TaxTriageResultViewController`:
- Delete `configureBatchGroup(batchURL:projectURL:)` and all private helpers it calls
- Delete `configure(result:config:)`
- Delete `saveBatchManifest`, `updateBatchManifestUniqueReads`
- Delete `scheduleBatchPerSampleUniqueReadComputation`
- Delete `rebuildAccessionLookups`, `parseGCFMappingData`, `parseTaxIDMappingData`
- Delete `recomputeUniqueReadsButton` handler and the button itself

From `EsVirituResultViewController`:
- Delete `configureBatchGroup` equivalent
- Delete `configure(result:)` file-based path

From `TaxonomyViewController`:
- Delete legacy `configureBatchMode` or equivalent
- Delete file-based single-sample configuration

- [ ] **Step 4: Build to verify**

Run: `swift build --build-tests`

Fix compilation errors from deleted method references. Update `displayBatchGroup` in MainSplitViewController if it still calls any deleted methods.

- [ ] **Step 5: Run all tests**

Run: `swift test`

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift \
      Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift \
      Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift
git commit -m "refactor: remove all legacy classifier configuration methods, DB-only loading"
```

---

### Task 7: Rebuild Real DBs and Manual Verification

- [ ] **Step 1: Rebuild all real databases with extended schemas**

```bash
.build/debug/lungfish-cli build-db taxtriage "/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/taxtriage-2026-04-06T20-46-18" --force
.build/debug/lungfish-cli build-db taxtriage "/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/taxtriage-2026-04-07T18-44-54" --force
.build/debug/lungfish-cli build-db esviritu "/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/esviritu-batch-2026-04-06T20-46-01" --force
.build/debug/lungfish-cli build-db kraken2 "/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/kraken2-batch-2026-04-06T20-45-49" --force
```

Verify each produces output like:
```
Parsed N rows from ...
Built database at ... with N rows
```

- [ ] **Step 2: Verify DB content**

```bash
sqlite3 /Volumes/nvd_remote/.../taxtriage-2026-04-06T20-46-18/taxtriage.sqlite \
    "SELECT COUNT(*) FROM accession_map"
sqlite3 /Volumes/nvd_remote/.../kraken2-batch-2026-04-06T20-45-49/kraken2.sqlite \
    "SELECT sample, taxon_name, parent_tax_id, depth FROM classification_rows WHERE sample = 'SRR35517702' AND depth <= 2 LIMIT 10"
sqlite3 /Volumes/nvd_remote/.../esviritu-batch-2026-04-06T20-46-01/esviritu.sqlite \
    "SELECT COUNT(*) FROM coverage_windows"
```

- [ ] **Step 3: Launch app, run manual checklist**

1. Click TaxTriage (149 samples) → should show DB-backed flat table with correct TASS scores, reads, dashes for Unique Reads (nil in DB). No "Building manifest..." in Inspector. No FASTQ metadata console messages.
2. Click EsViritu Batch → should show DB-backed detection table
3. Click Kraken2 Batch → should show DB-backed taxonomy table
4. Delete a `.sqlite` file, click the result → should show placeholder, auto-build runs, reloads with DB
5. No console messages about JSON parsing, manifest building, or FASTQ metadata loading

- [ ] **Step 4: Final commit with verification notes**

```bash
git commit --allow-empty -m "verify: manual testing of DB-only classifier views complete"
```
