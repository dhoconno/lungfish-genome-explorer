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
           let sourceEnvelope = loadSourceProvenanceEnvelope(for: sourceURL) {
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
        try ProvenanceRehydrator.rehydrateSelectedOutputs(
            sourceDirectory: sourceURL.deletingLastPathComponent(),
            finalDirectory: finalDirectory,
            pathMap: operationPathMap(
                sourceURL: sourceURL,
                finalOutputURL: finalOutputURL,
                sourceInputURL: sourceInputURL
            )
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
        let rehydrated = try ProvenanceRehydrator.rehydrateSelectedOutputs(
            sourceDirectory: sourceURL.deletingLastPathComponent(),
            finalDirectory: referenceBundleURL,
            pathMap: [sourceURL.path: finalPayloadURL.path]
        )
        guard let wrappingEnvelope else { return }
        let merged = ProvenanceEnvelope(
            schemaVersion: rehydrated.schemaVersion,
            id: rehydrated.id,
            createdAt: rehydrated.createdAt,
            workflowName: rehydrated.workflowName,
            workflowVersion: rehydrated.workflowVersion,
            toolName: rehydrated.toolName,
            toolVersion: rehydrated.toolVersion,
            tool: rehydrated.tool,
            argv: rehydrated.argv,
            reproducibleCommand: rehydrated.reproducibleCommand,
            options: rehydrated.options,
            runtimeIdentity: rehydrated.runtimeIdentity,
            files: mergedProvenanceFiles(rehydrated.files, wrappingEnvelope.files),
            output: rehydrated.output,
            outputs: rehydrated.outputs,
            steps: rehydrated.steps + wrappingEnvelope.steps,
            wallTimeSeconds: rehydrated.wallTimeSeconds,
            exitStatus: rehydrated.exitStatus,
            stderr: rehydrated.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
        try ProvenanceWriter(signingProvider: nil).write(merged, to: referenceBundleURL)
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
            candidateURL = bundleURL.appendingPathComponent(filename).standardizedFileURL
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
