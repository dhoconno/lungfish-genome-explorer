import Foundation
import LungfishIO
import LungfishWorkflow

struct FASTQOperationProvenanceRehydrator: Sendable {
    func operationPathMap(
        sourceURL: URL,
        finalOutputURL: URL,
        sourceInputURL: URL?
    ) -> [String: String] {
        var pathMap = [sourceURL.path: finalOutputURL.path]
        if let finalInputURL = finalInputFileForMaterializedProvenance(sourceInputURL: sourceInputURL),
           let sourceEnvelope = loadSourceProvenanceEnvelope(for: sourceURL),
           !isNormalizedSequenceEnvelope(sourceEnvelope) {
            for materializedPath in materializedInputPaths(in: sourceEnvelope) {
                pathMap[materializedPath] = finalInputURL.path
            }
        }
        return pathMap
    }

    @discardableResult
    func rehydrateOperationOutput(
        sourceURL: URL,
        finalDirectory: URL,
        finalOutputURL: URL,
        sourceInputURL: URL?
    ) throws -> ProvenanceEnvelope {
        var pathMap = operationPathMap(sourceURL: sourceURL, finalOutputURL: finalOutputURL,
            sourceInputURL: sourceInputURL)
        if let source = loadSourceProvenanceEnvelope(for: sourceURL), isNormalizedSequenceEnvelope(source) {
            pathMap.merge(try retainNormalizationIntermediates(source, in: finalDirectory, excluding: sourceURL)) { _, new in new }
        }
        return try ProvenanceRehydrator.rehydrateSelectedOutputs(
            sourceDirectory: sourceURL.deletingLastPathComponent(), finalDirectory: finalDirectory, pathMap: pathMap
        )
    }

