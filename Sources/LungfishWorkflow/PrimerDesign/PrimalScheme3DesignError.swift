import CryptoKit
import Darwin
import Foundation
import LungfishIO

public enum PrimalScheme3DesignError: Error, LocalizedError, Sendable {
    case invalidRequest(String)
    case executionFailed(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): return "PrimalScheme: \(reason)"
        case .executionFailed(let code, let detail): return "PrimalScheme exited with status \(code): \(detail)"
        }
    }
}
