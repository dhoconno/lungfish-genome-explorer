import Foundation
import LungfishIO

public enum SequenceProcessingOutputNormalizerError: Error, LocalizedError, Sendable {
    case missingSourceProvenance(URL)
    case sourceIntegrityMismatch(URL)

    public var errorDescription: String? {
        switch self {
        case .missingSourceProvenance(let url):
            return "Cannot restore FASTA output without source CLI provenance: \(url.path)"
        case .sourceIntegrityMismatch(let url):
            return "Source output does not match its recorded provenance checksum and size: \(url.path)"
        }
    }
}

/// Restores a sequence-processing output's preferred format without fabricating qualities.
/// Conversion creates a distinct artifact; the original tool's bytes and provenance remain intact.
public enum SequenceProcessingOutputNormalizer {
    public static let normalizationToolName = "SyntheticFASTQBridge.convertFASTQToFASTA"

    public static let inputPreparationToolName = "SyntheticFASTQBridge.convertFASTAToFASTQ"
    private static let inputPreparationWorkflowName = "lungfish sequence-processing synthetic FASTQ input"

    /// Creates the FASTQ-only execution adapter and its provenance as one operation.
    /// Existing destinations are rejected; failed conversion/provenance never leaves
    /// an unrecorded synthetic scientific payload behind.
    public static func prepareFASTQInput(inputURL: URL, outputURL: URL) async throws {
        let input = inputURL.standardizedFileURL
        let output = outputURL.standardizedFileURL
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        guard !FileManager.default.fileExists(atPath: output.path),
              !FileManager.default.fileExists(atPath: sidecar.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try Task.checkCancellation()
        let inputFile = try descriptor(input, format: .fasta, role: .input)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        var published = false
        defer {
            if !published {
                try? FileManager.default.removeItem(at: output)
                try? FileManager.default.removeItem(at: sidecar)
            }
        }
        let started = Date()
        try await SyntheticFASTQBridge.convertFASTAToFASTQ(inputURL: input, outputURL: output)
        try Task.checkCancellation()
        let ended = Date()
        let outputFile = try descriptor(output, format: .fastq, role: .output)
        let runtime = ProvenanceRuntimeIdentity()
        let argv = [inputPreparationToolName, "--input", input.path, "--output", output.path]
        let defaults: [String: ParameterValue] = ["quality_character": .string("I"), "quality_phred": .integer(40)]
        let options: [String: ParameterValue] = defaults.merging([
            "sequence_processing_bridge": .boolean(true), "action": .string("prepare-fastq-execution-input"),
            "execution": .string("in-process"), "input_format": .string("fasta"), "output_format": .string("fastq"),
            "quality_policy": .string("synthetic-placeholder"), "input": .file(input), "output": .file(output)
        ]) { _, value in value }
        let step = ProvenanceStep(toolName: inputPreparationToolName, toolVersion: WorkflowRun.currentAppVersion,
            argv: argv, resolvedOptions: options, runtimeIdentity: runtime,
            inputs: [inputFile], outputs: [outputFile], exitStatus: 0,
            wallTimeSeconds: ended.timeIntervalSince(started), startedAt: started, completedAt: ended)
        let envelope = ProvenanceEnvelope(createdAt: started, workflowName: inputPreparationWorkflowName,
            toolName: inputPreparationToolName, toolVersion: WorkflowRun.currentAppVersion, argv: argv,
            options: ProvenanceOptions(explicit: ["input": .file(input), "output": .file(output)],
                defaults: defaults, resolvedDefaults: options), runtimeIdentity: runtime,
            files: [inputFile, outputFile], output: outputFile, outputs: [outputFile], steps: [step],
            wallTimeSeconds: ended.timeIntervalSince(started), exitStatus: 0)
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: sidecar)
        published = true
    }

    public static func normalize(outputURL: URL, preferredFormat: SequenceFormat) async throws -> URL {
        guard preferredFormat == .fasta, SequenceFormat.from(url: outputURL) == .fastq,
              (try? outputURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return outputURL
        }
        try Task.checkCancellation()
        let input = outputURL.standardizedFileURL
        guard let source = ProvenanceRecorder.findProvenanceEnvelope(for: input) else {
            throw SequenceProcessingOutputNormalizerError.missingSourceProvenance(input)
        }
        let inputDescriptor = try descriptor(input, format: .fastq, role: .input)
        let sourceOutputs = source.envelope.outputs + source.envelope.files.filter { $0.role == .output }
            + source.envelope.steps.flatMap(\.outputs) + [source.envelope.output].compactMap { $0 }
        guard sourceOutputs.contains(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == input.path
                && $0.checksumSHA256 == inputDescriptor.checksumSHA256
                && $0.fileSize == inputDescriptor.fileSize
        }) else {
            throw SequenceProcessingOutputNormalizerError.sourceIntegrityMismatch(input)
        }

