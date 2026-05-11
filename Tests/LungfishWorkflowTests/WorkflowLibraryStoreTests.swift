// WorkflowLibraryStoreTests.swift - Tests for Workflow Builder library persistence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class WorkflowLibraryStoreTests: XCTestCase {
    func testCreateListsAndLoadsManyProjectWorkflows() throws {
        let projectURL = try makeTemporaryProject()
        var alpha = WorkflowGraph(name: "Alpha Workflow", version: "1.2.0")
        alpha.description = "First workflow"
        let beta = WorkflowGraph(name: "Beta Workflow", version: "2.0.0")

        let alphaURL = try WorkflowLibraryStore.createWorkflow(alpha, in: projectURL)
        let betaURL = try WorkflowLibraryStore.createWorkflow(beta, in: projectURL)

        XCTAssertEqual(alphaURL.deletingLastPathComponent().lastPathComponent, "Workflows")
        XCTAssertEqual(alphaURL.pathExtension, "lungfishflow")
        XCTAssertEqual(betaURL.pathExtension, "lungfishflow")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alphaURL.appendingPathComponent("graph.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alphaURL.appendingPathComponent("workflow.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alphaURL.appendingPathComponent("provenance.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alphaURL.appendingPathComponent("versions/history.json").path))

        let entries = try WorkflowLibraryStore.listWorkflows(in: projectURL)

        XCTAssertEqual(entries.map(\.name), ["Alpha Workflow", "Beta Workflow"])
        XCTAssertEqual(entries.map(\.version), ["1.2.0", "2.0.0"])
        XCTAssertEqual(entries.first?.description, "First workflow")
        XCTAssertEqual(try WorkflowLibraryStore.loadWorkflow(from: alphaURL).name, "Alpha Workflow")
    }

    func testDuplicateAndDeleteWorkflow() throws {
        let projectURL = try makeTemporaryProject()
        let source = WorkflowGraph(name: "VSP2 Import")
        let sourceURL = try WorkflowLibraryStore.createWorkflow(source, in: projectURL)

        let duplicateURL = try WorkflowLibraryStore.duplicateWorkflow(at: sourceURL, in: projectURL)
        let entriesAfterDuplicate = try WorkflowLibraryStore.listWorkflows(in: projectURL)

        XCTAssertEqual(entriesAfterDuplicate.map(\.name), ["VSP2 Import", "VSP2 Import Copy"])
        XCTAssertNotEqual(try WorkflowLibraryStore.loadWorkflow(from: sourceURL).id, try WorkflowLibraryStore.loadWorkflow(from: duplicateURL).id)

        try WorkflowLibraryStore.deleteWorkflow(at: sourceURL)

        let remaining = try WorkflowLibraryStore.listWorkflows(in: projectURL)
        XCTAssertEqual(remaining.map(\.name), ["VSP2 Import Copy"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testRepeatedSavesAppendVersionHistory() throws {
        let projectURL = try makeTemporaryProject()
        var graph = WorkflowGraph(name: "Versioned Workflow", version: "1.0.0")
        let bundleURL = try WorkflowLibraryStore.createWorkflow(graph, in: projectURL)

        graph.version = "1.1.0"
        try WorkflowLibraryStore.saveWorkflow(graph, to: bundleURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let historyURL = bundleURL.appendingPathComponent("versions/history.json")
        let history = try decoder.decode([WorkflowVersionHistoryEntryForTest].self, from: Data(contentsOf: historyURL))

        XCTAssertEqual(history.map(\.version), ["1.0.0", "1.1.0"])
    }

    private func makeTemporaryProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-workflow-library-\(UUID().uuidString)", isDirectory: true)
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return projectURL
    }
}

private struct WorkflowVersionHistoryEntryForTest: Decodable {
    let version: String
}
