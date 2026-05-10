// WorkflowDiffCommandTests.swift - CLI tests for workflow diff
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class WorkflowDiffCommandTests: XCTestCase {
    func testWorkflowDiffParsesThroughTopLevelCLI() throws {
        let subcommands = WorkflowCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(subcommands.contains("diff"))

        let command = try WorkflowDiffSubcommand.parse(["/tmp/a.lungfishflow", "/tmp/b.lungfishflow"])
        XCTAssertEqual(command.first, "/tmp/a.lungfishflow")
        XCTAssertEqual(command.second, "/tmp/b.lungfishflow")
    }

    func testWorkflowDiffTextOutputMentionsVersionAndNodeChanges() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("old.lungfishflow")
        let newURL = root.appendingPathComponent("new.lungfishflow")
        try writeWorkflow(name: "Pipeline", version: "1.0.0", includeQC: false, to: oldURL)
        try writeWorkflow(name: "Pipeline", version: "1.1.0", includeQC: true, to: newURL)

        let command = try WorkflowDiffSubcommand.parse([oldURL.path, newURL.path])
        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("Workflow diff"), output)
        XCTAssertTrue(output.contains("Version: 1.0.0 -> 1.1.0"), output)
        XCTAssertTrue(output.contains("Added nodes"), output)
        XCTAssertTrue(output.contains("QC"), output)
    }

    func testWorkflowDiffJSONOutputIsMachineReadable() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("old.lungfishflow")
        let newURL = root.appendingPathComponent("new.lungfishflow")
        try writeWorkflow(name: "Pipeline", version: "1.0.0", includeQC: false, to: oldURL)
        try writeWorkflow(name: "Pipeline", version: "1.0.1", includeQC: true, to: newURL)

        let command = try WorkflowDiffSubcommand.parse(["--format", "json", oldURL.path, newURL.path])
        let output = try await captureStandardOutput {
            try await command.run()
        }
        guard let jsonStart = output.range(of: "{")?.lowerBound else {
            XCTFail("Expected JSON output, got: \(output.debugDescription)")
            return
        }
        let jsonOutput = String(output[jsonStart...])
        let json = try JSONSerialization.jsonObject(with: Data(jsonOutput.utf8)) as? [String: Any]

        XCTAssertEqual(json?["fromVersion"] as? String, "1.0.0")
        XCTAssertEqual(json?["toVersion"] as? String, "1.0.1")
        XCTAssertEqual(json?["hasChanges"] as? Bool, true)
    }

    private func writeWorkflow(name: String, version: String, includeQC: Bool, to url: URL) throws {
        var graph = WorkflowGraph(name: name, version: version)
        _ = graph.addNode(type: .fastqInput, position: .zero, label: "Reads")
        if includeQC {
            _ = graph.addNode(type: .qualityControl, position: CGPoint(x: 200, y: 0), label: "QC")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(graph)
        try data.write(to: url, options: .atomic)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-workflow-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        do {
            try await operation()
            fflush(stdout)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
