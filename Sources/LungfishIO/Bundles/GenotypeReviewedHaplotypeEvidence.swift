import Foundation

/// Analyst exclusions used for inference only. The original matrix and read
/// counts remain available for inspection, exports, and reproducibility.
public enum GenotypeReviewedHaplotypeEvidence {
    public static func callsForInference(
        _ calls: [ONTGenotypeCall],
        reviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]
    ) -> [ONTGenotypeCall] {
        func canonicalTarget(_ target: GenotypeAnnotationSidecar.MatrixTarget) -> GenotypeAnnotationSidecar.MatrixTarget? {
            guard case let .cell(locus, genotype, sample, nil) = target else { return nil }
            return .cell(
                locus: GenotypeHaplotypeLocusResolver.canonicalLocusName(locus),
                genotype: genotype,
                sample: sample
            )
        }
        var support: [GenotypeAnnotationSidecar.MatrixTarget: Int] = [:]
        for call in calls {
            let target = canonicalTarget(.cell(locus: call.locusGroup, genotype: call.genotype, sample: call.sample))!
            support[target] = max(support[target] ?? call.passedUniqueReads, call.passedUniqueReads)
        }
        let eligible = GenotypeMatrixReviewEligibility.eligibleReviews(reviews) { target in
            canonicalTarget(target).flatMap { support[$0] }
        }
        let excluded = Set(eligible.values.filter { $0.disposition == .falsePositive }.compactMap { canonicalTarget($0.target) })
        guard !excluded.isEmpty else { return calls }
        return calls.filter { call in
            let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
                locus: GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locusGroup),
                genotype: call.genotype,
                sample: call.sample
            )
            return !excluded.contains(target)
        }
    }
}
