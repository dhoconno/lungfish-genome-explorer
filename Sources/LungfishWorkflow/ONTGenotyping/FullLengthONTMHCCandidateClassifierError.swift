import Foundation
import LungfishIO

public enum FullLengthONTMHCCandidateClassifierError: Error, LocalizedError, Equatable, Sendable {
    case invalidCluster(field: String, value: String)
    case invalidObservation(stableClusterID: String, index: Int, field: String, value: String)
    case invalidAlignment(stableClusterID: String, index: Int, field: String, value: String)
    case arithmeticOverflow(stableClusterID: String, field: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCluster(let field, let value):
            return "Invalid MHC candidate cluster \(field): \(value)."
        case .invalidObservation(let stableClusterID, let index, let field, let value):
            return "Invalid observation \(index) for MHC cluster '\(stableClusterID)' (\(field)): \(value)."
        case .invalidAlignment(let stableClusterID, let index, let field, let value):
            return "Invalid alignment \(index) for MHC cluster '\(stableClusterID)' (\(field)): \(value)."
        case .arithmeticOverflow(let stableClusterID, let field):
            return "Numeric overflow while computing \(field) for MHC cluster '\(stableClusterID)'."
        }
    }
}
