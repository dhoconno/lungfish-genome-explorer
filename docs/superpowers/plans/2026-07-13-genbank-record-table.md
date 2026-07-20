# GenBank Record Table Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Preserve every recoverable GenBank record field, expose one filterable row per record, and scope the annotation detail list to all records remaining after filtering.

**Architecture:** Extend GenBankReader with lossless ordered record fields, materialize those fields and aggregated feature qualifiers in an indexed SQLite sidecar, and link the optional sidecar from BundleManifest. The reference viewport loads sidecar rows into a dynamic BatchTableView; its displayed sequence names become an optional SQLite annotation-query scope while the graphical viewer continues to display the selected sequence.

**Tech Stack:** Swift 6, AppKit, SQLite3, XCTest, existing LungfishCore/LungfishIO/LungfishWorkflow bundle and provenance APIs.

---

## File responsibility map

- Sources/LungfishIO/Formats/GenBank/GenBankReader.swift: retain ordered multiline record fields.
- Sources/LungfishIO/Bundles/GenBankRecordDatabase.swift: own SQLite schema, writer, reader, aggregation, and validation.
- Sources/LungfishCore/Bundles/BundleManifest.swift: declare the optional record-store descriptor.
- Sources/LungfishCore/Bundles/BundleManifest+Validation.swift: reject unsafe record-store paths.
- Sources/LungfishCore/Bundles/ReferenceBundleBuilder.swift: carry the prepared store URL in BuildConfiguration.
- Sources/LungfishWorkflow/Bundles/ReferenceSourcePreparer.swift: create the store during GenBank preparation.
- Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift: embed, link, validate, and provenance-record the store.
- Sources/LungfishApp/Views/Results/Reference/ReferenceBundleRecordTable.swift: dynamic record rows and columns.
- Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift: load rows, reconcile selection, publish filter scope, and respect safe areas.
- Sources/LungfishIO/Bundles/AnnotationDatabase+Query.swift: indexed multi-chromosome query scope.
- Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift: scoped background queries and counts.
- Sources/LungfishApp/Views/Viewer/ViewerViewController.swift: annotation-scope forwarding API.

### Task 1: Preserve ordered GenBank record fields

**Files:**
- Modify: Sources/LungfishIO/Formats/GenBank/GenBankReader.swift
- Test: Tests/LungfishIOTests/GenBankReaderComprehensiveTests.swift

- [ ] **Step 1: Add a failing multi-record parser test**

Create a fixture with DBLINK continuations, KEYWORDS, SOURCE/ORGANISM/taxonomy, two REFERENCE blocks, COMMENT continuations, an unknown header, a source feature, and multiline translation. Assert this API:

~~~swift
let records = try GenBankReader(url: url).readAllSync()
let record = try XCTUnwrap(records.first)
XCTAssertEqual(record.values(forRecordField: "DBLINK"), ["INSDC: AF161864", "INSDC: EU392139"])
XCTAssertEqual(record.values(forRecordField: "ORGANISM"), ["Macaca fascicularis"])
XCTAssertTrue(record.values(forRecordField: "TAXONOMY")[0].contains("Primates"))
XCTAssertEqual(record.values(forRecordField: "REFERENCE.1.PUBMED"), ["10640754"])
XCTAssertEqual(record.values(forRecordField: "REFERENCE.2.PUBMED"), ["19107381"])
XCTAssertEqual(record.values(forRecordField: "COMMENT.IPD accession"), ["NHP00353"])
XCTAssertEqual(record.values(forRecordField: "CUSTOM_HEADER"), ["retained value"])
XCTAssertEqual(record.annotations.first(where: { $0.type == .source })?.qualifier("organism"), "Macaca fascicularis")
~~~

- [ ] **Step 2: Run the parser test and verify RED**

Run:

~~~bash
swift test --filter GenBankReaderComprehensiveTests/testPreservesAllRecordHeadersReferencesAndSourceQualifiers
~~~

Expected: compilation fails because values(forRecordField:) and ordered record fields do not exist.

- [ ] **Step 3: Add ordered fields and parsing**

Add this value type and thread recordFields through GenBankRecord:

~~~swift
public struct GenBankRecordField: Sendable, Equatable {
    public let key: String
    public let value: String
    public let ordinal: Int
}

