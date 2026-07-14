import XCTest
import SQLite3
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit

@MainActor
final class ReferenceBundleViewportControllerTests: XCTestCase {
    func testGenBankRecordTableExposesAndFiltersDynamicFields() throws {
        let table = ReferenceBundleRecordTable(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let fields = [
            GenBankRecordDatabase.FieldDefinition(
                key: "feature.allele", displayTitle: "Allele", valueType: "text",
                sourceCategory: "feature", preferredOrder: 0
            ),
            GenBankRecordDatabase.FieldDefinition(
                key: "record.ORGANISM", displayTitle: "Organism", valueType: "text",
                sourceCategory: "record", preferredOrder: 1
            ),
            GenBankRecordDatabase.FieldDefinition(
                key: "record.LOCUS.LENGTH", displayTitle: "Locus Length", valueType: "number",
                sourceCategory: "record", preferredOrder: 2
            ),
            GenBankRecordDatabase.FieldDefinition(
                key: "feature.gene", displayTitle: "Gene", valueType: "text",
                sourceCategory: "feature", preferredOrder: 3
            ),
            GenBankRecordDatabase.FieldDefinition(
                key: "record.DEFINITION", displayTitle: "Definition", valueType: "text",
                sourceCategory: "record", preferredOrder: 4
            ),
            GenBankRecordDatabase.FieldDefinition(
                key: "record.ACCESSION", displayTitle: "Accession", valueType: "text",
                sourceCategory: "record", preferredOrder: 5
            ),
            GenBankRecordDatabase.FieldDefinition(
                key: "feature.product", displayTitle: "Product", valueType: "text",
                sourceCategory: "feature", preferredOrder: 6
            ),
            GenBankRecordDatabase.FieldDefinition(
                key: "feature.number", displayTitle: "Number", valueType: "number",
                sourceCategory: "feature", preferredOrder: 7
            ),
            GenBankRecordDatabase.FieldDefinition(
                key: "record.CUSTOM_HEADER", displayTitle: "Custom Header", valueType: "text",
                sourceCategory: "record", preferredOrder: 8
            ),
        ]
        let first = BundleBrowserSequenceSummary(
            name: "record-a", displayDescription: "first definition", length: 100,
            aliases: [], isPrimary: true, isMitochondrial: false, metrics: nil
        )
        let second = BundleBrowserSequenceSummary(
            name: "record-b", displayDescription: "second definition", length: 200,
            aliases: [], isPrimary: true, isMitochondrial: false, metrics: nil
        )
        table.configure(dynamicFields: fields, rows: [
            .init(summary: first, values: [
                "feature.allele": "Mafa-A1", "record.ORGANISM": "Macaca fascicularis",
                "record.LOCUS.LENGTH": "100", "feature.gene": "Gene-A",
                "record.DEFINITION": "first definition", "record.ACCESSION": "ACC-A",
                "feature.product": "Product A", "feature.number": "10",
                "record.CUSTOM_HEADER": "unexpected-header-value",
            ]),
            .init(summary: second, values: [
                "feature.allele": "Mafa-B2", "record.ORGANISM": "Macaca fascicularis",
                "record.LOCUS.LENGTH": "200", "feature.gene": "Gene-B",
                "record.DEFINITION": "second definition", "record.ACCESSION": "ACC-B",
                "feature.product": "Product B", "feature.number": "20",
                "record.CUSTOM_HEADER": "other-value",
            ]),
        ])

        XCTAssertEqual(table.tableView.tableColumns.map(\.identifier.rawValue), [
            "sequence", "length", "role", "genbank.feature.allele",
            "genbank.record.ORGANISM", "genbank.record.LOCUS.LENGTH",
            "genbank.feature.gene", "genbank.record.DEFINITION", "genbank.record.ACCESSION",
            "genbank.feature.product", "genbank.feature.number",
            "genbank.record.CUSTOM_HEADER",
        ])
        table.setFilterText("Mafa-B2")
        XCTAssertEqual(table.displayedRows.map(\.summary.name), ["record-b"])

        table.setFilterText("")
        table.setColumnFilter(
            ColumnFilter(columnId: "genbank.record.ORGANISM", op: .equal, value: "Macaca fascicularis"),
            for: "genbank.record.ORGANISM"
        )
        XCTAssertEqual(table.displayedRows.map(\.summary.name), ["record-a", "record-b"])

        table.clearAllColumnFilters()
        table.setColumnFilter(
            ColumnFilter(columnId: "genbank.record.LOCUS.LENGTH", op: .greaterOrEqual, value: "150"),
            for: "genbank.record.LOCUS.LENGTH"
        )
        XCTAssertEqual(table.displayedRows.map(\.summary.name), ["record-b"])
        XCTAssertEqual(table.columnTypeHints["genbank.record.LOCUS.LENGTH"], true)
        XCTAssertEqual(table.columnTypeHints["genbank.feature.number"], true)
        XCTAssertTrue(table.compareRows(
            table.unfilteredRows[0], table.unfilteredRows[1],
            by: "genbank.record.LOCUS.LENGTH", ascending: true
        ))

        table.clearAllColumnFilters()
        table.setFilterText("unexpected-header-value")
        XCTAssertEqual(table.displayedRows.map(\.summary.name), ["record-a"])
        table.setFilterText("")
        table.setColumnFilter(
            ColumnFilter(columnId: "genbank.record.CUSTOM_HEADER", op: .equal, value: "other-value"),
            for: "genbank.record.CUSTOM_HEADER"
        )
        XCTAssertEqual(table.displayedRows.map(\.summary.name), ["record-b"])

        let customColumn = try XCTUnwrap(table.tableView.tableColumns.first {
            $0.identifier.rawValue == "genbank.record.CUSTOM_HEADER"
        })
        XCTAssertEqual(customColumn.minWidth, 0)
        XCTAssertEqual(customColumn.maxWidth, .greatestFiniteMagnitude)
        let chooserItem = try XCTUnwrap(table.tableView.headerView?.menu?.items.first {
            ($0.representedObject as? String) == "genbank.record.CUSTOM_HEADER"
        })
        NSApp.sendAction(try XCTUnwrap(chooserItem.action), to: chooserItem.target, from: chooserItem)
        XCTAssertTrue(customColumn.isHidden)
        table.configure(dynamicFields: fields, rows: table.unfilteredRows)
        XCTAssertTrue(try XCTUnwrap(table.tableView.tableColumns.first {
            $0.identifier.rawValue == "genbank.record.CUSTOM_HEADER"
        }).isHidden)
    }

    func testGenBankRecordTableLegacyRowsUseOnlyFixedColumns() {
        let table = ReferenceBundleRecordTable(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let summary = BundleBrowserSequenceSummary(
            name: "chr1", displayDescription: nil, length: 100,
            aliases: [], isPrimary: true, isMitochondrial: false, metrics: nil
        )

        table.configure(dynamicFields: [], rows: [.init(summary: summary, values: [:])])

        XCTAssertEqual(table.tableView.tableColumns.map(\.identifier.rawValue), ["sequence", "length", "role"])
        XCTAssertEqual(table.displayedRows.map(\.summary.name), ["chr1"])
    }

    func testDirectBundleMergesGenBankRecordStoreAndFiltersDynamicValues() throws {
        let records = try [
            ReferenceViewportFixture.makeGenBankRecord(
                name: "record-a", length: 100, allele: "Mafa-A1", organism: "Macaca fascicularis"
            ),
            ReferenceViewportFixture.makeGenBankRecord(
                name: "record-b", length: 200, allele: "Mafa-B2", organism: "Macaca fascicularis"
            ),
        ]
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Annotated Reference",
            chromosomes: [.init(name: "record-a", length: 100), .init(name: "record-b", length: 200)],
            includeAlignment: false,
            includeVariant: false,
            recordStoreRecords: records
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

        XCTAssertTrue(vc.testRecordTableColumnIdentifiers.contains("genbank.feature.allele"))
        XCTAssertTrue(vc.testRecordTableColumnIdentifiers.contains("genbank.record.ORGANISM"))
        vc.testApplySequenceFilter("Mafa-B2")
        XCTAssertEqual(vc.testDisplayedSequenceNames, ["record-b"])
        XCTAssertEqual(vc.testSelectedSequenceName, "record-b")
    }

    func testCorruptDeclaredRecordStoreShowsWarningAndManifestRows() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Corrupt Metadata Reference",
            chromosomes: [.init(name: "chr1", length: 100), .init(name: "chr2", length: 200)],
            includeAlignment: false,
            includeVariant: false,
            corruptRecordStore: true
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

        XCTAssertEqual(vc.testDisplayedSequenceNames, ["chr1", "chr2"])
        XCTAssertEqual(vc.testRecordTableColumnIdentifiers, ["sequence", "length", "role"])
        XCTAssertTrue(vc.testSummaryText.contains("Warning:"), vc.testSummaryText)
        XCTAssertTrue(vc.testSummaryText.contains("showing manifest records"), vc.testSummaryText)
    }

    func testMismatchedRecordStoreShowsWarningAndManifestRows() throws {
        let records = try [
            ReferenceViewportFixture.makeGenBankRecord(
                name: "unknown-record", length: 100, allele: "Mafa-A1", organism: "Macaca fascicularis"
            )
        ]
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Mismatched Metadata Reference",
            chromosomes: [.init(name: "chr1", length: 100)],
            includeAlignment: false,
            includeVariant: false,
            recordStoreRecords: records
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

        XCTAssertEqual(vc.testDisplayedSequenceNames, ["chr1"])
        XCTAssertEqual(vc.testRecordTableColumnIdentifiers, ["sequence", "length", "role"])
        XCTAssertTrue(vc.testSummaryText.contains("does not match"), vc.testSummaryText)
    }

    func testLengthMismatchedRecordStoreShowsWarningAndManifestRows() throws {
        let records = try [
            ReferenceViewportFixture.makeGenBankRecord(
                name: "chr1", length: 99, allele: "Mafa-A1", organism: "Macaca fascicularis"
            )
        ]
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Length Mismatched Metadata Reference",
            chromosomes: [.init(name: "chr1", length: 100)],
            includeAlignment: false,
            includeVariant: false,
            recordStoreRecords: records
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

        XCTAssertEqual(vc.testDisplayedSequenceNames, ["chr1"])
        XCTAssertEqual(vc.testRecordTableColumnIdentifiers, ["sequence", "length", "role"])
        XCTAssertTrue(vc.testSummaryText.contains("does not match"), vc.testSummaryText)
    }

    func testDuplicateRecordStoreIdentityShowsWarningAndManifestRows() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Duplicate Metadata Reference",
            chromosomes: [.init(name: "chr1", length: 100)],
            includeAlignment: false,
            includeVariant: false,
            duplicateRecordStoreIdentity: "chr1"
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

        XCTAssertEqual(vc.testDisplayedSequenceNames, ["chr1"])
        XCTAssertEqual(vc.testRecordTableColumnIdentifiers, ["sequence", "length", "role"])
        XCTAssertTrue(vc.testSummaryText.contains("ambiguous record identities"), vc.testSummaryText)
    }

