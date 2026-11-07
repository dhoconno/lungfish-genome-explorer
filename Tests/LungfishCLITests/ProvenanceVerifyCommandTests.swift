// ProvenanceVerifyCommandTests.swift - CLI tests for provenance verification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
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

    // MARK: A record with no signature (Phase 3.3 lane P3WORDS, row P3-PV)

    /// A record with no signature file is not a failed workflow. The command says that the record carries no signature, so
    /// there is nothing to verify, when Lungfish signs a record and what to do, and it exits with the input error code of
    /// the CLI exit-code contract (3), the code of a request the command cannot do with the file it was given.
    func testVerifyOfAnUnsignedRecordSaysItCarriesNoSignature() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data(#"{"name":"unsigned"}"#.utf8).write(to: provenanceURL, options: .atomic)

        let command = try ProvenanceCommand.VerifySubcommand.parse([provenanceURL.path])
        let run = await captureStandardError { try await command.run() }

        let words = run.stderr.lowercased()
        XCTAssertTrue(words.contains("carries no signature"), run.stderr)
        XCTAssertTrue(words.contains("nothing to verify"), run.stderr)
        XCTAssertTrue(run.stderr.contains("LUNGFISH_PROVENANCE_SIGNING_KEY_FILE"), run.stderr)
        XCTAssertTrue(run.stderr.contains("LUNGFISH_PROVENANCE_SIGNING_KEY "), run.stderr)
        XCTAssertTrue(words.contains("as the record is written"), run.stderr)
        XCTAssertTrue(run.stderr.contains(provenanceURL.path), run.stderr)
        XCTAssertFalse(run.stderr.contains("Workflow execution failed"), run.stderr)
        XCTAssertFalse(run.stderr.contains("Signature artifact is missing"), run.stderr)
        // UX SF3 (c): a person sent a record alone needs the path of the signature file that was not found.
        XCTAssertTrue(run.stderr.contains(provenanceURL.lastPathComponent + ".signature.json"), run.stderr)
        // UX SF3 (a): the words say what each variable holds. Fact W3: some records are never signed.
        XCTAssertTrue(words.contains("holds the path of a file"), run.stderr)
        XCTAssertTrue(words.contains("never signed"), run.stderr)
        XCTAssertEqual(Self.exitStatus(of: run.error), CLIExitCode.inputError.rawValue, "the exit status of an unsigned record")
    }

    /// The unsigned copy a Viral Recon run keeps in its results folder on purpose names the bundle whose signed record
    /// states that folder, so a person knows where to verify.
    func testVerifyOfTheUnsignedViralReconCopyNamesTheBundleThatHoldsTheSignedRecord() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = directory.appendingPathComponent("results", isDirectory: true)
        let bundle = directory.appendingPathComponent("viralrecon-run-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "nf-core/viralrecon", toolName: "nextflow", outputPath: results.path
        )
        let copyURL = results.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let bundleRecordURL = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try ProvenanceJSON.encoder.encode(envelope).write(to: copyURL, options: .atomic)
        try ProvenanceJSON.encoder.encode(envelope).write(to: bundleRecordURL, options: .atomic)
        _ = try LocalProvenanceSigningProvider(privateKey: "run-key").sign(provenanceURL: bundleRecordURL)

        let command = try ProvenanceCommand.VerifySubcommand.parse([results.path])
        let run = await captureStandardError { try await command.run() }

        let words = run.stderr.lowercased()
        XCTAssertTrue(words.contains("carries no signature"), run.stderr)
        XCTAssertTrue(words.contains("viral recon"), run.stderr)
        XCTAssertTrue(words.contains("on purpose"), run.stderr)
        XCTAssertTrue(run.stderr.contains(bundle.lastPathComponent), "the words name the run bundle\n\(run.stderr)")
        XCTAssertTrue(run.stderr.contains("lungfish-cli provenance verify"), run.stderr)
        // UX SF3 (b): the path in the command is quoted, so a bundle in `My Project.lungfish` pastes as one word.
        XCTAssertTrue(run.stderr.contains(bundle.lastPathComponent + "'"), run.stderr)
        XCTAssertEqual(Self.exitStatus(of: run.error), CLIExitCode.inputError.rawValue, "the exit status of the copy")
    }

    /// The run bundle's own record matches a Viral Recon run by name, but it is not the copy in the results folder, so it
    /// gets the words for an unsigned record and none about a copy kept on purpose (fact check W4).
    func testVerifyOfAnUnsignedRunBundleRecordDoesNotCallItTheViralReconCopy() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent(
            "nf-core-viralrecon.\(NFCoreRunBundleStore.directoryExtension)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let envelope = ProvenanceEnvelope.fixture(workflowName: "nf-core/viralrecon", toolName: "nextflow")
        let recordURL = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try ProvenanceJSON.encoder.encode(envelope).write(to: recordURL, options: .atomic)

        let command = try ProvenanceCommand.VerifySubcommand.parse([recordURL.path])
        let run = await captureStandardError { try await command.run() }

        let words = run.stderr.lowercased()
        XCTAssertTrue(words.contains("carries no signature"), run.stderr)
        XCTAssertFalse(words.contains("viral recon"), run.stderr)
        XCTAssertFalse(words.contains("on purpose"), run.stderr)
        XCTAssertEqual(Self.exitStatus(of: run.error), CLIExitCode.inputError.rawValue, "the exit status of the bundle's own record")
    }

    /// A signature file the person names with `--signature` that is not there is a different case from a record that
    /// carries no signature, so it keeps the words of the missing artifact.
    func testVerifyNamingAMissingSignatureFileKeepsTheArtifactWords() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data(#"{"name":"unsigned"}"#.utf8).write(to: provenanceURL, options: .atomic)
        let named = directory.appendingPathComponent("named.signature.json")

        let command = try ProvenanceCommand.VerifySubcommand.parse([provenanceURL.path, "--signature", named.path])
        let run = await captureStandardError { try await command.run() }

        XCTAssertTrue(run.error?.localizedDescription.contains("Signature artifact is missing") == true,
                      "\(String(describing: run.error)) \(run.stderr)")
        XCTAssertFalse(run.stderr.lowercased().contains("carries no signature"), run.stderr)
    }

    /// The exit status a command ends with: the code of a thrown `ExitCode`, or of a `CLIError` as the CLI's main maps it.
    private static func exitStatus(of error: Error?) -> Int32? {
        if let exit = error as? ExitCode { return exit.rawValue }
        if let cli = error as? CLIError { return cli.exitCode.rawValue }
        return nil
    }

    private func captureStandardError(_ operation: () async throws -> Void) async -> (stderr: String, error: Error?) {
        let pipe = Pipe()
        fflush(stderr)
        let originalStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        var thrown: Error?
        do {
            try await operation()
        } catch {
            thrown = error
        }
        fflush(stderr)
        dup2(originalStderr, STDERR_FILENO)
        close(originalStderr)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", thrown)
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
