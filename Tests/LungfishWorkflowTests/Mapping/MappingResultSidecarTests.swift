import XCTest
@testable import LungfishWorkflow

final class MappingResultSidecarTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mapping-sidecar-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveAndLoadRoundTrip() throws {
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            sourceReferenceBundleURL: URL(fileURLWithPath: "/tmp/source.lungfishref"),
            viewerBundleURL: tempDir.appendingPathComponent("viewer.lungfishref"),
            bamURL: tempDir.appendingPathComponent("sample.sorted.bam"),
            baiURL: tempDir.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 1_000,
            mappedReads: 950,
            unmappedReads: 50,
            wallClockSeconds: 12.5,
            contigs: [
                MappingContigSummary(
                    contigName: "chr1",
                    contigLength: 4_862,
                    mappedReads: 950,
                    mappedReadPercent: 95.0,
                    meanDepth: 28.4,
                    coverageBreadth: 0.998,
                    medianMAPQ: 60,
                    meanIdentity: 0.991
                ),
            ]
        )

        try result.save(to: tempDir)
        XCTAssertTrue(MappingResult.exists(in: tempDir))

        let loaded = try MappingResult.load(from: tempDir)
        XCTAssertEqual(loaded.mapper, .minimap2)
        XCTAssertEqual(loaded.modeID, MappingMode.minimap2MapONT.id)
        XCTAssertEqual(loaded.sourceReferenceBundleURL?.path, "/tmp/source.lungfishref")
        XCTAssertEqual(loaded.viewerBundleURL?.lastPathComponent, "viewer.lungfishref")
        XCTAssertEqual(loaded.bamURL.lastPathComponent, "sample.sorted.bam")
        XCTAssertEqual(loaded.baiURL.lastPathComponent, "sample.sorted.bam.bai")
        XCTAssertEqual(loaded.contigs.map(\.contigName), ["chr1"])
        XCTAssertEqual(loaded.totalReads, 1_000)
        XCTAssertEqual(loaded.mappedReads, 950)
        XCTAssertEqual(loaded.unmappedReads, 50)
    }

    func testLoadFallsBackToLegacyAlignmentResultSidecar() throws {
        let legacyJSON = """
        {
          "bamPath" : "sample.sorted.bam",
          "baiPath" : "sample.sorted.bam.bai",
          "mappedReads" : 95,
          "savedAt" : "2026-04-19T12:00:00Z",
          "schemaVersion" : 1,
          "toolVersion" : "2.30",
          "totalReads" : 100,
          "unmappedReads" : 5,
          "wallClockSeconds" : 4.25
        }
        """
        try legacyJSON.write(
            to: tempDir.appendingPathComponent("alignment-result.json"),
            atomically: true,
            encoding: .utf8
        )

        let loaded = try MappingResult.load(from: tempDir)

        XCTAssertEqual(loaded.mapper, .minimap2)
        XCTAssertEqual(loaded.bamURL.lastPathComponent, "sample.sorted.bam")
        XCTAssertEqual(loaded.baiURL.lastPathComponent, "sample.sorted.bam.bai")
        XCTAssertEqual(loaded.totalReads, 100)
        XCTAssertEqual(loaded.mappedReads, 95)
        XCTAssertEqual(loaded.unmappedReads, 5)
        XCTAssertTrue(loaded.contigs.isEmpty)
    }
}
