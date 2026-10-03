@preconcurrency import Foundation
import CryptoKit
import Darwin

public enum ManagedToolSourceInstallerError: Error, LocalizedError, Sendable, Equatable {
    case invalidSourceURL
    case checksumMismatch(expected: String, actual: String)
    case unsafeArchiveMember(String)
    case missingRequiredFile(String)
    case processFailed(operation: String, exitStatus: Int32, stderr: String)
    case runtimeProbeFailed(ManagedToolSourceRuntimeProbe)
    case processTimedOut(seconds: TimeInterval)
    case publicationRecoveryFailed(backupPath: String, originalError: String, recoveryError: String)

    public var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            return "Managed tool sources must use HTTPS URLs."
        case .checksumMismatch:
            return "Downloaded managed tool source did not match its pinned SHA-256 checksum."
        case .unsafeArchiveMember(let member):
            return "Managed tool archive contains an unsafe member path: \(member)"
        case .missingRequiredFile(let path):
            return "Managed tool archive is missing required file: \(path)"
        case .processFailed(let operation, let status, _):
            return "Managed tool \(operation) failed with exit status \(status)."
        case .runtimeProbeFailed(let probe):
            return "Managed tool \(URL(fileURLWithPath: probe.executablePath).lastPathComponent) readiness probe failed with exit status \(probe.exitStatus)."
        case .processTimedOut(let seconds):
            return "Managed tool process timed out after \(Int(seconds)) seconds."
        case .publicationRecoveryFailed(let backupPath, let originalError, let recoveryError):
            return "Managed tool publication failed (\(originalError)) and rollback was incomplete (\(recoveryError)). Previous files remain recoverable at \(backupPath)."
        }
    }
}
