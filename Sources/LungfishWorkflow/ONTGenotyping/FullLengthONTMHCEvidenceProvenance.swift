import Foundation

public enum FullLengthONTMHCArtifactRole: String, Codable, Sendable, Equatable {
    case referenceFASTA
    case sourceClusterFASTA
    case namespacedClusterFASTA
    case commandInput
    case commandOutput
    case commandStdoutLog
    case commandStderrLog
    case evidenceBAM
    case evidenceBAI
}

public enum FullLengthONTMHCArtifactPhase: String, Codable, Sendable, Equatable {
    case input
    case temporary
    case staging
    case final
    case diagnostic
}

public struct FullLengthONTMHCArtifactDescriptor: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let byteSize: UInt64
    public let role: FullLengthONTMHCArtifactRole
    public let phase: FullLengthONTMHCArtifactPhase

    init(
        url: URL,
        role: FullLengthONTMHCArtifactRole,
        phase: FullLengthONTMHCArtifactPhase
    ) throws {
        try FullLengthONTMHCAlignmentSafety().requireRegularFileNoFollow(url, role: role.rawValue)
        path = url.standardizedFileURL.path
        sha256 = try ProvenanceFileHasher.sha256(of: url)
        byteSize = try ProvenanceFileHasher.fileSize(of: url)
        self.role = role
        self.phase = phase
    }
}

public struct FullLengthONTMHCToolVersionRecord: Sendable, Equatable {
    public let toolName: String
    public let version: String
    public let discoveryCommand: FullLengthONTMHCCohortAlignmentCommandRecord
}

public struct FullLengthONTMHCInProcessTransformationRecord: Sendable, Equatable {
    public let workflowName: String
    public let workflowVersion: String
    public let argv: [String]
    public let resolvedOptions: [String: String]
    public let inputs: [FullLengthONTMHCArtifactDescriptor]
    public let outputs: [FullLengthONTMHCArtifactDescriptor]
    public let exitStatus: Int32
    public let startedAt: Date
    public let completedAt: Date
    public let wallTime: TimeInterval

    var capturedArtifactDescriptors: [FullLengthONTMHCArtifactDescriptor] {
        inputs + outputs
    }
}

public struct FullLengthONTMHCArtifactPublicationMapping: Sendable, Equatable {
    public let stagedDescriptor: FullLengthONTMHCArtifactDescriptor
    public let finalDescriptor: FullLengthONTMHCArtifactDescriptor
}

public enum FullLengthONTMHCCleanupKind: String, Codable, Sendable, Equatable {
    case retiredPublicationDirectory
    case temporaryWorkDirectory
}

public struct FullLengthONTMHCCleanupDiagnostic: Sendable, Equatable {
    public let kind: FullLengthONTMHCCleanupKind
    public let retainedDirectoryURL: URL
    public let message: String
    public let publishedArtifactsRemainValid: Bool
}

public protocol FullLengthONTMHCWorkDirectoryCleaning: Sendable {
    func removeWorkDirectory(at url: URL) throws
}

public struct DefaultFullLengthONTMHCWorkDirectoryCleaner: FullLengthONTMHCWorkDirectoryCleaning {
    public init() {}

    public func removeWorkDirectory(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

extension FullLengthONTMHCCohortAlignmentCommandRecord {
    func replacingToolVersion(with version: String?) -> Self {
        .init(
            executableURL: executableURL,
            toolVersion: version,
            argv: argv,
            arguments: arguments,
            inputs: inputs,
            outputs: outputs,
            inputDescriptors: inputDescriptors,
            outputDescriptors: outputDescriptors,
            stdoutLogDescriptor: stdoutLogDescriptor,
            stderrLogDescriptor: stderrLogDescriptor,
            exitStatus: exitStatus,
            stdout: stdout,
            stderr: stderr,
            wasCancelled: wasCancelled,
            startedAt: startedAt,
            completedAt: completedAt,
            wallTime: wallTime
        )
    }

    var capturedArtifactDescriptors: [FullLengthONTMHCArtifactDescriptor] {
        inputDescriptors + outputDescriptors + [stdoutLogDescriptor, stderrLogDescriptor]
    }
}
