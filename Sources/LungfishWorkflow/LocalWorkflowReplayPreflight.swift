import Foundation

/// Read-only validation of a durable local attempt before configuration or execution.
public enum LocalWorkflowReplayPreflight {
    public static func load(from sourceBundleURL: URL) throws -> LocalWorkflowReplayConfiguration {
        let manifestURL = sourceBundleURL.appendingPathComponent("manifest.json")
        let provenanceURL = sourceBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        guard sourceBundleURL.pathExtension.lowercased() == LocalWorkflowRunBundleStore.directoryExtension,
              (try? FileManager.default.attributesOfItem(atPath: sourceBundleURL.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw LocalWorkflowReplayError.unavailable("Choose an existing local run history bundle.")
        }
        let manifestState = try regularFileState(at: manifestURL, label: "history")
        let provenanceState = try regularFileState(at: provenanceURL, label: "provenance")
        guard case .file(let metadata, let digest) = manifestState else {
            throw LocalWorkflowReplayError.unavailable("The run history is not a regular file.")
        }
        let envelope: ProvenanceEnvelope
        do {
            guard let loaded = try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: provenanceURL) else {
                throw LocalWorkflowReplayError.unavailable("Canonical provenance is missing from this run.")
            }
            envelope = loaded
        } catch {
            throw LocalWorkflowReplayError.unavailable("This run has missing or invalid canonical provenance: \(error.localizedDescription)")
        }
        let records = envelope.outputs + envelope.steps.flatMap(\.outputs)
        guard envelope.toolName == "lungfish-cli workflow run"
                || envelope.steps.contains(where: { $0.toolName == "lungfish-cli workflow run" }),
              records.contains(where: {
                  URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path
                    == manifestURL.standardizedFileURL.resolvingSymlinksInPath().path
                    && $0.checksumSHA256 == digest && $0.fileSize == UInt64(metadata.size)
              }) else {
            throw LocalWorkflowReplayError.unavailable("The run history does not match its retained provenance. Choose an intact original run.")
        }
        let configuration = try LocalWorkflowReplayConfiguration.restored(from: LocalWorkflowRunBundleStore.read(from: sourceBundleURL))
        guard ProvenancePublicationSnapshot.statesMatch(manifestState, try regularFileState(at: manifestURL, label: "history")),
              ProvenancePublicationSnapshot.statesMatch(provenanceState, try regularFileState(at: provenanceURL, label: "provenance")) else {
            throw LocalWorkflowReplayError.repairRequired("The source history changed while it was loaded. Reopen the original run.")
        }
        return configuration
    }

