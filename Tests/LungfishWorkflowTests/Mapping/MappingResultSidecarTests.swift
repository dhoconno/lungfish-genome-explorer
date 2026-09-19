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

    func testLoadRebasesLegacyAbsolutePathsIntoMovedRenamedProject() throws {
        let oldProject = tempDir.appendingPathComponent("Original.lungfish", isDirectory: true)
        let oldAnalysis = oldProject
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("mapping-run", isDirectory: true)
        let newProject = tempDir.appendingPathComponent("Renamed.lungfish", isDirectory: true)
        let newAnalysis = newProject
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("mapping-run", isDirectory: true)
        let oldSource = oldProject
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("reference.lungfishref", isDirectory: true)
        let newSource = newProject
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("reference.lungfishref", isDirectory: true)

        for directory in [oldAnalysis, newAnalysis, oldSource, newSource] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for analysis in [oldAnalysis, newAnalysis] {
            try Data().write(to: analysis.appendingPathComponent("sample.sorted.bam"))
            try Data().write(to: analysis.appendingPathComponent("sample.sorted.bam.bai"))
            try FileManager.default.createDirectory(
                at: analysis.appendingPathComponent("viewer.lungfishref", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try writeMappingSidecar(
            in: newAnalysis,
            sourceReferenceBundlePath: oldSource.path,
            viewerBundlePath: oldAnalysis.appendingPathComponent("viewer.lungfishref").path,
            bamPath: oldAnalysis.appendingPathComponent("sample.sorted.bam").path,
            baiPath: oldAnalysis.appendingPathComponent("sample.sorted.bam.bai").path
        )

        let loaded = try MappingResult.load(from: newAnalysis)

        XCTAssertEqual(loaded.bamURL.standardizedFileURL, newAnalysis.appendingPathComponent("sample.sorted.bam").standardizedFileURL)
        XCTAssertEqual(loaded.baiURL.standardizedFileURL, newAnalysis.appendingPathComponent("sample.sorted.bam.bai").standardizedFileURL)
        XCTAssertEqual(loaded.viewerBundleURL?.standardizedFileURL, newAnalysis.appendingPathComponent("viewer.lungfishref").standardizedFileURL)
        XCTAssertEqual(loaded.sourceReferenceBundleURL?.standardizedFileURL, newSource.standardizedFileURL)
    }

    func testLoadRetainsUnrelatedExternalAbsoluteReferencePath() throws {
        let oldProject = tempDir.appendingPathComponent("Original.lungfish", isDirectory: true)
        let oldAnalysis = oldProject
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("mapping-run", isDirectory: true)
        let newAnalysis = tempDir
            .appendingPathComponent("Renamed.lungfish", isDirectory: true)
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("mapping-run", isDirectory: true)
        let externalReference = tempDir
            .appendingPathComponent("external", isDirectory: true)
            .appendingPathComponent("reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: oldAnalysis, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newAnalysis, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalReference, withIntermediateDirectories: true)
        try Data().write(to: newAnalysis.appendingPathComponent("sample.sorted.bam"))
        try Data().write(to: newAnalysis.appendingPathComponent("sample.sorted.bam.bai"))

        try writeMappingSidecar(
            in: newAnalysis,
            sourceReferenceBundlePath: externalReference.path,
            viewerBundlePath: nil,
            bamPath: oldAnalysis.appendingPathComponent("sample.sorted.bam").path,
            baiPath: oldAnalysis.appendingPathComponent("sample.sorted.bam.bai").path
        )

        let loaded = try MappingResult.load(from: newAnalysis)

        XCTAssertEqual(loaded.sourceReferenceBundleURL?.standardizedFileURL, externalReference.standardizedFileURL)
    }

    func testSavedPathsRemainPortableAfterProjectRelocation() throws {
        let originalProject = tempDir.appendingPathComponent("Original.lungfish", isDirectory: true)
        let originalAnalysis = originalProject
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("mapping-run", isDirectory: true)
        let originalReference = originalProject
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: originalAnalysis, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalReference, withIntermediateDirectories: true)

        let result = makeResult(analysisDirectory: originalAnalysis, sourceReferenceBundleURL: originalReference)
        try result.save(to: originalAnalysis)

        let sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: originalAnalysis.appendingPathComponent("mapping-result.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(sidecar["bamPath"] as? String, "sample.sorted.bam")
        XCTAssertEqual(sidecar["baiPath"] as? String, "sample.sorted.bam.bai")
        XCTAssertEqual(sidecar["viewerBundlePath"] as? String, "viewer.lungfishref")
        XCTAssertEqual(sidecar["sourceReferenceBundlePath"] as? String, "@/Downloads/reference.lungfishref")

        let relocatedProject = tempDir.appendingPathComponent("Relocated.lungfish", isDirectory: true)
        try FileManager.default.moveItem(at: originalProject, to: relocatedProject)
        let relocatedAnalysis = relocatedProject
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("mapping-run", isDirectory: true)
        let loaded = try MappingResult.load(from: relocatedAnalysis)

        XCTAssertEqual(loaded.bamURL.standardizedFileURL, relocatedAnalysis.appendingPathComponent("sample.sorted.bam").standardizedFileURL)
        XCTAssertEqual(loaded.viewerBundleURL?.standardizedFileURL, relocatedAnalysis.appendingPathComponent("viewer.lungfishref").standardizedFileURL)
        XCTAssertEqual(
            loaded.sourceReferenceBundleURL?.standardizedFileURL,
            relocatedProject.appendingPathComponent("Downloads/reference.lungfishref").standardizedFileURL
        )
    }

    func testSaveFromStagingUsesFinalDirectoryAsPortabilityAnchor() throws {
        let finalProject = tempDir.appendingPathComponent("Final.lungfish", isDirectory: true)
        let finalAnalysis = finalProject
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("mapping-run", isDirectory: true)
        let finalReference = finalProject
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("reference.lungfishref", isDirectory: true)
        let stagingAnalysis = tempDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: finalAnalysis.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: finalReference, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingAnalysis, withIntermediateDirectories: true)

        let result = makeResult(analysisDirectory: finalAnalysis, sourceReferenceBundleURL: finalReference)
        try result.save(to: stagingAnalysis, relativeTo: finalAnalysis)

        let sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stagingAnalysis.appendingPathComponent("mapping-result.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(sidecar["bamPath"] as? String, "sample.sorted.bam")
        XCTAssertEqual(sidecar["baiPath"] as? String, "sample.sorted.bam.bai")
        XCTAssertEqual(sidecar["viewerBundlePath"] as? String, "viewer.lungfishref")
        XCTAssertEqual(sidecar["sourceReferenceBundlePath"] as? String, "@/Downloads/reference.lungfishref")

        try FileManager.default.moveItem(at: stagingAnalysis, to: finalAnalysis)
        let loaded = try MappingResult.load(from: finalAnalysis)
        XCTAssertEqual(loaded.bamURL.standardizedFileURL, finalAnalysis.appendingPathComponent("sample.sorted.bam").standardizedFileURL)
        XCTAssertEqual(loaded.sourceReferenceBundleURL?.standardizedFileURL, finalReference.standardizedFileURL)
    }

    func testStandaloneAnalysisRetainsAbsoluteReferenceInsideUnrelatedProject() throws {
        let standaloneAnalysis = tempDir.appendingPathComponent("standalone-analysis", isDirectory: true)
        let unrelatedReference = tempDir
            .appendingPathComponent("Unrelated.lungfish", isDirectory: true)
            .appendingPathComponent("Downloads/reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: standaloneAnalysis, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedReference, withIntermediateDirectories: true)

        let result = makeResult(
            analysisDirectory: standaloneAnalysis,
            sourceReferenceBundleURL: unrelatedReference
        )
        try result.save(to: standaloneAnalysis)

        let sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: standaloneAnalysis.appendingPathComponent("mapping-result.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(sidecar["sourceReferenceBundlePath"] as? String, unrelatedReference.path)
        XCTAssertEqual(
            try MappingResult.load(from: standaloneAnalysis).sourceReferenceBundleURL?.standardizedFileURL,
            unrelatedReference.standardizedFileURL
        )
    }

    func testContigSummaryEncodesReadGroupIDsInSortedOrder() throws {
        let summary = MappingContigSummary(
            sampleID: "S1",
            alignmentTrackID: "track-a",
            readGroupIDs: ["rg-z", "rg-a", "rg-m"],
            contigName: "chr1",
            contigLength: 100,
            mappedReads: 3,
            mappedReadPercent: 100,
            meanDepth: 1,
            coverageBreadth: 1,
            medianMAPQ: 60,
            meanIdentity: 1
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        XCTAssertEqual(object["readGroupIDs"] as? [String], ["rg-a", "rg-m", "rg-z"])
    }

    private func makeResult(
        analysisDirectory: URL,
        sourceReferenceBundleURL: URL
    ) -> MappingResult {
        MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            viewerBundleURL: analysisDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true),
            bamURL: analysisDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: analysisDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 100,
            mappedReads: 95,
            unmappedReads: 5,
            wallClockSeconds: 1,
            contigs: []
        )
    }

    private func writeMappingSidecar(
        in directory: URL,
        sourceReferenceBundlePath: String?,
        viewerBundlePath: String?,
        bamPath: String,
        baiPath: String
    ) throws {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "mapper": "minimap2",
            "modeID": MappingMode.defaultShortRead.id,
            "bamPath": bamPath,
            "baiPath": baiPath,
            "totalReads": 100,
            "mappedReads": 95,
            "unmappedReads": 5,
            "wallClockSeconds": 1,
            "contigs": [],
        ]
        object["sourceReferenceBundlePath"] = sourceReferenceBundlePath
        object["viewerBundlePath"] = viewerBundlePath
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("mapping-result.json"))
    }
}
