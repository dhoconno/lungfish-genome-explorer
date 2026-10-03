@preconcurrency import Foundation
import CryptoKit
import Darwin

/// A successful direct readiness probe for a managed source overlay. These
/// values are retained by callers that need to record post-import validation.
public struct ManagedToolSourceRuntimeProbe: Sendable, Hashable {
    public let executablePath: String
    public let arguments: [String]
    public let exitStatus: Int32
    public let stderr: String

    public init(executablePath: String, arguments: [String], exitStatus: Int32, stderr: String) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.exitStatus = exitStatus
        self.stderr = stderr
    }
}
