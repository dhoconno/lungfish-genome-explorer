// ProvenanceVerifyCommandTests.swift - CLI tests for provenance verification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ProvenanceVerifyCommandTests: XCTestCase {
    func testProvenanceVerifyParsesThroughTopLevelCLI() throws {
        let subcommands = ProvenanceCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(subcommands.contains("verify"))

        let command = try ProvenanceCommand.VerifySubcommand.parse(["/tmp/.lungfish-provenance.json"])
        XCTAssertEqual(command.file, "/tmp/.lungfish-provenance.json")
    }

    func testProvenanceVerifyReportsValidSignature() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data(#"{"name":"cli-signed"}"#.utf8).write(to: provenanceURL, options: .atomic)
        _ = try LocalProvenanceSigningProvider(privateKey: "cli-key").sign(provenanceURL: provenanceURL)

        let command = try ProvenanceCommand.VerifySubcommand.parse([provenanceURL.path])
        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("Signature valid"), output)
        XCTAssertTrue(output.contains("lungfish-local-deterministic-v1"), output)
    }

    func testProvenanceVerifyThrowsForTamperedSignature() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data(#"{"name":"before"}"#.utf8).write(to: provenanceURL, options: .atomic)
        _ = try LocalProvenanceSigningProvider(privateKey: "cli-key").sign(provenanceURL: provenanceURL)
        try Data(#"{"name":"after"}"#.utf8).write(to: provenanceURL, options: .atomic)

        let command = try ProvenanceCommand.VerifySubcommand.parse([provenanceURL.path])

        do {
            try await command.run()
            XCTFail("Expected verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("digest mismatch"), error.localizedDescription)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-provenance-verify-\(UUID().uuidString)", isDirectory: true)
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
