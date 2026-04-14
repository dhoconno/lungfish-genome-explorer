# Kraken2 Metadata-Pruned Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add fast Kraken2 batch search that combines editable TSV-backed sample metadata filters with database-backed taxon-name search and renders a pruned multi-sample hierarchy instead of materializing all sample trees up front.

**Architecture:** Keep `metadata/sample_metadata.tsv` as the editable source of truth, mirror it into a queryable cache inside `kraken2.sqlite`, then add Kraken2Database APIs that first resolve eligible samples by metadata and taxon-name predicates and finally fetch only matching rows plus their ancestors. Update the Kraken2 batch view to use this pruned search path for cross-sample exploration while preserving existing metadata columns and sample selection behavior.

**Tech Stack:** Swift, AppKit, SQLite3, XCTest, Testing

---

### Task 1: Metadata Cache In Kraken2 SQLite

**Files:**
- Modify: `Sources/LungfishIO/Formats/Kraken/Kraken2Database.swift`
- Modify: `Sources/LungfishCore/Models/SampleMetadataStore.swift`
- Test: `Tests/LungfishIOTests/Kraken2DatabaseTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testRefreshSampleMetadataCacheStoresTSVFieldsBySample() throws {
    let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [:])
    let store = try SampleMetadataStore(
        csvData: Data("sample_id\tcity\tcollection_date\nS1\tDallas\t2024-01-05\nS2\tAustin\t2024-02-01\n".utf8),
        knownSampleIds: Set(["S1", "S2"])
    )

    try db.refreshSampleMetadataCache(store: store)

    let values = try db.fetchMetadataValues(field: "city")
    XCTAssertEqual(values["S1"], "Dallas")
    XCTAssertEqual(values["S2"], "Austin")
}

func testMetadataFilterReturnsMatchingSamples() throws {
    let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [:])
    let store = try SampleMetadataStore(
        csvData: Data("sample_id\tcity\nS1\tDallas\nS2\tAustin\nS3\tDallas\n".utf8),
        knownSampleIds: Set(["S1", "S2", "S3"])
    )

    try db.refreshSampleMetadataCache(store: store)

    let sampleIds = try db.filterSamplesByMetadata([
        .init(field: "city", op: .contains, value: "Dallas")
    ])

    XCTAssertEqual(Set(sampleIds), Set(["S1", "S3"]))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter Kraken2DatabaseTests`
Expected: FAIL because the metadata cache APIs and schema do not exist yet.

- [ ] **Step 3: Write minimal implementation**

```swift
public struct KrakenMetadataFilter: Sendable {
    public enum Operation: Sendable { case equal, contains, greaterOrEqual, lessOrEqual }
    public let field: String
    public let op: Operation
    public let value: String
}

public func refreshSampleMetadataCache(store: SampleMetadataStore) throws
public func filterSamplesByMetadata(_ filters: [KrakenMetadataFilter]) throws -> [String]
public func fetchMetadataValues(field: String) throws -> [String: String]
```

Add schema:

```sql
CREATE TABLE IF NOT EXISTS sample_metadata_cache (
    sample TEXT NOT NULL,
    field TEXT NOT NULL,
    value TEXT NOT NULL,
    PRIMARY KEY(sample, field)
);
CREATE INDEX IF NOT EXISTS idx_kr_metadata_field_value
ON sample_metadata_cache(field, value);
CREATE INDEX IF NOT EXISTS idx_kr_metadata_sample
ON sample_metadata_cache(sample);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter Kraken2DatabaseTests`
Expected: PASS with the new cache tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Formats/Kraken/Kraken2Database.swift Sources/LungfishCore/Models/SampleMetadataStore.swift Tests/LungfishIOTests/Kraken2DatabaseTests.swift
git commit -m "feat: cache kraken2 sample metadata in sqlite"
```

### Task 2: SQL-Backed Pruned Search APIs

**Files:**
- Modify: `Sources/LungfishIO/Formats/Kraken/Kraken2Database.swift`
- Test: `Tests/LungfishIOTests/Kraken2DatabaseTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testSearchPrunedRowsReturnsMatchingTaxaAndAncestors() throws {
    let db = try Kraken2Database.create(at: dbURL, rows: coronavirusRows, metadata: [:])

    let result = try db.searchPrunedHierarchy(
        taxonQuery: "coronavirus",
        sampleIds: ["S1", "S2", "S3"]
    )

    XCTAssertEqual(Set(result.matchingSamples), Set(["S1", "S3"]))
    XCTAssertTrue(result.rows.contains(where: { $0.sample == "S1" && $0.taxonName == "Coronaviridae" }))
    XCTAssertTrue(result.rows.contains(where: { $0.sample == "S1" && $0.taxonName == "root" }))
    XCTAssertFalse(result.rows.contains(where: { $0.sample == "S2" && $0.taxonName == "Influenza A virus" }))
}

