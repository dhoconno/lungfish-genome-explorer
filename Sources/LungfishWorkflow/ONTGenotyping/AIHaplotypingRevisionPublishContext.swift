import Foundation
import CryptoKit
import LungfishCore
import LungfishIO

public struct AIHaplotypingRevisionPublishContext {
    public let toolName: String
    public let toolKind: String
    public let argv: [String]
    public let durableReplayArgv: [String]
    public let explicitOptions: [String: ParameterValue]
    public let defaultOptions: [String: ParameterValue]
    public let resolvedOptions: [String: ParameterValue]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let startedAt: Date
    /// Started when the run started. The publication ends the run on it, so
    /// the revision's provenance cannot end before the run began.
    public let runClock: ProvenanceRunClock
    public let stderr: String?

    public init(
        toolName: String,
        toolKind: String,
        argv: [String],
        durableReplayArgv: [String]? = nil,
        explicitOptions: [String: ParameterValue] = [:],
        defaultOptions: [String: ParameterValue] = [:],
        resolvedOptions: [String: ParameterValue] = [:],
        runtimeIdentity: ProvenanceRuntimeIdentity = ProvenanceRuntimeIdentity(),
        runClock: ProvenanceRunClock = ProvenanceRunClock(),
        stderr: String? = nil
    ) {
        self.toolName = toolName
        self.toolKind = toolKind
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv ?? argv
        self.explicitOptions = explicitOptions
        self.defaultOptions = defaultOptions
        self.resolvedOptions = resolvedOptions
        self.runtimeIdentity = runtimeIdentity
        self.startedAt = runClock.startedAt
        self.runClock = runClock
        self.stderr = stderr
    }
}
