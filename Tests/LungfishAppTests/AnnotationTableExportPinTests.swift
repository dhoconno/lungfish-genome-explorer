import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
@testable import LungfishOperations
@testable import LungfishWorkflow

/// Lane 12.39 M1 pins of B2, the annotation table export, at the base with no Sources edit (QA 1). Each tab the
/// drawer offers is captured with every piece of state its builder applies, then written as CSV, TSV, XLSX and
/// JSON. The record pins hold the facts the conversion moves (tool, kind, argv, workflow, inputs, `resolved`).
final class AnnotationTableExportPinTests: XCTestCase {
    private var root: URL!
    private var source: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationTableExportPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("variants.db")
        try Data("source database".utf8).write(to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Bytes, one test per tab

    func testAnnotationTabBytes() throws {
        let snapshot = annotationSnapshot()
        XCTAssertEqual(snapshot.rowIdentities, ["genes:1", "genes:2"])
        try assertDelimited(snapshot, csv: """
        Name,Type,Chromosome,Start (0-based),"End (0-based, exclusive)",Size (bp),Strand,Track,product,note
        orf1ab,gene,NC_045512.2,265,21555,21290,'+,Genes,ORF1ab polyprotein,'=SUM(A1)
        S,CDS,NC_045512.2,21562,25384,3822,'-,genes,"surface, glycoprotein",

        """, tsv: """
        Name\tType\tChromosome\tStart (0-based)\tEnd (0-based, exclusive)\tSize (bp)\tStrand\tTrack\tproduct\tnote
        orf1ab\tgene\tNC_045512.2\t265\t21555\t21290\t'+\tGenes\tORF1ab polyprotein\t'=SUM(A1)
        S\tCDS\tNC_045512.2\t21562\t25384\t3822\t'-\tgenes\tsurface, glycoprotein\t

        """)
        try assertWorkbookAndJSON(snapshot)
    }

    func testVariantTabBytes() throws {
        let snapshot = variantSnapshot()
        XCTAssertEqual(snapshot.rowIdentities, ["ivar:7", "ivar:8"])
        try assertDelimited(snapshot, csv: """
        ID,Chrom,Position (1-based),Ref,Alt,Quality,Filter,Samples,AF,DP,Consequence,Track
        rs1,NC_045512.2,29409,C,T,99.5,PASS,2,0.75,120,missense_variant,iVar
        ,NC_045512.2,100,A,"G,T",,,,"0.1,0.2",abc,,iVar

        """, tsv: """
        ID\tChrom\tPosition (1-based)\tRef\tAlt\tQuality\tFilter\tSamples\tAF\tDP\tConsequence\tTrack
        rs1\tNC_045512.2\t29409\tC\tT\t99.5\tPASS\t2\t0.75\t120\tmissense_variant\tiVar
        \tNC_045512.2\t100\tA\tG,T\t\t\t\t0.1,0.2\tabc\t\tiVar

        """)
        try assertWorkbookAndJSON(snapshot)
    }

    func testSampleTabBytes() throws {
        let snapshot = sampleSnapshot()
        XCTAssertEqual(snapshot.rowIdentities, ["S1|a.vcf", "S2|a.vcf"])
        try assertDelimited(snapshot, csv: """
        Visible,Sample,Display Name,Source,country
        true,S1,Sample One,a.vcf,USA
        false,S2,,a.vcf,

        """, tsv: """
        Visible\tSample\tDisplay Name\tSource\tcountry
        true\tS1\tSample One\ta.vcf\tUSA
        false\tS2\t\ta.vcf\t

        """)
        try assertWorkbookAndJSON(snapshot)
    }

    func testGenotypeTabBytes() throws {
        let snapshot = genotypeSnapshot()
        XCTAssertEqual(snapshot.rowIdentities, ["ivar:7:S1"])
        try assertDelimited(snapshot, csv: """
        Sample,Variant,Position (1-based),GT,Zygosity,AD,DP,AB,AF
        S1,rs1,29409,0/1,Het,"30,90",120,0.75,0.75

        """, tsv: """
        Sample\tVariant\tPosition (1-based)\tGT\tZygosity\tAD\tDP\tAB\tAF
        S1\trs1\t29409\t0/1\tHet\t30,90\t120\t0.75\t0.75

        """)
        try assertWorkbookAndJSON(snapshot)
    }

    // MARK: - The record, the retained selection and the alert words

    func testRecordAtTheBase() throws {
        let snapshot = variantSnapshot()
        let output = root.appendingPathComponent("variants-selected.csv")
        try AnnotationTableExportFrozenSideA.export(
            snapshot: snapshot, format: .csv, outputURL: output, shouldCancel: { false }
        )
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)
        ))
        let argv = [
            "Lungfish.app", "export-annotation-table", "--tab", "variants", "--scope", "selected",
            "--format", "csv", "--output", output.path, "--source", source.standardizedFileURL.path,
        ]
        XCTAssertEqual(envelope.toolName, "Lungfish.app")
        XCTAssertEqual(envelope.tool.kind, "gui")
        XCTAssertEqual(envelope.argv, argv)
        XCTAssertEqual(envelope.workflowName, "lungfish app annotation table export")
        let replay = try XCTUnwrap(envelope.durableReplayArgv)
        XCTAssertEqual(replay.count, 3)
        XCTAssertEqual(replay.first, "/bin/cp")
        XCTAssertTrue(replay[1].contains("/.lungfish-export-inputs/"))
        XCTAssertTrue(replay[1].hasSuffix("/selected.csv"))
        XCTAssertEqual(replay.last, output.path)

        let inputs = envelope.files.filter { $0.role == .input }.map(\.path)
        XCTAssertEqual(inputs.count, 3, "the source, the retained payload copy and selection.json: \(inputs)")
        XCTAssertTrue(inputs.contains { $0.hasSuffix("/variants.db") })
        XCTAssertTrue(inputs.contains { $0.hasSuffix("/selected.csv") })
        let selectionPath = try XCTUnwrap(inputs.first { $0.hasSuffix("/selection.json") })
        XCTAssertTrue(envelope.files.filter { $0.role == .input }.allSatisfy { $0.checksumSHA256 != nil })

        XCTAssertEqual(Set(envelope.options.resolvedDefaults.keys), [
            "rowCount", "columnCount", "columnIDs", "columnTitles", "rowIdentities", "query",
            "coordinateConventions", "xlsxArchiveTool", "xlsxArchiveArgv", "xlsxArchiveToolVersion",
            "replayScope", "replaysUpstreamAnalysis",
        ])
        XCTAssertEqual(envelope.options.resolvedDefaults["rowCount"]?.integerValue, 2)
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["outputFormat", "outputPath", "scope", "sourcePaths", "tab"])
        XCTAssertEqual(envelope.options.defaults.keys.sorted(), [
            "encoding", "formulaTextPolicy", "headerRow", "missingValuePolicy", "numericPolicy",
        ])

        // The base's selection.json holds the whole snapshot, rendered table included (the trace of M1 (3)).
        let decoded = try JSONDecoder().decode(
            AnnotationTableExportSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: selectionPath))
        )
        XCTAssertEqual(decoded, snapshot)
    }

    func testFailureAlertWords() {
        XCTAssertEqual(
            AnnotationTableExportServiceError.noScientificSources.localizedDescription,
            "Cannot export this scientific table because no durable source files are available for provenance."
        )
        XCTAssertEqual(
            AnnotationTableExportServiceError.missingScientificSource(URL(fileURLWithPath: "/tmp/gone.db"))
                .localizedDescription,
            "Cannot export this scientific table because a required provenance source is missing: /tmp/gone.db"
        )
        let empty = AnnotationTableExportSnapshot(
            table: .init(name: "Variants", columns: [], rows: []), tab: "variants", scope: .selected,
            rowIdentities: [], sourceURLs: [], queryDescription: [:], coordinateConventions: [:]
        )
        XCTAssertThrowsError(try AnnotationTableExportFrozenSideA.export(
            snapshot: empty, format: .csv, outputURL: root.appendingPathComponent("none.csv"), shouldCancel: { false }
        )) { error in
            XCTAssertEqual(error.localizedDescription, AnnotationTableExportServiceError.noScientificSources.localizedDescription)
        }
    }

    /// The trace of M1 (3). The identities the base records rebuild the variant rows from the database alone for
    /// every column read from the database. INFO projected from a FORMAT overlay and the derived columns are not in
    /// the database, so the rows rebuild only with the overlay and the resolver, which sit in LungfishOperations.
    func testVariantIdentitiesRebuildTheRowsFromTheDatabase() throws {
        let vcfURL = root.appendingPathComponent("rebuild.vcf")
        let databaseURL = root.appendingPathComponent("rebuild.db")
        try """
        ##fileformat=VCFv4.2
        ##INFO=<ID=AF,Number=A,Type=Float,Description="Allele frequency">
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Depth">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t101\trs1\tA\tG\t30\tPASS\tAF=0.5;DP=40
        chr1\t205\t.\tC\tT,G\t.\tq10\tAF=0.1,0.2;DP=7
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: databaseURL)
        let database = try VariantDatabase(url: databaseURL)
        let context = AnnotationVariantQueryContext(
            databases: [("track", database)], trackNames: ["track": "iVar"],
            trackChromosomes: ["track": ["chr1"]], annotationDatabases: [],
            infoKeys: ["AF", "DP"], variantAliasMap: [:]
        )
        let shown = try AnnotationTableVariantQueryRequest(
            context: context, query: .init(), types: [], infoFilters: [],
            selectedSamples: [], activeTokens: [], region: nil, geneList: nil,
            filterBookmarkedOnly: false, filterModerateOrHigher: false,
            withinSampleAFRange: nil, bookmarkedKeys: [], hiddenTrackIDs: [],
            variantColumnFilters: [], callerSettingsByTrack: [:],
            resolverSnapshot: .empty, numericColumnKeys: ["position"],
            sortKey: "position", sortAscending: false
        ).run(shouldCancel: { false })
        let columns = Self.variantColumns.filter { $0.id != "ConsequenceColumn" }
        let pinned = AnnotationTableExportSnapshot.captureVariants(
            shown, columns: columns, scope: .allMatching, numericInfoColumnIDs: ["info_AF"],
            integerInfoColumnIDs: ["info_DP"], sourceURLs: [databaseURL], queryDescription: [:]
        )

        // Rebuild from the identities alone: read every record, keep those the identities name, in their order.
        let records = try database.queryForTableExport(
            nameFilter: "", types: [], infoFilters: [], sampleNames: [], smartFilter: nil,
            activeTokens: [], limit: Int.max
        )
        let info = try database.batchInfoValuesForExport(variantIds: records.compactMap(\.id))
        let byIdentity = Dictionary(uniqueKeysWithValues: records.compactMap { record -> (String, AnnotationSearchIndex.SearchResult)? in
            guard let id = record.id else { return nil }
            return ("track:\(id)", record.toSearchResult(trackId: "track", infoDict: info[id] ?? [:], sourceFile: "iVar"))
        })
        let rebuilt = AnnotationTableExportSnapshot.captureVariants(
            pinned.rowIdentities.compactMap { byIdentity[$0] }, columns: columns, scope: .allMatching,
            numericInfoColumnIDs: ["info_AF"], integerInfoColumnIDs: ["info_DP"],
            sourceURLs: [databaseURL], queryDescription: [:]
        )
        XCTAssertGreaterThanOrEqual(pinned.rowIdentities.count, 2)
        XCTAssertEqual(rebuilt.table, pinned.table)
    }
}

// MARK: - Fixtures and assertions

extension AnnotationTableExportPinTests {
    static let variantColumns: [ScientificTableColumn] = [
        .init(id: "VariantIdColumn", title: "ID"), .init(id: "VariantChromColumn", title: "Chrom"),
        .init(id: "PositionColumn", title: "Position"), .init(id: "RefColumn", title: "Ref"),
        .init(id: "AltColumn", title: "Alt"), .init(id: "QualityColumn", title: "Quality"),
        .init(id: "FilterColumn", title: "Filter"), .init(id: "SamplesColumn", title: "Samples"),
        .init(id: "info_AF", title: "AF"), .init(id: "info_DP", title: "DP"),
        .init(id: "ConsequenceColumn", title: "Consequence"), .init(id: "TrackNameColumn", title: "Track"),
    ]

    func annotationSnapshot() -> AnnotationTableExportSnapshot {
        let rows = [
            AnnotationSearchIndex.SearchResult(
                name: "orf1ab", chromosome: "NC_045512.2", start: 265, end: 21_555, trackId: "genes",
                trackName: "Genes", type: "gene", strand: "+",
                attributes: ["product": "ORF1ab polyprotein", "note": "=SUM(A1)"], annotationRowId: 1
            ),
            AnnotationSearchIndex.SearchResult(
                name: "S", chromosome: "NC_045512.2", start: 21_562, end: 25_384, trackId: "genes",
                type: "CDS", strand: "-", attributes: ["product": "surface, glycoprotein"], annotationRowId: 2
            ),
        ]
        let columns: [ScientificTableColumn] = [
            .init(id: "NameColumn", title: "Name"), .init(id: "TypeColumn", title: "Type"),
            .init(id: "ChromosomeColumn", title: "Chromosome"), .init(id: "StartColumn", title: "Start"),
            .init(id: "EndColumn", title: "End"), .init(id: "SizeColumn", title: "Size"),
            .init(id: "StrandColumn", title: "Strand"), .init(id: "TrackNameColumn", title: "Track"),
            .init(id: "attr_product", title: "product"), .init(id: "attr_note", title: "note"),
        ]
        return .captureAnnotations(
            rows, columns: columns, scope: .allMatching, sourceURLs: [source],
            queryDescription: ["text": "", "sort": "start:ascending"]
        )
    }

    func variantSnapshot() -> AnnotationTableExportSnapshot {
        let rows = [
            AnnotationSearchIndex.SearchResult(
                name: "rs1", chromosome: "NC_045512.2", start: 29_408, end: 29_409, trackId: "ivar",
                trackName: "iVar", type: "SNP", ref: "C", alt: "T", quality: 99.5, filter: "PASS",
                sampleCount: 2, variantRowId: 7, infoDict: ["AF": "0.75", "DP": "120"], sourceFile: "sample.vcf"
            ),
            AnnotationSearchIndex.SearchResult(
                name: ".", chromosome: "NC_045512.2", start: 99, end: 100, trackId: "ivar",
                trackName: "iVar", type: "SNP", ref: "A", alt: "G,T", quality: -1, filter: ".",
                variantRowId: 8, infoDict: ["AF": "0.1,0.2", "DP": "abc"]
            ),
        ]
        return .captureVariants(
            rows, columns: Self.variantColumns, scope: .selected, numericInfoColumnIDs: ["info_AF"],
            integerInfoColumnIDs: ["info_DP"], sourceURLs: [source],
            queryDescription: ["text": "PASS", "sort": "position:ascending"],
            resolvedText: ["ivar:7": ["ConsequenceColumn": "missense_variant"]]
        )
    }

    func sampleSnapshot() -> AnnotationTableExportSnapshot {
        let rows = [
            AnnotationTableDrawerView.SampleDisplayRow(
                rowKey: "S1|a.vcf", name: "S1", sourceFile: "a.vcf", isVisible: true,
                metadata: ["country": "USA"], displayName: "Sample One"
            ),
            AnnotationTableDrawerView.SampleDisplayRow(
                rowKey: "S2|a.vcf", name: "S2", sourceFile: "a.vcf", isVisible: false, metadata: [:], displayName: nil
            ),
        ]
        let columns: [ScientificTableColumn] = [
            .init(id: "SampleVisibleColumn", title: "Visible"), .init(id: "SampleNameColumn", title: "Sample"),
            .init(id: "SampleDisplayNameColumn", title: "Display Name"), .init(id: "SampleSourceColumn", title: "Source"),
            .init(id: "meta_country", title: "country"),
        ]
        return .captureSamples(rows, columns: columns, scope: .allMatching, sourceURLs: [source], queryDescription: [:])
    }

    func genotypeSnapshot() -> AnnotationTableExportSnapshot {
        let row = AnnotationTableDrawerView.GenotypeDisplayRow(
            sampleName: "S1", variantRowId: 7, variantID: "rs1", chromosome: "NC_045512.2", position: 29_408,
            ref: "C", alt: "T", genotype: "0/1", zygosity: "Het", alleleDepths: "30,90", depth: 120,
            genotypeQuality: 99, alleleBalance: 0.75, infoDict: ["AF": "0.75"], trackId: "ivar", trackName: "iVar"
        )
        let columns: [ScientificTableColumn] = [
            .init(id: "GTSampleColumn", title: "Sample"), .init(id: "GTVariantColumn", title: "Variant"),
            .init(id: "GTPositionColumn", title: "Position"), .init(id: "GTGenotypeColumn", title: "GT"),
            .init(id: "GTZygosityColumn", title: "Zygosity"), .init(id: "GTADColumn", title: "AD"),
            .init(id: "GTDPColumn", title: "DP"), .init(id: "GTABColumn", title: "AB"),
            .init(id: "gtinfo_AF", title: "AF"),
        ]
        return .captureGenotypes(
            [row], columns: columns, scope: .allMatching, numericInfoColumnIDs: ["gtinfo_AF"],
            sourceURLs: [source], queryDescription: [:]
        )
    }

    /// Writes the snapshot through the base service and returns the payload.
    func export(_ snapshot: AnnotationTableExportSnapshot, format: ScientificTableFormat) throws -> Data {
        let output = root.appendingPathComponent("\(snapshot.tab)-\(UUID().uuidString).\(format.rawValue)")
        try AnnotationTableExportFrozenSideA.export(snapshot: snapshot, format: format, outputURL: output, shouldCancel: { false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path))
        return try Data(contentsOf: output)
    }

    func assertDelimited(
        _ snapshot: AnnotationTableExportSnapshot, csv: String, tsv: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(String(decoding: try export(snapshot, format: .csv), as: UTF8.self), csv, file: file, line: line)
        XCTAssertEqual(String(decoding: try export(snapshot, format: .tsv), as: UTF8.self), tsv, file: file, line: line)
    }

    /// XLSX holds a zip archive that is byte-stable since lane 13.50, so the pin reads the bytes. JSON is the table
    /// encoded with sorted keys.
    func assertWorkbookAndJSON(
        _ snapshot: AnnotationTableExportSnapshot, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let workbook = try export(snapshot, format: .xlsx)
        XCTAssertEqual(Array(workbook.prefix(2)), Array("PK".utf8), file: file, line: line)
        let reference = root.appendingPathComponent("reference-\(UUID().uuidString).xlsx")
        try ScientificTableWriter.write(snapshot.table, format: .xlsx, to: reference)
        XCTAssertEqual(workbook, try Data(contentsOf: reference), file: file, line: line)

        let json = try export(snapshot, format: .json)
        let decoded = try JSONDecoder().decode(ScientificTableData.self, from: json)
        XCTAssertEqual(decoded, snapshot.table, file: file, line: line)
        XCTAssertEqual(json.last, 0x0A, file: file, line: line)
    }
}
