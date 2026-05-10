import XCTest
@testable import LungfishWorkflow

final class OperationStatsTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationStatsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    func testAggregatorReadsCompletedProvenanceSidecarsAndSummarizesRuntimeAndPeakMemory() throws {
        try writeProvenance(
            named: "kraken2-a",
            run: WorkflowRun(
                name: "Kraken2 Classification",
                startTime: Date(timeIntervalSince1970: 100),
                endTime: Date(timeIntervalSince1970: 110),
                status: .completed,
                steps: [
                    StepExecution(
                        toolName: "kraken2",
                        toolVersion: "2.17.1",
                        command: ["kraken2", "--db", "Standard-8"],
                        inputs: [],
                        exitCode: 0,
                        wallTime: 10,
                        peakMemoryBytes: 4_000_000_000
                    ),
                ]
            )
        )
        try writeProvenance(
            named: "kraken2-b",
            run: WorkflowRun(
                name: "Kraken2 Classification",
                startTime: Date(timeIntervalSince1970: 200),
                endTime: Date(timeIntervalSince1970: 230),
                status: .completed,
                steps: [
                    StepExecution(
                        toolName: "kraken2",
                        toolVersion: "2.17.1",
                        command: ["kraken2", "--db", "Standard"],
                        inputs: [],
                        exitCode: 0,
                        wallTime: 30,
                        peakMemoryBytes: 8_000_000_000
                    ),
                ]
            )
        )
        try writeProvenance(
            named: "failed",
            run: WorkflowRun(
                name: "Kraken2 Classification",
                startTime: Date(timeIntervalSince1970: 300),
                endTime: Date(timeIntervalSince1970: 360),
                status: .failed,
                steps: [
                    StepExecution(
                        toolName: "kraken2",
                        toolVersion: "2.17.1",
                        command: ["kraken2"],
                        inputs: [],
                        exitCode: 1,
                        wallTime: 60,
                        peakMemoryBytes: 99_000_000_000
                    ),
                ]
            )
        )

        let report = try OperationStatsAggregator().summarize(projectURL: projectURL)

        XCTAssertEqual(report.completedRunCount, 2)
        XCTAssertEqual(report.totalWallTimeSeconds, 40)
        XCTAssertEqual(report.peakMemoryBytes, 8_000_000_000)
        XCTAssertEqual(report.operations.count, 1)
        XCTAssertEqual(report.operations[0].name, "Kraken2 Classification")
        XCTAssertEqual(report.operations[0].completedRunCount, 2)
        XCTAssertEqual(report.operations[0].averageWallTimeSeconds, 20)
        XCTAssertEqual(report.operations[0].peakMemoryBytes, 8_000_000_000)
    }

    private func writeProvenance(named name: String, run: WorkflowRun) throws {
        let directory = projectURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        try data.write(to: directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
    }
}
