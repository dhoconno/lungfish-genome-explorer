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
}