public func values(forRecordField key: String) -> [String] {
    recordFields
        .filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        .sorted { $0.ordinal < $1.ordinal }
        .map(\.value)
}
~~~

Refactor the header scanner to emit LOCUS.NAME/LENGTH/MOLECULE_TYPE/TOPOLOGY/DIVISION/DATE, every top-level header, REFERENCE.<ordinal>.<subfield>, COMMENT plus COMMENT.<label>, and unknown uppercase header keys. Preserve continuations and repeated values. Derive definition/accession/version from the same accumulator; do not change FEATURES or ORIGIN semantics.

Extend the recovery result so a malformed record-field continuation can emit a warning with recordIdentifier and field key while the record's sequence and other recovered fields remain available. Add one assertion that the malformed field is omitted, the warning is present, and the remaining fields survive.

- [ ] **Step 4: Run all GenBank reader tests**

~~~bash
swift test --filter GenBankReader
~~~

Expected: all GenBank reader tests pass.

- [ ] **Step 5: Commit**

~~~bash
git add Sources/LungfishIO/Formats/GenBank/GenBankReader.swift Tests/LungfishIOTests/GenBankReaderComprehensiveTests.swift
git commit -m "feat: preserve GenBank record fields"
~~~

### Task 2: Add the indexed GenBank record database

**Files:**
- Create: Sources/LungfishIO/Bundles/GenBankRecordDatabase.swift
- Create: Tests/LungfishIOTests/GenBankRecordDatabaseTests.swift

- [ ] **Step 1: Write failing round-trip tests**

Build two GenBankRecord values with repeated headers and source/gene/CDS qualifiers, then assert:

~~~swift
let result = try GenBankRecordDatabase.create(records: records, at: databaseURL)
XCTAssertEqual(result.recordCount, 2)
let database = try GenBankRecordDatabase(url: databaseURL)
XCTAssertEqual(database.records().map(\.sequenceName), ["NHP00353", "NHP02052"])
XCTAssertEqual(database.records()[0].values["feature.allele"], "Mafa-I*01:01:01")
XCTAssertEqual(database.records()[0].values["record.REFERENCE.1.PUBMED"], "10640754")
XCTAssertEqual(database.records()[0].values["feature.db_xref"], "taxon:9541")
~~~

Also assert duplicate values are removed in first-seen order and distinct repeated values survive.

- [ ] **Step 2: Run and verify RED**

~~~bash
swift test --filter GenBankRecordDatabaseTests
~~~

Expected: compilation fails because GenBankRecordDatabase does not exist.

- [ ] **Step 3: Implement schema and API**

Create these tables and indexes:

~~~sql
CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE records (
  id INTEGER PRIMARY KEY,
  sequence_name TEXT NOT NULL UNIQUE,
  sequence_length INTEGER NOT NULL,
  source_ordinal INTEGER NOT NULL
);
CREATE TABLE field_definitions (
  key TEXT PRIMARY KEY,
  display_title TEXT NOT NULL,
  value_type TEXT NOT NULL,
  source_category TEXT NOT NULL,
  preferred_order INTEGER NOT NULL
);
CREATE TABLE field_values (
  record_id INTEGER NOT NULL REFERENCES records(id) ON DELETE CASCADE,
  field_key TEXT NOT NULL REFERENCES field_definitions(key),
  value_ordinal INTEGER NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (record_id, field_key, value_ordinal)
);
CREATE INDEX idx_field_values_key_value ON field_values(field_key, value COLLATE NOCASE);
CREATE INDEX idx_field_values_record_key ON field_values(record_id, field_key);
~~~

Expose Sendable FieldDefinition, RecordRow, and CreateResult. Namespace headers as record.<key> and qualifiers as feature.<key>. Aggregate all features including source, remove exact duplicates, and join only for display. Order Allele, Gene, Definition, Accession, Organism, Product, and LOCUS fields first; sort remaining keys case-insensitively. Infer numeric fields only when every non-empty value parses numerically.

- [ ] **Step 4: Add corrupt-schema and version tests, then verify GREEN**

~~~bash
swift test --filter GenBankRecordDatabaseTests
~~~

Expected: all tests pass, including rejection of missing tables and unsupported versions.