        let folder = input.deletingLastPathComponent().appendingPathComponent("sequence-normalized-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: folder) } }
        let base = input.pathExtension.lowercased() == "gz" ? input.deletingPathExtension() : input
        let output = folder.appendingPathComponent(base.deletingPathExtension().lastPathComponent + ".fasta")
        let snapshot = folder.appendingPathComponent("source-provenance.json")
        try FileManager.default.copyItem(at: source.sidecarURL, to: snapshot)
        let snapshotDescriptor = try descriptor(snapshot, format: .json, role: .input)
        let started = Date()
        try await SyntheticFASTQBridge.convertFASTQToFASTA(inputURL: input, outputURL: output)
        // The bridge appends records and therefore leaves no file for an empty dataset.
        if !FileManager.default.fileExists(atPath: output.path) { try Data().write(to: output) }
        try Task.checkCancellation()
        let ended = Date()
        let outputDescriptor = try descriptor(output, format: .fasta, role: .output)
        let step = ProvenanceStep(
            toolName: normalizationToolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [normalizationToolName, "--input", input.path, "--output", output.path],
            resolvedOptions: [
                "action": .string("restore-fasta-output"),
                "execution": .string("in-process"),
                "input_format": .string("fastq"),
                "preferred_format": .string("fasta"),
                "output_format": .string("fasta"),
                "quality_policy": .string("discard"),
                "line_width": .integer(60),
                "line_width_source": .string("FASTAWriter default"),
                "validate_sequence": .boolean(false),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: [inputDescriptor, snapshotDescriptor], outputs: [outputDescriptor],
            exitStatus: 0, wallTimeSeconds: ended.timeIntervalSince(started),
            dependsOn: source.envelope.steps.map(\.id), startedAt: started, completedAt: ended
        )
        let withInputLineage = try includingPreparedInputLineage(in: source.envelope)
        let original = try retainingMaterializedInputs(withInputLineage, in: folder)
        let envelope = ProvenanceEnvelope(
            schemaVersion: original.schemaVersion, id: original.id, createdAt: original.createdAt,
            workflowName: original.workflowName, workflowVersion: original.workflowVersion,
            toolName: original.toolName, toolVersion: original.toolVersion,
            githubReleaseVersion: original.githubReleaseVersion, tool: original.tool,
            argv: original.argv, durableReplayArgv: original.durableReplayArgv,
            reproducibleCommand: original.reproducibleCommand, options: original.options,
            runtimeIdentity: original.runtimeIdentity,
            files: original.files + [inputDescriptor, snapshotDescriptor, outputDescriptor],
            output: outputDescriptor, outputs: original.outputs + [outputDescriptor],
            steps: original.steps + [step], wallTimeSeconds: original.wallTimeSeconds,
            exitStatus: original.exitStatus, stderr: original.stderr,
            signatures: [], legacyWorkflowRun: original.legacyRun
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: output))
        published = true
        return output
    }

    /// Follow only receipts emitted by this adapter, never arbitrary nearby lineage.
    private static func includingPreparedInputLineage(in envelope: ProvenanceEnvelope) throws -> ProvenanceEnvelope {
        let consumed = envelope.files.filter { $0.role == .input } + envelope.steps.flatMap(\.inputs)
        var upstreamSteps: [ProvenanceStep] = []
        var upstreamFiles: [ProvenanceFileDescriptor] = []
        var seen = Set<UUID>(envelope.steps.map(\.id))
        for input in consumed {
            let inputURL = URL(fileURLWithPath: input.path)
            let sidecar = ProvenanceRecorder.fileSidecarURL(for: inputURL)
            guard let upstream = try? ProvenanceEnvelopeReader.load(fromSidecar: sidecar),
                  upstream.workflowName == inputPreparationWorkflowName,
                  upstream.toolName == inputPreparationToolName,
                  upstream.steps.contains(where: { $0.toolName == inputPreparationToolName
                    && $0.resolvedOptions["sequence_processing_bridge"] == .boolean(true) }) else { continue }
            guard let produced = upstream.outputs.first(where: { $0.path == inputURL.standardizedFileURL.path }),
                  let checksum = input.checksumSHA256, let size = input.fileSize,
                  produced.checksumSHA256 == checksum, produced.fileSize == size else {
                throw SequenceProcessingOutputNormalizerError.sourceIntegrityMismatch(inputURL)
            }
            for step in upstream.steps where seen.insert(step.id).inserted {
                upstreamSteps.append(step)
                upstreamFiles += step.inputs + step.outputs
            }
        }
        guard !upstreamSteps.isEmpty else { return envelope }
        return ProvenanceEnvelope(schemaVersion: envelope.schemaVersion, id: envelope.id, createdAt: envelope.createdAt,
            workflowName: envelope.workflowName, workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName, toolVersion: envelope.toolVersion, githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool, argv: envelope.argv, durableReplayArgv: envelope.durableReplayArgv,
            reproducibleCommand: envelope.reproducibleCommand, options: envelope.options,
            runtimeIdentity: envelope.runtimeIdentity, files: envelope.files + upstreamFiles,
            output: envelope.output, outputs: envelope.outputs, steps: upstreamSteps + envelope.steps,
            wallTimeSeconds: envelope.wallTimeSeconds, exitStatus: envelope.exitStatus, stderr: envelope.stderr,
            signatures: [], legacyWorkflowRun: envelope.legacyRun)
    }

