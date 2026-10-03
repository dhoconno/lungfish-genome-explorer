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
        startedAt: Date = Date(),
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
        self.startedAt = startedAt
        self.stderr = stderr
    }
}
