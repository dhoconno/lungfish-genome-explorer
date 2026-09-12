import Foundation

/// Resolves annotation eligibility without changing raw evidence or stored reviews.
/// Targets are grouped exactly, including stable cluster identity, before callers
/// apply any existing locus normalization.
public enum GenotypeMatrixReviewEligibility {
    public typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    public typealias Review = GenotypeAnnotationSidecar.MatrixReviewAnnotation

    public static let version = 1

    public static func permits(
        _ disposition: GenotypeAnnotationSidecar.MatrixReviewDisposition,
        rawSupport: Int?
    ) -> Bool {
        guard let rawSupport else { return false }
        switch disposition {
        case .falsePositive: return rawSupport > 0
        case .falseNegative: return rawSupport == 0
        }
    }

    public static func eligibleReviews(
        _ reviews: [Review],
        rawSupport: (Target) -> Int?
    ) -> [Target: Review] {
        Dictionary(grouping: reviews, by: \.target).reduce(into: [:]) { result, group in
            guard group.value.count == 1, case .cell = group.key,
                  let review = group.value.first,
                  permits(review.disposition, rawSupport: rawSupport(group.key)) else { return }
            result[group.key] = review
        }
    }

    /// Exact raw observations plus complete-roster entries from the catalog
    /// already validated by the bundle loader. Missing observations outside that
    /// authority remain absent, including unobserved candidate cells.
    public static func rawSupport(in result: ONTGenotypeResultBundleData) -> [Target: Int] {
        var support: [Target: Int] = [:]
        for call in result.calls {
            let target = Target.cell(locus: call.locusGroup, genotype: call.genotype, sample: call.sample)
            support[target] = max(support[target] ?? call.passedUniqueReads, call.passedUniqueReads)
        }
        if let document = result.mhcCandidates {
            let candidates = Dictionary(document.candidates.map { ($0.stableClusterID, $0) }, uniquingKeysWith: { _, last in last })
            for observation in document.observations {
                guard let candidate = candidates[observation.stableClusterID] else { continue }
                let target = Target.cell(locus: candidate.locus, genotype: candidate.provisionalName,
                    sample: observation.sampleID, stableClusterID: candidate.stableClusterID)
                support[target, default: 0] += observation.aggregatedSampleReadCount
            }
        }
        if let document = result.mhcUnnameableClusters {
            let interpretations = Dictionary(document.clusters.compactMap { record in
                record.candidateInterpretation.map { (record.stableClusterID, $0) }
            }, uniquingKeysWith: { _, last in last })
            for observation in document.observations {
                guard let interpretation = interpretations[observation.stableClusterID] else { continue }
                let target = Target.cell(locus: interpretation.locus, genotype: interpretation.provisionalName,
                    sample: observation.sampleID, stableClusterID: observation.stableClusterID)
                support[target, default: 0] += observation.aggregatedSampleReadCount
            }
        }
        for row in result.reviewableRowCatalog?.rows ?? [] {
            for (sample, reads) in row.supportBySample {
                let target = Target.cell(locus: row.locus, genotype: row.callID, sample: sample, stableClusterID: row.stableID)
                if support[target] == nil { support[target] = reads }
            }
        }
        return support
    }
}
