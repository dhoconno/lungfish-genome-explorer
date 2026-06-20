import Foundation
import LungfishIO

public struct AIHaplotypingPromptSelection: Codable, Equatable, Sendable {
    public let promptTemplateID: String?
    public let promptTemplateVersion: String?
    public let includeKnowledgePack: Bool
    public let compactKnowledgePack: Bool
    public let usesSpecialistPrompt: Bool

    public init(
        promptTemplateID: String?,
        promptTemplateVersion: String?,
        includeKnowledgePack: Bool,
        compactKnowledgePack: Bool,
        usesSpecialistPrompt: Bool
    ) {
        self.promptTemplateID = promptTemplateID
        self.promptTemplateVersion = promptTemplateVersion
        self.includeKnowledgePack = includeKnowledgePack
        self.compactKnowledgePack = compactKnowledgePack
        self.usesSpecialistPrompt = usesSpecialistPrompt
    }
}

public enum AIHaplotypingPromptSelectionResolver {
    public static func resolve(
        result: ONTGenotypeResultBundleData,
        mode: AIHaplotypingPromptMode,
        requestedPromptTemplateID: String?,
        requestedPromptTemplateVersion: String?,
        compactKnowledgePack: Bool
    ) -> AIHaplotypingPromptSelection {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        let requestedID = nonEmpty(requestedPromptTemplateID)
        let requestedVersion = nonEmpty(requestedPromptTemplateVersion)
        let defaultToMCMSpecialist = requestedID == nil && requestedVersion == nil && preset.matches(result: result)
        let promptTemplateID = requestedID ?? (defaultToMCMSpecialist ? preset.aiPromptTemplateID(for: mode) : nil)
        let promptTemplateVersion = requestedVersion ?? (defaultToMCMSpecialist ? preset.aiPromptTemplateVersion : nil)
        let usesSpecialist = isMCMSpecialistPrompt(
            id: promptTemplateID,
            version: promptTemplateVersion,
            mode: mode
        )
        return AIHaplotypingPromptSelection(
            promptTemplateID: promptTemplateID,
            promptTemplateVersion: promptTemplateVersion,
            includeKnowledgePack: !usesSpecialist,
            compactKnowledgePack: usesSpecialist ? false : compactKnowledgePack,
            usesSpecialistPrompt: usesSpecialist
        )
    }

    public static func isMCMSpecialistPrompt(
        id: String?,
        version: String?,
        mode: AIHaplotypingPromptMode
    ) -> Bool {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        return nonEmpty(id) == preset.aiPromptTemplateID(for: mode)
            && nonEmpty(version) == preset.aiPromptTemplateVersion
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
