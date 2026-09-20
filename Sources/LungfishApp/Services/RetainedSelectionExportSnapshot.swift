import Foundation
import LungfishWorkflow

/// Durable inputs for replaying the exact bytes selected in a GUI export.
/// Publication still uses the shared payload-and-provenance transaction.
struct RetainedSelectionExportSnapshot {
    static let replayScope = "retained-selection snapshot byte replay"
    let directory: URL
    let payloadURL: URL
    let selectionURL: URL

    init(outputURL: URL, selectionMetadata: Data) throws {
        directory = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".lungfish-export-inputs/\(UUID())", isDirectory: true)
        payloadURL = directory.appendingPathComponent("selected." + outputURL.pathExtension)
        selectionURL = directory.appendingPathComponent("selection.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try selectionMetadata.write(to: selectionURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func publish(
        _ request: ScientificFileExportProvenance.Request,
        preserveOriginalSources: Bool = false
    ) throws {
        var resolved = request.resolved
        resolved["replayScope"] = .string(Self.replayScope)
        resolved["replaysUpstreamAnalysis"] = .boolean(false)
        let replayInputs = [payloadURL, selectionURL]
        let sourceURLs = preserveOriginalSources
            ? deduplicated(request.sourceURLs + replayInputs)
            : replayInputs
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: request.workflowName, toolName: request.toolName,
            sourceURLs: sourceURLs, outputURL: request.outputURL,
            outputFormat: request.outputFormat, argv: request.argv,
            durableReplayArgv: ["/bin/cp", payloadURL.path, request.outputURL.path],
            explicitOptions: request.explicitOptions, defaults: request.defaults,
            resolved: resolved, startedAt: request.startedAt
        )) { stagedURL in
            try FileManager.default.copyItem(at: payloadURL, to: stagedURL)
        }
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    func discardAfterFailure(_ error: Error) {
        // A retained attempted output may still be named by recovery receipts.
        guard !(error is ScientificPublicationRecoveryRequired) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