    func testDirectReferenceBundleShowsSequenceListAndLoadsFirstSequenceDetail() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200),
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

        XCTAssertEqual(vc.testDisplayedSequenceNames, ["chr1", "chr2"])
        XCTAssertEqual(vc.testSelectedSequenceName, "chr1")
        XCTAssertFalse(vc.testEmbeddedViewerShowsReferenceViewport)
        XCTAssertEqual(vc.testPresentationMode, .listDetail)
    }

    func testReloadViewerBundleForInspectorChangesPreservesSelectedSequence() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200),
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))
        vc.testSelectSequence(named: "chr2")

        XCTAssertEqual(vc.testSelectedSequenceName, "chr2")

        try vc.reloadViewerBundleForInspectorChanges()

        XCTAssertEqual(vc.testSelectedSequenceName, "chr2")
    }

    func testDirectReferenceBundleSequenceOperationContextUsesSelectedEmbeddedSequence() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200),
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))
        vc.testSelectSequence(named: "chr2")

        let context = try XCTUnwrap(vc.testCurrentSequenceAnnotationOperationContext)
        XCTAssertEqual(context.bundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(context.chromosome, "chr2")
        XCTAssertEqual(context.range, 0..<200)
        XCTAssertEqual(context.sequenceLength, 200)
    }

    func testFilteringSequenceRowsSelectsFirstVisibleSequenceAndClearsWhenEmpty() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200),
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

        vc.testApplySequenceFilter("chr2")

        XCTAssertEqual(vc.testDisplayedSequenceNames, ["chr2"])
        XCTAssertEqual(vc.testSelectedSequenceName, "chr2")

        vc.testApplySequenceFilter("missing")

        XCTAssertEqual(vc.testDisplayedSequenceNames, [])
        XCTAssertNil(vc.testSelectedSequenceName)
        XCTAssertEqual(vc.testDetailPlaceholderMessage, "No sequences are available for this reference bundle.")
    }

    func testRecordStoreFilteringPublishesDisplayedRecordScopeBeforeReconcilingSelection() throws {
        let records = try [
            ReferenceViewportFixture.makeGenBankRecord(name: "record-a", length: 100, allele: "A", organism: "Test"),
            ReferenceViewportFixture.makeGenBankRecord(name: "record-b", length: 100, allele: "B", organism: "Test"),
            ReferenceViewportFixture.makeGenBankRecord(name: "record-c", length: 100, allele: "C", organism: "Test"),
        ]
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Scoped Reference",
            chromosomes: [
                .init(name: "record-a", length: 100),
                .init(name: "record-b", length: 100),
                .init(name: "record-c", length: 100),
            ],
            includeAlignment: false,
            includeVariant: false,
            recordStoreRecords: records
        )
        let vc = ReferenceBundleViewportController()
        _ = vc.view
        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: try .load(from: bundleURL)))

        XCTAssertEqual(vc.testAnnotationRecordScope, ["record-a", "record-b", "record-c"])
        vc.testSelectSequence(named: "record-c")
        XCTAssertEqual(vc.testAnnotationRecordScope, ["record-a", "record-b", "record-c"])

        vc.testApplySequenceFilter("record-b")
        XCTAssertEqual(vc.testAnnotationRecordScope, ["record-b"])
        XCTAssertEqual(vc.testSelectedSequenceName, "record-b")

        vc.testApplySequenceFilter("missing")
        XCTAssertEqual(vc.testAnnotationRecordScope, [])
        XCTAssertNil(vc.testSelectedSequenceName)
    }

    func testLegacyReferenceUsesNilScopeUntilFilteringIsActive() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Legacy Reference",
            chromosomes: [.init(name: "chr1", length: 100), .init(name: "chr2", length: 100)],
            includeAlignment: false,
            includeVariant: false
        )
        let vc = ReferenceBundleViewportController()
        _ = vc.view
        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: try .load(from: bundleURL)))

        XCTAssertNil(vc.testAnnotationRecordScope)
        vc.testApplySequenceFilter("chr2")
        XCTAssertEqual(vc.testAnnotationRecordScope, ["chr2"])
        vc.testApplySequenceFilter("")
        XCTAssertNil(vc.testAnnotationRecordScope)
    }

    func testFocusModeUsesVisibleBackButtonAndRestoresListDetailSelection() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200),
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))
        vc.testSelectSequence(named: "chr2")

        vc.testEnterFocusedDetailMode()

        XCTAssertEqual(vc.testPresentationMode, .focusedDetail)
        XCTAssertEqual(vc.testBackButtonAccessibilityIdentifier, "reference-viewport-back-button")
        XCTAssertFalse(vc.testBackButtonIsHidden)
        XCTAssertEqual(vc.testSelectedSequenceName, "chr2")

        vc.testTapBackButton()

        XCTAssertEqual(vc.testPresentationMode, .listDetail)
        XCTAssertEqual(vc.testSelectedSequenceName, "chr2")
        XCTAssertFalse(vc.testListContainer.isHidden)
    }
}

