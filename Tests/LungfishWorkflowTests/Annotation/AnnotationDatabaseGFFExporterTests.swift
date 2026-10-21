import Testing
import Foundation
import LungfishIO
@testable import LungfishWorkflow

@Suite("AnnotationDatabaseGFFExporter")
struct AnnotationDatabaseGFFExporterTests {
    /// Bootstraps a writable v4 annotation database at the given URL by
    /// creating it from an empty BED file (the only public way to create a
    /// fresh database since `AnnotationDatabase.init(url:readWrite:)` only
    /// opens existing databases that already have the v4 schema).
    private func makeEmptyDatabase(at url: URL) throws -> AnnotationDatabase {
        let bedURL = url.deletingPathExtension().appendingPathExtension("bed")
        try "".write(to: bedURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bedURL) }
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: url)
        return try AnnotationDatabase(url: url, readWrite: true)
    }

    @Test("writes one GFF3 line per CDS feature in the database")
    func writesCDS() throws {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try makeEmptyDatabase(at: dbURL)
        try db.insertAnnotation(
            name: "S",
            type: "CDS",
            chromosome: "MN908947.3",
            start: 21562,
            end: 25384,
            strand: "+",
            attributes: nil,
            geneName: nil
        )
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try AnnotationDatabaseGFFExporter.export(database: db, to: outURL)
        let contents = try String(contentsOf: outURL, encoding: .utf8)
        #expect(contents.contains("##gff-version 3"))
        #expect(contents.contains("MN908947.3\t.\tCDS\t21563\t25384\t.\t+\t0\t"))
    }

    @Test("exports GFF3-imported CDS coordinates as one-based and preserves CDS phase")
    func exportsGFF3ImportedCDSCoordinatesAndPhase() async throws {
        let gffURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: gffURL) }
        try """
        ##gff-version 3
        MN908947.3\tGenbank\tgene\t28274\t29533\t.\t+\t.\tID=gene-N;Name=N;gene=N
        MN908947.3\tGenbank\tCDS\t28274\t29533\t.\t+\t0\tID=cds-N;Parent=gene-N;Name=N;gene=N
        """.write(to: gffURL, atomically: true, encoding: .utf8)

        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        _ = try await AnnotationDatabase.createFromGFF3(
            gffURL: gffURL,
            outputURL: dbURL,
            chromosomeSizes: [("MN908947.3", 29_903)]
        )
        let db = try AnnotationDatabase(url: dbURL)

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try AnnotationDatabaseGFFExporter.export(database: db, to: outURL)

        let contents = try String(contentsOf: outURL, encoding: .utf8)
        #expect(contents.contains("MN908947.3\t.\tCDS\t28274\t29533\t.\t+\t0\t"))
    }

    @Test("multi-segment ORF1ab CDS (NCBI RefSeq shared ID) exports two CDS lines with correct per-segment phase")
    func exportsMultiSegmentORF1abCDSAsTwoLines() async throws {
        // MT192765.1's ORF1ab: a -1 ribosomal frameshift CDS built from two
        // GFF3 CDS lines sharing one `ID`, mirroring NCBI RefSeq annotation
        // style (e.g. `ID=cds-YP_009724389.1` on both segments). The old
        // exporter collapsed these into one span (259..21548), which put
        // every downstream SNP in the wrong reading frame. The fix must
        // expand the record's BED12 blocks back into per-segment GFF3 lines.
        let gffURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: gffURL) }
        try """
        ##gff-version 3
        MT192765.1\tGenbank\tCDS\t259\t13461\t.\t+\t0\tID=cds-orf1ab;gene=orf1ab
        MT192765.1\tGenbank\tCDS\t13461\t21548\t.\t+\t0\tID=cds-orf1ab;gene=orf1ab
        """.write(to: gffURL, atomically: true, encoding: .utf8)

        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        _ = try await AnnotationDatabase.createFromGFF3(
            gffURL: gffURL,
            outputURL: dbURL,
            chromosomeSizes: [("MT192765.1", 29_903)]
        )
        let db = try AnnotationDatabase(url: dbURL)

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try AnnotationDatabaseGFFExporter.export(database: db, to: outURL)

        let contents = try String(contentsOf: outURL, encoding: .utf8)
        let cdsLines = contents.split(separator: "\n").filter { $0.contains("\tCDS\t") }

        // Two segments, not one collapsed 259..21548 span.
        #expect(cdsLines.count == 2)
        #expect(!contents.contains("259\t21548"))
        #expect(contents.contains("MT192765.1\t.\tCDS\t259\t13461\t.\t+\t0\t"))
        #expect(contents.contains("MT192765.1\t.\tCDS\t13461\t21548\t.\t+\t0\t"))

        // Both lines share the same ID so iVar treats them as one CDS.
        for line in cdsLines {
            #expect(line.contains("ID=cds-orf1ab"))
        }
    }

    @Test("minus-strand spliced CDS gets phase from transcription-order cumulative length")
    func exportsMinusStrandSplicedCDSWithCorrectPhase() async throws {
        // Two exons on the minus strand. Transcription order is descending
        // genomic order, so the genomically-later segment (100..140, length
        // 40) is transcribed first (phase 0), and the genomically-earlier
        // segment (0..10, length 10) is transcribed second. 40 % 3 == 1, so
        // its phase is (3-1)%3 == 2.
        let gffURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: gffURL) }
        try """
        ##gff-version 3
        chr1\ttest\tCDS\t1\t10\t.\t-\t.\tID=cds-minus;gene=minus
        chr1\ttest\tCDS\t101\t140\t.\t-\t.\tID=cds-minus;gene=minus
        """.write(to: gffURL, atomically: true, encoding: .utf8)

        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        _ = try await AnnotationDatabase.createFromGFF3(
            gffURL: gffURL,
            outputURL: dbURL,
            chromosomeSizes: [("chr1", 1_000)]
        )
        let db = try AnnotationDatabase(url: dbURL)

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try AnnotationDatabaseGFFExporter.export(database: db, to: outURL)

        let contents = try String(contentsOf: outURL, encoding: .utf8)
        #expect(contents.contains("chr1\t.\tCDS\t1\t10\t.\t-\t2\t"))
        #expect(contents.contains("chr1\t.\tCDS\t101\t140\t.\t-\t0\t"))
    }

    @Test("writes empty GFF when database has no records")
    func writesEmpty() throws {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try makeEmptyDatabase(at: dbURL)
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try AnnotationDatabaseGFFExporter.export(database: db, to: outURL)
        let contents = try String(contentsOf: outURL, encoding: .utf8)
        #expect(contents.hasPrefix("##gff-version 3"))
    }

    // MARK: - Parent-first order

    /// One feature line of an exported GFF3, with the `ID` and `Parent` it carries.
    private struct ExportedFeature {
        let id: String?
        let parent: String?
    }

    /// The feature lines of a GFF3 document in file order, comment and directive lines skipped.
    private func featureLines(in gff3: String) -> [ExportedFeature] {
        gff3.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let attributes = AnnotationDatabase.parseAttributes(columns[8])
            return ExportedFeature(id: attributes["ID"], parent: attributes["Parent"])
        }
    }

    /// Imports `gff3` by `createFromGFF3`, as a downloaded reference is, then exports the database and returns the
    /// text the exporter wrote.
    private func exportedGFF3(
        ofGFF3 gff3: String,
        chromosomeSizes: [(String, Int64)]
    ) async throws -> String {
        let directory = FileManager.default.temporaryDirectory
        let gffURL = directory.appendingPathComponent("\(UUID().uuidString).gff3")
        let dbURL = directory.appendingPathComponent("\(UUID().uuidString).db")
        let outURL = directory.appendingPathComponent("\(UUID().uuidString).gff3")
        defer {
            for url in [gffURL, dbURL, outURL] { try? FileManager.default.removeItem(at: url) }
        }
        try gff3.write(to: gffURL, atomically: true, encoding: .utf8)
        _ = try await AnnotationDatabase.createFromGFF3(
            gffURL: gffURL,
            outputURL: dbURL,
            chromosomeSizes: chromosomeSizes
        )
        try AnnotationDatabaseGFFExporter.export(database: try AnnotationDatabase(url: dbURL), to: outURL)
        return try String(contentsOf: outURL, encoding: .utf8)
    }

    /// The feature lines of `exportedGFF3`, in file order.
    private func exportedFeatures(
        ofGFF3 gff3: String,
        chromosomeSizes: [(String, Int64)]
    ) async throws -> [ExportedFeature] {
        return featureLines(in: try await exportedGFF3(ofGFF3: gff3, chromosomeSizes: chromosomeSizes))
    }

    /// The `ID`s of `features` in file order. Records a failure for every `Parent` that names an `ID`
    /// no earlier line defines, which is what SnpEff 5.0e needs to build the gene before its CDS.
    private func identifiers(of features: [ExportedFeature]) -> [String] {
        var defined = Set<String>()
        for feature in features {
            if let parent = feature.parent {
                #expect(
                    defined.contains(parent),
                    "\(feature.id ?? "a line") names Parent \(parent) before a line defines it"
                )
            }
            if let id = feature.id { defined.insert(id) }
        }
        return features.compactMap(\.id)
    }

    @Test("writes every Parent after the line that defines it, genes before their CDS")
    func writesParentsBeforeChildren() async throws {
        // NCBI's lines for the S and N genes of MN908947.3 with Name and Parent kept. In name order the
        // S CDS (Name=QHD43416.1) came before gene S, and SnpEff 5.0e then named the spike gene after its CDS.
        let features = try await exportedFeatures(
            ofGFF3: """
            ##gff-version 3
            MN908947.3\tGenbank\tgene\t21563\t25384\t.\t+\t.\tID=gene-S;Name=S;gbkey=Gene;gene=S;gene_biotype=protein_coding
            MN908947.3\tGenbank\tCDS\t21563\t25384\t.\t+\t0\tID=cds-QHD43416.1;Parent=gene-S;Dbxref=NCBI_GP:QHD43416.1;Name=QHD43416.1;Note=structural protein;gbkey=CDS;gene=S;product=surface glycoprotein;protein_id=QHD43416.1
            MN908947.3\tGenbank\tgene\t28274\t29533\t.\t+\t.\tID=gene-N;Name=N;gbkey=Gene;gene=N;gene_biotype=protein_coding
            MN908947.3\tGenbank\tCDS\t28274\t29533\t.\t+\t0\tID=cds-QHD43423.2;Parent=gene-N;Dbxref=NCBI_GP:QHD43423.2;Name=QHD43423.2;Note=structural protein;gbkey=CDS;gene=N;product=nucleocapsid phosphoprotein;protein_id=QHD43423.2
            """,
            chromosomeSizes: [("MN908947.3", 29_903)]
        )
        #expect(identifiers(of: features) == ["gene-S", "cds-QHD43416.1", "gene-N", "cds-QHD43423.2"])
    }

    @Test("exports the NCBI MN908947.3 annotation in NCBI's order")
    func exportsMN908947InNCBIOrder() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Annotation/
            .deletingLastPathComponent()  // LungfishWorkflowTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Fixtures/sarscov2-srr36291587/MN908947.3.gff3")
        let ncbi = try String(contentsOf: fixture, encoding: .utf8)
        let ncbiIDs = featureLines(in: ncbi).compactMap(\.id)
        #expect(!ncbiIDs.isEmpty)

        let features = try await exportedFeatures(ofGFF3: ncbi, chromosomeSizes: [("MN908947.3", 29_903)])
        #expect(identifiers(of: features) == ncbiIDs)
    }

    @Test("exports the NCBI MN908947.3 annotation with NCBI's columns and attributes")
    func exportsMN908947WithNCBIsColumnsAndAttributes() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Annotation/
            .deletingLastPathComponent()  // LungfishWorkflowTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Fixtures/sarscov2-srr36291587/MN908947.3.gff3")
        let ncbi = try String(contentsOf: fixture, encoding: .utf8)
        let exported = try await exportedGFF3(ofGFF3: ncbi, chromosomeSizes: [("MN908947.3", 29_903)])

        func rows(of gff3: String) -> [[String]] {
            gff3.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
                line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            }
        }
        let expectedRows = rows(of: ncbi)
        let actualRows = rows(of: exported)
        #expect(expectedRows.count == 24)
        #expect(actualRows.count == 24)
        try #require((expectedRows + actualRows).allSatisfy { $0.count == 9 }, "every feature line has nine columns")

        for (index, (a, e)) in zip(actualRows, expectedRows).enumerated() {
            // Columns 1 and 3 to 8 (sequence, type, start, end, score, strand, phase) are NCBI's. Column 2, the
            // source, is `.` in the export and `Genbank` in the fixture, and neither tool reads it.
            #expect([a[0]] + Array(a[2...7]) == [e[0]] + Array(e[2...7]), "line \(index + 1)")

            // Column 9 is NCBI's attributes and nothing else. The import's internal `lungfish_gff_phase` key stays in
            // the database and never reaches the file (lane 13.20 M1).
            let attributes = AnnotationDatabase.parseAttributes(a[8])
            #expect(attributes["lungfish_gff_phase"] == nil, "line \(index + 1)")
            #expect(!a[8].contains("lungfish_gff_phase"), "line \(index + 1)")
            #expect(attributes == AnnotationDatabase.parseAttributes(e[8]), "line \(index + 1)")
        }

        // The two-block orf1ab CDS is two lines with one ID, joined at base 13468 of the -1 frameshift, both in phase 0.
        let orf1ab = actualRows
            .filter { AnnotationDatabase.parseAttributes($0[8])["ID"] == "cds-QHD43415.1" }
            .map { [$0[3], $0[4], $0[7]] }
        #expect(orf1ab == [["266", "13468", "0"], ["13468", "21555", "0"]])
    }

    @Test("orders by chromosome, start, longer span first, then Parent depth, whatever the names sort to")
    func ordersByChromosomeStartEndAndParentDepth() async throws {
        // Every key runs against the name order. chr2 is listed first, gene-first has the later name, gene-long
        // the later name of the two genes that start at 100, and the five features that share 500..600 are
        // listed child first, with a second gene, gene-e, between the CDS and the exon. gene-e and gene-d tie at
        // depth 0 and cds-d and exon-d tie at depth 2, so the order the file listed them in decides. Without the
        // depth key the last pass would write gene-d, mrna-d and cds-d, then gene-e, then exon-d.
        let features = try await exportedFeatures(
            ofGFF3: """
            ##gff-version 3
            chr2\tt\tgene\t5\t50\t.\t+\t.\tID=gene-on-chr2;Name=Aon-chr2
            chr1\tt\tCDS\t500\t600\t.\t+\t0\tID=cds-d;Parent=mrna-d;Name=Acds
            chr1\tt\tgene\t500\t600\t.\t+\t.\tID=gene-e;Name=Dgene
            chr1\tt\texon\t500\t600\t.\t+\t.\tID=exon-d;Parent=mrna-d;Name=Aexon
            chr1\tt\tmRNA\t500\t600\t.\t+\t.\tID=mrna-d;Parent=gene-d;Name=Bmrna
            chr1\tt\tgene\t500\t600\t.\t+\t.\tID=gene-d;Name=Cgene
            chr1\tt\tgene\t100\t200\t.\t+\t.\tID=gene-short;Name=Ashort
            chr1\tt\tgene\t100\t300\t.\t+\t.\tID=gene-long;Name=Clong
            chr1\tt\tgene\t30\t40\t.\t+\t.\tID=gene-second;Name=Asecond
            chr1\tt\tgene\t10\t20\t.\t+\t.\tID=gene-first;Name=Cfirst
            """,
            chromosomeSizes: [("chr1", 1_000), ("chr2", 1_000)]
        )
        #expect(identifiers(of: features) == [
            "gene-first", "gene-second", "gene-long", "gene-short",
            "gene-e", "gene-d", "mrna-d", "cds-d", "exon-d",
            "gene-on-chr2",
        ])
    }

    @Test("keeps the lines of a multi-block CDS together")
    func keepsTheLinesOfOneRecordTogether() async throws {
        // gene-in-intron starts inside the gap between the two CDS blocks, so ordering lines instead of
        // records would put it between the two cds-split lines.
        let features = try await exportedFeatures(
            ofGFF3: """
            ##gff-version 3
            chr1\tt\tgene\t15\t18\t.\t+\t.\tID=gene-in-intron;Name=Aintron
            chr1\tt\tCDS\t21\t30\t.\t+\t0\tID=cds-split;Parent=gene-split;Name=Bsplit
            chr1\tt\tCDS\t1\t10\t.\t+\t0\tID=cds-split;Parent=gene-split;Name=Bsplit
            chr1\tt\tgene\t1\t30\t.\t+\t.\tID=gene-split;Name=Csplit
            """,
            chromosomeSizes: [("chr1", 1_000)]
        )
        #expect(identifiers(of: features) == ["gene-split", "cds-split", "cds-split", "gene-in-intron"])
    }

    @Test("a Parent that no record defines leaves the record at depth 0")
    func parentThatNoRecordDefinesIsDepthZero() async throws {
        // Both records span 10..20. gene-orphan names a Parent the file never defines, so it ties with
        // gene-root at depth 0 and the file order decides, where a depth of 1 would put gene-root first.
        let features = try await exportedFeatures(
            ofGFF3: """
            ##gff-version 3
            chr1\tt\tgene\t10\t20\t.\t+\t.\tID=gene-orphan;Parent=gene-missing;Name=Zorphan
            chr1\tt\tgene\t10\t20\t.\t+\t.\tID=gene-root;Name=Aroot
            """,
            chromosomeSizes: [("chr1", 1_000)]
        )
        #expect(features.compactMap(\.id) == ["gene-orphan", "gene-root"])
    }

    @Test("moves a Parent ahead of a child that starts before it")
    func movesAParentAheadOfAChildThatStartsBeforeIt() async throws {
        // The exon lies outside its mRNA, so start order alone writes the exon first.
        let features = try await exportedFeatures(
            ofGFF3: """
            ##gff-version 3
            chr1\tt\texon\t1\t50\t.\t+\t.\tID=exon-early;Parent=mrna-late;Name=Aexon
            chr1\tt\tmRNA\t10\t100\t.\t+\t.\tID=mrna-late;Name=Bmrna
            """,
            chromosomeSizes: [("chr1", 1_000)]
        )
        #expect(identifiers(of: features) == ["mrna-late", "exon-early"])
    }

    @Test("a Parent cycle or a record that names itself still exports every line")
    func parentCyclesStillExportEveryLine() async throws {
        let features = try await exportedFeatures(
            ofGFF3: """
            ##gff-version 3
            chr1\tt\tgene\t1\t10\t.\t+\t.\tID=cycle-a;Parent=cycle-b;Name=A
            chr1\tt\tgene\t1\t10\t.\t+\t.\tID=cycle-b;Parent=cycle-a;Name=B
            chr1\tt\tgene\t1\t10\t.\t+\t.\tID=self-parent;Parent=self-parent;Name=C
            """,
            chromosomeSizes: [("chr1", 1_000)]
        )
        #expect(features.count == 3)
        #expect(Set(features.compactMap(\.id)) == ["cycle-a", "cycle-b", "self-parent"])
    }

    @Test("pins column 9 of a CDS imported with a phase, without the internal phase key and with column 8 as before (lane 13.20 M0, flipped by M1)")
    func pinsColumnNineOfACDSImportedWithAPhase() async throws {
        let exported = try await exportedGFF3(
            ofGFF3: """
            ##gff-version 3
            MN908947.3\tGenbank\tgene\t100\t900\t.\t+\t.\tID=gene-N;Name=N;gene=N
            MN908947.3\tGenbank\tCDS\t100\t900\t.\t+\t0\tID=cds-N;Parent=gene-N;Name=N;gene=N;product=nucleocapsid phosphoprotein%3B test
            MN908947.3\tGenbank\tCDS\t1000\t1300\t.\t+\t2\tID=cds-X
            MN908947.3\tGenbank\tCDS\t1500\t1800\t.\t+\t1\t.
            """,
            chromosomeSizes: [("MN908947.3", 29_903)]
        )
        // Type, start, phase (column 8) and attributes (column 9) of each feature line, in file order.
        let lines = exported.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line -> [String] in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return [columns[2], columns[3], columns[7], columns[8]]
        }
        #expect(lines == [
            ["gene", "100", ".", "ID=gene-N;Name=N;gene=N"],
            ["CDS", "100", "0", "ID=cds-N;Name=N;Parent=gene-N;gene=N;product=nucleocapsid phosphoprotein%3B test"],
            ["CDS", "1000", "2", "ID=cds-X"],
            ["CDS", "1500", "1", "ID=CDS"],
        ])
    }

    @Test("column 9 drops only the internal phase pair, wherever it sits, and keeps every other pair byte for byte (lane 13.20 M1)")
    func columnNineDropsOnlyTheInternalPhasePair() {
        func record(_ attributes: String?) -> AnnotationDatabaseRecord {
            AnnotationDatabaseRecord(
                name: "cds-N", type: "CDS", chromosome: "chr1", start: 0, end: 30, strand: "+", attributes: attributes
            )
        }
        let cases: [(stored: String?, column9: String)] = [
            (nil, "ID=cds-N"),
            ("ID=cds-N;Name=N", "ID=cds-N;Name=N"),
            ("lungfish_gff_phase=1;ID=cds-N;Name=N", "ID=cds-N;Name=N"),
            ("ID=cds-N;lungfish_gff_phase=1;Name=N", "ID=cds-N;Name=N"),
            ("ID=cds-N;Name=N;lungfish_gff_phase=1", "ID=cds-N;Name=N"),
            ("ID=cds-N;note=a%3Bb%2Cc%3Dd;lungfish_gff_phase=2;product=p q", "ID=cds-N;note=a%3Bb%2Cc%3Dd;product=p q"),
            ("lungfish_gff_phase=0", "ID=cds-N"),
            ("lungfish_gff_phase=0;", "ID=cds-N"),
            ("x_lungfish_gff_phase=0;lungfish_gff_phase_x=1;ID=cds-N", "x_lungfish_gff_phase=0;lungfish_gff_phase_x=1;ID=cds-N"),
            ("gene_id \"G\"; lungfish_gff_phase \"1\"; transcript_id \"T\"", "gene_id \"G\"; transcript_id \"T\""),
        ]
        for (stored, column9) in cases {
            #expect(AnnotationDatabaseGFFExporter.columnNine(for: record(stored)) == column9, "stored \(stored ?? "nil")")
        }
    }
}
