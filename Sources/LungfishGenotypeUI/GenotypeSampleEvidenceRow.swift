import Combine
import Foundation
import LungfishIO

struct GenotypeSampleEvidenceRow: Identifiable, Equatable, Sendable {
    struct Indicators: OptionSet, Equatable, Sendable {
        let rawValue: UInt8

        static let falsePositive = Indicators(rawValue: 1 << 0)
        static let falseNegative = Indicators(rawValue: 1 << 1)
        static let comment = Indicators(rawValue: 1 << 2)
    }

    let id: GenotypeCandidateMatrixRowID
    let allele: String
    let readSupport: Int?
    let indicators: Indicators
    let accessibilityLabel: String
    let semanticQualifiers: [String]
    let commentCounts: GenotypeMatrixScopedCommentCounts

    init(
        id: GenotypeCandidateMatrixRowID,
        allele: String,
        readSupport: Int?,
        indicators: Indicators,
        accessibilityLabel: String,
        semanticQualifiers: [String] = [],
        commentCounts: GenotypeMatrixScopedCommentCounts = .zero
    ) {
        self.id = id
        self.allele = allele
        self.readSupport = readSupport
        self.indicators = indicators
        self.accessibilityLabel = accessibilityLabel
        self.semanticQualifiers = semanticQualifiers
        self.commentCounts = commentCounts
    }
}