- [ ] **Step 5: Commit**

~~~bash
git add Sources/LungfishIO/Bundles/GenBankRecordDatabase.swift Tests/LungfishIOTests/GenBankRecordDatabaseTests.swift
git commit -m "feat: index GenBank record metadata"
~~~

### Task 3: Link the optional store from BundleManifest

**Files:**
- Modify: Sources/LungfishCore/Bundles/BundleManifest.swift
- Modify: Sources/LungfishCore/Bundles/BundleManifest+Validation.swift
- Modify: Sources/LungfishIO/Bundles/ReferenceBundle.swift
- Test: Tests/LungfishCoreTests/BundleManifestTests.swift
- Test: Tests/LungfishIOTests/ReferenceBundleTests.swift

- [ ] **Step 1: Write failing compatibility and validation tests**

Round-trip:

~~~swift
ReferenceRecordStoreInfo(
    schemaVersion: 1,
    format: "genbank",
    databasePath: "metadata/genbank_records.sqlite",
    recordCount: 2_321
)
~~~

Assert old manifests decode with recordStore == nil, ../escape.sqlite fails validation, and ReferenceBundle.recordStoreDatabase() opens a valid store.

- [ ] **Step 2: Verify RED**

~~~bash
swift test --filter BundleManifestTests/testRecordStoreRoundTrip
swift test --filter ReferenceBundleTests/testOpensValidatedGenBankRecordStore
~~~

Expected: compilation fails because the descriptor does not exist.

- [ ] **Step 3: Implement the optional descriptor**

~~~swift
public struct ReferenceRecordStoreInfo: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let format: String
    public let databasePath: String
    public let recordCount: Int
}
~~~

Thread recordStore through BundleManifest initialization, Codable, equality, and copy helpers. Validate record_store.database_path. Resolve it in ReferenceBundle with validatedBundleMemberURL and return GenBankRecordDatabase?; absence returns nil, but a corrupt declared store throws.

- [ ] **Step 4: Verify GREEN**

~~~bash
swift test --filter BundleManifestTests
swift test --filter ReferenceBundleTests
~~~

Expected: both suites pass, including legacy decoding.

- [ ] **Step 5: Commit**

~~~bash
git add Sources/LungfishCore/Bundles/BundleManifest.swift Sources/LungfishCore/Bundles/BundleManifest+Validation.swift Sources/LungfishIO/Bundles/ReferenceBundle.swift Tests/LungfishCoreTests/BundleManifestTests.swift Tests/LungfishIOTests/ReferenceBundleTests.swift
git commit -m "feat: declare reference record stores"
~~~

### Task 4: Build and provenance-record the store

**Files:**
- Modify: Sources/LungfishCore/Bundles/ReferenceBundleBuilder.swift
- Modify: Sources/LungfishWorkflow/Bundles/ReferenceSourcePreparer.swift
- Modify: Sources/LungfishWorkflow/Bundles/ReferenceBundleImportService.swift
- Modify: Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift
- Modify: Sources/LungfishWorkflow/ONTGenotyping/MHCAmpliconReferenceBundleBuilder.swift
- Test: Tests/LungfishWorkflowTests/ReferenceSourcePreparerTests.swift
- Test: Tests/LungfishWorkflowTests/NativeBundleBuilderProvenanceTests.swift
- Test: Tests/LungfishWorkflowTests/MHCAmpliconReferenceBundleBuilderTests.swift
- Test: Tests/LungfishCLITests/ImportFastaGenBankAnnotationTests.swift

- [ ] **Step 1: Add failing preparation/build assertions**

For a two-record fixture, assert prepared.recordStoreURL opens with two records. For standard and MHC builds, assert manifest.recordStore.recordCount == 2, the final store exists, and canonical provenance contains its final stored path, checksum, and size. Assert FASTA preparation returns nil.

- [ ] **Step 2: Verify RED**

~~~bash
swift test --filter ReferenceSourcePreparerTests
swift test --filter MHCAmpliconReferenceBundleBuilderTests/testBuildsAnnotatedGenBankReferenceWithRecordStore
~~~

Expected: compilation fails because preparation/configuration does not carry the store.

- [ ] **Step 3: Carry the staged store**

