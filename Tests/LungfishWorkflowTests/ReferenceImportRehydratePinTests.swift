// ReferenceImportRehydratePinTests.swift - Pins the rehydrate a reference import runs after the bundle is built
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// Pin P3 of ruling A48 F2. `rehydrateReferenceBundleProvenance` on the FASTA a FASTQ operation wrote
/// merges the source's steps with the bundle's wrapping steps, in that order, and rewrites only the
/// argv words that equal the source path (`FASTQOperationProvenanceRehydrator.swift:87-98`).
final class ReferenceImportRehydratePinTests: XCTestCase {
    func testMergedStepsAreTheSourcesThenTheWrappingStepsWithTheSourcePathRewritten() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceImportRehydratePinTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let execution = root.appendingPathComponent("execution", isDirectory: true)
        try FileManager.default.createDirectory(at: execution, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("reads.fastq")
        let raw = execution.appendingPathComponent("output.fastq")
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: input)
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: raw)
        let sourceArgv = ["fixture-tool", "--input", input.path, "--output", raw.path]
        let sourceStep = ProvenanceStep(
            toolName: "fixture-tool", toolVersion: "1", argv: sourceArgv, runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: [try descriptor(input, role: .input)], outputs: [try descriptor(raw, role: .output)],
            exitStatus: 0, wallTimeSeconds: 1
        )
        let source = try ProvenanceRunBuilder(
            workflowName: "lungfish fixture", workflowVersion: "1", toolName: "fixture-tool", toolVersion: "1"
        )
        .argv(sourceArgv).runtime(ProvenanceRuntimeIdentity()).input(input, format: .fastq)
        .output(raw, format: .fastq).step(sourceStep)
        .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(source, toSidecar: ProvenanceRecorder.fileSidecarURL(for: raw))
        let normalized = try await SequenceProcessingOutputNormalizer.normalize(outputURL: raw, preferredFormat: .fasta)
        let sourceSteps = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: normalized)?.envelope).steps

        let bundle = root.appendingPathComponent("Reference Sequences/result.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let final = bundle.appendingPathComponent("genome.fasta")
        try Data(">r\nACGT\n".utf8).write(to: final)
        try BundleManifest(
            formatVersion: "1.0", name: "result", identifier: "org.lungfish.import.fixture",
            source: SourceInfo(organism: "result", assembly: "result"),
            genome: GenomeInfo(
                path: "genome.fasta", indexPath: "genome.fasta.fai", totalLength: 4,
                chromosomes: [ChromosomeInfo(name: "r", length: 4, offset: 3, lineBases: 4, lineWidth: 5)]
            )
        ).save(to: bundle)
        let wrappingArgv = ["lungfish-cli", "import", "fasta", normalized.path, "--output-dir", root.path]
        let wrappingStep = ProvenanceStep(
            toolName: "lungfish import fasta", toolVersion: "1", argv: wrappingArgv,
            inputs: [try descriptor(normalized, role: .input)], outputs: [try descriptor(final, role: .output)],
            exitStatus: 0
        )
        let wrapping = try ProvenanceRunBuilder(
            workflowName: "lungfish import fasta", workflowVersion: "1", toolName: "lungfish import fasta", toolVersion: "1"
        )
        .argv(wrappingArgv).runtime(ProvenanceRuntimeIdentity()).input(normalized, format: .fasta)
        .output(final, format: .fasta).step(wrappingStep)
        .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(wrapping, to: bundle)

        try FASTQOperationProvenanceRehydrator().rehydrateReferenceBundleProvenance(
            sourceURL: normalized, referenceBundleURL: bundle
        )

        let merged = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle))
        XCTAssertEqual(merged.steps.map(\.toolName), sourceSteps.map(\.toolName) + ["lungfish import fasta"])
        XCTAssertEqual(merged.argv, sourceArgv)
        let wrapped = try XCTUnwrap(merged.steps.last)
        XCTAssertEqual(wrapped.argv, wrappingArgv)
        let replay = try XCTUnwrap(wrapped.durableReplayArgv)
        XCTAssertEqual(replay.count, wrappingArgv.count)
        for (index, word) in wrappingArgv.enumerated() where index != 3 {
            XCTAssertEqual(replay[index], word, "word \(index)")
        }
        XCTAssertNotEqual(replay[3], normalized.path)
        XCTAssertTrue(replay[3].hasPrefix(bundle.path + "/"), replay[3])
        XCTAssertTrue(FileManager.default.fileExists(atPath: replay[3]))
        XCTAssertFalse(wrapped.reproducibleCommand.contains(normalized.path))
        XCTAssertNotEqual(wrapped.inputs.first?.path, normalized.path)
    }

    private func descriptor(_ url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: url.path, checksumSHA256: try ProvenanceFileHasher.sha256(of: url),
            fileSize: try ProvenanceFileHasher.fileSize(of: url), role: role
        )
    }
}
