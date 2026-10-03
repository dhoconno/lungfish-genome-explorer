import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCUnnameableWorkbookRow: Equatable, Sendable {
    let stableClusterID: String
    let reason: String
    let supportClass: String
    let independentSampleCount: Int
    let occurrenceCount: Int
    let totalClusterReads: Int
    let supportingSampleIDs: [String]
    let readsBySample: [String: Int]
    let fastaRecordID: String
    let sequenceSHA256: String
    let failedMetrics: [String: Double]
    let reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary
    let selectedEvidence: ONTMHCEvidenceLocator?
    let evidence: [ONTMHCEvidenceLocator]
    let candidateInterpretation: ONTMHCIncompleteCandidateInterpretation?
}
