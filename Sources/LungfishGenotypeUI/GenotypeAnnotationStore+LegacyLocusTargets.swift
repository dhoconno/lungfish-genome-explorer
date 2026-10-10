import Foundation
import LungfishIO

/// Matrix reviews and comments saved at a full-length call's pre-N9
/// pseudo-locus (MHC-NHP01270) are read at the call's current locus through
/// `GenotypeMatrixTargetLocusAlias`. An edit at the current locus must also
/// reach the saved entry, or a cleared review or removed comment comes back
/// on the next read and a cleared review still feeds
/// `GenotypeReviewedHaplotypeEvidence`. Each saved entry gets its own target
/// mutation and audit entry, so the replay payload removes it as the store
/// did.
extension GenotypeAnnotationStore {
    typealias MatrixTarget = GenotypeAnnotationSidecar.MatrixTarget

    /// The pre-N9 targets of `targets` that hold a saved entry, in target
    /// order, without the requested targets themselves.
    static func legacyTargets(
        of targets: [MatrixTarget],
        alias: GenotypeMatrixTargetLocusAlias,
        saved: [MatrixTarget]
    ) -> [MatrixTarget] {
        guard !alias.isEmpty else { return [] }
        let savedTargets = Set(saved)
        var seen = Set(targets)
        return targets.flatMap(alias.savedTargets(for:)).filter {
            savedTargets.contains($0) && seen.insert($0).inserted
        }
    }

    /// Gives each requested target without a review of its own the review
    /// saved at its pre-N9 target, the one the matrix showed.
    static func foldLegacyReviews(
        into existing: inout [MatrixTarget: GenotypeAnnotationSidecar.MatrixReviewDisposition],
        targets: [MatrixTarget],
        alias: GenotypeMatrixTargetLocusAlias
    ) {
        let saved = existing
        for target in targets where saved[target] == nil {
            existing[target] = alias.savedTargets(for: target).compactMap { saved[$0] }.first
        }
    }

    /// One removal per pre-N9 target whose review a new review at the
    /// current target replaces. The caller has already dropped the reviews
    /// from the sidecar. Each removal is audited as a cleared review.
    static func legacyReviewRemovals(
        _ legacyTargets: [MatrixTarget],
        reviewsByTarget: [MatrixTarget: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]],
        in latest: inout GenotypeAnnotationSidecar,
        author: String,
        timestamp: String
    ) -> [GenotypeMatrixAnnotationReplayPayload.TargetMutation] {
        legacyTargets.map { target in
            let beforeReviews = reviewsByTarget[target] ?? []
            let audit = GenotypeAnnotationSidecar.AuditEntry(
                action: "clearMatrixReview",
                sample: target.auditSample,
                locus: target.locus,
                slot: nil,
                before: beforeReviews.last?.disposition.rawValue,
                after: nil,
                color: nil,
                reason: "matrix-review",
                rationale: target.stableAuditDescription,
                author: author,
                timestamp: timestamp
            )
            latest.append(audit: audit)
            return .init(
                target: target,
                beforeComments: nil,
                resolvedCurrentComment: nil,
                afterComments: nil,
                beforeReviews: beforeReviews,
                afterReviews: [],
                canonicalizationAudits: [],
                actionAudit: audit
            )
        }
    }
}
