import XCTest
@testable import LungfishIO

final class AnalysesSidebarTests: XCTestCase {
    func testListAnalysesWithFixtures() throws {
        let project = try TestAnalysisFixtures.createTempProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let analyses = try AnalysesFolder.listAnalyses(in: project)
        XCTAssertEqual(analyses.count, 6)
        let tools = Set(analyses.map(\.tool))
        XCTAssertTrue(tools.contains("esviritu"))
        XCTAssertTrue(tools.contains("kraken2"))
        XCTAssertTrue(tools.contains("taxtriage"))
        XCTAssertTrue(tools.contains("spades"))
        XCTAssertTrue(tools.contains("minimap2"))
        for i in 0..<(analyses.count - 1) {
            XCTAssertGreaterThanOrEqual(analyses[i].timestamp, analyses[i + 1].timestamp)
        }
    }

    func testBatchDetection() throws {
        let project = try TestAnalysisFixtures.createTempProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let analyses = try AnalysesFolder.listAnalyses(in: project)
        let batches = analyses.filter(\.isBatch)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.tool, "esviritu")
    }

    // MARK: - Manifest fixture loading with pruning

    func testLoadFixtureManifestAndPrune() throws {
        let project = try TestAnalysisFixtures.createTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let bundleURL = project.appendingPathComponent("testSample.lungfishfastq")
        let manifest = AnalysisManifestStore.load(bundleURL: bundleURL, projectURL: project)

        // The fixture manifest has 3 entries; the stale DEADBEEF one has no matching
        // directory in Analyses/ and must be pruned on load.
        XCTAssertEqual(manifest.analyses.count, 2,
                       "Expected 2 live entries after pruning the stale DEADBEEF entry")

        let tools = Set(manifest.analyses.map(\.tool))
        XCTAssertTrue(tools.contains("esviritu"), "esviritu entry should survive pruning")
        XCTAssertTrue(tools.contains("kraken2"), "kraken2 entry should survive pruning")

        XCTAssertFalse(
            manifest.analyses.contains(where: {
                $0.analysisDirectoryName == "esviritu-2026-01-10T08-00-00"
            }),
            "Stale esviritu-2026-01-10T08-00-00 entry must be removed by pruning"
        )
    }

    // MARK: - knownTools coverage

    func testKnownToolsCoverAllFixtureTypes() throws {
        let project = try TestAnalysisFixtures.createTempProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let analyses = try AnalysesFolder.listAnalyses(in: project)
        for info in analyses {
            XCTAssertTrue(
                AnalysesFolder.knownTools.contains(info.tool),
                "Tool '\(info.tool)' from directory '\(info.url.lastPathComponent)' not in knownTools"
            )
        }
    }

    func testMappingSidecarProbeRecognizesRenamedReadMappingAnalyses() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-analysis-probe-\(UUID().uuidString)", isDirectory: true)
        let analysesDir = project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        let resultDir = analysesDir.appendingPathComponent("renamed-mapping-run", isDirectory: true)

        defer { try? FileManager.default.removeItem(at: project) }

        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let sidecar = """
        {
          "schemaVersion" : 1,
          "mapper" : "bowtie2",
          "modeID" : "short-read-default",
          "sourceReferenceBundlePath" : null,
          "viewerBundlePath" : null,
          "bamPath" : "reads.sorted.bam",
          "baiPath" : "reads.sorted.bam.bai",
          "totalReads" : 100,
          "mappedReads" : 80,
          "unmappedReads" : 20,
          "wallClockSeconds" : 4.2,
          "contigs" : []
        }
        """
        try sidecar.write(
            to: resultDir.appendingPathComponent("mapping-result.json"),
            atomically: true,
            encoding: .utf8
        )

        let analyses = try AnalysesFolder.listAnalyses(in: project)

        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "bowtie2")
        XCTAssertTrue(AnalysesFolder.knownTools.contains("bowtie2"))
        XCTAssertTrue(AnalysesFolder.knownTools.contains("bwa-mem2"))
        XCTAssertTrue(AnalysesFolder.knownTools.contains("bbmap"))
    }
}