private enum ReferenceViewportFixture {
    struct Chromosome {
        let name: String
        let length: Int
    }

    static func makeReferenceBundle(
        name: String,
        chromosomes: [Chromosome],
        includeAlignment: Bool,
        includeVariant: Bool,
        recordStoreRecords: [GenBankRecord]? = nil,
        corruptRecordStore: Bool = false,
        duplicateRecordStoreIdentity: String? = nil
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-viewport-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)

        let fasta = chromosomes.map { ">\($0.name)\n\(String(repeating: "A", count: $0.length))\n" }.joined()
        let fastaURL = genomeURL.appendingPathComponent("sequence.fa")
        try fasta.write(to: fastaURL, atomically: true, encoding: .utf8)

        var offset = Int64(0)
        let chromInfos = chromosomes.map { chrom in
            let info = ChromosomeInfo(
                name: chrom.name,
                length: Int64(chrom.length),
                offset: offset,
                lineBases: chrom.length,
                lineWidth: chrom.length + 1
            )
            offset += Int64(">\(chrom.name)\n".utf8.count + chrom.length + 1)
            return info
        }

        let indexURL = genomeURL.appendingPathComponent("sequence.fa.fai")
        let index = zip(chromosomes, chromInfos).map { chrom, info in
            "\(chrom.name)\t\(chrom.length)\t\(info.offset)\t\(chrom.length)\t\(chrom.length + 1)\n"
        }.joined()
        try index.write(to: indexURL, atomically: true, encoding: .utf8)