func testSearchPrunedHierarchyRespectsMetadataFilteredSamples() throws {
    let db = try Kraken2Database.create(at: dbURL, rows: coronavirusRows, metadata: [:])
    try db.refreshSampleMetadataCache(store: metadataStore)

    let filtered = try db.filterSamplesByMetadata([.init(field: "city", op: .equal, value: "Dallas")])
    let result = try db.searchPrunedHierarchy(taxonQuery: "coronavirus", sampleIds: filtered)

    XCTAssertEqual(result.matchingSamples, ["S1"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter Kraken2DatabaseTests`
Expected: FAIL because there is no pruned hierarchy search API.

- [ ] **Step 3: Write minimal implementation**

```swift
public struct KrakenPrunedSearchResult: Sendable {
    public let rows: [Kraken2ClassificationRow]
    public let matchingSamples: [String]
}

public func searchPrunedHierarchy(
    taxonQuery: String,
    sampleIds: [String]
) throws -> KrakenPrunedSearchResult
```

Implementation shape:

```sql
WITH RECURSIVE
matches AS (... sample/tax_id rows where lower(taxon_name) LIKE ? ...),
ancestors(sample, tax_id) AS (
  SELECT sample, tax_id FROM matches
  UNION
  SELECT cr.sample, cr.parent_tax_id
  FROM classification_rows cr
  JOIN ancestors a
    ON cr.sample = a.sample AND cr.tax_id = a.tax_id
  WHERE cr.parent_tax_id IS NOT NULL
)
SELECT DISTINCT cr.*
FROM classification_rows cr
JOIN ancestors a
  ON cr.sample = a.sample AND cr.tax_id = a.tax_id;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter Kraken2DatabaseTests`
Expected: PASS with pruned-row search tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Formats/Kraken/Kraken2Database.swift Tests/LungfishIOTests/Kraken2DatabaseTests.swift
git commit -m "feat: add pruned kraken2 hierarchy search"
```

### Task 3: Pruned Tree Construction In Kraken2 Batch UI

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Test: `Tests/LungfishAppTests/TaxonomyViewControllerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testConfigureFromDatabaseLoadsMetadataColumnsForBatchMode() throws {
    let vc = TaxonomyViewController()
    _ = vc.view
    vc.sampleMetadataStore = try makeMetadataStore(...)

    vc.configureFromDatabase(db)

    XCTAssertNotNil(vc.samplePickerState)
    XCTAssertEqual(vc.testTableView.metadataColumns.store?.records["S1"]?["city"], "Dallas")
}

func testApplyBatchSearchBuildsPrunedDisplayTree() throws {
    let vc = TaxonomyViewController()
    _ = vc.view
    vc.configureFromDatabase(db)

    vc.applyDatabaseBackedSearchForTesting(
        taxonQuery: "coronavirus",
        metadataFilters: [.init(field: "city", op: .equal, value: "Dallas")]
    )

    let names = Set(vc.testTableView.tree?.allNodes().map(\\.name) ?? [])
    XCTAssertTrue(names.contains("Coronaviridae"))
    XCTAssertTrue(names.contains("S1"))
    XCTAssertFalse(names.contains("S2"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TaxonomyViewControllerTests`
Expected: FAIL because batch mode does not drive metadata-aware pruned search.

- [ ] **Step 3: Write minimal implementation**

```swift
private var activeMetadataFilters: [KrakenMetadataFilter] = []
private var activeTaxonSearchText: String = ""

private func applyDatabaseBackedBatchSearch()
private func buildDisplayTree(from prunedRows: [Kraken2ClassificationRow], matchingSamples: [String]) -> TaxonTree?
```

Behavior:

```swift
if activeTaxonSearchText.isEmpty && activeMetadataFilters.isEmpty {
    applyBatchSampleFilter()
} else {
    let eligibleSamples = try db.filterSamplesByMetadata(activeMetadataFilters)
    let pruned = try db.searchPrunedHierarchy(taxonQuery: activeTaxonSearchText, sampleIds: eligibleSamples)
    let tree = buildDisplayTree(from: pruned.rows, matchingSamples: pruned.matchingSamples)
    taxonomyTableView.tree = tree
    sunburstView.tree = tree
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TaxonomyViewControllerTests`
Expected: PASS with pruned-tree UI tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift Tests/LungfishAppTests/TaxonomyViewControllerTests.swift
git commit -m "feat: use pruned kraken2 batch search in taxonomy view"
```

### Task 4: Verification And Regression Coverage

**Files:**
- Modify: `Tests/LungfishAppTests/ColumnFilterIntegrationTests.swift`
- Modify: `Tests/LungfishIOTests/Kraken2DatabaseTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@Test("Metadata month filter narrows Kraken2 cross-sample search")
func metadataMonthFilterNarrowsKrakenSearch() throws { ... }

@Test("Search term coronavirus includes all matching ranks and ancestors")
func coronavirusSearchIncludesAncestors() throws { ... }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ColumnFilterIntegrationTests`
Expected: FAIL until the search/filter integration is complete.

- [ ] **Step 3: Write minimal implementation**

No new production code if prior tasks are correct; add only the test helpers and any small glue needed to expose testable hooks without widening production APIs unnecessarily.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ColumnFilterIntegrationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tests/LungfishAppTests/ColumnFilterIntegrationTests.swift Tests/LungfishIOTests/Kraken2DatabaseTests.swift
git commit -m "test: cover kraken2 metadata pruned search"
```

### Task 5: Full Verification

**Files:**
- Modify: `Sources/LungfishIO/Formats/Kraken/Kraken2Database.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Tests/LungfishIOTests/Kraken2DatabaseTests.swift`
- Modify: `Tests/LungfishAppTests/TaxonomyViewControllerTests.swift`
- Modify: `Tests/LungfishAppTests/ColumnFilterIntegrationTests.swift`

- [ ] **Step 1: Run focused database tests**

Run: `swift test --filter Kraken2DatabaseTests`
Expected: PASS

- [ ] **Step 2: Run focused taxonomy UI tests**

Run: `swift test --filter TaxonomyViewControllerTests`
Expected: PASS

- [ ] **Step 3: Run metadata/filter integration tests**

Run: `swift test --filter ColumnFilterIntegrationTests`
Expected: PASS

- [ ] **Step 4: Run one wider app/workflow slice**

Run: `swift test --filter Tax`
Expected: PASS for touched taxonomy-related suites, or report the exact failing suite if there is pre-existing breakage.

- [ ] **Step 5: Commit final fixes if needed**

```bash
git add Sources/LungfishIO/Formats/Kraken/Kraken2Database.swift Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift Tests/LungfishIOTests/Kraken2DatabaseTests.swift Tests/LungfishAppTests/TaxonomyViewControllerTests.swift Tests/LungfishAppTests/ColumnFilterIntegrationTests.swift
git commit -m "fix: finalize kraken2 metadata-backed pruned search"
```
