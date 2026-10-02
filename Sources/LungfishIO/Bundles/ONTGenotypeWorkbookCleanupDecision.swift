import CryptoKit
import Darwin
import Foundation

public enum ONTGenotypeWorkbookCleanupDecision: String, Codable, Sendable {
    case committed
    case preparedDiscard = "prepared-discard"
    case rollback
    case manualSaveWinner = "manual-save-winner"
}