        var recordStore: ReferenceRecordStoreInfo?
        if let recordStoreRecords {
            let metadataURL = bundleURL.appendingPathComponent("metadata", isDirectory: true)
            try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
            try GenBankRecordDatabase.create(
                records: recordStoreRecords,
                at: metadataURL.appendingPathComponent("genbank_records.sqlite")
            )
            recordStore = ReferenceRecordStoreInfo(
                schemaVersion: GenBankRecordDatabase.schemaVersion,
                format: ReferenceRecordStoreInfo.supportedFormat,
                databasePath: "metadata/genbank_records.sqlite",
                recordCount: recordStoreRecords.count
            )
        } else if corruptRecordStore {
            let metadataURL = bundleURL.appendingPathComponent("metadata", isDirectory: true)
            try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
            try Data("not a sqlite database".utf8).write(
                to: metadataURL.appendingPathComponent("genbank_records.sqlite")
            )
            recordStore = ReferenceRecordStoreInfo(
                schemaVersion: GenBankRecordDatabase.schemaVersion,
                format: ReferenceRecordStoreInfo.supportedFormat,
                databasePath: "metadata/genbank_records.sqlite",
                recordCount: chromosomes.count
            )
        } else if let duplicateRecordStoreIdentity {
            let metadataURL = bundleURL.appendingPathComponent("metadata", isDirectory: true)
            try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
            try createDuplicateRecordDatabase(
                at: metadataURL.appendingPathComponent("genbank_records.sqlite"),
                identity: duplicateRecordStoreIdentity,
                length: chromosomes.first?.length ?? 0
            )
            recordStore = ReferenceRecordStoreInfo(
                schemaVersion: GenBankRecordDatabase.schemaVersion,
                format: ReferenceRecordStoreInfo.supportedFormat,
                databasePath: "metadata/genbank_records.sqlite",
                recordCount: 2
            )
        } else {
            recordStore = nil
        }

