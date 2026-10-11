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

    /// The genotype writers record steps without a start date, so a step has no `startTime` key and
    /// the record does not decode as a `WorkflowRun`. It is still a completed run.
    func testAggregatorCountsACompletedRecordWhoseStepsHoldNoStartDate() throws {
        let directory = projectURL.appendingPathComponent("genotype.lungfishgenotype", isDirectory: true)
        let envelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_000),
            workflowName: "genotype haplotype-call",
            toolName: "lungfish-cli",
            argv: ["lungfish-cli", "genotype", "haplotype-call"],
            steps: [
                ProvenanceStep(toolName: "minimap2", toolVersion: "2.30", argv: ["minimap2"], exitStatus: 0, wallTimeSeconds: 7, peakMemoryBytes: 1_000),
                ProvenanceStep(toolName: "samtools", toolVersion: "1.22", argv: ["samtools"], exitStatus: 0, wallTimeSeconds: 5, peakMemoryBytes: 3_000),
            ],
            wallTimeSeconds: 12,
            exitStatus: 0,
            status: .completed
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: directory)

        let report = try OperationStatsAggregator().summarize(projectURL: projectURL)

        XCTAssertEqual(report.sidecarCount, 1)
        XCTAssertEqual(report.completedRunCount, 1, "a completed record whose steps hold no start date counts")
        XCTAssertEqual(report.operations.first?.name, "genotype haplotype-call")
        XCTAssertEqual(report.totalWallTimeSeconds, 12)
        XCTAssertEqual(report.peakMemoryBytes, 3_000)
    }

    /// An exit status of 0 alone is not a completed run, because a run cancelled in Bracken
    /// preparation can end on a step that exited 0. A record that never states its status, and a
    /// record only the primitive adapter reads, are not counted.
    func testAggregatorCountsOnlyRecordsThatStateTheyCompleted() throws {
        let unstated = projectURL.appendingPathComponent("unstated", isDirectory: true)
        try FileManager.default.createDirectory(at: unstated, withIntermediateDirectories: true)
        try Data(#"""
        {"createdAt": "2026-05-10T23:19:32Z", "workflowName": "fixture-backfill", "exitStatus": 0,
         "runtimeIdentity": {"executablePath": "python3"}, "wallTimeSeconds": 1}
        """#.utf8).write(to: unstated.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        let primitive = projectURL.appendingPathComponent("primitive", isDirectory: true)
        try FileManager.default.createDirectory(at: primitive, withIntermediateDirectories: true)
        try Data(#"{"operation": "msa", "exitStatus": 0, "status": "completed", "wallTimeSeconds": 2}"#.utf8)
            .write(to: primitive.appendingPathComponent(ProvenanceRecorder.provenanceFilename))

        let report = try OperationStatsAggregator().summarize(projectURL: projectURL)

        XCTAssertEqual(report.sidecarCount, 2)
        XCTAssertEqual(report.completedRunCount, 0)
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
