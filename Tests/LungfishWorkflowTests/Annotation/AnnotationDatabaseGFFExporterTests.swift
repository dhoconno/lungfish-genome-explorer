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

    @Test("SCI-01: multi-segment ORF1ab CDS (NCBI RefSeq shared ID) exports two CDS lines with correct per-segment phase")
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

    @Test("SCI-01: minus-strand spliced CDS gets phase from transcription-order cumulative length")
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
}