Add referenceRecordStoreURL: URL? = nil to BuildConfiguration and recordStoreURL: URL? to PreparedReferenceSource. In prepareGenBank:

~~~swift
let recordStoreURL = tempDirectory.appendingPathComponent("genbank_records.sqlite")
_ = try GenBankRecordDatabase.create(records: recovery.records, at: recordStoreURL)
~~~

Pass the URL from ReferenceBundleImportService and MHCAmpliconReferenceBundleBuilder into BuildConfiguration. FASTA preparation passes nil.

- [ ] **Step 4: Embed and link it**

NativeBundleBuilder copies the declared store to metadata/genbank_records.sqlite, validates it by opening it, reads recordCount, and supplies ReferenceRecordStoreInfo to BundleManifest. Include the staged URL in transient provenance-input replacement. bundleOutputFileRecords already enumerates the final sidecar; verify its FileRecord points to the published bundle, not the temp directory.

- [ ] **Step 5: Verify GREEN**

~~~bash
swift test --filter ReferenceSourcePreparerTests
swift test --filter NativeBundleBuilderProvenanceTests
swift test --filter MHCAmpliconReferenceBundleBuilderTests
swift test --filter ImportFastaGenBankAnnotationTests
~~~

Expected: all suites pass; FASTA imports remain unchanged.

- [ ] **Step 6: Commit**

~~~bash
git add Sources/LungfishCore/Bundles/ReferenceBundleBuilder.swift Sources/LungfishWorkflow/Bundles/ReferenceSourcePreparer.swift Sources/LungfishWorkflow/Bundles/ReferenceBundleImportService.swift Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift Sources/LungfishWorkflow/ONTGenotyping/MHCAmpliconReferenceBundleBuilder.swift Tests/LungfishWorkflowTests/ReferenceSourcePreparerTests.swift Tests/LungfishWorkflowTests/NativeBundleBuilderProvenanceTests.swift Tests/LungfishWorkflowTests/MHCAmpliconReferenceBundleBuilderTests.swift Tests/LungfishCLITests/ImportFastaGenBankAnnotationTests.swift
git commit -m "feat: embed GenBank record stores"
~~~

### Task 5: Build the dynamic record table

**Files:**
- Create: Sources/LungfishApp/Views/Results/Reference/ReferenceBundleRecordTable.swift
- Modify: Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift
- Test: Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift
- Test: Tests/LungfishKitTests/BatchTableViewTests.swift

- [ ] **Step 1: Add failing column/filter tests**

Create a record store with Allele, Gene, Definition, Accession, Organism, Product, numeric length, and a custom key. Assert dynamic identifiers exist, global search finds an allele, organism column equality returns two rows, length numeric filtering works, and a legacy bundle retains Sequence/Length/Role.

- [ ] **Step 2: Verify RED**

~~~bash
swift test --filter ReferenceBundleViewportControllerTests/testGenBankRecordColumnsAndFilters
~~~

Expected: only three summary columns are available.

- [ ] **Step 3: Implement record rows and table**

~~~swift
struct ReferenceBundleRecordRow: Sendable, Equatable {
    let summary: BundleBrowserSequenceSummary
    let values: [String: String]
}

@MainActor
final class ReferenceBundleRecordTable: BatchTableView<ReferenceBundleRecordRow> {
    var dynamicFields: [GenBankRecordDatabase.FieldDefinition] = []
}
~~~

Make columnSpecs return Sequence/Length/Role plus dynamic definitions. Search summary fields and every values entry. Override columnValue, columnNumericValue, columnTypeHints, compareRows, and rowIdentity. Rebuild dynamic columns before configure(rows:).

- [ ] **Step 4: Load rows in the viewport**

If ReferenceBundle.recordStoreDatabase() returns a store, merge database rows with matching BundleBrowserSequenceSummary rows. Duplicate/unknown sequence identities produce a visible warning and manifest-row fallback. Without a store, use empty values and the three fixed columns. Selection and display use row.summary.name.

- [ ] **Step 5: Verify GREEN**

~~~bash
swift test --filter ReferenceBundleViewportControllerTests
swift test --filter BatchTableViewTests
~~~

Expected: dynamic filtering and legacy fallback pass.

- [ ] **Step 6: Commit**

