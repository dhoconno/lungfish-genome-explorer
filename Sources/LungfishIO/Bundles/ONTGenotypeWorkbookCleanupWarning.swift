import CryptoKit
import Darwin
import Foundation

struct ONTGenotypeWorkbookCleanupWarning: Codable, Sendable {
    let schemaVersion: Int
    let transactionID: String
    let finalBundlePath: String
    let quarantinePath: String
    let statePath: String
    let decision: ONTGenotypeWorkbookCleanupDecision
    let retryState: String
    let reason: String
    let recordedAt: Date
}
