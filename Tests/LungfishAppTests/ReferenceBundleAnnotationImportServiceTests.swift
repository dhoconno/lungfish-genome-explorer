import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

@MainActor
final class ReferenceBundleAnnotationImportServiceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testAttachesBEDAsAnnotationTrackToExistingBundle() async throws {
        let bundleURL = try makeBundle(named: "M1")
        let bedURL = tempRoot.appendingPathComponent("M1.bed")
        try "chr1\t1\t12\tgeneA\t0\t+\n".write(to: bedURL, atomically: true, encoding: .utf8)

        let result = try await ReferenceBundleAnnotationImportService().attachAnnotationTrack(
            sourceURL: bedURL,
            bundleURL: bundleURL
        )

        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.annotations.count, 1)
        XCTAssertEqual(manifest.annotations.first?.id, result.track.id)
        XCTAssertEqual(manifest.annotations.first?.name, "M1")
        XCTAssertEqual(manifest.annotations.first?.databasePath, "annotations/m1.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("annotations/m1.db").path))
        XCTAssertEqual(result.featureCount, 1)
    }

    func testAttachesGFFAsAnnotationTrackToExistingBundle() async throws {
        let bundleURL = try makeBundle(named: "M1")
        let gffURL = tempRoot.appendingPathComponent("M1.gff")
        try """
        ##gff-version 3
        chr1\tRefSeq\tgene\t2\t8\t.\t+\t.\tID=geneA;Name=Gene A

        """.write(to: gffURL, atomically: true, encoding: .utf8)

        let result = try await ReferenceBundleAnnotationImportService().attachAnnotationTrack(
            sourceURL: gffURL,
            bundleURL: bundleURL
        )

        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.annotations.count, 1)
        XCTAssertEqual(manifest.annotations.first?.databasePath, "annotations/m1.db")
        XCTAssertEqual(result.featureCount, 1)
    }

    func testDiscoverReferenceBundlesReturnsProjectRelativeDisplayPaths() throws {
        _ = try makeBundle(named: "M1", relativePath: "Reference Sequences/M1.lungfishref")
        _ = try makeBundle(named: "M1", relativePath: "Imported/Nested/M1.lungfishref")

        let choices = try ReferenceBundleAnnotationImportService.discoverReferenceBundles(in: tempRoot)

        XCTAssertEqual(
            choices.map(\.displayPath),
            [
                "Imported/Nested/M1.lungfishref",
                "Reference Sequences/M1.lungfishref",
            ]
        )
    }

    private func makeBundle(named name: String, relativePath: String? = nil) throws -> URL {
        let bundleURL = tempRoot.appendingPathComponent(relativePath ?? "\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("genome", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("annotations", isDirectory: true),
            withIntermediateDirectories: true
        )

        try ">chr1\nACGTACGTACGTACGT\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "chr1\t16\t6\t7\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa.fai"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.test.\(UUID().uuidString.lowercased())",
            source: SourceInfo(organism: "Test", assembly: name),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 16,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 16, offset: 6, lineBases: 16, lineWidth: 17)
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
