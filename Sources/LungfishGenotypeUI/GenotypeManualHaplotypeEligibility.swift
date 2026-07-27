import Foundation
import LungfishIO

public enum GenotypeManualHaplotypeEligibility: Equatable, Sendable {
    case eligible(resultKind: GenotypeResultWorkflowKind)
    case ineligible(reason: String)

    public static func evaluate(
        _ result: ONTGenotypeResultBundleData
    ) -> GenotypeManualHaplotypeEligibility {
        let manifest = result.manifest
        let legacyKind: GenotypeResultWorkflowKind?
        switch manifest.kind {
        case GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue:
            legacyKind = .fullLengthONTMHCGenotype
        case GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue:
            legacyKind = .miSeqAmpliconMHCGenotype
        default:
            legacyKind = nil
        }

        if let issue = manifest.workflowKindDeclaration.issue {
            return .ineligible(reason: issue)
        }
        if let issue = manifest.workflowModeDeclaration.issue {
            return .ineligible(reason: issue)
        }

        let resultKind: GenotypeResultWorkflowKind
        switch (manifest.workflowKind, manifest.workflowMode) {
        case let (.some(kind), .some(mode)):
            guard legacyKind == kind else {
                return .ineligible(reason: "The typed workflow kind and result kind disagree.")
            }
            guard mode == .genotypeOnly else {
                return .ineligible(reason: "This result declares that haplotyping was performed.")
            }
            resultKind = kind
        case (nil, nil):
            guard let legacyKind else {
                return .ineligible(reason: "This legacy result schema is not a recognized genotype-only MHC workflow.")
            }
            resultKind = legacyKind
        default:
            return .ineligible(reason: "The workflow declaration is incomplete or partially migrated.")
        }

        let manifestDeclaresHaplotyping =
            manifest.haplotypeAnalysisPath != nil
            || manifest.activeHaplotypeAnalysisRevisionID != nil
            || !(manifest.haplotypeAnalysisRevisions ?? []).isEmpty
            || manifest.haplotypeDefinitionSetID != nil
            || manifest.haplotypeAssayID != nil
        let resultContainsHaplotyping =
            result.haplotypeAnalysis != nil
            || result.artifacts.haplotypeAnalysisURL != nil

        guard !manifestDeclaresHaplotyping, !resultContainsHaplotyping else {
            return .ineligible(
                reason: "The genotype-only workflow declaration and authoritative haplotyping fields disagree."
            )
        }
        return .eligible(resultKind: resultKind)
    }
}
