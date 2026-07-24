import Foundation
import LungfishIO

struct GenotypeMatrixAnnotationReplayPayload: Codable, Equatable, Sendable {
    static let format = "lungfish.genotype.matrix-annotation-replay.v1"

    enum Action: String, Codable, Equatable, Sendable {
        case setMatrixReview
        case clearMatrixReview
        case upsertMatrixComment
        case removeMatrixComment
    }

    struct TargetMutation: Codable, Equatable, Sendable {
        let target: GenotypeAnnotationSidecar.MatrixTarget
        let beforeComments: [GenotypeAnnotationSidecar.MatrixComment]?
        let resolvedCurrentComment: GenotypeAnnotationSidecar.MatrixComment?
        let afterComments: [GenotypeAnnotationSidecar.MatrixComment]?
        let beforeReviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]?
        let afterReviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]?
        let canonicalizationAudits: [GenotypeAnnotationSidecar.AuditEntry]
        let actionAudit: GenotypeAnnotationSidecar.AuditEntry
    }

    enum ReplayError: Error, Equatable, LocalizedError {
        case priorCommentsMismatch(GenotypeAnnotationSidecar.MatrixTarget)
        case priorReviewsMismatch(GenotypeAnnotationSidecar.MatrixTarget)

        var errorDescription: String? {
            switch self {
            case .priorCommentsMismatch(let target):
                return "Recorded matrix comments do not match replay input for \(target.stableAuditDescription)."
            case .priorReviewsMismatch(let target):
                return "Recorded matrix reviews do not match replay input for \(target.stableAuditDescription)."
            }
        }
    }

    let schemaVersion: Int
    let action: Action
    let author: String
    let timestamp: String
    let targetMutations: [TargetMutation]

    init(
        action: Action,
        author: String,
        timestamp: String,
        targetMutations: [TargetMutation]
    ) {
        self.schemaVersion = 1
        self.action = action
        self.author = author
        self.timestamp = timestamp
        self.targetMutations = targetMutations
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    func applying(
        to prior: GenotypeAnnotationSidecar
    ) throws -> GenotypeAnnotationSidecar {
        var replayed = prior

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
}
