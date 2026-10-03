import CryptoKit
import Darwin
import Foundation
import LungfishIO

public enum ProjectStorageCleanupExecutionError: Error, LocalizedError {
    case unsafeAuthority(String)
    case stateCorrupt(String)
    case systemFailure(path: String, operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unsafeAuthority(let reason):
            return "Project storage cleanup authority is unsafe: \(reason)"
        case .stateCorrupt(let reason):
            return "Project storage cleanup state is unsafe: \(reason)"
        case .systemFailure(let path, let operation, let code):
            return "Could not \(operation) \(path) (errno \(code))."
        }
    }
}
