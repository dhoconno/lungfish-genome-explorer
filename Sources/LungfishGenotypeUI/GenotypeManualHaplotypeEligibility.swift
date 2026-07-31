import Foundation
import LungfishIO

public enum GenotypeManualHaplotypeEligibility: Equatable, Sendable {
    case eligible(resultKind: GenotypeResultWorkflowKind)
    case ineligible(reason: String)

    public static func evaluate(
        _ result: ONTGenotypeResultBundleData
    ) -> GenotypeManualHaplotypeEligibility {
        let authority = GenotypeManualHaplotypeAuthority.evaluate(
            result.manifest
        )
        let resultKind: GenotypeResultWorkflowKind
        switch authority {
        case .eligible(let eligibleKind):
            resultKind = eligibleKind
        case .ineligible(let reason):
            return .ineligible(reason: reason)
        }
        let resultContainsHaplotyping =
            result.haplotypeAnalysis != nil
            || result.artifacts.haplotypeAnalysisURL != nil

        guard !resultContainsHaplotyping else {
            return .ineligible(
                reason: "The genotype-only workflow declaration and authoritative haplotyping fields disagree."
            )
        }
        return .eligible(resultKind: resultKind)
    }
}
