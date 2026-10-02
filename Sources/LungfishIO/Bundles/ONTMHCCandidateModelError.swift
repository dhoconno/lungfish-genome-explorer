import Foundation

public enum ONTMHCCandidateModelError: Error, LocalizedError, Equatable, Sendable {
    case invalidMinimumAlignedBases(Int)
    case invalidMinimumIdentity(Double)
    case invalidMinimumShorterCoverage(Double)
    case invalidMinimumIntronGapBases(Int)
    case invalidHitSummary(kind: String, field: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .invalidMinimumAlignedBases(let value):
            return "Minimum aligned bases must be greater than zero; received \(value)."
        case .invalidMinimumIdentity(let value):
            return "Minimum identity must be finite and between zero and one; received \(value)."
        case .invalidMinimumShorterCoverage(let value):
            return "Minimum shorter-sequence coverage must be finite and between zero and one; received \(value)."
        case .invalidMinimumIntronGapBases(let value):
            return "Minimum intron gap bases must be greater than zero; received \(value)."
        case .invalidHitSummary(let kind, let field, let value):
            return "Invalid \(kind) hit summary \(field): \(value)."
        }
    }
}
