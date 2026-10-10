import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Adapts FASTA only at the FASTQ-only demultiplexer boundary, retaining each
/// transformation's provenance and publishing quality-free sequence bundles.
enum FastqDemultiplexSequenceFormat {
    struct PreparedInput {
        let url: URL
        let steps: [ProvenanceStep]
    }

    static func prepareFASTA(inputURL: URL, outputDirectory: URL) async throws -> PreparedInput {
        let directory = outputDirectory.appendingPathComponent("execution-inputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let materializationClock = ProvenanceRunClock()
        let resolved = try await CLISequenceInputMaterialization.resolveExecutionInputs(
            for: [inputURL], tempDirectory: directory,
            materializer: FASTQCLIMaterializer(runner: .shared), operationName: "demultiplex"
        )
        guard let fasta = resolved.inputURLs.first else { throw CLIError.formatDetectionFailed(path: inputURL.path) }
        let materializationSteps = try CLISequenceInputMaterialization.materializationProvenanceSteps(
            workflowVersion: WorkflowRun.currentAppVersion, originalInputURLs: [inputURL],
            executionInputURLs: [fasta], startedAt: materializationClock.startedAt, endedAt: materializationClock.now
        )
        let bridge = directory.appendingPathComponent("input.fastq")
        try await SequenceProcessingOutputNormalizer.prepareFASTQInput(inputURL: fasta, outputURL: bridge)
        guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: bridge)) else {
            throw ProvenanceRehydrationError.missingSourceProvenance(bridge.path)
        }
        return PreparedInput(url: bridge, steps: materializationSteps + envelope.steps)
    }

    /// Move tool bytes before provenance publication so the final descriptors refer
    /// to retained paths, and primary-sequence discovery cannot select a FASTQ preview.
    static func retainToolPayload(in bundleURL: URL) throws -> URL {
        let fm = FileManager.default
        let candidates = try fm.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)
            .filter { FASTQBundle.isFASTQFileURL($0) }
        guard let payload = candidates.first(where: { $0.lastPathComponent != "preview.fastq" }) else {
            throw CLIError.conversionFailed(reason: "Missing materialized demultiplex payload in \(bundleURL.path)")
        }
        let archive = bundleURL.appendingPathComponent("tool-output", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        for file in candidates {
            try fm.moveItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))
        }
        return archive.appendingPathComponent(payload.lastPathComponent)
    }

    static func publishFASTA(bundleURL: URL, toolPayload: URL, toolName: String, toolVersion: String) async throws -> ProvenanceEnvelope {
        let fasta = try await SequenceProcessingOutputNormalizer.normalize(outputURL: toolPayload, preferredFormat: .fasta)
        let relativePayload = CanonicalFilePath.relativePath(of: fasta, within: bundleURL)
            ?? String(fasta.path.dropFirst(bundleURL.path.count + 1))
        let statistics = try await SyntheticFASTQBridge.placeholderStatistics(fromFASTQ: toolPayload)
        let operation = FASTQDerivativeOperation(kind: .demultiplex, toolUsed: toolName, toolVersion: toolVersion)
        let manifest = FASTQDerivedBundleManifest(
            name: bundleURL.deletingPathExtension().lastPathComponent,
            parentBundleRelativePath: ".", rootBundleRelativePath: ".", rootFASTQFilename: relativePayload,
            payload: .fullFASTA(fastaFilename: relativePayload), lineage: [operation], operation: operation,
            cachedStatistics: statistics, pairingMode: nil, sequenceFormat: .fasta,
            payloadChecksums: PayloadChecksum(checksums: [relativePayload: try ProvenanceFileHasher.sha256(of: fasta)])
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        guard let normalized = ProvenanceRecorder.findProvenanceEnvelope(for: fasta)?.envelope else {
            throw SequenceProcessingOutputNormalizerError.missingSourceProvenance(fasta)
        }
        let manifestDescriptor = try ProvenanceFileDescriptor.file(
            url: FASTQBundle.derivedManifestURL(in: bundleURL), format: .json, role: .output
        )
        let published = merge(base: normalized, additions: [], extraFiles: [manifestDescriptor])
        try ProvenanceWriter(signingProvider: nil).write(published, to: bundleURL)
        return published
    }

    static func publishDirectoryProvenance(_ directory: URL, bundles: [ProvenanceEnvelope]) throws {
        guard let original = ProvenanceRecorder.loadEnvelope(from: directory) else {
            throw SequenceProcessingOutputNormalizerError.missingSourceProvenance(directory)
        }
        let merged = merge(base: original, additions: bundles, extraFiles: [])
        try ProvenanceWriter(signingProvider: nil).write(merged, to: directory)
    }

    private static func merge(
        base: ProvenanceEnvelope, additions: [ProvenanceEnvelope], extraFiles: [ProvenanceFileDescriptor]
    ) -> ProvenanceEnvelope {
        var fileKeys = Set<String>()
        let files = (base.files + additions.flatMap(\.files) + extraFiles).filter {
            fileKeys.insert("\($0.path)|\($0.role.rawValue)").inserted
        }
        var outputPaths = Set<String>()
        let outputs = (base.outputs + additions.flatMap(\.outputs) + extraFiles).filter {
            outputPaths.insert($0.path).inserted
        }
        var stepIDs = Set<UUID>()
        let steps = (base.steps + additions.flatMap(\.steps)).filter { stepIDs.insert($0.id).inserted }
        return ProvenanceEnvelope(
            schemaVersion: base.schemaVersion, id: base.id, createdAt: base.createdAt,
            workflowName: base.workflowName, workflowVersion: base.workflowVersion,
            toolName: base.toolName, toolVersion: base.toolVersion,
            githubReleaseVersion: base.githubReleaseVersion, tool: base.tool, argv: base.argv,
            durableReplayArgv: base.durableReplayArgv, reproducibleCommand: base.reproducibleCommand,
            options: base.options, runtimeIdentity: base.runtimeIdentity, files: files,
            output: additions.first?.output ?? base.output, outputs: outputs, steps: steps,
            wallTimeSeconds: base.wallTimeSeconds, exitStatus: base.exitStatus, stderr: base.stderr,
            signatures: [], status: base.status, legacyWorkflowRun: base.legacyRun
        )
    }
}
