import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeHaplotypeAnalysisReviewState: String, Codable, CaseIterable, Equatable, Sendable {
    case unreviewed
    case needsReview
    case reviewed
    case confirmed
    case rejected
}
