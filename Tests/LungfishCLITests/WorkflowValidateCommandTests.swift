// WorkflowValidateCommandTests.swift - CLI tests for workflow validation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
@testable import LungfishCLI

final class WorkflowValidateCommandTests: XCTestCase {
    func testWorkflowValidateAcceptsNextflowWorkflowWithProcessBlock() async throws {
        let root = try makeTempDirectory()
        let workflow = root.appendingPathComponent("main.nf")
        try """
        nextflow.enable.dsl=2

        process HELLO {
          output:
          path "hello.txt"

          script:
          "echo hello > hello.txt"
        }
        """.write(to: workflow, atomically: true, encoding: .utf8)

        let command = try WorkflowValidateSubcommand.parse([workflow.path])
        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("Validating Nextflow workflow"), output)
        XCTAssertTrue(output.contains("Workflow syntax appears valid"), output)
    }

    func testWorkflowValidateRejectsPlainTextNextflowFile() async throws {
        let root = try makeTempDirectory()
        let workflow = root.appendingPathComponent("main.nf")
        try "this is a note, not a workflow\n".write(to: workflow, atomically: true, encoding: .utf8)

        let command = try WorkflowValidateSubcommand.parse([workflow.path])

        do {
            try await command.run()
            XCTFail("Expected invalid Nextflow workflow to throw")
        } catch let error as CLIError {
            guard case .validationFailed(let errors) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(errors.contains { $0.contains("Nextflow") }, "\(errors)")
        }
    }

    func testWorkflowValidateRejectsCommentOnlyNextflowMarker() async throws {
        let root = try makeTempDirectory()
        let workflow = root.appendingPathComponent("main.nf")
        try "// nextflow.enable.dsl=2\n".write(to: workflow, atomically: true, encoding: .utf8)

        let command = try WorkflowValidateSubcommand.parse([workflow.path])

        do {
            try await command.run()
            XCTFail("Expected comment-only Nextflow marker to throw")
        } catch let error as CLIError {
            guard case .validationFailed(let errors) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(errors.contains { $0.contains("Nextflow") }, "\(errors)")
        }
    }

    func testWorkflowValidateRejectsWrongOrderDelimiters() async throws {
        let root = try makeTempDirectory()
        let workflow = root.appendingPathComponent("main.nf")
        try "process BAD } {\n".write(to: workflow, atomically: true, encoding: .utf8)

        let command = try WorkflowValidateSubcommand.parse([workflow.path])

        do {
            try await command.run()
            XCTFail("Expected wrong-order delimiters to throw")
        } catch let error as CLIError {
            guard case .validationFailed(let errors) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(errors.contains { $0.contains("braces") }, "\(errors)")
        }
    }

    func testWorkflowValidateAcceptsSnakefileWithRule() async throws {
        let root = try makeTempDirectory()
        let workflow = root.appendingPathComponent("Snakefile")
        try """
        rule all:
            output:
                "result.txt"
            shell:
                "echo ok > {output}"
        """.write(to: workflow, atomically: true, encoding: .utf8)

        let command = try WorkflowValidateSubcommand.parse([workflow.path])
        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("Validating Snakemake workflow"), output)
        XCTAssertTrue(output.contains("Workflow syntax appears valid"), output)
    }

    func testWorkflowValidateRejectsEmptySnakefile() async throws {
        let root = try makeTempDirectory()
        let workflow = root.appendingPathComponent("Snakefile")
        try "".write(to: workflow, atomically: true, encoding: .utf8)

        let command = try WorkflowValidateSubcommand.parse([workflow.path])

        do {
            try await command.run()
            XCTFail("Expected empty Snakefile to throw")
        } catch let error as CLIError {
            guard case .validationFailed(let errors) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(errors.contains { $0.contains("empty") }, "\(errors)")
        }
    }

    func testWorkflowValidateQuietSuppressesSuccessOutput() async throws {
        let root = try makeTempDirectory()
        let workflow = root.appendingPathComponent("main.nf")
        try """
        nextflow.enable.dsl=2
        process HELLO {
          script:
          "echo hello"
        }
        """.write(to: workflow, atomically: true, encoding: .utf8)

        let command = try WorkflowValidateSubcommand.parse(["--quiet", workflow.path])
        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertEqual(output, "")
    }

    func testWorkflowValidateJSONFormatEmitsStructuredSuccess() async throws {
        let root = try makeTempDirectory()
        let workflow = root.appendingPathComponent("main.nf")
        try """
        nextflow.enable.dsl=2
        process HELLO {
          script:
          "echo hello"
        }
        """.write(to: workflow, atomically: true, encoding: .utf8)

        let command = try WorkflowValidateSubcommand.parse(["--format", "json", workflow.path])
        let output = try await captureStandardOutput {
            try await command.run()
        }
        let data = try XCTUnwrap(output.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["workflow"] as? String, workflow.path)
        XCTAssertEqual(json["engine"] as? String, "nextflow")
        XCTAssertEqual(json["valid"] as? Bool, true)
        XCTAssertEqual((json["errors"] as? [String])?.isEmpty, true)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-workflow-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
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
