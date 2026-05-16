import Foundation

public enum ReferenceBundleImportProvenanceError: Error, LocalizedError, Sendable, Equatable {
    case missingSidecar(URL)

    public var errorDescription: String? {
        switch self {
        case .missingSidecar(let bundleURL):
            return "Reference bundle provenance is missing for \(bundleURL.lastPathComponent)"
        }
    }
}

struct ReferenceBundleImportProvenanceContext: Sendable {
    let workflowName: String
    let replayCommand: [String]
    let options: ProvenanceOptions

    init(
        workflowName: String,
        replayCommand: [String],
        options: ProvenanceOptions
    ) {
        self.workflowName = workflowName
        self.replayCommand = replayCommand
        self.options = options
    }
}

enum ReferenceBundleImportProvenanceRehydrator {
    static func rehydrateSidecar(
        bundleURL: URL,
        durableSourceURL: URL,
        sourceRelativePath: String?,
        context: ReferenceBundleImportProvenanceContext
    ) throws {
        guard let envelope = try ProvenanceEnvelopeReader.load(from: bundleURL) else {
            throw ReferenceBundleImportProvenanceError.missingSidecar(bundleURL)
        }

        let original = envelope.legacyWorkflowRun()
        let durableInput = ProvenanceRecorder.fileRecord(url: durableSourceURL, format: .unknown, role: .input)
        let updatedSteps = original.steps.map { step in
            let refreshedOutputs = step.outputs.map(refreshOutputRecord)
            return StepExecution(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                containerImage: step.containerImage,
                containerDigest: step.containerDigest,
                command: context.replayCommand,
                durableReplayArgv: context.replayCommand,
                inputs: [durableInput],
                outputs: refreshedOutputs,
                exitCode: step.exitCode,
                wallTime: step.wallTime,
                peakMemoryBytes: step.peakMemoryBytes,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startTime: step.startTime,
                endTime: step.endTime
            )
        }

        var parameters = original.parameters
        let updatedOptions = options(
            context.options,
            bundleURL: bundleURL,
            durableSourceURL: durableSourceURL,
            sourceRelativePath: sourceRelativePath
        )
        parameters.merge(updatedOptions.explicit) { _, workflowValue in workflowValue }
        if let sourceRelativePath,
           !sourceRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parameters["source_relative_path"] = .string(sourceRelativePath)
        } else {
            parameters.removeValue(forKey: "source_relative_path")
        }

        let updated = WorkflowRun(
            id: original.id,
            name: context.workflowName,
            startTime: original.startTime,
            endTime: original.endTime,
            status: original.status,
            appVersion: original.appVersion,
            hostOS: original.hostOS,
            runtime: original.runtime,
            steps: updatedSteps,
            parameters: parameters
        )
        let canonical = updated.canonicalEnvelope()
        let updatedEnvelope = ProvenanceEnvelope(
            schemaVersion: canonical.schemaVersion,
            id: canonical.id,
            createdAt: canonical.createdAt,
            workflowName: canonical.workflowName,
            workflowVersion: canonical.workflowVersion,
            toolName: canonical.toolName,
            toolVersion: canonical.toolVersion,
            tool: canonical.tool,
            argv: context.replayCommand,
            durableReplayArgv: context.replayCommand,
            reproducibleCommand: context.replayCommand.map(shellEscape).joined(separator: " "),
            options: updatedOptions,
            runtimeIdentity: canonical.runtimeIdentity,
            files: canonical.files,
            output: canonical.output,
            outputs: canonical.outputs,
            steps: canonical.steps,
            wallTimeSeconds: canonical.wallTimeSeconds,
            exitStatus: canonical.exitStatus,
            stderr: canonical.stderr,
            signatures: canonical.signatures,
            legacyWorkflowRun: updated
        )

        try ProvenanceWriter(signingProvider: nil).write(updatedEnvelope, to: bundleURL)
    }

    private static func options(
        _ options: ProvenanceOptions,
        bundleURL: URL,
        durableSourceURL: URL,
        sourceRelativePath: String?
    ) -> ProvenanceOptions {
        var durableValues: [String: ParameterValue] = [
            "source": .file(durableSourceURL),
            "source_url": .file(durableSourceURL),
            "input_files": .array([.file(durableSourceURL)]),
            "bundle_path": .file(bundleURL),
        ]
        if let sourceRelativePath,
           !sourceRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            durableValues["source_relative_path"] = .string(sourceRelativePath)
        }

        return ProvenanceOptions(
            explicit: options.explicit.merging(durableValues) { _, durableValue in durableValue },
            defaults: options.defaults,
            resolvedDefaults: options.resolvedDefaults.merging(durableValues) { _, durableValue in durableValue }
        )
    }

    private static func refreshOutputRecord(_ record: FileRecord) -> FileRecord {
        let url = URL(fileURLWithPath: record.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return record
        }

        let refreshed = ProvenanceRecorder.fileRecord(
            url: url,
            format: record.format,
            role: record.role
        )
        return FileRecord(
            path: record.path,
            sha256: refreshed.sha256,
            sizeBytes: refreshed.sizeBytes,
            format: record.format ?? refreshed.format,
            role: record.role
        )
    }
}
