import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class MappingViewportLegacyReadCountTests: XCTestCase {
    nonisolated(unsafe) private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-legacy-counts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    func testLegacyManifestCountsAreOverriddenByMetadataDatabaseWithoutMutatingBundle() async throws {
        let fixture = try makeLegacyViewerBundle()
        let originalManifest = try Data(contentsOf: fixture.manifestURL)
        let originalDatabase = try Data(contentsOf: fixture.databaseURL)
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            viewerBundleURL: fixture.bundleURL,
            bamURL: tempDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: tempDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 5_633_919,
            mappedReads: 25,
            unmappedReads: 5_633_894,
            wallClockSeconds: 1,
            contigs: []
        )
        let builderCalled = expectation(description: "summary builder receives authoritative total")
        let controller = MappingResultViewController()
        _ = controller.view
        controller.setAlignmentTrackSummaryBuilderForTesting { _, totalReads in
            XCTAssertEqual(totalReads, 5_633_919)
            builderCalled.fulfill()
            return [
                MappingContigSummary(
                    contigName: "segment-1",
                    contigLength: 100,
                    mappedReads: 2,
                    mappedReadPercent: Double(2) / Double(totalReads) * 100,
                    meanDepth: 0,
                    coverageBreadth: 0,
                    medianMAPQ: 0,
                    meanIdentity: 0
                ),
                MappingContigSummary(
                    contigName: "segment-2",
                    contigLength: 100,
                    mappedReads: 23,
                    mappedReadPercent: Double(23) / Double(totalReads) * 100,
                    meanDepth: 0,
                    coverageBreadth: 0,
                    medianMAPQ: 0,
                    meanIdentity: 0
                ),
            ]
        }

        controller.configureForTesting(result: result)

        await fulfillment(of: [builderCalled], timeout: 2)
        try await waitUntil {
            controller.testSummaryText == "Legacy minimap2 — 25 / 5,633,919 reads mapped (0.0%)"
        }
        let firstSegment = try XCTUnwrap(
            controller.testContigTableView.displayedRows.first { $0.contigName == "segment-1" }
        )
        XCTAssertEqual(firstSegment.mappedReadPercent, Double(2) / Double(5_633_919) * 100, accuracy: 1e-12)
        XCTAssertEqual(try Data(contentsOf: fixture.manifestURL), originalManifest)
        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), originalDatabase)
    }

    private func makeLegacyViewerBundle() throws -> (
        bundleURL: URL,
        manifestURL: URL,
        databaseURL: URL
    ) {
        let bundleURL = tempDirectory.appendingPathComponent("legacy.lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let alignmentDirectory = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentDirectory, withIntermediateDirectories: true)
        try Data().write(to: genomeDirectory.appendingPathComponent("sequence.fa.gz"))
        try Data().write(to: genomeDirectory.appendingPathComponent("sequence.fa.gz.fai"))
        try Data().write(to: genomeDirectory.appendingPathComponent("sequence.fa.gz.gzi"))
        try Data().write(to: alignmentDirectory.appendingPathComponent("legacy.bam"))
        try Data().write(to: alignmentDirectory.appendingPathComponent("legacy.bam.bai"))

        let databaseURL = alignmentDirectory.appendingPathComponent("legacy.stats.db")
        do {
            let database = try AlignmentMetadataDatabase.create(at: databaseURL)
            database.addReadGroup(id: "legacy-rg", sample: "Legacy sample")
            database.addChromosomeStats(chromosome: "segment-1", length: 100, mapped: 2, unmapped: 0)
            database.addChromosomeStats(chromosome: "segment-2", length: 100, mapped: 23, unmapped: 0)
            database.addFlagStat(category: "total", qcPass: 5_633_919, qcFail: 0)
            database.addFlagStat(category: "mapped", qcPass: 25, qcFail: 0)
        }

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Legacy Viewer",
            identifier: "org.lungfish.tests.legacy-counts",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 200,
                chromosomes: [
                    ChromosomeInfo(name: "segment-1", length: 100, offset: 0, lineBases: 80, lineWidth: 81),
                    ChromosomeInfo(name: "segment-2", length: 100, offset: 100, lineBases: 80, lineWidth: 81),
                ]
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "legacy-track",
                    name: "Legacy minimap2",
                    sourcePath: "alignments/legacy.bam",
                    indexPath: "alignments/legacy.bam.bai",
                    metadataDBPath: "alignments/legacy.stats.db",
                    mappedReadCount: 25,
                    unmappedReadCount: 0
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return (
            bundleURL,
            bundleURL.appendingPathComponent(BundleManifest.filename),
            databaseURL
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        predicate: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
