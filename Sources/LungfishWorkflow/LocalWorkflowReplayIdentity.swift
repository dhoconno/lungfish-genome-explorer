import Foundation
import CryptoKit
import LungfishCore

/// Complete local filesystem binding used only when capturing or reopening a run.
/// Missing bindings never imply that a historical command can be executed safely.
public struct LocalWorkflowReplayArtifact: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let relativePath: String
        public let kind: String
        public let sha256: String?
        public let sizeBytes: UInt64
        public let executable: Bool
    }
    public let rootURL: URL
    public let entries: [Entry]
    /// Explicit presentation-only exceptions; package resources always use an empty list.
    public let excludedRelativePaths: [String]
}

public struct LocalWorkflowReplayIdentity: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let packageURL: URL
    public let packageManifest: WorkflowPackageManifest
    public let package: LocalWorkflowReplayArtifact
    public let inputs: [LocalWorkflowReplayArtifact]

    public static func capture(for request: LocalWorkflowRunRequest) throws -> Self {
        let packageURL = try packageRoot(containing: request.workflowURL)
        let validated = try WorkflowPackageValidator.validatePackage(at: packageURL)
        let manifestData = try Data(contentsOf: validated.manifestURL)
        guard try JSONDecoder().decode(WorkflowPackageManifest.self, from: manifestData) == validated.manifest else {
            throw LocalWorkflowReplayError.repairRequired("The workflow package changed during identity capture.")
        }
        let entrypoint = packageURL.appendingPathComponent(validated.manifest.runner.entrypoint).standardizedFileURL
        guard isInside(entrypoint, root: packageURL),
              entrypoint.resolvingSymlinksInPath() == request.workflowURL.resolvingSymlinksInPath() else {
            throw LocalWorkflowReplayError.unavailable("The request must use the validated package entrypoint.")
        }
        let artifact = try captureArtifact(at: packageURL)
        let manifestHash = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        guard artifact.entries.first(where: { $0.relativePath == "manifest.json" })?.sha256 == manifestHash else {
            throw LocalWorkflowReplayError.repairRequired("The workflow manifest changed during identity capture.")
        }
        return Self(schemaVersion: 1, packageURL: artifact.rootURL, packageManifest: validated.manifest,
                    package: artifact, inputs: try request.inputURLs.map { try captureArtifact(at: $0, isInput: true) })
    }

    public func validateCurrentInputs(for request: LocalWorkflowRunRequest) throws {
        guard schemaVersion == 1 else {
            throw LocalWorkflowReplayError.unavailable("This run uses an unsupported identity version.")
        }
        let current = try Self.capture(for: request)
        guard packageManifest == current.packageManifest, package.entries == current.package.entries,
              package.excludedRelativePaths == current.package.excludedRelativePaths else {
            throw LocalWorkflowReplayError.repairRequired("The workflow package changed. Locate the original package before running again.")
        }
        guard inputs.count == current.inputs.count,
              zip(inputs, current.inputs).allSatisfy({ pair in pair.0.entries == pair.1.entries && pair.0.excludedRelativePaths == pair.1.excludedRelativePaths }) else {
            throw LocalWorkflowReplayError.repairRequired("A retained input changed. Locate the original input before running again.")
        }
    }
    static func packageRoot(containing workflowURL: URL) throws -> URL {
        var candidate = workflowURL.standardizedFileURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == WorkflowPackageValidator.packageExtension { return candidate }
            candidate.deleteLastPathComponent()
        }
        throw LocalWorkflowReplayError.unavailable("Run Again requires an identified local workflow package.")
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let prefix = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        return components.count > prefix.count && components.starts(with: prefix)
    }

    private static func captureArtifact(at url: URL, isInput: Bool = false) throws -> LocalWorkflowReplayArtifact {
        try Task.checkCancellation()
        let first = try ProvenancePublicationSnapshot.artifactState(at: url, fileManager: .default)
        let exclusions: [String]
        if isInput, url.pathExtension.lowercased() == WorkflowPackageBundleType.lungfishref.rawValue,
           case .directory = first {
            exclusions = [BundleViewState.filename]
        } else {
            exclusions = []
        }
        let filteredFirst = try removingPresentationFile(from: first, exclusions: exclusions)
        let entries = try flatten(filteredFirst, relativePath: "")
        let second = try ProvenancePublicationSnapshot.artifactState(at: url, fileManager: .default)
        let filteredSecond = try removingPresentationFile(from: second, exclusions: exclusions)
        guard ProvenancePublicationSnapshot.statesMatch(filteredFirst, filteredSecond) else {
            throw LocalWorkflowReplayError.repairRequired("A source changed while its identity was checked: \(url.path)")
        }
        try Task.checkCancellation()
        return LocalWorkflowReplayArtifact(rootURL: url.standardizedFileURL.resolvingSymlinksInPath(),
                                           entries: entries, excludedRelativePaths: exclusions)
    }

    private static func removingPresentationFile(
        from state: ProvenancePublicationArtifactState, exclusions: [String]
    ) throws -> ProvenancePublicationArtifactState {
        guard !exclusions.isEmpty, case .directory(let metadata, let children) = state else { return state }
        let retained = try children.filter { child in
            guard exclusions.contains(child.name) else { return true }
            guard case .file = child.state else {
                throw LocalWorkflowReplayError.unavailable("The presentation-state path must be a regular file.")
            }
            return false
        }
        return .directory(metadata, children: retained)
    }

    private static func flatten(
        _ state: ProvenancePublicationArtifactState, relativePath: String
    ) throws -> [LocalWorkflowReplayArtifact.Entry] {
        switch state {
        case .file(let metadata, let digest):
            guard metadata.size >= 0 else { throw LocalWorkflowReplayError.unavailable("Invalid retained input size.") }
            return [.init(relativePath: relativePath, kind: "file", sha256: digest,
                          sizeBytes: UInt64(metadata.size), executable: metadata.mode & 0o111 != 0)]
        case .directory(_, let children):
            return [.init(relativePath: relativePath, kind: "directory", sha256: nil, sizeBytes: 0, executable: false)]
                + (try children.flatMap { child in
                    try flatten(child.state, relativePath: relativePath.isEmpty ? child.name : relativePath + "/" + child.name)
                })
        case .symbolicLink:
            throw LocalWorkflowReplayError.unavailable("Exact Run Again does not support symbolic links in package or input payloads.")
        case .missing:
            throw LocalWorkflowReplayError.repairRequired("A required package or input is missing. Locate the original source before running again.")
        case .other:
            throw LocalWorkflowReplayError.unavailable("Exact Run Again supports regular files and directories only.")
        }
    }

}

public enum LocalWorkflowReplayError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case repairRequired(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .repairRequired(let reason): return reason
        }
    }
}
