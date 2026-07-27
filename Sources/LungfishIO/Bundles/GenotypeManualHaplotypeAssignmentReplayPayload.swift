import CryptoKit
import Foundation

public struct GenotypeManualHaplotypeAssignmentReplayPayload:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = 1
    public static let format =
        "lungfish.genotype.manual-haplotype-assignment-replay.v1"
    public static let cliSubcommandName =
        "replay-manual-haplotype-assignments"

    public struct ArtifactDescriptor: Codable, Equatable, Sendable {
        public let path: String
        public let checksumSHA256: String
        public let fileSize: UInt64

        public init(path: String, checksumSHA256: String, fileSize: UInt64) {
            self.path = path
            self.checksumSHA256 = checksumSHA256
            self.fileSize = fileSize
        }
    }

    public struct OperationMetadata: Codable, Equatable, Sendable {
        public let operationID: String
        public let sample: String
        public let author: String
        public let timestamp: String
        public let copySourceSample: String?

        public init(
            operationID: String,
            sample: String,
            author: String,
            timestamp: String,
            copySourceSample: String?
        ) {
            self.operationID = operationID
            self.sample = sample
            self.author = author
            self.timestamp = timestamp
            self.copySourceSample = copySourceSample
        }
    }

    public struct TargetBundleIdentity: Codable, Equatable, Sendable {
        public let bundlePath: String
        public let manifest: ArtifactDescriptor

        public init(bundlePath: String, manifest: ArtifactDescriptor) {
            self.bundlePath = bundlePath
            self.manifest = manifest
        }
    }

    public struct PriorSidecarIdentity: Codable, Equatable, Sendable {
        public let descriptor: ArtifactDescriptor
        public let revisionSHA256: String

        public init(
            descriptor: ArtifactDescriptor,
            revisionSHA256: String
        ) {
            self.descriptor = descriptor
            self.revisionSHA256 = revisionSHA256
        }
    }

    public enum ReplayError: Error, Equatable, LocalizedError, Sendable {
        case unsupportedSchemaVersion(Int)
        case targetBundlePathMismatch(expected: String, actual: String)
        case targetManifestPathMismatch(expected: String, actual: String)
        case targetManifestChecksumMismatch(expected: String, actual: String)
        case targetManifestSizeMismatch(expected: UInt64, actual: UInt64)
        case priorSidecarPathMismatch(expected: String, actual: String)
        case priorSidecarChecksumMismatch(expected: String, actual: String)
        case priorSidecarSizeMismatch(expected: UInt64, actual: UInt64)
        case priorSidecarRevisionMismatch(expected: String, actual: String)
        case priorAssignmentsMismatch

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                "Unsupported manual haplotype assignment replay schema version \(version); expected \(currentSchemaVersion)."
            case .targetBundlePathMismatch(let expected, let actual):
                "Replay target bundle mismatch: expected \(expected), found \(actual)."
            case .targetManifestPathMismatch(let expected, let actual):
                "Replay target manifest mismatch: expected \(expected), found \(actual)."
            case .targetManifestChecksumMismatch(let expected, let actual):
                "Replay target manifest checksum mismatch: expected \(expected), found \(actual)."
            case .targetManifestSizeMismatch(let expected, let actual):
                "Replay target manifest size mismatch: expected \(expected), found \(actual)."
            case .priorSidecarPathMismatch(let expected, let actual):
                "Replay prior sidecar mismatch: expected \(expected), found \(actual)."
            case .priorSidecarChecksumMismatch(let expected, let actual):
                "Replay prior sidecar checksum mismatch: expected \(expected), found \(actual)."
            case .priorSidecarSizeMismatch(let expected, let actual):
                "Replay prior sidecar size mismatch: expected \(expected), found \(actual)."
            case .priorSidecarRevisionMismatch(let expected, let actual):
                "Replay prior sidecar revision mismatch: expected \(expected), found \(actual)."
            case .priorAssignmentsMismatch:
                "Recorded prior manual haplotype assignments do not match the replay input."
            }
        }
    }

    public let schemaVersion: Int
    public let operation: OperationMetadata
    public let targetBundle: TargetBundleIdentity
    public let priorSidecar: PriorSidecarIdentity
    public let beforeAssignments: [ManualHaplotypeAssignment]
    public let afterAssignments: [ManualHaplotypeAssignment]
    public let auditEntries: [GenotypeAnnotationSidecar.AuditEntry]

    public init(
        operation: OperationMetadata,
        targetBundle: TargetBundleIdentity,
        priorSidecar: PriorSidecarIdentity,
        beforeAssignments: [ManualHaplotypeAssignment],
        afterAssignments: [ManualHaplotypeAssignment],
        auditEntries: [GenotypeAnnotationSidecar.AuditEntry]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.operation = operation
        self.targetBundle = targetBundle
        self.priorSidecar = priorSidecar
        self.beforeAssignments = beforeAssignments
        self.afterAssignments = afterAssignments
        self.auditEntries = auditEntries
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        let payload = try JSONDecoder().decode(Self.self, from: data)
        guard payload.schemaVersion == currentSchemaVersion else {
            throw ReplayError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        return payload
    }

    public func applying(
        to priorData: Data,
        targetBundleURL: URL,
        targetManifestData: Data
    ) throws -> GenotypeAnnotationSidecar {
        let actualBundlePath = targetBundleURL.standardizedFileURL.path
        guard targetBundle.bundlePath == actualBundlePath else {
            throw ReplayError.targetBundlePathMismatch(
                expected: targetBundle.bundlePath,
                actual: actualBundlePath
            )
        }

        let actualManifestPath = ONTGenotypeResultBundleManifest.filename
        guard targetBundle.manifest.path == actualManifestPath else {
            throw ReplayError.targetManifestPathMismatch(
                expected: targetBundle.manifest.path,
                actual: actualManifestPath
            )
        }
        try Self.validate(
            targetManifestData,
            descriptor: targetBundle.manifest,
            checksumError: ReplayError.targetManifestChecksumMismatch,
            sizeError: ReplayError.targetManifestSizeMismatch
        )

        let actualSidecarPath = GenotypeAnnotationSidecar.filename
        guard priorSidecar.descriptor.path == actualSidecarPath else {
            throw ReplayError.priorSidecarPathMismatch(
                expected: priorSidecar.descriptor.path,
                actual: actualSidecarPath
            )
        }
        try Self.validate(
            priorData,
            descriptor: priorSidecar.descriptor,
            checksumError: ReplayError.priorSidecarChecksumMismatch,
            sizeError: ReplayError.priorSidecarSizeMismatch
        )
        let actualPriorRevision = Self.sha256Hex(priorData)
        guard priorSidecar.revisionSHA256 == actualPriorRevision else {
            throw ReplayError.priorSidecarRevisionMismatch(
                expected: priorSidecar.revisionSHA256,
                actual: actualPriorRevision
            )
        }

        var replayed = try GenotypeAnnotationSidecar.decode(priorData)
        try replayed.promoteToCurrentSchema()
        guard replayed.manualHaplotypeAssignments == beforeAssignments else {
            throw ReplayError.priorAssignmentsMismatch
        }
        replayed.manualHaplotypeAssignments = afterAssignments
        for audit in auditEntries {
            replayed.append(audit: audit)
        }
        return replayed
    }

    public static func replayOutputProvenanceURL(
        forBundleAt bundleURL: URL
    ) -> URL {
        let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(
            forBundleAt: bundleURL
        )
        return URL(
            fileURLWithPath:
                sidecarURL.path
                + ".manual-haplotype-replay.lungfish-provenance.json"
        )
    }

    private static func validate(
        _ data: Data,
        descriptor: ArtifactDescriptor,
        checksumError: (String, String) -> ReplayError,
        sizeError: (UInt64, UInt64) -> ReplayError
    ) throws {
        let actualChecksum = sha256Hex(data)
        guard descriptor.checksumSHA256 == actualChecksum else {
            throw checksumError(descriptor.checksumSHA256, actualChecksum)
        }
        let actualSize = UInt64(data.count)
        guard descriptor.fileSize == actualSize else {
            throw sizeError(descriptor.fileSize, actualSize)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
