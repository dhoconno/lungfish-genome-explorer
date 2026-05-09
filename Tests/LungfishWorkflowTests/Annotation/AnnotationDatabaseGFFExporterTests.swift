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
