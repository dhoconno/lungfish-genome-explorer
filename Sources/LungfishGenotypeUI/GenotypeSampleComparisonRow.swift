import Combine
import Foundation
import LungfishIO

struct GenotypeSampleComparisonRow: Identifiable, Equatable, Sendable {
    enum Relationship: Equatable, Sendable {
        case shared
        case targetOnly
        case sourceOnly
    }

    let id: GenotypeCandidateMatrixRowID
    let allele: String
    let targetReadSupport: String
    let sourceReadSupport: String
    let relationship: Relationship
    let indicatorSummary: String?
    let semanticQualifiers: [String]
    let targetCommentCounts: GenotypeMatrixScopedCommentCounts
    let sourceCommentCounts: GenotypeMatrixScopedCommentCounts
    let targetAccessibilityLabel: String?
    let sourceAccessibilityLabel: String?
}
