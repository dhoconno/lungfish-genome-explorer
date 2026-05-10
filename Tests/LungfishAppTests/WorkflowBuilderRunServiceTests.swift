import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class WorkflowBuilderRunServiceTests: XCTestCase {
    func testRunCreatesDurableRunRecordProvenanceAndOperationRows() async throws {
        let fixture = try makeFixture()
        var graph = WorkflowGraph(name: "Reads to Trim")
        let trimming = graph.addNode(type: .trimming, position: .zero)
        _ = try graph.addConnection(
            sourceNodeId: graph.sampleInput.id,
            sourcePortId: "sample",
            targetNodeId: trimming.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: trimming.id,
            sourcePortId: "trimmed",
            targetNodeId: graph.projectOutput.id,
            targetPortId: "input"
        )
        let operationCenter = OperationCenter()
        let service = WorkflowBuilderRunService(operationCenter: operationCenter)
        let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

        let result = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)

        XCTAssertEqual(result.runDirectoryURL.lastPathComponent, result.runID.uuidString)
        XCTAssertEqual(result.runDirectoryURL.deletingLastPathComponent().lastPathComponent, "runs")
        let record = try WorkflowBuilderRunStore.readRun(runID: result.runID, from: fixture.workflowBundleURL)
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.workflowName, "Reads to Trim")
        XCTAssertEqual(record.graphID, graph.id)
        XCTAssertFalse(record.graphChecksumSHA256.isEmpty)
        XCTAssertEqual(record.binding.sample.path, fixture.sampleURL.standardizedFileURL.path)
        XCTAssertEqual(record.binding.project.path, fixture.projectURL.standardizedFileURL.path)
        XCTAssertEqual(record.nodeRecords.map(\.status), [.succeeded, .succeeded, .succeeded])
        XCTAssertEqual(record.provenance.toolName, "Lungfish Workflow Builder")
        XCTAssertEqual(record.provenance.exitStatus, 0)
        XCTAssertTrue(record.provenance.argv.contains("run"))
        XCTAssertTrue(record.provenance.inputs.contains { $0.path == fixture.sampleURL.standardizedFileURL.path })
        XCTAssertTrue(record.provenance.outputs.contains { $0.path == result.runDirectoryURL.standardizedFileURL.path })

        let runRows = operationCenter.items.filter { $0.workflowRunID == result.runID }
        XCTAssertEqual(runRows.count, 4)
        XCTAssertTrue(runRows.contains { $0.title == "Workflow Run: Reads to Trim" && $0.state == .completed })
        XCTAssertTrue(runRows.contains { $0.title == "Sample input" && $0.state == .completed })
        XCTAssertTrue(runRows.contains { $0.title == "Trimming" && $0.state == .completed })
        XCTAssertTrue(runRows.contains { $0.title == "Project output" && $0.state == .completed })
    }

    func testFirstFailingNodeMarksRunFailedAndSkipsDownstreamNodes() async throws {
        let fixture = try makeFixture()
        var graph = WorkflowGraph(name: "Failing Workflow")
        let trimming = graph.addNode(type: .trimming, position: .zero)
        let qc = graph.addNode(type: .qualityControl, position: .zero)
        _ = try graph.addConnection(
            sourceNodeId: graph.sampleInput.id,
            sourcePortId: "sample",
            targetNodeId: trimming.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: trimming.id,
            sourcePortId: "trimmed",
            targetNodeId: qc.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: qc.id,
            sourcePortId: "report",
            targetNodeId: graph.projectOutput.id,
            targetPortId: "input"
        )
        let operationCenter = OperationCenter()
        let service = WorkflowBuilderRunService(operationCenter: operationCenter) { node, _ in
            if node.id == trimming.id {
                throw WorkflowBuilderRunService.ExecutionError.nodeFailed(nodeID: node.id, message: "fastp exited 2")
            }
        }
        let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

        do {
            _ = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)
            XCTFail("Expected run failure")
        } catch WorkflowBuilderRunService.ExecutionError.nodeFailed(let nodeID, let message) {
            XCTAssertEqual(nodeID, trimming.id)
            XCTAssertEqual(message, "fastp exited 2")
        }

        let runID = try XCTUnwrap(operationCenter.items.first?.workflowRunID)
        let record = try WorkflowBuilderRunStore.readRun(runID: runID, from: fixture.workflowBundleURL)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.errorMessage, "fastp exited 2")
        XCTAssertEqual(record.nodeRecords.first { $0.nodeID == trimming.id }?.status, .failed)
        XCTAssertEqual(record.nodeRecords.first { $0.nodeID == qc.id }?.status, .skipped)
        XCTAssertEqual(record.nodeRecords.first { $0.nodeID == graph.projectOutput.id }?.status, .skipped)
        XCTAssertTrue(operationCenter.items.contains { $0.workflowRunID == runID && $0.title == "Trimming" && $0.state == .failed })
        XCTAssertFalse(operationCenter.items.contains { $0.workflowRunID == runID && $0.title == "Quality Control" })
    }

    func testValidationFailureDoesNotCreateRunRows() async throws {
        let fixture = try makeFixture()
        let graph = WorkflowGraph(name: "Empty")
        let operationCenter = OperationCenter()
        let service = WorkflowBuilderRunService(operationCenter: operationCenter)
        let binding = WorkflowBuilderRunBinding(sampleURL: fixture.sampleURL, projectURL: fixture.projectURL)

        do {
            _ = try await service.run(graph: graph, workflowBundleURL: fixture.workflowBundleURL, binding: binding)
            XCTFail("Expected validation failure")
        } catch WorkflowBuilderRunService.ExecutionError.validationFailed(let issues) {
            XCTAssertTrue(issues.contains(.emptyWorkflow))
        }

        XCTAssertTrue(operationCenter.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workflowBundleURL.appendingPathComponent("runs").path))
    }

    func testSampleDiscoverySelectsActiveSampleDeterministically() throws {
        let fixture = try makeFixture()
        let second = fixture.projectURL.appendingPathComponent("Imports/B.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let samples = WorkflowBuilderRunSampleDiscovery.discoverSamples(
            in: fixture.projectURL,
            preferredSampleURL: second
        )

        XCTAssertEqual(samples.map(\.url.lastPathComponent), ["B.lungfishfastq", "A.lungfishfastq"])
        XCTAssertEqual(samples.first?.displayName, "B")
    }

    private struct Fixture {
        let root: URL
        let projectURL: URL
        let sampleURL: URL
        let workflowBundleURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-builder-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let sampleURL = projectURL.appendingPathComponent("Imports/A.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\n!!!!\n".write(
            to: sampleURL.appendingPathComponent("reads.fastq"),
            atomically: true,
            encoding: .utf8
        )
        let workflowBundleURL = projectURL.appendingPathComponent("Workflows/test.lungfishflow", isDirectory: true)
        try FileManager.default.createDirectory(at: workflowBundleURL, withIntermediateDirectories: true)
        return Fixture(root: root, projectURL: projectURL, sampleURL: sampleURL, workflowBundleURL: workflowBundleURL)
    }
}
