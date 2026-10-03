import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct ProjectStorageCleanupExecutionResult: Sendable {
    public let summary: ProjectStorageCleanupExecutionSummary
    public let summaryURL: URL
    public let provenanceURL: URL
}
