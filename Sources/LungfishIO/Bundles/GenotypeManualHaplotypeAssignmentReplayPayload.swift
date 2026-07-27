import CryptoKit
import Foundation
import LungfishCore

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
        case invalidOperation(String)

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
            case .invalidOperation(let reason):
                "Invalid manual haplotype assignment replay operation: \(reason)"
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
        try validateCoherentOperation(prior: replayed)
        replayed.manualHaplotypeAssignments = afterAssignments
        for audit in auditEntries {
            replayed.append(audit: audit)
        }
        return replayed
    }

    private func validateCoherentOperation(
        prior: GenotypeAnnotationSidecar
    ) throws {
        let operationID = operation.operationID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operationID.isEmpty, operationID == operation.operationID else {
            throw ReplayError.invalidOperation(
                "operationID must be nonempty and whitespace-normalized."
            )
        }
        let sample = operation.sample
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !sample.isEmpty, sample == operation.sample else {
            throw ReplayError.invalidOperation(
                "operation sample must be nonempty and normalized."
            )
        }
        let author = operation.author
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !author.isEmpty, author == operation.author else {
            throw ReplayError.invalidOperation(
                "operation author must be nonempty and normalized."
            )
        }
        let fractionalTimestampFormatter = ISO8601DateFormatter()
        fractionalTimestampFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime]
        guard fractionalTimestampFormatter.date(from: operation.timestamp) != nil
                || timestampFormatter.date(from: operation.timestamp) != nil
        else {
            throw ReplayError.invalidOperation(
                "operation timestamp must be a valid ISO 8601 date."
            )
        }
        if let copySourceSample = operation.copySourceSample {
            let normalizedCopySourceSample = copySourceSample
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
            guard !normalizedCopySourceSample.isEmpty,
                  normalizedCopySourceSample == copySourceSample else {
                throw ReplayError.invalidOperation(
                    "copy source sample must be nonempty and normalized when present."
                )
            }
        }
        guard !prior.auditLog.contains(where: {
            $0.manualHaplotypeAssignment?.operationID == operation.operationID
        }) else {
            throw ReplayError.invalidOperation(
                "operationID \(operation.operationID) was already applied."
            )
        }

        let isSelectedSample: (ManualHaplotypeAssignment) -> Bool = {
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedSampleIdentity($0.sample) == operation.sample
        }
        guard beforeAssignments.filter({ !isSelectedSample($0) })
                == afterAssignments.filter({ !isSelectedSample($0) })
        else {
            throw ReplayError.invalidOperation(
                "assignments for unrelated samples must remain exact."
            )
        }

        let selectedBefore = beforeAssignments.filter {
            isSelectedSample($0)
        }
        let selectedAfter = afterAssignments.filter {
            isSelectedSample($0)
        }
        let selectedBeforeOrphans = selectedBefore.filter {
            GenotypeManualHaplotypeLocus(normalizing: $0.locus) == nil
        }
        let selectedAfterOrphans = selectedAfter.filter {
            GenotypeManualHaplotypeLocus(normalizing: $0.locus) == nil
        }
        guard selectedBeforeOrphans == selectedAfterOrphans else {
            throw ReplayError.invalidOperation(
                "unrecognized selected-sample loci must remain exact and ordered."
            )
        }
        let recognizedSelectedBefore = selectedBefore.filter {
            GenotypeManualHaplotypeLocus(normalizing: $0.locus) != nil
        }
        let recognizedSelectedAfter = selectedAfter.filter {
            GenotypeManualHaplotypeLocus(normalizing: $0.locus) != nil
        }
        let beforeState = try selectedBeforeState(
            recognizedSelectedBefore
        )
        let targetBefore = beforeState.effectiveByKey
        let targetAfter = try canonicalAfterMap(recognizedSelectedAfter)
        let canonicalizationKeys = Set(beforeState.rawByKey.compactMap {
            key, rawRecords in
            guard let effective = targetBefore[key] else {
                return key
            }
            let needsCanonicalization =
                rawRecords.count != 1
                || effective.sample != operation.sample
                || effective.locus != key.locus.rawValue
                || !Self.hasStableAssignmentID(effective)
            return needsCanonicalization ? key : nil
        })
        let allKeys = Set(targetBefore.keys).union(targetAfter.keys)
        let changedKeys = Set(allKeys.filter { key in
            guard let before = targetBefore[key],
                  let after = targetAfter[key] else {
                return true
            }
            return before.label != after.label
                || before.colorTokenIndex != after.colorTokenIndex
                || canonicalizationKeys.contains(key)
        })
        guard !changedKeys.isEmpty else {
            throw ReplayError.invalidOperation(
                "a replay operation must contain at least one assignment change."
            )
        }

        for key in allKeys {
            let before = targetBefore[key]
            let after = targetAfter[key]
            guard changedKeys.contains(key) else {
                guard before == after else {
                    throw ReplayError.invalidOperation(
                        "unchanged canonical assignments must remain exact."
                    )
                }
                continue
            }
            if let after {
                guard after.author == operation.author,
                      after.updatedAt == operation.timestamp else {
                    throw ReplayError.invalidOperation(
                        "changed after records must carry the operation author and timestamp."
                    )
                }
            }
            switch (before, after) {
            case let (.some(before), .some(after)):
                guard GenotypeManualHaplotypeAssignmentInputValidator
                        .normalizedSampleIdentity(before.sample)
                        == after.sample,
                      before.slot == after.slot,
                      before.diagnosticAlleles == after.diagnosticAlleles,
                      before.notes == after.notes else {
                    throw ReplayError.invalidOperation(
                        "updates must preserve key, diagnostic alleles, and notes."
                    )
                }
                if Self.hasStableAssignmentID(before) {
                    guard before.assignmentID == after.assignmentID else {
                        throw ReplayError.invalidOperation(
                            "updates must preserve an existing assignment ID."
                        )
                    }
                } else {
                    guard Self.hasStableAssignmentID(after) else {
                        throw ReplayError.invalidOperation(
                            "legacy assignments missing an ID must receive one."
                        )
                    }
                }
                guard before.label != after.label
                        || before.colorTokenIndex != after.colorTokenIndex
                        || canonicalizationKeys.contains(key) else {
                    throw ReplayError.invalidOperation(
                        "updates must change editable data or canonicalize legacy state."
                    )
                }
            case let (.none, .some(after)):
                guard after.diagnosticAlleles.isEmpty,
                      after.notes.isEmpty,
                      Self.hasStableAssignmentID(after) else {
                    throw ReplayError.invalidOperation(
                        "new assignments require a stable ID and empty diagnostic alleles and notes."
                    )
                }
            case (.some, .none):
                break
            case (.none, .none):
                throw ReplayError.invalidOperation(
                    "derived changed key has no before or after record."
                )
            }
        }

        let aggregateAudits = auditEntries.filter {
            $0.action == "replaceManualHaplotypeAssignments"
        }
        guard aggregateAudits.count == 1,
              auditEntries.count == changedKeys.count + 1 else {
            throw ReplayError.invalidOperation(
                "replay requires one detailed audit per changed key and exactly one aggregate audit."
            )
        }
        try validateAggregateAudit(aggregateAudits[0])

        let detailedAudits = auditEntries.filter {
            $0.action != "replaceManualHaplotypeAssignments"
        }
        var auditedKeys = Set<GenotypeManualHaplotypeAssignmentKey>()
        for audit in detailedAudits {
            guard audit.sample == operation.sample,
                  let rawLocus = audit.locus,
                  let locus = GenotypeManualHaplotypeLocus(
                    normalizing: rawLocus
                  ),
                  rawLocus == locus.rawValue,
                  let slot = audit.slot else {
                throw ReplayError.invalidOperation(
                    "detailed audits require the operation sample and canonical locus/slot."
                )
            }
            let key = GenotypeManualHaplotypeAssignmentKey(
                sample: audit.sample,
                locus: locus,
                slot: slot
            )
            guard changedKeys.contains(key), auditedKeys.insert(key).inserted else {
                throw ReplayError.invalidOperation(
                    "detailed audits must map uniquely to changed assignment keys."
                )
            }
            try validateDetailedAudit(
                audit,
                before: targetBefore[key],
                after: targetAfter[key]
            )
        }
        guard auditedKeys == Set(changedKeys) else {
            throw ReplayError.invalidOperation(
                "one or more changed assignment keys lack a detailed audit."
            )
        }
    }

    private struct SelectedBeforeState {
        let rawByKey: [
            GenotypeManualHaplotypeAssignmentKey: [
                ManualHaplotypeAssignment
            ]
        ]
        let effectiveByKey: [
            GenotypeManualHaplotypeAssignmentKey: ManualHaplotypeAssignment
        ]
    }

    private func selectedBeforeState(
        _ assignments: [ManualHaplotypeAssignment]
    ) throws -> SelectedBeforeState {
        var rawByKey: [
            GenotypeManualHaplotypeAssignmentKey: [
                ManualHaplotypeAssignment
            ]
        ] = [:]
        for assignment in assignments {
            guard let locus = GenotypeManualHaplotypeLocus(
                normalizing: assignment.locus
            ) else {
                throw ReplayError.invalidOperation(
                    "selected legacy assignments must use a recognized locus."
                )
            }
            let key = GenotypeManualHaplotypeAssignmentKey(
                sample: operation.sample,
                locus: locus,
                slot: assignment.slot
            )
            rawByKey[key, default: []].append(assignment)
        }
        let effectiveByKey = GenotypeManualHaplotypeAssignmentIndex(
            assignments: assignments
        ).assignmentsByKey.filter { $0.key.sample == operation.sample }
        guard Set(rawByKey.keys) == Set(effectiveByKey.keys) else {
            throw ReplayError.invalidOperation(
                "selected legacy assignments could not be resolved consistently."
            )
        }
        return SelectedBeforeState(
            rawByKey: rawByKey,
            effectiveByKey: effectiveByKey
        )
    }

    private func canonicalAfterMap(
        _ assignments: [ManualHaplotypeAssignment]
    ) throws -> [
        GenotypeManualHaplotypeAssignmentKey: ManualHaplotypeAssignment
    ] {
        let canonicalColors = Set(
            HaplotypeColorToken.canonicalPalette.map(\.canonicalIndex)
        )
        var result: [
            GenotypeManualHaplotypeAssignmentKey: ManualHaplotypeAssignment
        ] = [:]
        for assignment in assignments {
            let sample = assignment.sample
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
            guard !sample.isEmpty, sample == assignment.sample,
                  let locus = GenotypeManualHaplotypeLocus(
                    normalizing: assignment.locus
                  ),
                  assignment.locus == locus.rawValue,
                  let validatedLabel =
                    try? GenotypeManualHaplotypeAssignmentInputValidator
                        .validatedLabel(assignment.label),
                  validatedLabel == assignment.label,
                  canonicalColors.contains(assignment.colorTokenIndex),
                  Self.hasStableAssignmentID(assignment) else {
                throw ReplayError.invalidOperation(
                    "selected after assignments must be valid canonical records."
                )
            }
            let key = GenotypeManualHaplotypeAssignmentKey(
                sample: sample,
                locus: locus,
                slot: assignment.slot
            )
            guard result.updateValue(assignment, forKey: key) == nil else {
                throw ReplayError.invalidOperation(
                    "selected after assignments contain a duplicate canonical key."
                )
            }
        }
        return result
    }

    private static func hasStableAssignmentID(
        _ assignment: ManualHaplotypeAssignment
    ) -> Bool {
        guard let assignmentID = assignment.assignmentID else {
            return false
        }
        return !assignmentID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func validateDetailedAudit(
        _ audit: GenotypeAnnotationSidecar.AuditEntry,
        before: ManualHaplotypeAssignment?,
        after: ManualHaplotypeAssignment?
    ) throws {
        let expectedAction: String
        switch (before, after) {
        case (.none, .some):
            expectedAction = "addManualHaplotypeAssignment"
        case (.some, .some):
            // Canonicalization-only migrations deliberately reuse the existing
            // update action so GUI and CLI audit timelines share one stable
            // vocabulary for an existing semantic assignment key.
            expectedAction = "updateManualHaplotypeAssignment"
        case (.some, .none):
            expectedAction = "removeManualHaplotypeAssignment"
        case (.none, .none):
            throw ReplayError.invalidOperation(
                "detailed audit has no before or after record."
            )
        }
        guard audit.action == expectedAction,
              audit.author == operation.author,
              audit.timestamp == operation.timestamp,
              audit.before == before?.label,
              audit.after == after?.label,
              audit.color == after.map({
                  String($0.colorTokenIndex)
              }),
              let structured = audit.manualHaplotypeAssignment,
              structured.operationID == operation.operationID,
              structured.priorSidecarSHA256
                == priorSidecar.descriptor.checksumSHA256,
              structured.before == before,
              structured.after == after,
              structured.copySourceSample == operation.copySourceSample else {
            throw ReplayError.invalidOperation(
                "detailed audit does not match the derived assignment change."
            )
        }
    }

    private func validateAggregateAudit(
        _ audit: GenotypeAnnotationSidecar.AuditEntry
    ) throws {
        guard audit.sample == operation.sample,
              audit.locus == nil,
              audit.slot == nil,
              audit.before == nil,
              audit.after == nil,
              audit.color == nil,
              audit.author == operation.author,
              audit.timestamp == operation.timestamp,
              let structured = audit.manualHaplotypeAssignment,
              structured.operationID == operation.operationID,
              structured.priorSidecarSHA256
                == priorSidecar.descriptor.checksumSHA256,
              structured.before == nil,
              structured.after == nil,
              structured.copySourceSample == operation.copySourceSample else {
            throw ReplayError.invalidOperation(
                "aggregate audit does not match the replay operation metadata."
            )
        }
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
