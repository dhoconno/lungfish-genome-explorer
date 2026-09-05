import Foundation

/// A reopened configuration is data only; constructing it never launches an engine.
public struct LocalWorkflowReplayConfiguration: Sendable, Equatable {
    public let request: LocalWorkflowRunRequest
    public let identity: LocalWorkflowReplayIdentity

    public static func restored(from manifest: LocalWorkflowRunBundleManifest) throws -> Self {
        guard manifest.schemaVersion == LocalWorkflowRunBundleManifest.schemaVersion else {
            throw LocalWorkflowReplayError.unavailable("This run uses an unsupported history version.")
        }
        guard [.completed, .failed, .cancelled].contains(manifest.executionStatus) else {
            throw LocalWorkflowReplayError.unavailable("Only a finished local attempt can be opened with Run Again.")
        }
        guard let request = manifest.request, let identity = manifest.replayIdentity,
              identity.schemaVersion == 1, identity.inputs.count == request.inputURLs.count,
              manifest.workflowPath == request.workflowURL.path, manifest.engine == request.engine,
              manifest.params == request.effectiveParams, manifest.resume == request.resume,
              manifest.workDirectoryPath == request.workDirectory?.path,
              manifest.outputDirectoryName == request.outputDirectory.lastPathComponent else {
            throw LocalWorkflowReplayError.unavailable("This history has no complete typed configuration and captured source identity. Open a new configuration instead.")
        }
        return Self(request: request, identity: identity)
    }
}
