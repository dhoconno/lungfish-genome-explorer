import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum AIHaplotypingProviderArgument: String, CaseIterable, ExpressibleByArgument {
    case openAI = "openai"
    case anthropic

    var providerID: AIHaplotypingProviderID {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        }
    }

    var defaultEnvironmentVariable: String {
        switch self {
        case .openAI: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }

    var credentialSource: AIHaplotypingCredentialSource {
        environmentCredentialSource
    }

    var environmentCredentialSource: AIHaplotypingCredentialSource {
        switch self {
        case .openAI: return .environmentOpenAI
        case .anthropic: return .environmentAnthropic
        }
    }

    var keychainCredentialSource: AIHaplotypingCredentialSource {
        switch self {
        case .openAI: return .keychainOpenAI
        case .anthropic: return .keychainAnthropic
        }
    }

    var keychainKey: String {
        switch self {
        case .openAI: return KeychainSecretStorage.openAIAPIKey
        case .anthropic: return KeychainSecretStorage.anthropicAPIKey
        }
    }

    var defaultPreviewModel: String {
        switch self {
        case .openAI: return MCMHaplotypingPreset.mcmMHCmiseq.aiOpenAIModel
        case .anthropic: return "claude-sonnet-4-6"
        }
    }
}
