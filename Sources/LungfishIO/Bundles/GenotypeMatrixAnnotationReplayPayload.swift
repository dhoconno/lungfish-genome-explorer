import Foundation

public struct GenotypeMatrixAnnotationReplayPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let format = "lungfish.genotype.matrix-annotation-replay.v1"
    public static let cliSubcommandName = "replay-matrix-annotation"

    public enum Action: String, Codable, Equatable, Sendable {
        case setMatrixReview
        case clearMatrixReview
        case upsertMatrixComment
        case removeMatrixComment
    }

    public struct TargetMutation: Codable, Equatable, Sendable {
        public let target: GenotypeAnnotationSidecar.MatrixTarget
        public let beforeComments: [GenotypeAnnotationSidecar.MatrixComment]?
        public let resolvedCurrentComment: GenotypeAnnotationSidecar.MatrixComment?
        public let afterComments: [GenotypeAnnotationSidecar.MatrixComment]?
        public let beforeReviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]?
        public let afterReviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]?
        public let canonicalizationAudits: [GenotypeAnnotationSidecar.AuditEntry]
        public let actionAudit: GenotypeAnnotationSidecar.AuditEntry

        public init(
            target: GenotypeAnnotationSidecar.MatrixTarget,
            beforeComments: [GenotypeAnnotationSidecar.MatrixComment]?,
            resolvedCurrentComment: GenotypeAnnotationSidecar.MatrixComment?,
            afterComments: [GenotypeAnnotationSidecar.MatrixComment]?,
            beforeReviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]?,
            afterReviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]?,
            canonicalizationAudits: [GenotypeAnnotationSidecar.AuditEntry],
            actionAudit: GenotypeAnnotationSidecar.AuditEntry
        ) {
            self.target = target
            self.beforeComments = beforeComments
            self.resolvedCurrentComment = resolvedCurrentComment
            self.afterComments = afterComments
            self.beforeReviews = beforeReviews
            self.afterReviews = afterReviews
            self.canonicalizationAudits = canonicalizationAudits
            self.actionAudit = actionAudit
        }
    }

    public enum ReplayError: Error, Equatable, LocalizedError {
        case unsupportedSchemaVersion(Int)
        case priorCommentsMismatch(GenotypeAnnotationSidecar.MatrixTarget)
        case priorReviewsMismatch(GenotypeAnnotationSidecar.MatrixTarget)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                return "Unsupported matrix annotation replay schema version \(version); expected \(currentSchemaVersion)."
            case .priorCommentsMismatch(let target):
                return "Recorded matrix comments do not match replay input for \(target.stableAuditDescription)."
            case .priorReviewsMismatch(let target):
                return "Recorded matrix reviews do not match replay input for \(target.stableAuditDescription)."
            }
        }
    }

    public let schemaVersion: Int
    public let action: Action
    public let author: String
    public let timestamp: String
    public let targetMutations: [TargetMutation]

    public init(
        action: Action,
        author: String,
        timestamp: String,
        targetMutations: [TargetMutation]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.action = action
        self.author = author
        self.timestamp = timestamp
        self.targetMutations = targetMutations
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
        to prior: GenotypeAnnotationSidecar
    ) throws -> GenotypeAnnotationSidecar {
        var replayed = prior
        try replayed.promoteToCurrentSchema()

        for mutation in targetMutations {
            if let beforeComments = mutation.beforeComments {
                guard replayed.matrixComments.filter({ $0.target == mutation.target }) == beforeComments else {
                    throw ReplayError.priorCommentsMismatch(mutation.target)
                }
            }
            if let beforeReviews = mutation.beforeReviews {
                guard replayed.matrixReviews.filter({ $0.target == mutation.target }) == beforeReviews else {
                    throw ReplayError.priorReviewsMismatch(mutation.target)
                }
            }
        }

        let commentTargets = Set(targetMutations.compactMap {
            $0.beforeComments == nil ? nil : $0.target
        })
        if !commentTargets.isEmpty {
            replayed.matrixComments.removeAll { commentTargets.contains($0.target) }
            for mutation in targetMutations {
                replayed.matrixComments.append(contentsOf: mutation.afterComments ?? [])
            }
        }

        let reviewTargets = Set(targetMutations.compactMap {
            $0.beforeReviews == nil ? nil : $0.target
        })
        if !reviewTargets.isEmpty {
            replayed.matrixReviews.removeAll { reviewTargets.contains($0.target) }
            for mutation in targetMutations {
                replayed.matrixReviews.append(contentsOf: mutation.afterReviews ?? [])
            }
        }

        for mutation in targetMutations {
            for audit in mutation.canonicalizationAudits {
                replayed.append(audit: audit)
            }
            replayed.append(audit: mutation.actionAudit)
        }
        return replayed
    }

    public static func replayOutputProvenanceURL(for outputURL: URL) -> URL {
        URL(fileURLWithPath: outputURL.path + ".replay.lungfish-provenance.json")
    }
}
