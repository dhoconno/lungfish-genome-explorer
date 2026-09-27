import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class SequenceProcessingOutputNormalizerTests: XCTestCase {
    func testRestoresFASTAAndPreservesFullSourceProvenance() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("processed.fastq")
        try Data("@r1 description\nACGT\n+\n!I#J\n".utf8).write(to: input)
        let source = try sourceProvenance(input)
        let originalSidecar = try Data(contentsOf: ProvenanceRecorder.fileSidecarURL(for: input))
        let output = try await SequenceProcessingOutputNormalizer.normalize(outputURL: input, preferredFormat: .fasta)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), ">r1 description\nACGT\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        let normalized = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: output)?.envelope)
        XCTAssertEqual(normalized.argv, source.argv)
        XCTAssertEqual(normalized.options, source.options)
        XCTAssertEqual(normalized.runtimeIdentity, source.runtimeIdentity)
        XCTAssertEqual(normalized.stderr, source.stderr)
        XCTAssertEqual(Array(normalized.steps.dropLast()), source.steps)
        XCTAssertEqual(normalized.output?.path, output.path)
        let step = try XCTUnwrap(normalized.steps.last)
        XCTAssertEqual(step.toolName, SequenceProcessingOutputNormalizer.normalizationToolName)
        XCTAssertEqual(step.inputs.first?.checksumSHA256, try ProvenanceFileHasher.sha256(of: input))
        XCTAssertEqual(step.outputs.first?.checksumSHA256, try ProvenanceFileHasher.sha256(of: output))
        XCTAssertEqual(step.outputs.first?.fileSize, try ProvenanceFileHasher.fileSize(of: output))
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertNotNil(step.wallTimeSeconds)
        XCTAssertNotNil(step.runtimeIdentity)
        XCTAssertFalse(step.toolVersion.isEmpty)
        XCTAssertTrue(step.argv.contains(input.path))
        XCTAssertTrue(step.argv.contains(output.path))
        XCTAssertEqual(step.resolvedOptions["quality_policy"], .string("discard"))
        let snapshot = output.deletingLastPathComponent().appendingPathComponent("source-provenance.json")
        XCTAssertEqual(try Data(contentsOf: snapshot), originalSidecar)
        XCTAssertEqual(try Data(contentsOf: ProvenanceRecorder.fileSidecarURL(for: input)), originalSidecar)
    }

    func testMissingSourceProvenanceBlocksConversion() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("raw.fastq")
        try Data("@r\nAC\n+\nII\n".utf8).write(to: input)
        do {
            _ = try await SequenceProcessingOutputNormalizer.normalize(outputURL: input, preferredFormat: .fasta)
            XCTFail("Conversion requires provenance")
        } catch SequenceProcessingOutputNormalizerError.missingSourceProvenance { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["raw.fastq"])
    }

    func testChangedSourceBytesBlockConversion() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("raw.fastq")
        try Data("@r\nAC\n+\nII\n".utf8).write(to: input)
        _ = try sourceProvenance(input)
        try Data("@r\nGT\n+\nII\n".utf8).write(to: input)
        do {
            _ = try await SequenceProcessingOutputNormalizer.normalize(outputURL: input, preferredFormat: .fasta)
            XCTFail("Changed source checksum must fail")
        } catch SequenceProcessingOutputNormalizerError.sourceIntegrityMismatch { }
    }

    func testPreservesFASTQQualitiesAndNeverInventsQualitiesForFASTA() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (filename, body, preference) in [
            ("raw.fastq", "@r\nAC\n+\n!I\n", SequenceFormat.fastq),
            ("raw.fasta", ">r\nAC\n", .fastq),
            ("same.fasta", ">r\nAC\n", .fasta),
            ("report.tsv", "name\tcount\nr\t1\n", .fasta)
        ] {
            let input = root.appendingPathComponent(filename)
            try Data(body.utf8).write(to: input)
            let result = try await SequenceProcessingOutputNormalizer.normalize(outputURL: input, preferredFormat: preference)
            XCTAssertEqual(result, input)
            XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), body)
        }
    }

    func testRepeatedConversionsUseUniqueDirectoriesAndEmptyOutputsExist() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("empty.fastq")
        try Data().write(to: input)
        _ = try sourceProvenance(input)
        let first = try await SequenceProcessingOutputNormalizer.normalize(outputURL: input, preferredFormat: .fasta)
        let second = try await SequenceProcessingOutputNormalizer.normalize(outputURL: input, preferredFormat: .fasta)
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        XCTAssertEqual(try Data(contentsOf: first), Data())
        XCTAssertNotNil(ProvenanceRecorder.findProvenanceEnvelope(for: first))
    }

    func testPreparedBridgeLineageIsRecoveredFromCLIInputSidecar() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalFASTA = root.appendingPathComponent("original.fasta")
        try Data(">r1 original\nACGT\n".utf8).write(to: originalFASTA)
        let materialized = root.appendingPathComponent("materialized-inputs-fixture")
        let bridge = materialized.appendingPathComponent("synthetic.fastq")
        try await SequenceProcessingOutputNormalizer.prepareFASTQInput(inputURL: originalFASTA, outputURL: bridge)
        XCTAssertEqual(try String(contentsOf: bridge, encoding: .utf8), "@r1 original\nACGT\n+\nIIII\n")
        let receipt = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: bridge)?.envelope)
        XCTAssertEqual(receipt.steps.first?.inputs.first?.path, originalFASTA.path)
        XCTAssertEqual(receipt.steps.first?.resolvedOptions["quality_character"], .string("I"))
        XCTAssertEqual(receipt.steps.first?.exitStatus, 0)
        let output = root.appendingPathComponent("processed.fastq")
        try FileManager.default.copyItem(at: bridge, to: output)
        let argv = ["fixture-cli", "--input", bridge.path, "--output", output.path]
        let cliStep = ProvenanceStep(toolName: "fixture", toolVersion: "2", argv: argv,
            inputs: [try ProvenanceFileDescriptor.file(url: bridge, format: .fastq, role: .input)],
            outputs: [try ProvenanceFileDescriptor.file(url: output, format: .fastq, role: .output)], exitStatus: 0)
        let cli = try ProvenanceRunBuilder(workflowName: "lungfish fixture", workflowVersion: "1", toolName: "fixture", toolVersion: "2")
            .argv(argv).runtime(ProvenanceRuntimeIdentity()).input(bridge, format: .fastq).output(output, format: .fastq)
            .step(cliStep).complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(cli, toSidecar: ProvenanceRecorder.fileSidecarURL(for: output))
        let restored = try await SequenceProcessingOutputNormalizer.normalize(outputURL: output, preferredFormat: .fasta)
        try FileManager.default.removeItem(at: materialized)
        let final = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: restored)?.envelope)
        XCTAssertEqual(final.argv, argv)
        XCTAssertEqual(final.steps.map(\.toolName), [SequenceProcessingOutputNormalizer.inputPreparationToolName,
            "fixture", SequenceProcessingOutputNormalizer.normalizationToolName])
        XCTAssertEqual(final.steps[1].argv, argv)
        let bridgeStep = try XCTUnwrap(final.steps.first { $0.toolName == SequenceProcessingOutputNormalizer.inputPreparationToolName })
        XCTAssertEqual(bridgeStep.inputs.first?.path, originalFASTA.path)
        XCTAssertEqual(bridgeStep.inputs.first?.checksumSHA256, try ProvenanceFileHasher.sha256(of: originalFASTA))
        XCTAssertTrue(final.files.contains { $0.path == originalFASTA.path && $0.format == .fasta })
        let storedBridge = try XCTUnwrap(bridgeStep.outputs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedBridge.path))
        XCTAssertEqual(storedBridge.checksumSHA256, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: storedBridge.path)))
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), ">r1 original\nACGT\n")
    }

    func testUnmarkedInputSidecarsDoNotInjectUnrelatedSteps() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.fastq")
        let output = root.appendingPathComponent("output.fastq")
        try Data("@r\nAC\n+\nII\n".utf8).write(to: input)
        _ = try sourceProvenance(input)
        try FileManager.default.copyItem(at: input, to: output)
        let cli = try ProvenanceRunBuilder(workflowName: "lungfish fixture", workflowVersion: "1", toolName: "fixture", toolVersion: "2")
            .argv(["fixture", input.path, output.path]).runtime(ProvenanceRuntimeIdentity())
            .input(input, format: .fastq).output(output, format: .fastq)
            .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(cli, toSidecar: ProvenanceRecorder.fileSidecarURL(for: output))
        let restored = try await SequenceProcessingOutputNormalizer.normalize(outputURL: output, preferredFormat: .fasta)
        let final = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: restored)?.envelope)
        XCTAssertEqual(final.steps.count, 1)
        XCTAssertEqual(final.steps.first?.toolName, SequenceProcessingOutputNormalizer.normalizationToolName)
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("normalize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sourceProvenance(_ output: URL) throws -> ProvenanceEnvelope {
        let builder = try ProvenanceRunBuilder(workflowName: "lungfish fastq fixture", workflowVersion: "1",
            toolName: "fixture-tool", toolVersion: "2").argv(["lungfish", "fastq", "fixture", "--output", output.path])
            .runtime(ProvenanceRuntimeIdentity(condaEnvironment: "fixture-env"))
            .options(explicit: ["threads": .integer(2)], defaults: ["threads": .integer(1)], resolved: ["threads": .integer(2)])
            .output(output, format: .fastq)
        let envelope = try builder.complete(exitStatus: 0, stderr: "original diagnostic", startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: output))
        return envelope
    }
}