~~~bash
git add Sources/LungfishApp/Views/Results/Reference/ReferenceBundleRecordTable.swift Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift Tests/LungfishKitTests/BatchTableViewTests.swift
git commit -m "feat: display filterable GenBank records"
~~~

### Task 6: Add performant multi-record annotation queries

**Files:**
- Modify: Sources/LungfishIO/Bundles/AnnotationDatabase+Query.swift
- Test: Tests/LungfishIOTests/AnnotationDatabaseTests.swift

- [ ] **Step 1: Write failing scope tests**

Create annotations on three chromosomes and assert queryForTable, totalCount, and allTypes accept allowedChromosomes. Test nil means all, empty means none, two names aggregate two records, and 1,200 names do not hit SQLite's binding limit.

- [ ] **Step 2: Verify RED**

~~~bash
swift test --filter AnnotationDatabaseTests/testMultiChromosomeScope
~~~

Expected: scoped APIs do not exist.

- [ ] **Step 3: Implement connection-local scope**

Add allowedChromosomes: Set<String>? = nil to query, count, and type APIs. Nil adds no constraint; empty returns immediately; non-empty populates:

~~~sql
CREATE TEMP TABLE IF NOT EXISTS query_chromosome_scope (
  chromosome TEXT PRIMARY KEY
);
~~~

Clear and bulk-insert bound names in one transaction, then join annotations.chromosome to the temporary table. Preserve all current predicates and never interpolate values into SQL.

- [ ] **Step 4: Verify GREEN**

~~~bash
swift test --filter AnnotationDatabaseTests
~~~

Expected: all tests pass, including 1,200 names.

- [ ] **Step 5: Commit**

~~~bash
git add Sources/LungfishIO/Bundles/AnnotationDatabase+Query.swift Tests/LungfishIOTests/AnnotationDatabaseTests.swift
git commit -m "feat: scope annotations to reference records"
~~~

### Task 7: Propagate filter scope into the annotation drawer

**Files:**
- Modify: Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift
- Modify: Sources/LungfishApp/Views/Viewer/ViewerViewController.swift
- Modify: Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift
- Test: Tests/LungfishAppTests/AnnotationTableDrawerVariantTests.swift
- Test: Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift

- [ ] **Step 1: Add failing query-context and viewport tests**

Assert AnnotationQueryContext scopes rows/counts and distinguishes nil from empty. Filter two of three viewport rows and assert the drawer scope contains both, annotation count aggregates both, and changing selected row changes only the graphical selection.

- [ ] **Step 2: Verify RED**

~~~bash
swift test --filter AnnotationTableDrawerVariantTests/testAnnotationQueryContextScopesMultipleRecords
swift test --filter ReferenceBundleViewportControllerTests/testFilteredRecordsScopeAnnotationDrawer
~~~

Expected: annotation queries remain global.

- [ ] **Step 3: Carry scope through drawer queries**

Add allowedChromosomes to AnnotationQueryContext and all annotation fetch-loop calls. Add AnnotationTableDrawerView.setAllowedChromosomes(_:) that stores scope, cancels the current token, increments query generation, recomputes scoped count/types/dynamic columns, and launches a new query. Completion handlers must reject stale generations.

- [ ] **Step 4: Wire displayed rows**

Expose ViewerViewController.setAnnotationRecordScope(_:). In the viewport displayed-row callback compute:

~~~swift
let scope = Set(sequenceTableView.displayedRows.map { $0.summary.name })
embeddedViewerController.setAnnotationRecordScope(scope)
~~~

Pass nil only for a legacy/no-store table with no active filter. Pass an empty set for explicit zero matches. Reconcile selection after publishing scope.

- [ ] **Step 5: Verify GREEN**

~~~bash
swift test --filter AnnotationTableDrawerVariantTests
swift test --filter ReferenceBundleViewportControllerTests
~~~

Expected: scoped rows/counts, cancellation, selection, and empty results pass.

- [ ] **Step 6: Commit**

~~~bash
git add Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift Sources/LungfishApp/Views/Viewer/ViewerViewController.swift Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Tests/LungfishAppTests/AnnotationTableDrawerVariantTests.swift Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift
git commit -m "feat: filter annotation details by records"
~~~

