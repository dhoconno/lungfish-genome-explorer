import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeWorkbookUpdateRecoveryError: Error, LocalizedError, Sendable {
    case unsafeLock(String)
    case lockHeld(String)
    case systemFailure(String, Int32)
    case unsafeMarker(String)
    case recoveryRequired(String)
    case invalidTransaction(String)
    case ambiguousTransaction(String)
    case currentWorkbookIntegrity(String)
    case cleanupPendingWarning(
        quarantinePath: String,
        retryState: String,
        warningPath: String,
        reason: String
    )
    case cleanupPendingWarningPersistenceFailure(
        quarantinePath: String,
        retryState: String,
        reason: String,
        warningFailure: String
    )

    public var errorDescription: String? {
        switch self {
        case .unsafeLock(let path): return "Workbook publication lock is unsafe: \(path)"
        case .lockHeld(let path): return "Workbook publication lock is already held: \(path)"
        case .systemFailure(let path, let code): return "Workbook transaction failed at \(path) (errno \(code))."
        case .unsafeMarker(let path): return "Workbook transaction marker is unsafe: \(path)"
        case .recoveryRequired(let path):
            return "Workbook transaction recovery is required before the bundle can be used: \(path)"
        case .invalidTransaction(let message): return "Workbook transaction marker is invalid: \(message)"
        case .ambiguousTransaction(let message): return "Workbook transaction recovery is ambiguous: \(message)"
        case .currentWorkbookIntegrity(let message): return "The current workbook failed integrity validation: \(message)"
        case .cleanupPendingWarning(
            let quarantinePath,
            let retryState,
            let warningPath,
            let reason
        ):
            return "Workbook cleanup retained \(quarantinePath) in \(retryState) retry state. Warning: \(warningPath). \(reason)"
        case .cleanupPendingWarningPersistenceFailure(
            let quarantinePath,
            let retryState,
            let reason,
            let warningFailure
        ):
            return "Workbook cleanup retained \(quarantinePath) in \(retryState) retry state. "
                + "Original cleanup failure: \(reason) Warning persistence also failed: "
                + warningFailure
        }
    }
}
