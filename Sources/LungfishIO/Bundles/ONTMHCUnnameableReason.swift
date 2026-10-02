import Foundation

public enum ONTMHCUnnameableReason: String, Codable, Sendable {
    case noAlignment = "no-alignment"
    case insufficientAlignedBases = "insufficient-aligned-bases"
    case insufficientCoverage = "insufficient-coverage"
    case insufficientIdentity = "insufficient-identity"
    case incompleteReferenceSpan = "incomplete-reference-span"
    case referenceCanonicalizationUnavailable = "reference-canonicalization-unavailable"
    case unresolvedLocus = "unresolved-locus"
    case ambiguousReferenceClass = "ambiguous-reference-class"
}
