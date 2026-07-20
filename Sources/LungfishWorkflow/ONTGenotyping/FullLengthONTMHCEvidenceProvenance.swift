import Foundation

public enum FullLengthONTMHCArtifactRole: String, Codable, Sendable, Equatable {
    case referenceFASTA
    case sourceClusterFASTA
    case snapshotClusterFASTA
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
    case planned
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

    init(
        path: String,
        sha256: String,
        byteSize: UInt64,
        role: FullLengthONTMHCArtifactRole,
        phase: FullLengthONTMHCArtifactPhase
    ) {
        self.path = path
        self.sha256 = sha256
        self.byteSize = byteSize
        self.role = role
        self.phase = phase
    }

    func relocated(
        to url: URL,
        role: FullLengthONTMHCArtifactRole,
        phase: FullLengthONTMHCArtifactPhase
    ) -> Self {
        .init(
            path: url.standardizedFileURL.path,
            sha256: sha256,
            byteSize: byteSize,
            role: role,
            phase: phase
        )
    }
}

protocol FullLengthONTMHCArtifactDescriptorProviding: Sendable {
    func descriptor(
        for url: URL,
        role: FullLengthONTMHCArtifactRole,
        phase: FullLengthONTMHCArtifactPhase
    ) throws -> FullLengthONTMHCArtifactDescriptor
}

struct DefaultFullLengthONTMHCArtifactDescriptorProvider: FullLengthONTMHCArtifactDescriptorProviding {
    func descriptor(
        for url: URL,
        role: FullLengthONTMHCArtifactRole,
        phase: FullLengthONTMHCArtifactPhase
    ) throws -> FullLengthONTMHCArtifactDescriptor {
        try FullLengthONTMHCArtifactDescriptor(url: url, role: role, phase: phase)
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
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let inputs: [FullLengthONTMHCArtifactDescriptor]
    public let outputs: [FullLengthONTMHCArtifactDescriptor]
    public let exitStatus: Int32
    public let startedAt: Date
    public let completedAt: Date
    public let wallTime: TimeInterval

    public init(
        workflowName: String,
        workflowVersion: String,
        argv: [String],
        resolvedOptions: [String: String],
        runtimeIdentity: ProvenanceRuntimeIdentity = ProvenanceRuntimeIdentity(),
        inputs: [FullLengthONTMHCArtifactDescriptor],
        outputs: [FullLengthONTMHCArtifactDescriptor],
        exitStatus: Int32,
        startedAt: Date,
        completedAt: Date,
        wallTime: TimeInterval
    ) {
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.argv = argv
        self.resolvedOptions = resolvedOptions
        self.runtimeIdentity = runtimeIdentity
        self.inputs = inputs
        self.outputs = outputs
        self.exitStatus = exitStatus
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.wallTime = wallTime
    }

    var capturedArtifactDescriptors: [FullLengthONTMHCArtifactDescriptor] {
        inputs + outputs
    }

    public func provenanceStep() -> ProvenanceStep {
        ProvenanceStep(
            toolName: workflowName,
            toolVersion: workflowVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: resolvedOptions.mapValues(ParameterValue.string),
            runtimeIdentity: runtimeIdentity,
            inputs: inputs.map { $0.provenanceDescriptor(forcedRole: .input) },
            outputs: outputs.map {
                $0.provenanceDescriptor(
                    forcedRole: $0.role == .evidenceBAI ? .index : .output
                )
            },
            exitStatus: Int(exitStatus),
            wallTimeSeconds: wallTime,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}

private extension FullLengthONTMHCArtifactDescriptor {
    func provenanceDescriptor(forcedRole: FileRole) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: path,
            checksumSHA256: sha256,
            fileSize: byteSize,
            format: provenanceFormat,
            role: forcedRole
        )
    }

    var provenanceFormat: FileFormat {
        switch role {
        case .referenceFASTA, .sourceClusterFASTA, .snapshotClusterFASTA, .namespacedClusterFASTA:
            return .fasta
        case .evidenceBAM:
            return .bam
        case .commandStdoutLog, .commandStderrLog:
            return path.hasSuffix(".sam") ? .sam : .text
        case .evidenceBAI:
            return .unknown
        case .commandInput, .commandOutput:
            let normalizedPath = path.lowercased()
            if normalizedPath.hasSuffix(".bam") { return .bam }
            if normalizedPath.hasSuffix(".sam") { return .sam }
            if normalizedPath.hasSuffix(".fa") || normalizedPath.hasSuffix(".fasta") { return .fasta }
            return .unknown
        }
    }
}

public struct FullLengthONTMHCArtifactPublicationMapping: Sendable, Equatable {
    public let stagedDescriptor: FullLengthONTMHCArtifactDescriptor
    public let finalDescriptor: FullLengthONTMHCArtifactDescriptor
    public let isPublished: Bool

    public init(
        stagedDescriptor: FullLengthONTMHCArtifactDescriptor,
        finalDescriptor: FullLengthONTMHCArtifactDescriptor,
        isPublished: Bool = true
    ) {
        self.stagedDescriptor = stagedDescriptor
        self.finalDescriptor = finalDescriptor
        self.isPublished = isPublished
    }
}

public struct FullLengthONTMHCArtifactDescriptorCaptureError: Sendable, Equatable {
    public let path: String
    public let role: FullLengthONTMHCArtifactRole
    public let message: String

    public init(path: String, role: FullLengthONTMHCArtifactRole, message: String) {
        self.path = path
        self.role = role
        self.message = message
    }
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
            descriptorCaptureErrors: descriptorCaptureErrors,
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
