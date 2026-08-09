import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

enum FullLengthONTMHCCandidateObservationNormalizer {
    static func canonicalize(
        summary: ONTMHCGenotypingTargetHitSummary,
        candidateWasReverseComplemented: Bool
    ) throws -> ONTMHCGenotypingTargetHitSummary {
        guard candidateWasReverseComplemented else { return summary }
        let interpretations = summary.cdnaExtensionInterpretations.map { interpretation in
            ONTMHCCDNAExtensionInterpretation(
                rawReferenceID: interpretation.rawReferenceID,
                alleleName: interpretation.alleleName,
                locus: interpretation.locus,
                cDNAReferenceCoverage: interpretation.cDNAReferenceCoverage,
                clusterCoverage: interpretation.clusterCoverage,
                leadingClusterFlankBases: interpretation.trailingClusterFlankBases,
                trailingClusterFlankBases: interpretation.leadingClusterFlankBases,
                largestClusterStructuralSegmentBases: interpretation.largestClusterStructuralSegmentBases,
                largestCDNADeficitSegmentBases: interpretation.largestCDNADeficitSegmentBases,
                snpSubstitutions: interpretation.snpSubstitutions,
                ordinaryIndelBases: interpretation.ordinaryIndelBases,
                isReverse: !interpretation.isReverse,
                alignmentScore: interpretation.alignmentScore,
                identity: interpretation.identity
            )
        }
        return try ONTMHCGenotypingTargetHitSummary(
            bamPath: summary.bamPath,
            targetName: summary.targetName,
            alignmentCount: summary.alignmentCount,
            queryAlignmentCounts: summary.queryAlignmentCounts,
            exactMatchQueryNames: summary.exactMatchQueryNames,
            closestMatchQueryNames: summary.closestMatchQueryNames,
            cdnaExtensionInterpretations: interpretations
        )
    }
}
