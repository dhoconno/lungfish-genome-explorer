import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class WorkflowConfigurationPanelTests: XCTestCase {
    func testStaleSchemaLoadCannotOverwriteActiveWorkflowSchema() async throws {
        let loader = DelayedWorkflowSchemaLoader()
        let panel = WorkflowConfigurationPanel(schemaLoader: { url in
            try await loader.load(url)
        })

        let slowWorkflow = try makeWorkflowDirectory(named: "workflow-A", includeSchema: true)
        let fastWorkflow = try makeWorkflowDirectory(named: "workflow-B", includeSchema: true)

        panel.setWorkflow(slowWorkflow)
        await loader.waitUntilStarted("workflow-A")

        panel.setWorkflow(fastWorkflow)
        await loader.waitUntilStarted("workflow-B")

        await loader.complete("workflow-B")
        try await waitUntil { panel.testingLoadedSchemaTitle == "workflow-B" }

        await loader.complete("workflow-A")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(panel.testingLoadedSchemaTitle, "workflow-B")
        XCTAssertEqual(panel.testingWorkflowPath, fastWorkflow.standardizedFileURL)
    }

    func testNoSchemaWorkflowCancelsPendingLoadAndHidesLoadingState() async throws {
        let loader = DelayedWorkflowSchemaLoader()
        let panel = WorkflowConfigurationPanel(schemaLoader: { url in
            try await loader.load(url)
        })

        let slowWorkflow = try makeWorkflowDirectory(named: "workflow-A", includeSchema: true)
        let noSchemaWorkflow = try makeWorkflowDirectory(named: "workflow-B", includeSchema: false)

        panel.setWorkflow(slowWorkflow)
        await loader.waitUntilStarted("workflow-A")
        XCTAssertFalse(try loadingSchemaLabel(in: panel).isHidden)

        panel.setWorkflow(noSchemaWorkflow)

        XCTAssertTrue(try loadingSchemaLabel(in: panel).isHidden)

        await loader.complete("workflow-A")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(panel.testingLoadedSchemaTitle)
        XCTAssertEqual(panel.testingWorkflowPath, noSchemaWorkflow.standardizedFileURL)
    }

    private func makeWorkflowDirectory(named name: String, includeSchema: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowConfigurationPanelTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let workflowURL = directory.appendingPathComponent("\(name).nf")
        try "nextflow.enable.dsl=2\n".write(to: workflowURL, atomically: true, encoding: .utf8)
        if includeSchema {
            try "{}\n".write(
                to: directory.appendingPathComponent("nextflow_schema.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return workflowURL
    }

    private func loadingSchemaLabel(in panel: WorkflowConfigurationPanel) throws -> NSTextField {
        guard let label = findLoadingSchemaLabel(in: panel.contentView) else {
            XCTFail("Loading schema label was not found")
            throw TestError.missingLoadingLabel
        }
        return label
    }

    private func findLoadingSchemaLabel(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let label = view as? NSTextField, label.stringValue == "Loading schema..." {
            return label
        }
        for subview in view.subviews {
            if let label = findLoadingSchemaLabel(in: subview) {
                return label
            }
        }
        return nil
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private enum TestError: Error {
    case missingLoadingLabel
}

private actor DelayedWorkflowSchemaLoader {
    private var continuations: [String: CheckedContinuation<UnifiedWorkflowSchema, Error>] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func load(_ url: URL) async throws -> UnifiedWorkflowSchema {
        let workflowName = url.deletingLastPathComponent().lastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            continuations[workflowName] = continuation
            waiters.removeValue(forKey: workflowName)?.forEach { $0.resume() }
        }
    }

    func waitUntilStarted(_ workflowName: String) async {
        if continuations[workflowName] != nil {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[workflowName, default: []].append(continuation)
        }
    }

    func complete(_ workflowName: String) {
        continuations.removeValue(forKey: workflowName)?.resume(returning: UnifiedWorkflowSchema(
            title: workflowName,
            description: nil,
            groups: []
        ))
    }
}
