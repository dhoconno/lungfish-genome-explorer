import CryptoKit
import Foundation
import LungfishCore

public struct GenotypeCallOverrideReplayPayload:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = 1
    public static let format = "lungfish.genotype.call-override-replay.v1"
    public static let cliSubcommandName = "replay-call-overrides"

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
        public let analysisIdentity:
            GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity?

        public init(
            operationID: String,
            sample: String,
            author: String,
            timestamp: String,
            analysisIdentity:
                GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity?
        ) {
            self.operationID = operationID
            self.sample = sample
            self.author = author
            self.timestamp = timestamp
            self.analysisIdentity = analysisIdentity
        }
    }

    public struct TargetMutation: Codable, Equatable, Sendable {
        public let locus: String
        public let slot: HaplotypeSlot
        public let baseline: String
        public let before: String
        public let after: String
        public let reason: GenotypeAnnotationSidecar.OverrideReasonTag
        public let rationale: String

        public init(
            locus: String,
            slot: HaplotypeSlot,
            baseline: String,
            before: String,
            after: String,
            reason: GenotypeAnnotationSidecar.OverrideReasonTag,
            rationale: String
        ) {
            self.locus = locus
            self.slot = slot
            self.baseline = baseline
            self.before = before
            self.after = after
            self.reason = reason
            self.rationale = rationale
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
        case priorOverridesMismatch
        case invalidOperation(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                "Unsupported call override replay schema version \(version); expected \(currentSchemaVersion)."
            case let .targetBundlePathMismatch(expected, actual):
                "Replay target bundle mismatch: expected \(expected), found \(actual)."
            case let .targetManifestPathMismatch(expected, actual):
                "Replay target manifest mismatch: expected \(expected), found \(actual)."
            case let .targetManifestChecksumMismatch(expected, actual):
                "Replay target manifest checksum mismatch: expected \(expected), found \(actual)."
            case let .targetManifestSizeMismatch(expected, actual):
                "Replay target manifest size mismatch: expected \(expected), found \(actual)."
            case let .priorSidecarPathMismatch(expected, actual):
                "Replay prior sidecar mismatch: expected \(expected), found \(actual)."
            case let .priorSidecarChecksumMismatch(expected, actual):
                "Replay prior sidecar checksum mismatch: expected \(expected), found \(actual)."
            case let .priorSidecarSizeMismatch(expected, actual):
                "Replay prior sidecar size mismatch: expected \(expected), found \(actual)."
            case let .priorSidecarRevisionMismatch(expected, actual):
                "Replay prior sidecar revision mismatch: expected \(expected), found \(actual)."
            case .priorOverridesMismatch:
                "Recorded prior call overrides do not match the replay input."
            case .invalidOperation(let reason):
                "Invalid call override replay operation: \(reason)"
            }
        }
    }

    public let schemaVersion: Int
    public let operation: OperationMetadata
    public let targetBundle: TargetBundleIdentity
    public let priorSidecar: PriorSidecarIdentity
    public let beforeOverrides: [GenotypeAnnotationSidecar.CallOverride]
    public let afterOverrides: [GenotypeAnnotationSidecar.CallOverride]
    public let targetMutations: [TargetMutation]
    public let auditEntries: [GenotypeAnnotationSidecar.AuditEntry]

    public init(
        operation: OperationMetadata,
        targetBundle: TargetBundleIdentity,
        priorSidecar: PriorSidecarIdentity,
        beforeOverrides: [GenotypeAnnotationSidecar.CallOverride],
        afterOverrides: [GenotypeAnnotationSidecar.CallOverride],
        targetMutations: [TargetMutation],
        auditEntries: [GenotypeAnnotationSidecar.AuditEntry]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.operation = operation
        self.targetBundle = targetBundle
        self.priorSidecar = priorSidecar
        self.beforeOverrides = beforeOverrides
        self.afterOverrides = afterOverrides
        self.targetMutations = targetMutations
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
        let revision = Self.sha256Hex(priorData)
        guard revision == priorSidecar.revisionSHA256 else {
            throw ReplayError.priorSidecarRevisionMismatch(
                expected: priorSidecar.revisionSHA256,
                actual: revision
            )
        }

        var replayed = try GenotypeAnnotationSidecar.decode(priorData)
        try replayed.promoteToCurrentSchema()
        guard replayed.callOverrides == beforeOverrides else {
            throw ReplayError.priorOverridesMismatch
        }
        try validateCoherentOperation(prior: replayed)
        replayed.callOverrides = afterOverrides
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
                + ".call-override-replay.lungfish-provenance.json"
        )
    }

    private func validateCoherentOperation(
        prior: GenotypeAnnotationSidecar
    ) throws {
        guard normalized(operation.operationID) == operation.operationID,
              !operation.operationID.isEmpty,
              normalized(operation.sample) == operation.sample,
              !operation.sample.isEmpty,
              normalized(operation.author) == operation.author,
              !operation.author.isEmpty,
              !targetMutations.isEmpty,
              targetMutations.count == auditEntries.count else {
            throw ReplayError.invalidOperation(
                "operation metadata and changed targets must be complete and normalized."
            )
        }
        if let identity = operation.analysisIdentity,
           identity.assayID.isEmpty || identity.definitionSetID.isEmpty {
            throw ReplayError.invalidOperation(
                "analysis identity values must be nonempty when present."
            )
        }
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime]
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        guard timestampFormatter.date(from: operation.timestamp) != nil
                || fractionalFormatter.date(from: operation.timestamp) != nil
        else {
            throw ReplayError.invalidOperation(
                "operation timestamp must be a valid ISO 8601 date."
            )
        }
        guard !prior.auditLog.contains(where: {
            $0.callOverrideMutation?.operationID == operation.operationID
        }) else {
            throw ReplayError.invalidOperation(
                "operationID \(operation.operationID) was already applied."
            )
        }

        struct Key: Hashable {
            let sample: String
            let locus: String
            let slot: HaplotypeSlot
        }
        func key(
            _ override: GenotypeAnnotationSidecar.CallOverride
        ) -> Key {
            Key(
                sample: override.sample,
                locus: override.locus,
                slot: override.slot
            )
        }
        let beforeByKey = Dictionary(grouping: beforeOverrides, by: key)
        let afterByKey = Dictionary(grouping: afterOverrides, by: key)
        var seen = Set<Key>()
        for (mutation, audit) in zip(targetMutations, auditEntries) {
            let targetKey = Key(
                sample: operation.sample,
                locus: mutation.locus,
                slot: mutation.slot
            )
            guard seen.insert(targetKey).inserted,
                  audit.sample == operation.sample,
                  audit.locus == mutation.locus,
                  audit.slot == mutation.slot,
                  audit.before == mutation.before,
                  audit.after == mutation.after,
                  audit.reason == mutation.reason.rawValue,
                  audit.rationale == mutation.rationale,
                  audit.author == operation.author,
                  audit.timestamp == operation.timestamp,
                  audit.callOverrideMutation?.operationID
                    == operation.operationID,
                  audit.callOverrideMutation?.priorSidecarSHA256
                    == priorSidecar.descriptor.checksumSHA256,
                  audit.callOverrideMutation?.analysisIdentity
                    == operation.analysisIdentity else {
                throw ReplayError.invalidOperation(
                    "each changed target requires one matching structured audit."
                )
            }
            let beforeRecords = beforeByKey[targetKey] ?? []
            let afterRecords = afterByKey[targetKey] ?? []
            guard beforeRecords != afterRecords else {
                throw ReplayError.invalidOperation(
                    "each target mutation must change its stored override records."
                )
            }
            let before = authoritativeOverride(
                beforeRecords,
                analysisIdentity: operation.analysisIdentity
            )
            guard mutation.before
                    == (before?.overrideCall ?? mutation.baseline),
                  before?.originalCall == nil
                    || before?.originalCall == mutation.baseline else {
                throw ReplayError.invalidOperation(
                    "recorded target baseline or before value is inconsistent."
                )
            }
            if mutation.after == mutation.baseline {
                guard afterRecords.isEmpty,
                      audit.action == "clearOverride" else {
                    throw ReplayError.invalidOperation(
                        "a restore must remove the override and record clearOverride."
                    )
                }
            } else {
                guard afterRecords.count == 1,
                      let after = afterRecords.first,
                      after.originalCall == mutation.baseline,
                      after.overrideCall == mutation.after,
                      after.reasonTag == mutation.reason,
                      after.rationale == mutation.rationale,
                      after.author == operation.author,
                      after.timestamp == operation.timestamp,
                      after.analysisIdentity == operation.analysisIdentity,
                      after.operationID == operation.operationID,
                      audit.action == "override" else {
                    throw ReplayError.invalidOperation(
                        "an override target must match its after record."
                    )
                }
            }
        }
        let changedKeys = Set(targetMutations.map {
            Key(sample: operation.sample, locus: $0.locus, slot: $0.slot)
        })
        let untouchedBefore = beforeOverrides.filter {
            !changedKeys.contains(key($0))
        }
        let untouchedAfter = afterOverrides.filter {
            !changedKeys.contains(key($0))
        }
        guard untouchedBefore == untouchedAfter else {
            throw ReplayError.invalidOperation(
                "unrelated call overrides must remain exact and ordered."
            )
        }
    }

    private func authoritativeOverride(
        _ overrides: [GenotypeAnnotationSidecar.CallOverride],
        analysisIdentity:
            GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity?
    ) -> GenotypeAnnotationSidecar.CallOverride? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        var selected: (
            entry: GenotypeAnnotationSidecar.CallOverride,
            date: Date,
            index: Int,
            identityPriority: Int
        )?
        for (index, entry) in overrides.enumerated() {
            let identityPriority: Int
            if let analysisIdentity {
                if entry.analysisIdentity == analysisIdentity {
                    identityPriority = 2
                } else if entry.analysisIdentity == nil {
                    identityPriority = 1
                } else {
                    continue
                }
            } else {
                identityPriority = 0
            }
            guard let date = fractional.date(from: entry.timestamp)
                    ?? internet.date(from: entry.timestamp) else {
                continue
            }
            if let current = selected,
               identityPriority < current.identityPriority
                || (
                    identityPriority == current.identityPriority
                        && (
                            date < current.date
                                || (
                                    date == current.date
                                        && index < current.index
                                )
                        )
                ) {
                continue
            }
            selected = (entry, date, index, identityPriority)
        }
        return selected?.entry
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
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
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