    /// Grouped outputs outlive execution materialization cleanup too. Keep bridge
    /// inputs with the normalized artifact, while leaving durable external data in place.
    private static func retainingMaterializedInputs(_ envelope: ProvenanceEnvelope, in folder: URL) throws -> ProvenanceEnvelope {
        let files = envelope.files + envelope.steps.flatMap { $0.inputs + $0.outputs }
        var paths: [String: String] = [:]
        for file in files where paths[file.path] == nil {
            let source = URL(fileURLWithPath: file.path)
            guard source.pathComponents.contains(where: { $0.hasPrefix("materialized-inputs-") }),
                  (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if let hash = file.checksumSHA256, try ProvenanceFileHasher.sha256(of: source) != hash {
                throw SequenceProcessingOutputNormalizerError.sourceIntegrityMismatch(source)
            }
            let destination = folder.appendingPathComponent("retained-\(UUID().uuidString)-\(source.lastPathComponent)")
            try FileManager.default.copyItem(at: source, to: destination)
            paths[file.path] = destination.path
        }
        guard !paths.isEmpty else { return envelope }
        func mapped(_ file: ProvenanceFileDescriptor) -> ProvenanceFileDescriptor {
            guard let path = paths[file.path] else { return file }
            return ProvenanceFileDescriptor(path: path, checksumSHA256: file.checksumSHA256, fileSize: file.fileSize,
                format: file.format, role: file.role, originPath: file.originPath ?? file.path,
                sourceProvenancePath: file.sourceProvenancePath)
        }
        func replay(_ argv: [String]) -> [String] { argv.map { paths[$0] ?? $0 } }
        let steps = envelope.steps.map { step in
            let durable = replay(step.durableReplayArgv ?? step.argv)
            return ProvenanceStep(id: step.id, toolName: step.toolName, toolVersion: step.toolVersion,
                githubReleaseVersion: step.githubReleaseVersion, argv: step.argv, durableReplayArgv: durable,
                reproducibleCommand: durable.map(shellEscape).joined(separator: " "),
                resolvedOptions: step.resolvedOptions, runtimeIdentity: step.runtimeIdentity,
                inputs: step.inputs.map(mapped), outputs: step.outputs.map(mapped), exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds, peakMemoryBytes: step.peakMemoryBytes, stderr: step.stderr,
                dependsOn: step.dependsOn, startedAt: step.startedAt, completedAt: step.completedAt)
        }
        let durable = replay(envelope.durableReplayArgv ?? envelope.argv)
        return ProvenanceEnvelope(schemaVersion: envelope.schemaVersion, id: envelope.id, createdAt: envelope.createdAt,
            workflowName: envelope.workflowName, workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName, toolVersion: envelope.toolVersion, githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool, argv: envelope.argv, durableReplayArgv: durable,
            reproducibleCommand: durable.map(shellEscape).joined(separator: " "), options: envelope.options,
            runtimeIdentity: envelope.runtimeIdentity, files: envelope.files.map(mapped), output: envelope.output.map(mapped),
            outputs: envelope.outputs.map(mapped), steps: steps, wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus, stderr: envelope.stderr, signatures: [], legacyWorkflowRun: envelope.legacyRun)
    }

    private static func descriptor(_ url: URL, format: FileFormat, role: FileRole) throws -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(path: url.path,
            checksumSHA256: try ProvenanceFileHasher.sha256(of: url, cancellationCheck: { try Task.checkCancellation() }),
            fileSize: try ProvenanceFileHasher.fileSize(of: url), format: format, role: role)
    }
}
