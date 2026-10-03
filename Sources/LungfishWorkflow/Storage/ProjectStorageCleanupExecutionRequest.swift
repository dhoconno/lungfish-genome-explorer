import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct ProjectStorageCleanupExecutionRequest: Sendable {
    public let projectURL: URL
    public let cleanupID: UUID
    public let argv: [String]
    public let durableReplayArgv: [String]?
    public let options: ProvenanceOptions
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let startedAt: Date

    public init(
        projectURL: URL,
        cleanupID: UUID,
        argv: [String],
        durableReplayArgv: [String]? = nil,
        options: ProvenanceOptions,
        runtimeIdentity: ProvenanceRuntimeIdentity,
        startedAt: Date = Date()
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.cleanupID = cleanupID
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.options = options
        self.runtimeIdentity = runtimeIdentity
        self.startedAt = startedAt
    }
}