        let manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.tests.\(UUID().uuidString)",
            source: SourceInfo(organism: "Test organism", assembly: name),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(chromosomes.reduce(0) { $0 + $1.length }),
                chromosomes: chromInfos
            ),
            annotations: [],
            variants: [],
            tracks: [],
            alignments: [],
            browserSummary: BundleBrowserSummary(
                schemaVersion: 1,
                aggregate: .init(
                    annotationTrackCount: 0,
                    variantTrackCount: includeVariant ? 1 : 0,
                    alignmentTrackCount: includeAlignment ? 1 : 0,
                    totalMappedReads: includeAlignment ? 10 : nil
                ),
                sequences: chromosomes.map {
                    BundleBrowserSequenceSummary(
                        name: $0.name,
                        displayDescription: nil,
                        length: Int64($0.length),
                        aliases: [],
                        isPrimary: true,
                        isMitochondrial: false,
                        metrics: nil
                    )
                }
            ),
            recordStore: recordStore
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    static func makeGenBankRecord(
        name: String,
        length: Int,
        allele: String,
        organism: String
    ) throws -> GenBankRecord {
        GenBankRecord(
            sequence: try Sequence(name: name, alphabet: .dna, bases: String(repeating: "A", count: length)),
            annotations: [
                SequenceAnnotation(
                    type: .gene,
                    name: allele,
                    start: 0,
                    end: length,
                    qualifiers: ["allele": AnnotationQualifier(allele)]
                )
            ],
            locus: LocusInfo(name: name, length: length, moleculeType: .dna, topology: .linear),
            recordFields: [
                GenBankRecordField(key: "LOCUS.NAME", value: name, ordinal: 0),
                GenBankRecordField(key: "LOCUS.LENGTH", value: String(length), ordinal: 1),
                GenBankRecordField(key: "ORGANISM", value: organism, ordinal: 2),
            ]
        )
    }

    private static func createDuplicateRecordDatabase(
        at url: URL,
        identity: String,
        length: Int
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(database) }
        let escapedIdentity = identity.replacingOccurrences(of: "'", with: "''")
        let sql = """
            CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO metadata VALUES ('schema_version', '1');
            CREATE TABLE records (id INTEGER PRIMARY KEY, sequence_name TEXT NOT NULL, sequence_length INTEGER NOT NULL, source_ordinal INTEGER NOT NULL);
            INSERT INTO records VALUES (1, '\(escapedIdentity)', \(length), 0);
            INSERT INTO records VALUES (2, '\(escapedIdentity)', \(length), 1);
            CREATE TABLE field_definitions (key TEXT PRIMARY KEY, display_title TEXT NOT NULL, value_type TEXT NOT NULL, source_category TEXT NOT NULL, preferred_order INTEGER NOT NULL);
            CREATE TABLE field_values (record_id INTEGER NOT NULL, field_key TEXT NOT NULL, value_ordinal INTEGER NOT NULL, value TEXT NOT NULL, PRIMARY KEY (record_id, field_key, value_ordinal));
            CREATE INDEX idx_field_values_key_value ON field_values(field_key, value COLLATE NOCASE);
            CREATE INDEX idx_field_values_record_key ON field_values(record_id, field_key);
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
