import Foundation

/// Analyst exclusions used for inference only. The original matrix and read
/// counts remain available for inspection, exports, and reproducibility.
public enum GenotypeReviewedHaplotypeEvidence {
    public static func callsForInference(
        _ calls: [ONTGenotypeCall],
        reviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]
    ) -> [ONTGenotypeCall] {
        var dispositions: [GenotypeAnnotationSidecar.MatrixTarget: GenotypeAnnotationSidecar.MatrixReviewDisposition] = [:]
        for review in reviews {
            guard case let .cell(locus, genotype, sample, nil) = review.target else { continue }
            let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
                locus: GenotypeHaplotypeLocusResolver.canonicalLocusName(locus),
                genotype: genotype,
                sample: sample
            )
            dispositions[target] = review.disposition
        }
        guard !dispositions.isEmpty else { return calls }
        return calls.filter { call in
            let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
                locus: GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locusGroup),
                genotype: call.genotype,
                sample: call.sample
            )
            return dispositions[target] != .falsePositive
        }
    }
}