    func rehydrateReferenceBundleProvenance(
        sourceURL: URL,
        referenceBundleURL: URL
    ) throws {
        guard let finalPayloadURL = SequenceInputResolver.resolvePrimarySequenceURL(for: referenceBundleURL) else {
            return
        }

        let wrappingEnvelope = ProvenanceRecorder.loadEnvelope(from: referenceBundleURL)
        var pathMap = [sourceURL.path: finalPayloadURL.path]
        var normalizedStoredSourceURL: URL?
        if let source = loadSourceProvenanceEnvelope(for: sourceURL), isNormalizedSequenceEnvelope(source) {
            let storedSource = try retainedNormalizedSource(sourceURL, finalPayloadURL: finalPayloadURL, bundleURL: referenceBundleURL)
            normalizedStoredSourceURL = storedSource
            pathMap[sourceURL.path] = storedSource.path
            pathMap.merge(try retainNormalizationIntermediates(source, in: referenceBundleURL, excluding: sourceURL)) { _, new in new }
        }
        let rehydrated = try ProvenanceRehydrator.rehydrateSelectedOutputs(
            sourceDirectory: sourceURL.deletingLastPathComponent(),
            finalDirectory: referenceBundleURL,
            pathMap: pathMap
        )
        guard let wrappingEnvelope else { return }
        let finalDescriptor = ProvenanceFileDescriptor(path: finalPayloadURL.path,
            checksumSHA256: try ProvenanceFileHasher.sha256(of: finalPayloadURL),
            fileSize: try ProvenanceFileHasher.fileSize(of: finalPayloadURL), format: .fasta, role: .output)
        let merged = ProvenanceEnvelope(
            schemaVersion: rehydrated.schemaVersion,
            id: rehydrated.id,
            createdAt: rehydrated.createdAt,
            workflowName: rehydrated.workflowName,
            workflowVersion: rehydrated.workflowVersion,
            toolName: rehydrated.toolName,
            toolVersion: rehydrated.toolVersion,
            githubReleaseVersion: rehydrated.githubReleaseVersion,
            tool: rehydrated.tool,
            argv: rehydrated.argv,
            durableReplayArgv: rehydrated.durableReplayArgv,
            reproducibleCommand: rehydrated.reproducibleCommand,
            options: rehydrated.options,
            runtimeIdentity: rehydrated.runtimeIdentity,
            files: mergedProvenanceFiles(rehydrated.files, try wrappingEnvelope.files.map {
                try retainedWrappingDescriptor($0, sourceURL: sourceURL, storedSourceURL: normalizedStoredSourceURL)
            }),
            output: normalizedStoredSourceURL == nil ? rehydrated.output : finalDescriptor,
            outputs: normalizedStoredSourceURL == nil || rehydrated.outputs.contains(where: { $0.path == finalPayloadURL.path })
                ? rehydrated.outputs : rehydrated.outputs + [finalDescriptor],
            steps: rehydrated.steps + (try wrappingEnvelope.steps.map { step in
                ProvenanceStep(id: step.id, toolName: step.toolName, toolVersion: step.toolVersion,
                    githubReleaseVersion: step.githubReleaseVersion, argv: step.argv,
                    durableReplayArgv: normalizedStoredSourceURL.map { stored in
                        (step.durableReplayArgv ?? step.argv).map { $0 == sourceURL.path ? stored.path : $0 }
                    } ?? step.durableReplayArgv,
                    reproducibleCommand: normalizedStoredSourceURL.map { stored in
                        (step.durableReplayArgv ?? step.argv).map { $0 == sourceURL.path ? stored.path : $0 }
                            .map(shellEscape).joined(separator: " ")
                    } ?? step.reproducibleCommand,
                    resolvedOptions: step.resolvedOptions, runtimeIdentity: step.runtimeIdentity,
                    inputs: try step.inputs.map { try retainedWrappingDescriptor($0, sourceURL: sourceURL, storedSourceURL: normalizedStoredSourceURL) },
                    outputs: step.outputs, exitStatus: step.exitStatus, wallTimeSeconds: step.wallTimeSeconds,
                    peakMemoryBytes: step.peakMemoryBytes, stderr: step.stderr, dependsOn: step.dependsOn,
                    startedAt: step.startedAt, completedAt: step.completedAt)
            }),
            wallTimeSeconds: rehydrated.wallTimeSeconds,
            exitStatus: rehydrated.exitStatus,
            stderr: rehydrated.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
        try ProvenanceWriter(signingProvider: nil).write(merged, to: referenceBundleURL)
    }

    private func isNormalizedSequenceEnvelope(_ envelope: ProvenanceEnvelope) -> Bool {
        envelope.steps.contains { $0.toolName == SequenceProcessingOutputNormalizer.normalizationToolName }
    }

    /// Preserve consumed scientific bytes before execution-directory cleanup. Keeping
    /// separate copies avoids relabeling synthetic FASTQ as the user's original FASTA.
    private func retainNormalizationIntermediates(
        _ envelope: ProvenanceEnvelope, in finalDirectory: URL, excluding sourceURL: URL
    ) throws -> [String: String] {
        let descriptors = envelope.files + envelope.outputs + envelope.steps.flatMap { $0.inputs + $0.outputs }
        let folder = finalDirectory.appendingPathComponent("provenance-intermediates", isDirectory: true)
        let rawSource = envelope.steps.last(where: { $0.toolName == SequenceProcessingOutputNormalizer.normalizationToolName })?.inputs.first
        let artifactRoot = rawSource.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL.path + "/" }
        var pathMap: [String: String] = [:]
        for descriptor in descriptors {
            let source = URL(fileURLWithPath: descriptor.path).standardizedFileURL
            guard source != sourceURL.standardizedFileURL, pathMap[descriptor.path] == nil,
                  descriptor.path.hasPrefix("/"),
                  (artifactRoot.map { source.path.hasPrefix($0) } ?? false) || isMaterializedInputPath(source.path),
                  !source.path.hasPrefix(finalDirectory.standardizedFileURL.path + "/"),
                  (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if let expectedHash = descriptor.checksumSHA256,
               try ProvenanceFileHasher.sha256(of: source) != expectedHash {
                throw SequenceProcessingOutputNormalizerError.sourceIntegrityMismatch(source)
            }
            if let expectedSize = descriptor.fileSize,
               try ProvenanceFileHasher.fileSize(of: source) != expectedSize {
                throw SequenceProcessingOutputNormalizerError.sourceIntegrityMismatch(source)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
            try FileManager.default.copyItem(at: source, to: destination)
            pathMap[descriptor.path] = destination.path
        }
        return pathMap
    }

    private func retainedNormalizedSource(_ source: URL, finalPayloadURL: URL, bundleURL: URL) throws -> URL {
        if try ProvenanceFileHasher.sha256(of: source) == ProvenanceFileHasher.sha256(of: finalPayloadURL) {
            return finalPayloadURL
        }
        let folder = bundleURL.appendingPathComponent("provenance-intermediates", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func retainedWrappingDescriptor(
        _ descriptor: ProvenanceFileDescriptor, sourceURL: URL, storedSourceURL: URL?
    ) throws -> ProvenanceFileDescriptor {
        guard let storedSourceURL, URL(fileURLWithPath: descriptor.path).standardizedFileURL == sourceURL.standardizedFileURL else {
            return descriptor
        }
        return ProvenanceFileDescriptor(path: storedSourceURL.path,
            checksumSHA256: try ProvenanceFileHasher.sha256(of: storedSourceURL),
            fileSize: try ProvenanceFileHasher.fileSize(of: storedSourceURL),
            format: descriptor.format, role: descriptor.role,
            originPath: descriptor.originPath ?? descriptor.path,
            sourceProvenancePath: descriptor.sourceProvenancePath)
    }

    private func loadSourceProvenanceEnvelope(for sourceURL: URL) -> ProvenanceEnvelope? {
        ProvenanceRecorder.findProvenanceEnvelope(for: sourceURL)?.envelope
            ?? ProvenanceRecorder.loadEnvelope(from: sourceURL.deletingLastPathComponent())
    }

    private func materializedInputPaths(in envelope: ProvenanceEnvelope) -> Set<String> {
        let descriptors = envelope.files
            + envelope.steps.flatMap(\.inputs)
        return Set(
            descriptors
                .filter { $0.role == .input && isMaterializedInputPath($0.path) }
                .map(\.path)
        )
    }

    private func isMaterializedInputPath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathComponents.contains {
            $0.hasPrefix("materialized-inputs-")
        }
    }

    private func finalInputFileForMaterializedProvenance(sourceInputURL: URL?) -> URL? {
        guard let sourceInputURL else { return nil }
        let standardizedURL = sourceInputURL.standardizedFileURL

        if FASTQBundle.isBundleURL(standardizedURL) {
            return materializedPayloadFileForProvenance(in: standardizedURL)
                ?? regularPrimarySequenceURL(in: standardizedURL)
        }

        if isRegularFile(standardizedURL),
           FASTQBundle.isFASTQFileURL(standardizedURL) || SequenceFormat.from(url: standardizedURL) != nil {
            return standardizedURL
        }

        if let bundleURL = enclosingFASTQBundleURL(for: standardizedURL) {
            return materializedPayloadFileForProvenance(in: bundleURL)
                ?? regularPrimarySequenceURL(in: bundleURL)
        }

        return nil
    }

    private func materializedPayloadFileForProvenance(in bundleURL: URL) -> URL? {
        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            return nil
        }

        let candidateURL: URL?
        switch manifest.payload {
        case .full(let filename), .fullFASTA(let filename):
            candidateURL = try? FASTQBundle.validatedBundleMemberURL(
                for: filename,
                in: bundleURL,
                field: "payload.materialized.filename"
            )
        default:
            candidateURL = nil
        }

        guard let candidateURL, isRegularFile(candidateURL) else {
            return nil
        }
        return candidateURL
    }

    private func regularPrimarySequenceURL(in bundleURL: URL) -> URL? {
        guard let primaryURL = FASTQBundle.resolvePrimarySequenceURL(for: bundleURL)?.standardizedFileURL,
              primaryURL.lastPathComponent != "preview.fastq",
              isRegularFile(primaryURL) else {
            return nil
        }
        return primaryURL
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func enclosingFASTQBundleURL(for url: URL) -> URL? {
        if FASTQBundle.isBundleURL(url) {
            return url
        }
        return SequenceInputResolver.enclosingFASTQBundleURL(for: url)
    }

    private func mergedProvenanceFiles(
        _ primary: [ProvenanceFileDescriptor],
        _ additional: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var merged: [ProvenanceFileDescriptor] = []
        for descriptor in primary + additional {
            let key = "\(descriptor.role.rawValue)\u{0}\(descriptor.path)"
            if seen.insert(key).inserted {
                merged.append(descriptor)
            }
        }
        return merged
    }
}
