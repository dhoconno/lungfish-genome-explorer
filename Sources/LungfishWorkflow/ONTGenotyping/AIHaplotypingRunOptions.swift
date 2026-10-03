import Foundation
import LungfishCore
import LungfishIO

public struct AIHaplotypingRunOptions: Codable, Equatable, Sendable {
    public let mode: AIHaplotypingPromptMode
    public let providerID: AIHaplotypingProviderID
    public let credentialSource: AIHaplotypingCredentialSource?
    public let promptTemplateID: String?
    public let promptTemplateVersion: String?
    public let maxObservationsPerChunk: Int
    public let maxOutputTokens: Int
    public let temperature: Double
    public let reasoningEffort: String?
    public let maxProviderRetries: Int
    public let provenancePath: String
    public let compactKnowledgePack: Bool
    public let includeKnowledgePack: Bool
    public let chunkStartIndex: Int
    public let chunkEndIndex: Int
    public let reviewScope: AIHaplotypingReviewScope

    public init(
        mode: AIHaplotypingPromptMode,
        providerID: AIHaplotypingProviderID,
        credentialSource: AIHaplotypingCredentialSource? = nil,
        promptTemplateID: String? = nil,
        promptTemplateVersion: String? = nil,
        maxObservationsPerChunk: Int = 1,
        maxOutputTokens: Int = 4_096,
        temperature: Double = 0,
        reasoningEffort: String? = nil,
        maxProviderRetries: Int = 2,
        provenancePath: String = "ai-haplotyping/provenance.json",
        compactKnowledgePack: Bool = false,
        includeKnowledgePack: Bool = true,
        chunkStartIndex: Int = 1,
        chunkEndIndex: Int = 0,
        reviewScope: AIHaplotypingReviewScope = .all
    ) {
        self.mode = mode
        self.providerID = providerID
        self.credentialSource = credentialSource
        self.promptTemplateID = promptTemplateID
        self.promptTemplateVersion = promptTemplateVersion
        self.maxObservationsPerChunk = max(1, maxObservationsPerChunk)
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.temperature = max(0, min(2, temperature))
        let trimmedReasoningEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reasoningEffort = trimmedReasoningEffort.isEmpty ? nil : trimmedReasoningEffort
        self.maxProviderRetries = max(0, maxProviderRetries)
        let trimmedProvenancePath = provenancePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provenancePath = trimmedProvenancePath.isEmpty
            ? "ai-haplotyping/provenance.json"
            : trimmedProvenancePath
        self.compactKnowledgePack = compactKnowledgePack
        self.includeKnowledgePack = includeKnowledgePack
        self.chunkStartIndex = max(1, chunkStartIndex)
        self.chunkEndIndex = max(0, chunkEndIndex)
        self.reviewScope = reviewScope
    }

    public func generationParameters(
        schemaName: String,
        evidenceEncoding: String = "full-v1",
        promptCacheRetention: String? = nil,
        promptCacheKey: String? = nil
    ) -> [String: String] {
        let parameters = [
            "chunkEndIndex": String(chunkEndIndex),
            "chunkStartIndex": String(chunkStartIndex),
            "compactKnowledgePack": compactKnowledgePack ? "true" : "false",
            "evidenceEncoding": evidenceEncoding,
            "knowledgePackMode": includeKnowledgePack ? (compactKnowledgePack ? "compact" : "full") : "disabled",
            "maxObservationsPerChunk": String(maxObservationsPerChunk),
            "maxOutputTokens": String(maxOutputTokens),
            "maxProviderRetries": String(maxProviderRetries),
            "promptCacheKey": promptCacheKey ?? "none",
            "promptCacheRetention": promptCacheRetention ?? "none",
            "reasoningEffort": reasoningEffort ?? "none",
            "reviewScope": reviewScope.rawValue,
            "schemaName": schemaName,
            "temperature": Self.formatNumber(temperature),
        ]
        return parameters
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(value)
    }
}
