// ProvenanceBuilderTests.swift - Tests for immutable provenance run builder and writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishWorkflow

@Suite("Provenance Builder")
struct ProvenanceBuilderTests {
    @Test("Builder writes canonical signed sidecar with argv options files runtime and signature reference")
    func builderWritesCanonicalSignedSidecar() throws {
        let workingDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let inputURL = workingDirectory.appendingPathComponent("reads.fastq")
        let outputURL = workingDirectory.appendingPathComponent("trimmed.fastq")
        try Data("@read\nACGT\n+\n!!!!\n".utf8).write(to: inputURL, options: .atomic)
        try Data("@read\nACG\n+\n!!!\n".utf8).write(to: outputURL, options: .atomic)

        let startedAt = Date(timeIntervalSince1970: 10)
        let endedAt = Date(timeIntervalSince1970: 12.5)
        let builder = try ProvenanceRunBuilder(
            workflowName: "fastq.trim.fastp",
            workflowVersion: "2026.05",
            toolName: "fastp",
            toolVersion: "0.24.1"
        )
        .argv(["fastp", "-i", inputURL.path, "-o", outputURL.path, "--thread", "4"])
        .options(
            explicit: ["thread": .integer(4)],
            defaults: ["qualified_quality_phred": .integer(15)],
            resolved: ["thread": .integer(4), "qualified_quality_phred": .integer(15)]
        )
        .input(inputURL, format: .fastq, role: .input)
        .output(outputURL, format: .fastq, role: .output)
        .runtime(
            ProvenanceRuntimeIdentity.fixture(
                executablePath: "/usr/local/bin/lungfish-cli",
                condaEnvironment: "lungfish-test"
            )
        )

        let envelope = try builder.complete(
            exitStatus: 0,
            stderr: "",
            startedAt: startedAt,
            endedAt: endedAt
        )
        let writer = ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "builder-test-key")
        )

        let expectedSidecarURL = workingDirectory
            .appendingPathComponent("bundle")
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let sidecarURL = try writer.write(envelope, to: workingDirectory.appendingPathComponent("bundle"))
        let decoded = try ProvenanceEnvelopeReader.decode(try Data(contentsOf: sidecarURL))
        let verification = try ProvenanceSignatureVerifier.verify(provenanceURL: sidecarURL)

        #expect(sidecarURL == expectedSidecarURL)
        #expect(decoded.workflowName == "fastq.trim.fastp")
        #expect(decoded.workflowVersion == "2026.05")
        #expect(decoded.toolName == "fastp")
        #expect(decoded.toolVersion == "0.24.1")
        #expect(decoded.argv == ["fastp", "-i", inputURL.path, "-o", outputURL.path, "--thread", "4"])
        #expect(decoded.reproducibleCommand == "fastp -i \(inputURL.path) -o \(outputURL.path) --thread 4")
        #expect(decoded.options.explicit["thread"] == .integer(4))
        #expect(decoded.options.defaults["qualified_quality_phred"] == .integer(15))
        #expect(decoded.options.resolvedDefaults["thread"] == .integer(4))
        #expect(decoded.runtimeIdentity.executablePath == "/usr/local/bin/lungfish-cli")
        #expect(decoded.runtimeIdentity.condaEnvironment == "lungfish-test")
        #expect(decoded.files.count == 2)
        #expect(decoded.files.first { $0.path == inputURL.path }?.checksumSHA256?.count == 64)
        #expect(decoded.files.first { $0.path == outputURL.path }?.fileSize == 16)
        #expect(decoded.output?.path == outputURL.path)
        #expect(decoded.outputs.map(\.path) == [outputURL.path])
        #expect(decoded.exitStatus == 0)
        #expect(decoded.wallTimeSeconds == 2.5)
        #expect(decoded.signatures.count == 1)
        #expect(decoded.signatures.first?.provider == ProvenanceSigningConfiguration.localProviderID)
        #expect(decoded.signatures.first?.signaturePath == "\(ProvenanceRecorder.provenanceFilename).signature.json")
        #expect(decoded.signatures.first?.publicKeyPath == "\(ProvenanceRecorder.provenanceFilename).pub")
        #expect(decoded.signatures.first?.provenanceSHA256 == verification.provenanceSHA256)
        #expect(verification.isValid)
    }

    @Test("Successful scientific output without argv is rejected")
    func successfulOutputWithoutArgvIsRejected() throws {
        let workingDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let outputURL = workingDirectory.appendingPathComponent("result.fastq")
        try Data("@read\nACGT\n+\n!!!!\n".utf8).write(to: outputURL, options: .atomic)

        let builder = try ProvenanceRunBuilder(
            workflowName: "fastq.trim.fastp",
            workflowVersion: "2026.05",
            toolName: "fastp",
            toolVersion: "0.24.1"
        )
        .output(outputURL, format: .fastq, role: .output)
        .runtime(ProvenanceRuntimeIdentity.fixture())

        #expect(throws: ProvenanceBuilderError.missingArgv("fastq.trim.fastp")) {
            _ = try builder.complete(
                exitStatus: 0,
                startedAt: Date(timeIntervalSince1970: 20),
                endedAt: Date(timeIntervalSince1970: 21)
            )
        }
        #expect(ProvenanceBuilderError.missingArgv("fastq.trim.fastp").errorDescription?.contains("fastq.trim.fastp") == true)
    }

    @Test("Successful argv run without output is rejected")
    func successfulRunWithoutOutputIsRejected() throws {
        let builder = ProvenanceRunBuilder(
            workflowName: "fastq.trim.fastp",
            workflowVersion: "2026.05",
            toolName: "fastp",
            toolVersion: "0.24.1"
        )
        .argv(["fastp", "--version"])
        .runtime(ProvenanceRuntimeIdentity.fixture())

        #expect(throws: ProvenanceBuilderError.missingOutput("fastq.trim.fastp")) {
            _ = try builder.complete(
                exitStatus: 0,
                startedAt: Date(timeIntervalSince1970: 30),
                endedAt: Date(timeIntervalSince1970: 31)
            )
        }
        #expect(ProvenanceBuilderError.missingOutput("fastq.trim.fastp").errorDescription?.contains("fastq.trim.fastp") == true)
    }

    @Test("Successful output without runtime identity is rejected")
    func successfulOutputWithoutRuntimeIsRejected() throws {
        let workingDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let outputURL = workingDirectory.appendingPathComponent("result.fastq")
        try Data("@read\nACGT\n+\n!!!!\n".utf8).write(to: outputURL, options: .atomic)

        let builder = try ProvenanceRunBuilder(
            workflowName: "fastq.trim.fastp",
            workflowVersion: "2026.05",
            toolName: "fastp",
            toolVersion: "0.24.1"
        )
        .argv(["fastp", "-o", outputURL.path])
        .output(outputURL, format: .fastq, role: .output)

        #expect(throws: ProvenanceBuilderError.missingRuntimeIdentity("fastq.trim.fastp")) {
            _ = try builder.complete(
                exitStatus: 0,
                startedAt: Date(timeIntervalSince1970: 40),
                endedAt: Date(timeIntervalSince1970: 41)
            )
        }
        #expect(
            ProvenanceBuilderError
                .missingRuntimeIdentity("fastq.trim.fastp")
                .errorDescription?
                .contains("fastq.trim.fastp") == true
        )
    }

    @Test("Unreadable input file is rejected while building descriptors")
    func unreadableInputFileIsRejected() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-missing-\(UUID().uuidString).fastq")
        let builder = ProvenanceRunBuilder(
            workflowName: "fastq.trim.fastp",
            workflowVersion: "2026.05",
            toolName: "fastp",
            toolVersion: "0.24.1"
        )

        #expect(throws: ProvenanceBuilderError.unreadableFile(missingURL.path)) {
            _ = try builder.input(missingURL, format: .fastq, role: .input)
        }
        #expect(ProvenanceBuilderError.unreadableFile(missingURL.path).errorDescription?.contains(missingURL.path) == true)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-provenance-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
