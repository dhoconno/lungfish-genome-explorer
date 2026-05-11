// WorkflowBuilderPlanCompilerTests.swift - Tests for native Workflow Builder plan compilation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class WorkflowBuilderPlanCompilerTests: XCTestCase {
    func testCompilesVSP2TemplateIntoLinearCLIBackedPlan() throws {
        let fixture = try makeProjectFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Sample.lungfishfastq")
        let runDirectory = fixture.projectURL.appendingPathComponent("Workflow Runs/run-1", isDirectory: true)

        let plan = try WorkflowBuilderPlanCompiler().compile(
            graph: graph,
            projectURL: fixture.projectURL,
            runDirectoryURL: runDirectory
        )

        XCTAssertEqual(plan.workflowName, "VSP2 FASTQ Workflow")
        XCTAssertEqual(plan.inputBundleURL, fixture.inputBundleURL.standardizedFileURL)
        XCTAssertEqual(plan.recipe.id, "workflow-builder-\(graph.id.uuidString)")
        XCTAssertEqual(plan.recipe.requiredInput, .paired)
        XCTAssertEqual(plan.recipe.qualityBinning, .illumina4)
        XCTAssertEqual(plan.recipe.steps.map(\.type), [
            "fastp-dedup",
            "fastp-trim",
            "deacon-scrub",
            "fastp-merge",
            "seqkit-length-filter",
        ])
        XCTAssertEqual(plan.steps.map(\.operation), plan.recipe.steps.map(\.type))
        XCTAssertEqual(plan.steps.first?.inputBundleURL, fixture.inputBundleURL.standardizedFileURL)
        XCTAssertEqual(plan.steps.last?.outputBundleURL.pathExtension, "lungfishfastq")
        XCTAssertTrue(plan.argv.starts(with: ["lungfish-cli", "workflow", "builder-run"]))
        XCTAssertTrue(plan.steps[1].argv.contains("--param"))
        XCTAssertTrue(plan.steps[1].argv.contains("quality=15"))
        XCTAssertEqual(plan.steps[2].parameters["database"], "deacon-panhuman")
    }

    func testRejectsTemplateWithoutExplicitInputBundlePath() throws {
        let fixture = try makeProjectFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph()

        XCTAssertThrowsError(
            try WorkflowBuilderPlanCompiler().compile(
                graph: graph,
                projectURL: fixture.projectURL,
                runDirectoryURL: fixture.projectURL.appendingPathComponent("run", isDirectory: true)
            )
        ) { error in
            guard case WorkflowBuilderPlanCompilerError.validationFailed(let issues) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(issues.contains {
                if case .missingNodeParameter(_, _, "bundle_path") = $0 { return true }
                return false
            })
        }
    }

    func testPlanCompilationIsDeterministic() throws {
        let fixture = try makeProjectFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Sample.lungfishfastq")
        let runDirectory = fixture.projectURL.appendingPathComponent("Workflow Runs/run-1", isDirectory: true)
        let compiler = WorkflowBuilderPlanCompiler()

        let first = try compiler.compile(graph: graph, projectURL: fixture.projectURL, runDirectoryURL: runDirectory)
        let second = try compiler.compile(graph: graph, projectURL: fixture.projectURL, runDirectoryURL: runDirectory)

        XCTAssertEqual(first, second)
    }

    func testRejectsNonLinearNativeFastqGraph() throws {
        let fixture = try makeProjectFixture()
        var graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Sample.lungfishfastq")
        let input = try XCTUnwrap(graph.allNodes.first { $0.type == .fastqBundleInput })
        let extra = graph.addNode(type: .fastpTrim, position: .zero)
        _ = try graph.addConnection(
            sourceNodeId: input.id,
            sourcePortId: "reads",
            targetNodeId: extra.id,
            targetPortId: "reads"
        )

        XCTAssertThrowsError(
            try WorkflowBuilderPlanCompiler().compile(
                graph: graph,
                projectURL: fixture.projectURL,
                runDirectoryURL: fixture.projectURL.appendingPathComponent("run", isDirectory: true)
            )
        ) { error in
            guard case WorkflowBuilderPlanCompilerError.nonLinearGraph(let nodeID, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(nodeID, input.id)
        }
    }

    func testRejectsExtraBranchIntoProjectOutput() throws {
        let fixture = try makeProjectFixture()
        var graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Sample.lungfishfastq")
        _ = try graph.addConnection(
            sourceNodeId: graph.sampleInput.id,
            sourcePortId: "sample",
            targetNodeId: graph.projectOutput.id,
            targetPortId: "input"
        )

        XCTAssertThrowsError(
            try WorkflowBuilderPlanCompiler().compile(
                graph: graph,
                projectURL: fixture.projectURL,
                runDirectoryURL: fixture.projectURL.appendingPathComponent("run", isDirectory: true)
            )
        ) { error in
            guard case WorkflowBuilderPlanCompilerError.nonLinearGraph(let nodeID, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(nodeID, graph.projectOutput.id)
            XCTAssertTrue(reason.contains("Project output"))
        }
    }

    func testRejectsUnsupportedExecutableNode() throws {
        let fixture = try makeProjectFixture()
        var graph = WorkflowGraph(name: "Unsupported")
        let input = graph.addNode(
            type: .fastqBundleInput,
            position: .zero,
            label: nil
        )
        var configuredInput = input
        configuredInput.parameters["bundle_path"] = "@/Imports/Sample.lungfishfastq"
        try graph.updateNode(configuredInput)
        let qc = graph.addNode(type: .qualityControl, position: .zero)
        _ = try graph.addConnection(sourceNodeId: input.id, sourcePortId: "reads", targetNodeId: qc.id, targetPortId: "reads")
        _ = try graph.addConnection(sourceNodeId: qc.id, sourcePortId: "report", targetNodeId: graph.projectOutput.id, targetPortId: "input")

        XCTAssertThrowsError(
            try WorkflowBuilderPlanCompiler().compile(
                graph: graph,
                projectURL: fixture.projectURL,
                runDirectoryURL: fixture.projectURL.appendingPathComponent("run", isDirectory: true)
            )
        ) { error in
            guard case WorkflowBuilderPlanCompilerError.unsupportedNode(let nodeID, let type) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(nodeID, qc.id)
            XCTAssertEqual(type, .qualityControl)
        }
    }

    func testRejectsInputBundleEscapingProject() throws {
        let fixture = try makeProjectFixture()
        let outside = fixture.projectURL
            .deletingLastPathComponent()
            .appendingPathComponent("Outside.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/../Outside.lungfishfastq")

        XCTAssertThrowsError(
            try WorkflowBuilderPlanCompiler().compile(
                graph: graph,
                projectURL: fixture.projectURL,
                runDirectoryURL: fixture.projectURL.appendingPathComponent("run", isDirectory: true)
            )
        ) { error in
            guard case WorkflowBuilderPlanCompilerError.inputBundleOutsideProject = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private struct ProjectFixture {
        let rootURL: URL
        let projectURL: URL
        let inputBundleURL: URL
    }

    private func makeProjectFixture() throws -> ProjectFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-builder-compiler-\(UUID().uuidString)", isDirectory: true)
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let inputBundleURL = projectURL.appendingPathComponent("Imports/Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: inputBundleURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return ProjectFixture(rootURL: root, projectURL: projectURL, inputBundleURL: inputBundleURL)
    }
}
