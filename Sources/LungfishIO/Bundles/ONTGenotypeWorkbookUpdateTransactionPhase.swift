import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeWorkbookUpdateTransactionPhase: String, Codable, Sendable {
    case prepared
    case rollingBack
    case rollbackFailed
    case ambiguous
}
