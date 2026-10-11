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
        let updatedSteps = original.steps.enumerated().map { index, step in
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
                // Every step now carries the collection's command, so a script would run the import once
                // for each step. The steps after the first ran under it (plan decision S6).
                parentStepID: index == 0 ? step.parentStepID : original.steps.first?.id,
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
        // A run's steps hold no step field schema version 2 added, so those come back from the
        // record's own steps by id.
        let sourceSteps = Dictionary(envelope.steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let steps = canonical.steps.map { step in
            step.with { copy in
                guard let source = sourceSteps[step.id] else { return }
                copy.parentStepID = source.parentStepID ?? copy.parentStepID
                copy.managedToolID = source.managedToolID
                copy.toolVersionEvidence = source.toolVersionEvidence
            }
        }
        // The canonical envelope is made of the rebuilt run, which holds no release version, so the
        // record's own comes back from the envelope it was read from. That run also embeds a copy of the
        // old explicit options as its parameters. Only a nested run the record itself held, as one
        // written before 2.4 does, has parameters the options lack, so the copy merges that one.
        let updatedEnvelope = canonical.with {
            $0.githubReleaseVersion = envelope.githubReleaseVersion
            $0.argv = context.replayCommand
            $0.durableReplayArgv = context.replayCommand
            $0.reproducibleCommand = context.replayCommand.map(shellEscape).joined(separator: " ")
            $0.options = updatedOptions
            $0.steps = steps
            $0.legacyRun = envelope.legacyRun
        }

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
