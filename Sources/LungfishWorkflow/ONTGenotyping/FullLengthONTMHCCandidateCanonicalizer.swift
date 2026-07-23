import Foundation
import LungfishIO

enum FullLengthONTMHCReferenceReadiness: String, Codable, Equatable, Sendable {
    case referenceReady = "reference-ready"
    case incomplete = "not-reference-ready-incomplete"
    case unavailable = "not-reference-ready-unavailable"
}

struct FullLengthONTMHCCandidateCanonicalization: Sendable {
    let record: GenBankRecord
    let rawSequence: String
    let externalSequence: String?
    let trimRange: Range<Int>?
    let translationStatus: FullLengthONTMHCTranslationStatus
    let referenceReadiness: FullLengthONTMHCReferenceReadiness
}
