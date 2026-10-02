import Darwin
import Foundation

public enum OwnedWorkDirectoryMarkerError: Error, LocalizedError, Equatable {
    case invalidRequest(String)
    case unsafePath(String)
    case missingMarker(String)
    case invalidMarker(String)
    case identityMismatch(String)
    case rollbackQuarantineRetained(path: String, operation: String, code: Int32)
    case rollbackRemovalDurabilityUncertain(path: String, operation: String, code: Int32)
    case creationAndRollbackFailed(
        path: String,
        initiatingError: String,
        rollbackError: String
    )
    case cleanupQuarantineRetained(path: String, operation: String, code: Int32)
    case cleanupQuarantineLocationUncertain(
        lastKnownPath: String,
        operation: String,
        code: Int32
    )
    case cleanupRemovalDurabilityUncertain(path: String, operation: String, code: Int32)
    case systemFailure(path: String, operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): return "Invalid owned work-directory request: \(detail)"
        case .unsafePath(let path): return "Owned work-directory path is unsafe: \(path)"
        case .missingMarker(let path): return "Owned work-directory marker is missing: \(path)"
        case .invalidMarker(let detail): return "Owned work-directory marker is invalid: \(detail)"
        case .identityMismatch(let path): return "Owned work-directory identity no longer matches: \(path)"
        case .rollbackQuarantineRetained(let path, let operation, let code):
            return "Owned work-directory rollback retained a recoverable quarantine at \(path) after \(operation) failed (errno \(code))."
        case .rollbackRemovalDurabilityUncertain(let path, let operation, let code):
            return "Owned work-directory rollback removal at \(path) has uncertain durability after \(operation) failed (errno \(code))."
        case .creationAndRollbackFailed(
            let path,
            let initiatingError,
            let rollbackError
        ):
            return "Owned work-directory creation or binding failed at \(path): \(initiatingError) Rollback also failed and retained or left an uncertain disposition: \(rollbackError)"
        case .cleanupQuarantineRetained(let path, let operation, let code):
            return "Temporary cleanup retained recoverable or partially cleaned data at \(path) after \(operation) failed (errno \(code))."
        case .cleanupQuarantineLocationUncertain(let path, let operation, let code):
            return "Temporary cleanup can no longer verify its quarantine at the last known path \(path) after \(operation) failed (errno \(code))."
        case .cleanupRemovalDurabilityUncertain(let path, let operation, let code):
            return "Temporary cleanup removal at \(path) has uncertain durability after \(operation) failed (errno \(code))."
        case .systemFailure(let path, let operation, let code):
            return "Could not \(operation) \(path) (errno \(code))."
        }
    }
}
