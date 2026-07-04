import XCTest
@testable import LungfishWorkflow
import LungfishCore
import LungfishIO

final class ReadExtractionServiceTests: XCTestCase {
    func testSamtoolsRegionsMergeAdjacentBlocksAndUseOneBasedInclusiveCoordinates() throws {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "orf1ab",
            chromosome: "chr1",
            intervals: [
                AnnotationInterval(start: 100, end: 120),
                AnnotationInterval(start: 120, end: 130),
                AnnotationInterval(start: 200, end: 210),
                AnnotationInterval(start: 205, end: 220)
            ]
        )

        XCTAssertEqual(
            ReadExtractionService.samtoolsRegions(for: annotation),
            ["chr1:101-130", "chr1:201-220"]
        )
    }

    func testSamtoolsRegionsReturnEmptyWhenChromosomeIsMissing() throws {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "orf1ab",
            intervals: [AnnotationInterval(start: 100, end: 130)]
        )

        XCTAssertTrue(ReadExtractionService.samtoolsRegions(for: annotation).isEmpty)
    }

    func testCreateBundlePersistsExtractionPairingModeInFASTQMetadata() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("read-extract-bundle-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let r1 = root.appendingPathComponent("selected_R1.fastq")
        let r2 = root.appendingPathComponent("selected_R2.fastq")
        try "@read/1\nACGT\n+\nIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@read/2\nTGCA\n+\nIIII\n".write(to: r2, atomically: true, encoding: .utf8)

        let metadata = ExtractionMetadata(
            sourceDescription: "fixture",
            toolName: "test",
            extractionDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let service = ReadExtractionService()

        let bundleURL = try await service.createBundle(
            from: ExtractionResult(fastqURLs: [r1, r2], readCount: 1, pairedEnd: true),
            sourceName: "fixture",
            selectionDescription: "selected",
            metadata: metadata,
            in: root
        )

        let movedR1 = bundleURL.appendingPathComponent("selected_R1.fastq")
        let persisted = try XCTUnwrap(FASTQMetadataStore.load(for: movedR1))
        XCTAssertEqual(persisted.ingestion?.pairingMode, .pairedEnd)
        XCTAssertEqual(persisted.ingestion?.originalFilenames, ["selected_R1.fastq", "selected_R2.fastq"])
        XCTAssertEqual(persisted.downloadSource, "read-extraction")
    }
}
