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

    @Test("Step-only multi-step workflow chooses terminal output as primary")
    func stepOnlyWorkflowChoosesTerminalOutputAsPrimary() throws {
        let intermediate = ProvenanceFileDescriptor(
            path: "trimmed.fastq",
            checksumSHA256: String(repeating: "a", count: 64),
            fileSize: 12,
            role: .output
        )
        let intermediateInput = ProvenanceFileDescriptor(
            path: "trimmed.fastq",
            checksumSHA256: String(repeating: "a", count: 64),
            fileSize: 12,
            role: .input
        )
        let final = ProvenanceFileDescriptor(
            path: "aligned.bam",
            checksumSHA256: String(repeating: "b", count: 64),
            fileSize: 24,
            role: .output
        )
        let builder = ProvenanceRunBuilder(
            workflowName: "fastq.map.minimap2",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "workflow", "run"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(
            ProvenanceStep(
                toolName: "fastp",
                toolVersion: "0.24.1",
                argv: ["fastp", "-o", "trimmed.fastq"],
                outputs: [intermediate],
                exitStatus: 0
            )
        )
        .step(
            ProvenanceStep(
                toolName: "minimap2",
                toolVersion: "2.28",
                argv: ["minimap2", "reference.fasta", "trimmed.fastq"],
                inputs: [intermediateInput],
                outputs: [final],
                exitStatus: 0
            )
        )

        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 50),
            endedAt: Date(timeIntervalSince1970: 55)
        )

        #expect(envelope.output?.path == "aligned.bam")
        #expect(envelope.outputs.map(\.path) == ["trimmed.fastq", "aligned.bam"])
    }

    @Test("Successful path-only step output is rejected")
    func successfulPathOnlyStepOutputIsRejected() throws {
        let builder = ProvenanceRunBuilder(
            workflowName: "fastq.map.minimap2",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "workflow", "run"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(
            ProvenanceStep(
                toolName: "minimap2",
                toolVersion: "2.28",
                argv: ["minimap2", "reference.fasta", "reads.fastq"],
                outputs: [ProvenanceFileDescriptor(path: "aligned.bam", role: .output)],
                exitStatus: 0
            )
        )

        #expect(throws: ProvenanceBuilderError.incompleteFileDescriptor("aligned.bam")) {
            _ = try builder.complete(
                exitStatus: 0,
                startedAt: Date(timeIntervalSince1970: 56),
                endedAt: Date(timeIntervalSince1970: 57)
            )
        }
        #expect(
            ProvenanceBuilderError
                .incompleteFileDescriptor("aligned.bam")
                .errorDescription?
                .contains("aligned.bam") == true
        )
    }

    @Test("Successful path-only step input is rejected")
    func successfulPathOnlyStepInputIsRejected() throws {
        let output = ProvenanceFileDescriptor(
            path: "aligned.bam",
            checksumSHA256: String(repeating: "b", count: 64),
            fileSize: 24,
            role: .output
        )
        let builder = ProvenanceRunBuilder(
            workflowName: "fastq.map.minimap2",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "workflow", "run"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(
            ProvenanceStep(
                toolName: "minimap2",
                toolVersion: "2.28",
                argv: ["minimap2", "reference.fasta", "reads.fastq"],
                inputs: [ProvenanceFileDescriptor(path: "reads.fastq", role: .input)],
                outputs: [output],
                exitStatus: 0
            )
        )

        #expect(throws: ProvenanceBuilderError.incompleteFileDescriptor("reads.fastq")) {
            _ = try builder.complete(
                exitStatus: 0,
                startedAt: Date(timeIntervalSince1970: 57),
                endedAt: Date(timeIntervalSince1970: 58)
            )
        }
    }

    @Test("Successful hidden incomplete step output is rejected")
    func successfulHiddenIncompleteStepOutputIsRejected() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("aligned.bam")
        try Data("complete-bam".utf8).write(to: outputURL, options: .atomic)

        let builder = try ProvenanceRunBuilder(
            workflowName: "fastq.map.minimap2",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "workflow", "run"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .output(outputURL, format: .bam, role: .output)
        .step(
            ProvenanceStep(
                toolName: "minimap2",
                toolVersion: "2.28",
                argv: ["minimap2", "reference.fasta", "reads.fastq"],
                outputs: [ProvenanceFileDescriptor(path: outputURL.path, role: .output)],
                exitStatus: 0
            )
        )

        #expect(throws: ProvenanceBuilderError.incompleteFileDescriptor(outputURL.path)) {
            _ = try builder.complete(
                exitStatus: 0,
                startedAt: Date(timeIntervalSince1970: 58),
                endedAt: Date(timeIntervalSince1970: 59)
            )
        }
    }

    @Test("Repeated step output paths keep final metadata")
    func repeatedStepOutputPathsKeepFinalMetadata() throws {
        let early = ProvenanceFileDescriptor(
            path: "aligned.bam",
            checksumSHA256: String(repeating: "1", count: 64),
            fileSize: 10,
            role: .output
        )
        let final = ProvenanceFileDescriptor(
            path: "aligned.bam",
            checksumSHA256: String(repeating: "2", count: 64),
            fileSize: 20,
            role: .output
        )
        let builder = ProvenanceRunBuilder(
            workflowName: "fastq.map.minimap2",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "workflow", "run"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(
            ProvenanceStep(
                toolName: "samtools",
                toolVersion: "1.20",
                argv: ["samtools", "sort", "-o", "aligned.bam"],
                outputs: [early],
                exitStatus: 0
            )
        )
        .step(
            ProvenanceStep(
                toolName: "samtools",
                toolVersion: "1.20",
                argv: ["samtools", "index", "aligned.bam"],
                inputs: [
                    ProvenanceFileDescriptor(
                        path: "aligned.bam",
                        checksumSHA256: String(repeating: "1", count: 64),
                        fileSize: 10,
                        role: .input
                    )
                ],
                outputs: [final],
                exitStatus: 0
            )
        )

        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 59),
            endedAt: Date(timeIntervalSince1970: 60)
        )
        let output = try #require(envelope.outputs.first { $0.path == "aligned.bam" })
        let fileOutput = try #require(envelope.files.first { $0.path == "aligned.bam" && $0.role == .output })

        #expect(envelope.outputs.count == 1)
        #expect(output.checksumSHA256 == String(repeating: "2", count: 64))
        #expect(output.fileSize == 20)
        #expect(fileOutput.checksumSHA256 == String(repeating: "2", count: 64))
        #expect(fileOutput.fileSize == 20)
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

    @Test("Invalid time range is rejected with workflow context")
    func invalidTimeRangeIsRejected() throws {
        let builder = ProvenanceRunBuilder(
            workflowName: "fastq.trim.fastp",
            workflowVersion: "2026.05",
            toolName: "fastp",
            toolVersion: "0.24.1"
        )
        .argv(["fastp", "-o", "result.fastq"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(
            ProvenanceStep(
                toolName: "fastp",
                toolVersion: "0.24.1",
                argv: ["fastp", "-o", "result.fastq"],
                outputs: [ProvenanceFileDescriptor(path: "result.fastq", role: .output)],
                exitStatus: 0
            )
        )

        #expect(throws: ProvenanceBuilderError.invalidTimeRange("fastq.trim.fastp")) {
            _ = try builder.complete(
                exitStatus: 0,
                startedAt: Date(timeIntervalSince1970: 90),
                endedAt: Date(timeIntervalSince1970: 80)
            )
        }
        #expect(
            ProvenanceBuilderError
                .invalidTimeRange("fastq.trim.fastp")
                .errorDescription?
                .contains("fastq.trim.fastp") == true
        )
    }

    @Test("Nil and empty stderr are omitted")
    func nilAndEmptyStderrAreOmitted() throws {
        let nilEnvelope = try successfulEnvelope(stderr: nil)
        let emptyEnvelope = try successfulEnvelope(stderr: "")

        #expect(nilEnvelope.stderr == nil)
        #expect(emptyEnvelope.stderr == nil)
    }

    @Test("Short stderr is preserved")
    func shortStderrIsPreserved() throws {
        let envelope = try successfulEnvelope(stderr: "fastp warning\n")

        #expect(envelope.stderr == "fastp warning\n")
    }

    @Test("Long stderr is truncated with marker")
    func longStderrIsTruncatedWithMarker() throws {
        let longStderr = String(repeating: "x", count: 10_241)
        let expected = String(repeating: "x", count: 10_240) + "\n... [truncated]"

        let envelope = try successfulEnvelope(stderr: longStderr)

        #expect(envelope.stderr == expected)
        #expect(envelope.stderr?.hasSuffix("\n... [truncated]") == true)
    }

    @Test("Writer replaces stale signature references for the same provider")
    func writerReplacesStaleSameProviderSignatureReferences() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staleLocalReference = ProvenanceSignatureReference(
            provider: ProvenanceSigningConfiguration.localProviderID,
            provenanceSHA256: String(repeating: "1", count: 64),
            signaturePath: "stale.signature.json",
            publicKeyPath: "stale.pub"
        )
        let otherProviderReference = ProvenanceSignatureReference(
            provider: "other-provider",
            provenanceSHA256: String(repeating: "2", count: 64),
            signaturePath: "other.signature.json",
            publicKeyPath: "other.pub"
        )
        let envelope = ProvenanceEnvelope
            .fixture()
            .replacingSignatures([staleLocalReference, otherProviderReference])
        let writer = ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "replace-provider-key")
        )

        let sidecarURL = try writer.write(envelope, to: directory)
        let decoded = try ProvenanceEnvelopeReader.decode(try Data(contentsOf: sidecarURL))
        let localReferences = decoded.signatures.filter { $0.provider == ProvenanceSigningConfiguration.localProviderID }

        #expect(localReferences.count == 1)
        #expect(localReferences.first?.signaturePath == "\(ProvenanceRecorder.provenanceFilename).signature.json")
        #expect(decoded.signatures.contains { $0.provider == "other-provider" })
    }

    @Test("Writer creates documented bundle provenance rollup and output sidecars")
    func writerCreatesDocumentedBundleProvenanceLayout() throws {
        let workingDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let bundleURL = workingDirectory.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let readsURL = bundleURL.appendingPathComponent("reads/chunk-1.fastq.gz")
        let reportURL = bundleURL.appendingPathComponent("reports/qc.json")
        let externalURL = workingDirectory.appendingPathComponent("external.fastq")
        try FileManager.default.createDirectory(
            at: readsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("@read\nACGT\n+\n!!!!\n".utf8).write(to: readsURL, options: .atomic)
        try Data(#"{"reads":1}"#.utf8).write(to: reportURL, options: .atomic)
        try Data("@external\nAC\n+\n!!\n".utf8).write(to: externalURL, options: .atomic)

        let envelope = try ProvenanceRunBuilder(
            workflowName: "fastq.import.bundle",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish", "fastq", "import-ont", "--input", readsURL.path])
        .output(readsURL, format: .fastq, role: .output)
        .output(reportURL, format: .json, role: .output)
        .output(externalURL, format: .fastq, role: .output)
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 20),
            endedAt: Date(timeIntervalSince1970: 22)
        )

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)

        let rootSidecarURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let rollupURL = bundleURL
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent("bundle.lungfish-provenance.json")
        let readsSidecarURL = bundleURL
            .appendingPathComponent("provenance/reads", isDirectory: true)
            .appendingPathComponent("chunk-1.fastq.gz.lungfish-provenance.json")
        let reportSidecarURL = bundleURL
            .appendingPathComponent("provenance/reports", isDirectory: true)
            .appendingPathComponent("qc.json.lungfish-provenance.json")
        let externalSidecarURL = bundleURL
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent("external.fastq.lungfish-provenance.json")

        #expect(FileManager.default.fileExists(atPath: rootSidecarURL.path))
        #expect(FileManager.default.fileExists(atPath: rollupURL.path))
        #expect(FileManager.default.fileExists(atPath: readsSidecarURL.path))
        #expect(FileManager.default.fileExists(atPath: reportSidecarURL.path))
        #expect(!FileManager.default.fileExists(atPath: externalSidecarURL.path))

        let rollup = try ProvenanceEnvelopeReader.decode(try Data(contentsOf: rollupURL))
        let readsSidecar = try ProvenanceEnvelopeReader.decode(try Data(contentsOf: readsSidecarURL))
        let reportSidecar = try ProvenanceEnvelopeReader.decode(try Data(contentsOf: reportSidecarURL))

        #expect(rollup.outputs.map(\.path) == [readsURL.path, reportURL.path])
        #expect(rollup.output?.path == readsURL.path)
        #expect(!rollup.outputs.contains { $0.path == externalURL.path })
        #expect(readsSidecar.output?.path == readsURL.path)
        #expect(readsSidecar.outputs.map(\.path) == [readsURL.path])
        #expect(reportSidecar.output?.path == reportURL.path)
        #expect(reportSidecar.outputs.map(\.path) == [reportURL.path])
    }

    @Test("Writer bundle sidecars keep final metadata for repeated output paths")
    func writerBundleSidecarsKeepFinalMetadataForRepeatedOutputPaths() throws {
        let workingDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let bundleURL = workingDirectory.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let outputURL = bundleURL.appendingPathComponent("aligned.bam")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("final bam".utf8).write(to: outputURL, options: .atomic)

        let early = ProvenanceFileDescriptor(
            path: outputURL.path,
            checksumSHA256: String(repeating: "1", count: 64),
            fileSize: 10,
            role: .output
        )
        let final = ProvenanceFileDescriptor(
            path: outputURL.path,
            checksumSHA256: String(repeating: "2", count: 64),
            fileSize: 20,
            role: .output
        )
        let envelope = try ProvenanceRunBuilder(
            workflowName: "fastq.map.minimap2",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "workflow", "run"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(
            ProvenanceStep(
                toolName: "samtools",
                toolVersion: "1.20",
                argv: ["samtools", "sort", "-o", outputURL.path],
                outputs: [early],
                exitStatus: 0
            )
        )
        .step(
            ProvenanceStep(
                toolName: "samtools",
                toolVersion: "1.20",
                argv: ["samtools", "index", outputURL.path],
                inputs: [early.withRole(.input)],
                outputs: [final],
                exitStatus: 0
            )
        )
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 59),
            endedAt: Date(timeIntervalSince1970: 60)
        )

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)

        let rollupURL = bundleURL
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent("bundle.lungfish-provenance.json")
        let outputSidecarURL = bundleURL
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent("aligned.bam.lungfish-provenance.json")
        let rollup = try ProvenanceEnvelopeReader.decode(try Data(contentsOf: rollupURL))
        let outputSidecar = try ProvenanceEnvelopeReader.decode(try Data(contentsOf: outputSidecarURL))
        let rollupOutput = try #require(rollup.outputs.first { $0.path == outputURL.path })

        #expect(rollup.output?.checksumSHA256 == String(repeating: "2", count: 64))
        #expect(rollup.output?.fileSize == 20)
        #expect(rollupOutput.checksumSHA256 == String(repeating: "2", count: 64))
        #expect(rollupOutput.fileSize == 20)
        #expect(outputSidecar.output?.checksumSHA256 == String(repeating: "2", count: 64))
        #expect(outputSidecar.output?.fileSize == 20)
    }

    @Test("Writer bundle rollup replaces stale primary output metadata")
    func writerBundleRollupReplacesStalePrimaryOutputMetadata() throws {
        let workingDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let bundleURL = workingDirectory.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let outputURL = bundleURL.appendingPathComponent("aligned.bam")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("final bam".utf8).write(to: outputURL, options: .atomic)

        let early = ProvenanceFileDescriptor(
            path: outputURL.path,
            checksumSHA256: String(repeating: "1", count: 64),
            fileSize: 10,
            role: .output
        )
        let final = ProvenanceFileDescriptor(
            path: outputURL.path,
            checksumSHA256: String(repeating: "2", count: 64),
            fileSize: 20,
            role: .output
        )
        let envelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 60),
            workflowName: "fastq.map.minimap2",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05",
            argv: ["lungfish-cli", "workflow", "run"],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [early],
            output: early,
            outputs: [final],
            steps: [
                ProvenanceStep(
                    toolName: "samtools",
                    toolVersion: "1.20",
                    argv: ["samtools", "sort", "-o", outputURL.path],
                    outputs: [early],
                    exitStatus: 0
                ),
                ProvenanceStep(
                    toolName: "samtools",
                    toolVersion: "1.20",
                    argv: ["samtools", "index", outputURL.path],
                    inputs: [early.withRole(.input)],
                    outputs: [final],
                    exitStatus: 0
                )
            ],
            wallTimeSeconds: 1,
            exitStatus: 0
        )

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)

        let rollupURL = bundleURL
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent("bundle.lungfish-provenance.json")
        let rollup = try ProvenanceEnvelopeReader.decode(try Data(contentsOf: rollupURL))

        #expect(rollup.output?.checksumSHA256 == String(repeating: "2", count: 64))
        #expect(rollup.output?.fileSize == 20)
    }

    @Test("Recorder finds provenance when selected output is a bundle directory")
    func recorderFindsBundleDirectoryProvenance() throws {
        let workingDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let bundleURL = workingDirectory.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let readsURL = bundleURL.appendingPathComponent("reads.fastq.gz")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("@read\nACGT\n+\n!!!!\n".utf8).write(to: readsURL, options: .atomic)

        let envelope = try ProvenanceRunBuilder(
            workflowName: "fastq.import.bundle",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish", "fastq", "import-ont", "--output", bundleURL.path])
        .output(readsURL, format: .fastq, role: .output)
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 20),
            endedAt: Date(timeIntervalSince1970: 22)
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)

        let run = ProvenanceRecorder.findProvenance(forFile: bundleURL)

        #expect(run?.name == "fastq.import.bundle")
        #expect(run?.allOutputFiles.contains { $0.path == readsURL.path } == true)
    }

    @Test("Recorder rejects unrelated parent provenance for directories without sidecars")
    func recorderRejectsUnrelatedParentProvenanceForDirectorySelection() throws {
        let workingDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let unrelatedOutputURL = workingDirectory.appendingPathComponent("unrelated.fastq")
        let selectedDirectoryURL = workingDirectory.appendingPathComponent("folder-without-provenance", isDirectory: true)
        try Data("@read\nACGT\n+\n!!!!\n".utf8).write(to: unrelatedOutputURL, options: .atomic)
        try FileManager.default.createDirectory(at: selectedDirectoryURL, withIntermediateDirectories: true)

        let envelope = try ProvenanceRunBuilder(
            workflowName: "unrelated.output",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish", "convert", unrelatedOutputURL.path])
        .output(unrelatedOutputURL, format: .fastq, role: .output)
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 20),
            endedAt: Date(timeIntervalSince1970: 22)
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: workingDirectory)

        let run = ProvenanceRecorder.findProvenance(forFile: selectedDirectoryURL)

        #expect(run == nil)
    }

    @Test("Recorder does not match unrelated sibling outputs by filename")
    func recorderDoesNotMatchUnrelatedSiblingOutputsByFilename() throws {
        let workingDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let producedDirectory = workingDirectory.appendingPathComponent("produced", isDirectory: true)
        let selectedDirectory = workingDirectory.appendingPathComponent("selected", isDirectory: true)
        let producedURL = producedDirectory.appendingPathComponent("sample.sorted.bam")
        let selectedURL = selectedDirectory.appendingPathComponent("sample.sorted.bam")
        try FileManager.default.createDirectory(at: producedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        try Data("produced".utf8).write(to: producedURL, options: .atomic)
        try Data("selected".utf8).write(to: selectedURL, options: .atomic)

        let envelope = try ProvenanceRunBuilder(
            workflowName: "map.minimap2",
            workflowVersion: "2026.05",
            toolName: "minimap2",
            toolVersion: "2.28"
        )
        .argv(["minimap2", "-o", producedURL.path])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .output(producedURL, format: .bam, role: .output)
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 20),
            endedAt: Date(timeIntervalSince1970: 21)
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: workingDirectory)

        let run = ProvenanceRecorder.findProvenance(forFile: selectedURL)

        #expect(run == nil)
    }

    private func successfulEnvelope(stderr: String?) throws -> ProvenanceEnvelope {
        let output = ProvenanceFileDescriptor(
            path: "result.fastq",
            checksumSHA256: String(repeating: "f", count: 64),
            fileSize: 12,
            role: .output
        )
        return try ProvenanceRunBuilder(
            workflowName: "fastq.trim.fastp",
            workflowVersion: "2026.05",
            toolName: "fastp",
            toolVersion: "0.24.1"
        )
        .argv(["fastp", "-o", "result.fastq"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(
            ProvenanceStep(
                toolName: "fastp",
                toolVersion: "0.24.1",
                argv: ["fastp", "-o", "result.fastq"],
                outputs: [output],
                exitStatus: 0
            )
        )
        .complete(
            exitStatus: 0,
            stderr: stderr,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101)
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-provenance-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
