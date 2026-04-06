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
}
