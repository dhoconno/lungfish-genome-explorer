// WorkflowBuilderRunCommandTests.swift - CLI tests for native Workflow Builder execution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

final class WorkflowBuilderRunCommandTests: XCTestCase {
    func testWorkflowBuilderRunParsesThroughTopLevelCLI() throws {
        let subcommands = WorkflowCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(subcommands.contains("builder-run"))

        let command = try WorkflowBuilderRunSubcommand.parse([
            "--workflow", "/tmp/workflow.lungfishflow",
            "--project", "/tmp/project.lungfish",
            "--run-directory", "/tmp/run",
            "--threads", "6",
            "--dry-run",
        ])
        XCTAssertEqual(command.workflow, "/tmp/workflow.lungfishflow")
        XCTAssertEqual(command.project, "/tmp/project.lungfish")
        XCTAssertEqual(command.runDirectory, "/tmp/run")
        XCTAssertEqual(command.threads, 6)
        XCTAssertTrue(command.dryRun)
    }

    func testWorkflowBuilderRunDryRunCompilesPlanJSON() async throws {
        let fixture = try makeFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Sample.lungfishfastq")
        _ = try WorkflowLibraryStore.saveWorkflow(graph, to: fixture.workflowBundleURL)

        let command = try WorkflowBuilderRunSubcommand.parse([
            "--workflow", fixture.workflowBundleURL.path,
            "--project", fixture.projectURL.path,
            "--run-directory", fixture.runDirectoryURL.path,
            "--dry-run",
        ])
        let output = try await captureStandardOutput {
            try await command.run()
        }

        guard let jsonStart = output.range(of: "{")?.lowerBound else {
            return XCTFail("Expected plan JSON, got: \(output)")
        }
        let plan = try JSONDecoder().decode(
            WorkflowBuilderExecutablePlan.self,
            from: Data(String(output[jsonStart...]).utf8)
        )
        XCTAssertEqual(plan.workflowName, "VSP2 FASTQ Workflow")
        XCTAssertEqual(plan.recipe.requiredInput, Recipe.InputRequirement.paired)
        XCTAssertEqual(plan.recipe.qualityBinning, QualityBinningScheme.illumina4)
        XCTAssertEqual(plan.steps.map { $0.operation }, [
            "fastp-dedup",
            "fastp-trim",
            "deacon-scrub",
            "fastp-merge",
            "seqkit-length-filter",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runDirectoryURL.appendingPathComponent("outputs").path))
    }

    private struct Fixture {
        let rootURL: URL
        let projectURL: URL
        let workflowBundleURL: URL
        let runDirectoryURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-builder-run-command-\(UUID().uuidString)", isDirectory: true)
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let inputBundleURL = projectURL.appendingPathComponent("Imports/Sample.lungfishfastq", isDirectory: true)
        let workflowBundleURL = projectURL.appendingPathComponent("Workflows/VSP2.lungfishflow", isDirectory: true)
        let runDirectoryURL = workflowBundleURL.appendingPathComponent("runs/dry-run", isDirectory: true)
        try FileManager.default.createDirectory(at: inputBundleURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\n!!!!\n".write(
            to: inputBundleURL.appendingPathComponent("Sample_R1.fastq"),
            atomically: true,
            encoding: .utf8
        )
        try "@r2\nTGCA\n+\n!!!!\n".write(
            to: inputBundleURL.appendingPathComponent("Sample_R2.fastq"),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            rootURL: root,
            projectURL: projectURL,
            workflowBundleURL: workflowBundleURL,
            runDirectoryURL: runDirectoryURL
        )
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
