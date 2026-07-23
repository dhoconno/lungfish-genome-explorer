import Foundation

public enum FullLengthONTMHCCDNARelationship: String, Codable, Equatable, Sendable {
    case known
    case `extension`
    case ineligible
}

public struct FullLengthONTMHCCDNAStructuralInterpretation: Codable, Equatable, Sendable {
    public let referenceSequenceID: String
    public let clusterID: String
    public let relationship: FullLengthONTMHCCDNARelationship
    public let cDNAReferenceCoverage: Double
    public let clusterCoverage: Double
    public let leadingClusterFlankBases: Int
    public let trailingClusterFlankBases: Int
    public let largestClusterStructuralSegmentBases: Int
    public let largestCDNADeficitSegmentBases: Int
    public let snpSubstitutions: Int
    public let ordinaryIndelBases: Int
    public let identity: Double
    public let alignmentScore: Int
    public let isReverse: Bool

    public init(
        referenceSequenceID: String,
        clusterID: String,
        relationship: FullLengthONTMHCCDNARelationship,
        cDNAReferenceCoverage: Double,
        clusterCoverage: Double,
        leadingClusterFlankBases: Int,
        trailingClusterFlankBases: Int,
        largestClusterStructuralSegmentBases: Int,
        largestCDNADeficitSegmentBases: Int,
        snpSubstitutions: Int,
        ordinaryIndelBases: Int,
        identity: Double,
        alignmentScore: Int,
        isReverse: Bool
    ) {
        self.referenceSequenceID = referenceSequenceID
        self.clusterID = clusterID
        self.relationship = relationship
        self.cDNAReferenceCoverage = cDNAReferenceCoverage
        self.clusterCoverage = clusterCoverage
        self.leadingClusterFlankBases = leadingClusterFlankBases
        self.trailingClusterFlankBases = trailingClusterFlankBases
        self.largestClusterStructuralSegmentBases = largestClusterStructuralSegmentBases
        self.largestCDNADeficitSegmentBases = largestCDNADeficitSegmentBases
        self.snpSubstitutions = snpSubstitutions
        self.ordinaryIndelBases = ordinaryIndelBases
        self.identity = identity
        self.alignmentScore = alignmentScore
        self.isReverse = isReverse
    }
}

/// Shared structural interpretation for the two minimap2 orientations used by the
/// current full-length ONT MHC workflow.
enum FullLengthONTMHCCDNAStructuralClassifier {
    static let minimumReferenceCoverage = 0.95
    static let minimumClusterCoverage = 0.95
    static let meaningfulStructuralSegmentBases = 20

    static func classifyCohort(
        referenceSequenceID: String,
        clusterID: String,
        cDNAReferenceLength: Int,
        clusterLength: Int,
        targetStart: Int,
        isReverse: Bool,
        metrics: FullLengthONTMHCSAMMetrics
    ) throws -> FullLengthONTMHCCDNAStructuralInterpretation {
        let alignedCDNABases = try FullLengthONTMHCSAMMetrics.adding(
            metrics.comparableBases,
            metrics.insertedBases,
            metric: .querySpan,
            operation: .add
        )
        let targetEnd = try alignmentEnd(start: targetStart, span: metrics.referenceSpan)
        let leadingFlank = max(0, targetStart - 1)
        let trailingFlank = max(0, clusterLength - targetEnd)
        let largestStructuralSegment = [
            leadingFlank,
            trailingFlank,
            metrics.largestDeletedSegment,
            metrics.largestSkippedReferenceSegment,
        ].max() ?? 0
        let largestDeficit = [
            metrics.largestInsertedSegment,
            metrics.largestSoftClippedSegment,
            metrics.largestHardClippedSegment,
        ].max() ?? 0
        let cDNACoverage = coverage(alignedCDNABases, of: cDNAReferenceLength)
        let clusterCoverage = coverage(metrics.referenceSpan, of: clusterLength)
        let identity = coverage(metrics.matches, of: metrics.comparableBases)
        let alignmentScore = try score(metrics)
        let relationship = relationship(
            snps: metrics.snps,
            cDNACoverage: cDNACoverage,
            clusterCoverage: clusterCoverage,
            largestStructuralSegment: largestStructuralSegment,
            largestDeficitSegment: largestDeficit,
            hardClippedBases: metrics.hardClippedBases
        )
        return FullLengthONTMHCCDNAStructuralInterpretation(
            referenceSequenceID: referenceSequenceID,
            clusterID: clusterID,
            relationship: relationship,
            cDNAReferenceCoverage: cDNACoverage,
            clusterCoverage: clusterCoverage,
            leadingClusterFlankBases: leadingFlank,
            trailingClusterFlankBases: trailingFlank,
            largestClusterStructuralSegmentBases: largestStructuralSegment,
            largestCDNADeficitSegmentBases: largestDeficit,
            snpSubstitutions: metrics.snps,
            ordinaryIndelBases: metrics.nonIntronIndelBases,
            identity: identity,
            alignmentScore: alignmentScore,
            isReverse: isReverse
        )
    }