    public static func validate(
        request: LocalWorkflowRunRequest,
        configuration: LocalWorkflowReplayConfiguration,
        sourceBundleURL: URL,
        runtimeURL: URL?,
        runBundleURL: URL? = nil
    ) throws {
        try Task.checkCancellation()
        guard try load(from: sourceBundleURL) == configuration else {
            throw LocalWorkflowReplayError.repairRequired("The selected source run differs from the reopened configuration.")
        }
        let original = configuration.request
        guard request.engine == original.engine, request.cpus == original.cpus, request.memory == original.memory,
              request.resume == original.resume, request.workDirectory == original.workDirectory,
              request.inputURLs.count == original.inputURLs.count else {
            throw LocalWorkflowReplayError.repairRequired("Retained settings changed. Restore the original settings or start a new configuration.")
        }
        var relocatedParameters = original.params
        for (key, value) in original.params {
            let matchingInputs = original.inputURLs.indices.filter { original.inputURLs[$0].path == value }
            if !matchingInputs.isEmpty {
                let paths = Set(matchingInputs.map { request.inputURLs[$0].path })
                guard paths.count == 1 else {
                    throw LocalWorkflowReplayError.repairRequired("Input settings cannot be relocated without changing their meaning.")
                }
                relocatedParameters[key] = paths.first
            } else if value == original.outputDirectory.path {
                relocatedParameters[key] = request.outputDirectory.path
            }
        }
        guard request.params == relocatedParameters else {
            throw LocalWorkflowReplayError.repairRequired("Retained settings changed. Restore the original settings or start a new configuration.")
        }
        let destination = canonical(request.outputDirectory)
        let currentPackage = try LocalWorkflowReplayIdentity.packageRoot(containing: request.workflowURL)
        let protected = [original.outputDirectory, sourceBundleURL, configuration.identity.packageURL, currentPackage]
            + original.inputURLs + request.inputURLs + [original.workDirectory, request.workDirectory].compactMap { $0 }
        guard !protected.contains(where: { overlaps(destination, canonical($0)) }),
              (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil,
              FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path),
              (try? FileManager.default.attributesOfItem(atPath: destination.deletingLastPathComponent().path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw LocalWorkflowReplayError.repairRequired("Choose a new, absent destination under a writable folder outside the original run, outputs, package and inputs.")
        }
        guard !request.expectedOutputURLs.isEmpty, request.expectedOutputURLs.count == original.expectedOutputURLs.count else {
            throw LocalWorkflowReplayError.repairRequired("The retained output declarations are incomplete.")
        }
        for (previous, next) in zip(original.expectedOutputURLs, request.expectedOutputURLs) {
            let oldRoot = original.outputDirectory.standardizedFileURL.pathComponents
            let oldPath = previous.standardizedFileURL.pathComponents
            guard oldPath.count > oldRoot.count, oldPath.starts(with: oldRoot) else {
                throw LocalWorkflowReplayError.unavailable("A retained output escapes the original results directory.")
            }
            let relative = oldPath.dropFirst(oldRoot.count).joined(separator: "/")
            guard canonical(next).pathComponents == destination.appendingPathComponent(relative).standardizedFileURL.pathComponents,
                  canonical(next).pathComponents.count > destination.pathComponents.count,
                  canonical(next).pathComponents.starts(with: destination.pathComponents) else {
                throw LocalWorkflowReplayError.repairRequired("Expected output paths must preserve the original declarations inside the new destination.")
            }
        }
        if let runBundleURL {
            let runBundle = canonical(runBundleURL)
            var existingParent = runBundle.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: existingParent.path), existingParent.path != "/" {
                existingParent.deleteLastPathComponent()
            }
            guard runBundleURL.pathExtension.lowercased() == LocalWorkflowRunBundleStore.directoryExtension,
                  (try? FileManager.default.attributesOfItem(atPath: runBundleURL.path)) == nil,
                  (try? FileManager.default.attributesOfItem(atPath: runBundle.path)) == nil,
                  !(protected + [destination]).contains(where: { overlaps(runBundle, canonical($0)) }),
                  FileManager.default.isWritableFile(atPath: existingParent.path),
                  (try? FileManager.default.attributesOfItem(atPath: existingParent.path)[.type] as? FileAttributeType) == .typeDirectory else {
                throw LocalWorkflowReplayError.repairRequired("Choose a fresh run bundle outside the source run, package, inputs and results directories.")
            }
        }
        guard let runtimeURL, FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
            throw LocalWorkflowReplayError.repairRequired("The workflow runtime is unavailable or cannot be identified safely. Open tool setup or use an absolute runtime PATH before running again.")
        }
        try configuration.identity.validateCurrentInputs(for: request)
        try Task.checkCancellation()
    }

    private static func regularFileState(at url: URL, label: String) throws -> ProvenancePublicationArtifactState {
        guard let state = try? ProvenancePublicationSnapshot.artifactState(at: url, fileManager: .default),
              case .file = state else {
            throw LocalWorkflowReplayError.unavailable("The run's \(label) file is missing or is not a regular file.")
        }
        return state
    }

    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    private static func overlaps(_ first: URL, _ second: URL) -> Bool {
        first.pathComponents.starts(with: second.pathComponents) || second.pathComponents.starts(with: first.pathComponents)
    }
}