### Task 8: Keep controls below the title bar

**Files:**
- Modify: Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift
- Test: Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift

- [ ] **Step 1: Add a failing safe-area test**

Host the viewport in a fullSizeContentView test window and assert summaryBar.minY is at least safeAreaRect.minY and the search field is below the summary. Host it in a normal child container and assert no double inset.

- [ ] **Step 2: Verify RED**

~~~bash
swift test --filter ReferenceBundleViewportControllerTests/testReferenceControlsRespectWindowSafeArea
~~~

Expected: summary content begins above the effective safe-area top.

- [ ] **Step 3: Fix constraints**

Anchor summaryBar and focusContainer top constraints to view.safeAreaLayoutGuide.topAnchor. Keep existing leading/trailing/bottom constraints and BatchTableView's internal four-point search inset.

- [ ] **Step 4: Verify GREEN**

~~~bash
swift test --filter ReferenceBundleViewportControllerTests
~~~

Expected: safe-area and existing layout tests pass.

- [ ] **Step 5: Commit**

~~~bash
git add Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift
git commit -m "fix: keep reference filters below title bar"
~~~

### Task 9: Verify the IPD-MHC workflow and package a debug build

**Files:**
- Modify only if a regression fixture requires correction: Tests/LungfishWorkflowTests/ReferenceSourcePreparerTests.swift
- Modify only if a viewport fixture requires correction: Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift

- [ ] **Step 1: Run focused suites**

~~~bash
swift test --filter GenBankReader
swift test --filter GenBankRecordDatabaseTests
swift test --filter AnnotationDatabaseTests
swift test --filter ReferenceSourcePreparerTests
swift test --filter NativeBundleBuilderProvenanceTests
swift test --filter MHCAmpliconReferenceBundleBuilderTests
swift test --filter ImportFastaGenBankAnnotationTests
swift test --filter ReferenceBundleViewportControllerTests
swift test --filter AnnotationTableDrawerVariantTests
~~~

Expected: zero failures.

- [ ] **Step 2: Import the supplied file**

~~~bash
IPD_TEST_OUTPUT="$(mktemp -d /tmp/lungfish-ipd-record-test.XXXXXX)"
.build/arm64-apple-macosx/debug/lungfish-cli import fasta /Users/dho/Downloads/IPD-MHC_NHKIR_classI_Mafa.gb --output-dir "$IPD_TEST_OUTPUT"
~~~

Expected: one bundle with 2,321 record rows, 27,689 non-source annotations, a linked metadata/genbank_records.sqlite, and final-path provenance.

- [ ] **Step 3: Inspect deterministic values**

Run SQLite queries for record count, field-definition count, and NHP00353 feature.allele. Expected: 2321, a nonzero complete field set, and Mafa-I*01:01:01. Verify provenance contains the final sidecar path, SHA-256, and size.

- [ ] **Step 4: Run the complete suite**

~~~bash
swift test
~~~

Expected: zero failures. If a known unrelated flaky test fails, rerun that exact test once and report both outputs.

- [ ] **Step 5: Build and verify the app**

~~~bash
scripts/build-app.sh --configuration debug --log-dir build/logs
codesign --verify --deep --strict --verbose=2 build/Debug/Lungfish.app
plutil -extract CFBundleIdentifier raw build/Debug/Lungfish.app/Contents/Info.plist
~~~

Expected: successful build, valid code signature, and com.lungfish.browser.debug.

- [ ] **Step 6: Commit fixture-only corrections if any**

~~~bash
git add Tests/LungfishWorkflowTests/ReferenceSourcePreparerTests.swift Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift
git commit -m "test: cover IPD-MHC record filtering"
~~~

Do not create an empty commit when no fixture correction was needed.

## Completion criteria

- The upper list contains 2,321 records, not 27,689 features.
- Every recovered header and feature-qualifier field is a sortable/filterable column.
- Global search covers every field; per-column filters support text and numeric values.
- Annotation detail aggregates all filtered records; graphical detail follows selection.
- Empty results clear both detail surfaces.
- Controls are fully below the title bar.
- FASTA-only and legacy bundles remain compatible.
- Standard and MHC builds carry final-path record-store provenance.
- Focused tests, full tests, app build, and strict signing have fresh evidence.
