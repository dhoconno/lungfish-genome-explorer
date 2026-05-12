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

    func testProvenanceVerifyReportsSignedMethodsExportArtifact() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let exportDirectory = directory.appendingPathComponent("methods-export", isDirectory: true)
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "signed.methods.source",
            toolName: "fastp",
            argv: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"]
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: sourceSidecarURL, options: .atomic)
        let bundle = try ProvenanceExporter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "methods-report-key")
        ).exportBundle(
            envelope,
            format: .methods,
            to: exportDirectory,
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: directory,
            exportArgv: [
                "lungfish", "provenance", "export",
                directory.path,
                "--format", "methods",
                "--output", exportDirectory.path,
            ]
        )

        let command = try ProvenanceCommand.VerifySubcommand.parse([bundle.primaryArtifactURL.path])
        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("Signature valid"), output)
        XCTAssertTrue(output.contains("methods.md.signature.json"), output)
    }

    func testProvenanceVerifyUsesExplicitArtifactsForSignedMethodsExportArtifact() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let exportDirectory = directory.appendingPathComponent("methods-export", isDirectory: true)
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "signed.methods.source",
            toolName: "fastp",
            argv: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"]
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: sourceSidecarURL, options: .atomic)
        let bundle = try ProvenanceExporter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "methods-report-key")
        ).exportBundle(
            envelope,
            format: .methods,
            to: exportDirectory,
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: directory,
            exportArgv: [
                "lungfish", "provenance", "export",
                directory.path,
                "--format", "methods",
                "--output", exportDirectory.path,
            ]
        )
        let defaultSignatureURL = ProvenanceSigningConfiguration.signatureURL(for: bundle.primaryArtifactURL)
        let defaultPublicKeyURL = ProvenanceSigningConfiguration.publicKeyURL(for: bundle.primaryArtifactURL)
        let customSignatureURL = directory.appendingPathComponent("custom-methods.signature.json")
        let customPublicKeyURL = directory.appendingPathComponent("custom-methods.pub")
        try FileManager.default.moveItem(at: defaultSignatureURL, to: customSignatureURL)
        try FileManager.default.moveItem(at: defaultPublicKeyURL, to: customPublicKeyURL)

        let command = try ProvenanceCommand.VerifySubcommand.parse([
            bundle.primaryArtifactURL.path,
            "--signature", customSignatureURL.path,
            "--public-key", customPublicKeyURL.path,
        ])
        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("Signature valid"), output)
        XCTAssertTrue(output.contains(customSignatureURL.path), output)
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
