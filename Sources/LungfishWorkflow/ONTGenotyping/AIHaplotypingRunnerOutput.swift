import Foundation
import LungfishCore
import LungfishIO

public struct AIHaplotypingRunnerOutput: Codable, Equatable, Sendable {
    public let mode: AIHaplotypingPromptMode
    public let registry: AIHaplotypingEvidenceRegistry
    public let chunkOutputs: [AIHaplotypingChunkOutput]
    public let normalizedCalls: [AIHaplotypingValidatedCall]
    public let validatedDefinitions: [AIHaplotypingValidatedDefinition]
    public let validationReports: [AIHaplotypingValidationReport]
    public let providerAttempts: [AIProviderAttemptMetadata]

    public init(
        mode: AIHaplotypingPromptMode,
        registry: AIHaplotypingEvidenceRegistry,
        chunkOutputs: [AIHaplotypingChunkOutput],
        normalizedCalls: [AIHaplotypingValidatedCall],
        validatedDefinitions: [AIHaplotypingValidatedDefinition],
        validationReports: [AIHaplotypingValidationReport],
        providerAttempts: [AIProviderAttemptMetadata]
    ) {
        self.mode = mode
        self.registry = registry
        self.chunkOutputs = chunkOutputs
        self.normalizedCalls = normalizedCalls
        self.validatedDefinitions = validatedDefinitions
        self.validationReports = validationReports
        self.providerAttempts = providerAttempts
    }
}
