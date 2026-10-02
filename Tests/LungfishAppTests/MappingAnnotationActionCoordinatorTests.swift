import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishWorkflow

@MainActor
final class MappingAnnotationActionCoordinatorTests: XCTestCase {
    func testSamtoolsRegionsMergeAdjacentBlocksAndConvertToOneBasedInclusiveCoordinates() throws {
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

        let regions = MappingAnnotationActionCoordinator.samtoolsRegions(for: annotation)

        XCTAssertEqual(regions, ["chr1:101-130", "chr1:201-220"])
    }

    func testZoomRegionUsesPaddedBoundingSpanAndClampsToChromosomeLength() throws {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "spike",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 1_000, end: 1_100)]
        )

        let region = MappingAnnotationActionCoordinator.zoomRegion(
            for: annotation,
            chromosomeLength: 2_000
        )

        XCTAssertEqual(region, GenomicRegion(chromosome: "chr1", start: 950, end: 1_150))
    }

    func testExtractionConfigurationUsesFinalNormalizedBamURL() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let result = MappingResult(
            mapper: .minimap2,
            modeID: "short-read-default",
            bamURL: tempDir.appendingPathComponent("sample.sorted.bam"),
            baiURL: tempDir.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 100,
            mappedReads: 80,
            unmappedReads: 20,
            wallClockSeconds: 1.0,
            contigs: []
        )
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "n",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 10, end: 25)]
        )

        let config = MappingAnnotationActionCoordinator.extractionConfiguration(
            for: annotation,
            mappingResult: result,
            outputDirectory: tempDir
        )

        XCTAssertEqual(config?.bamURL, result.bamURL)
        // ReadExtractionService.extractByBAMRegion refuses a region extraction
        // without an explicit index, so the action passes the mapping's own
        // (R3).
        XCTAssertEqual(config?.indexURL, result.baiURL)
        XCTAssertEqual(config?.outputDirectory, tempDir)
        XCTAssertEqual(config?.regions, ["chr1:11-25"])
        XCTAssertEqual(config?.outputBaseName, "n")
        XCTAssertEqual(config?.fallbackToAll, false)
        XCTAssertEqual(config?.deduplicateReads, true)
    }
}
