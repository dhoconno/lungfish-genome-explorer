import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCCandidateWorkbookRow: Equatable, Sendable {
    let stableClusterID: String
    let provisionalName: String
    let locus: String
    let classification: String
    let supportClass: String
    let independentSampleCount: Int
    let occurrenceCount: Int
    let totalClusterReads: Int
    let supportingSampleIDs: [String]
    let readsBySample: [String: Int]
    let fastaRecordID: String
    let sequenceSHA256: String
    let reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary
    let bamPath: String
    let queryName: String
    let referenceName: String
    let readGroupID: String?
    let referenceStart: Int
    let cigar: String
    let closestReferenceName: String
    let extensionOf: [String]
    let closestReferenceClass: String
    let snpCount: Int
    let insertedBases: Int
    let deletedBases: Int
    let longGapBases: Int
    let comparableBases: Int
    let shorterCoverage: Double
    let identity: Double
    let mappingQuality: Int
    let alignmentScore: Int
    let tintCategory: FullLengthONTMHCWorkbookTintCategory
}
