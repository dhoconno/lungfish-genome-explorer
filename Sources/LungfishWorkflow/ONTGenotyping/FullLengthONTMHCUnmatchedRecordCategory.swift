import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

enum FullLengthONTMHCUnmatchedRecordCategory: String, Codable, Equatable, Sendable {
    case candidate
    case candidateIncomplete = "candidate-incomplete"
    case unnameable = "un-nameable"
}