    static func classifyReciprocal(
        referenceSequenceID: String,
        clusterID: String,
        cDNAReferenceLength: Int,
        clusterLength: Int,
        referenceStart: Int,
        isReverse: Bool,
        metrics: FullLengthONTMHCSAMMetrics
    ) throws -> FullLengthONTMHCCDNAStructuralInterpretation {
        let referenceEnd = try alignmentEnd(start: referenceStart, span: metrics.referenceSpan)
        let leadingReferenceDeficit = max(0, referenceStart - 1)
        let trailingReferenceDeficit = max(0, cDNAReferenceLength - referenceEnd)
        let largestStructuralSegment = max(
            metrics.largestInsertedSegment,
            metrics.largestSoftClippedSegment
        )
        let largestDeficit = [
            leadingReferenceDeficit,
            trailingReferenceDeficit,
            metrics.largestDeletedSegment,
            metrics.largestSkippedReferenceSegment,
            metrics.largestHardClippedSegment,
        ].max() ?? 0
        let cDNACoverage = coverage(metrics.referenceSpan, of: cDNAReferenceLength)
        let clusterCoverage = coverage(metrics.querySpan, of: clusterLength)
        let identity = coverage(metrics.matches, of: metrics.comparableBases)
        let alignmentScore = try score(metrics)
        let relationship = relationship(
            snps: metrics.snps,
            cDNACoverage: cDNACoverage,
            clusterCoverage: clusterCoverage,
            largestStructuralSegment: largestStructuralSegment,
            largestDeficitSegment: largestDeficit,
            hardClippedBases: metrics.hardClippedBases
        )
        return FullLengthONTMHCCDNAStructuralInterpretation(
            referenceSequenceID: referenceSequenceID,
            clusterID: clusterID,
            relationship: relationship,
            cDNAReferenceCoverage: cDNACoverage,
            clusterCoverage: clusterCoverage,
            leadingClusterFlankBases: 0,
            trailingClusterFlankBases: 0,
            largestClusterStructuralSegmentBases: largestStructuralSegment,
            largestCDNADeficitSegmentBases: largestDeficit,
            snpSubstitutions: metrics.snps,
            ordinaryIndelBases: metrics.nonIntronIndelBases,
            identity: identity,
            alignmentScore: alignmentScore,
            isReverse: isReverse
        )
    }

    private static func relationship(
        snps: Int,
        cDNACoverage: Double,
        clusterCoverage: Double,
        largestStructuralSegment: Int,
        largestDeficitSegment: Int,
        hardClippedBases: Int
    ) -> FullLengthONTMHCCDNARelationship {
        guard snps == 0,
              cDNACoverage >= minimumReferenceCoverage,
              largestDeficitSegment < meaningfulStructuralSegmentBases,
              hardClippedBases == 0 else {
            return .ineligible
        }
        if largestStructuralSegment >= meaningfulStructuralSegmentBases {
            return .extension
        }
        guard clusterCoverage >= minimumClusterCoverage else {
            return .ineligible
        }
        return .known
    }

    private static func alignmentEnd(start: Int, span: Int) throws -> Int {
        let offset = try FullLengthONTMHCSAMMetrics.subtracting(
            span,
            1,
            metric: .targetEnd,
            operation: .subtract
        )
        return try FullLengthONTMHCSAMMetrics.adding(
            start,
            offset,
            metric: .targetEnd,
            operation: .add
        )
    }

    private static func coverage(_ numerator: Int, of denominator: Int) -> Double {
        guard numerator >= 0, denominator > 0 else { return 0 }
        return min(1, Double(numerator) / Double(denominator))
    }

    private static func score(_ metrics: FullLengthONTMHCSAMMetrics) throws -> Int {
        let indelPenalty = try FullLengthONTMHCSAMMetrics.multiplying(
            metrics.nonIntronIndelBases,
            10,
            metric: .alignmentScore,
            operation: .multiply(10)
        )
        let snpPenalty = try FullLengthONTMHCSAMMetrics.multiplying(
            metrics.snps,
            100,
            metric: .alignmentScore,
            operation: .multiply(100)
        )
        let afterIndels = try FullLengthONTMHCSAMMetrics.subtracting(
            metrics.matches,
            indelPenalty,
            metric: .alignmentScore,
            operation: .subtract
        )
        return try FullLengthONTMHCSAMMetrics.subtracting(
            afterIndels,
            snpPenalty,
            metric: .alignmentScore,
            operation: .subtract
        )
    }
}
