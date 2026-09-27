import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class NormalizedSequenceProvenanceTests: XCTestCase {
    func testImportRetainsScientificIntermediatesWithoutCopyingExternalReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("normalized-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let execution = root.appendingPathComponent("execution")
        let materialized = root.appendingPathComponent("materialized-inputs-fixture")
        try FileManager.default.createDirectory(at: execution, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materialized, withIntermediateDirectories: true)
        let bridge = materialized.appendingPathComponent("input.fastq")
        let raw = execution.appendingPathComponent("output.fastq")
        let reference = root.appendingPathComponent("external-reference.fasta")
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: bridge)
        try FileManager.default.copyItem(at: bridge, to: raw)
        try Data(">reference\nACGT\n".utf8).write(to: reference)
        let sourceArgv = ["fixture-tool", "--input", bridge.path, "--reference", reference.path, "--output", raw.path]
        let sourceStep = ProvenanceStep(toolName: "fixture-tool", toolVersion: "1", argv: sourceArgv,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: [try descriptor(bridge, role: .input), try descriptor(reference, role: .input)],
            outputs: [try descriptor(raw, role: .output)], exitStatus: 0, wallTimeSeconds: 1)
        let source = try ProvenanceRunBuilder(workflowName: "lungfish fixture", workflowVersion: "1", toolName: "fixture-tool", toolVersion: "1")
            .argv(sourceArgv).runtime(ProvenanceRuntimeIdentity()).input(bridge, format: .fastq)
            .input(reference, format: .fasta).output(raw, format: .fastq).step(sourceStep)
            .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(source, toSidecar: ProvenanceRecorder.fileSidecarURL(for: raw))
        let normalized = try await SequenceProcessingOutputNormalizer.normalize(outputURL: raw, preferredFormat: .fasta)
        // Grouped output must already survive bridge cleanup, before any GUI import.
        try FileManager.default.removeItem(at: materialized)
        let grouped = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: normalized)?.envelope)
        let retainedBridge = try XCTUnwrap(grouped.steps.first?.inputs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedBridge.path))
        XCTAssertEqual(grouped.steps.first?.argv, sourceArgv)

        let bundle = root.appendingPathComponent("result.lungfishref")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let final = bundle.appendingPathComponent("genome.fasta")
        // Different FASTA wrapping models an importer changing serialized bytes.
        try Data(">r\nAC\nGT\n".utf8).write(to: final)
        try BundleManifest(formatVersion: "1.0", name: "Fixture", identifier: "test.normalized",
            source: SourceInfo(organism: "Fixture", assembly: "fixture"),
            genome: GenomeInfo(path: "genome.fasta", indexPath: "genome.fasta.fai", totalLength: 4,
                chromosomes: [ChromosomeInfo(name: "r", length: 4, offset: 3, lineBases: 2, lineWidth: 3)]))
            .save(to: bundle)
        let wrappingStep = ProvenanceStep(toolName: "fixture-wrap", toolVersion: "1", argv: ["wrap", normalized.path, final.path],
            inputs: [try descriptor(normalized, role: .input)], outputs: [try descriptor(final, role: .output)], exitStatus: 0)
        let wrapping = try ProvenanceRunBuilder(workflowName: "wrap", workflowVersion: "1", toolName: "fixture-wrap", toolVersion: "1")
            .argv(["wrap", normalized.path, final.path]).runtime(ProvenanceRuntimeIdentity())
            .input(normalized, format: .fasta).output(final, format: .fasta).step(wrappingStep)
            .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(wrapping, to: bundle)
        try FASTQOperationProvenanceRehydrator().rehydrateReferenceBundleProvenance(sourceURL: normalized, referenceBundleURL: bundle)
        try FileManager.default.removeItem(at: execution)
        let finalEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle))
        XCTAssertEqual(finalEnvelope.argv, sourceArgv)
        XCTAssertEqual(finalEnvelope.output?.path, final.path)
        XCTAssertTrue(finalEnvelope.steps.contains { $0.toolName == "fixture-wrap" })
        let conversion = try XCTUnwrap(finalEnvelope.steps.first { $0.toolName == SequenceProcessingOutputNormalizer.normalizationToolName })
        XCTAssertNotEqual(conversion.outputs.first?.path, final.path, "Conversion output remains the plain FASTA it actually produced")
        for file in finalEnvelope.steps.flatMap({ $0.inputs + $0.outputs }) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
            XCTAssertEqual(file.checksumSHA256, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: file.path)))
        }
        let external = try XCTUnwrap(finalEnvelope.steps.first?.inputs.first { $0.path == reference.path })
        XCTAssertEqual(external.path, reference.path)
        let retained = try FileManager.default.contentsOfDirectory(atPath: bundle.appendingPathComponent("provenance-intermediates").path)
        XCTAssertFalse(retained.contains { $0.contains("external-reference") })
    }

    private func descriptor(_ url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(path: url.path, checksumSHA256: try ProvenanceFileHasher.sha256(of: url),
            fileSize: try ProvenanceFileHasher.fileSize(of: url), role: role)
    }
}
