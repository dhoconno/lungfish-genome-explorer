import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

enum FullLengthONTMHCWorkbookProjectionError: Error, LocalizedError, Equatable, Sendable {
    case duplicateStableClusterID(String)
    case recordAppearsInBothDocuments(String)
    case observationWithoutRecord(String)
    case duplicateObservation(stableClusterID: String, sampleID: String, readGroupID: String)
    case observationSummaryMismatch(stableClusterID: String, field: String, expected: Int, actual: Int)
    case invalidUnmatchedArtifactIdentity(stableClusterID: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .duplicateStableClusterID(let id):
            "Duplicate stable MHC cluster ID in workbook projection: \(id)."
        case .recordAppearsInBothDocuments(let id):
            "Stable MHC cluster ID appears in both candidate and un-nameable documents: \(id)."
        case .observationWithoutRecord(let id):
            "Workbook observation does not have a candidate or un-nameable record: \(id)."
        case .duplicateObservation(let id, let sample, let readGroup):
            "Duplicate MHC workbook observation for \(id), sample \(sample), read group \(readGroup)."
        case .observationSummaryMismatch(let id, let field, let expected, let actual):
            "MHC workbook projection summary mismatch for \(id) (\(field)): expected \(expected), found \(actual)."
        case .invalidUnmatchedArtifactIdentity(let id, let detail):
            "Invalid unmatched MHC artifact identity for \(id): \(detail)."
        }
    }
}
