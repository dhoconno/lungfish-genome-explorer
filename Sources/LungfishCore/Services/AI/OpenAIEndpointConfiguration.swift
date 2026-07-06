// OpenAIEndpointConfiguration.swift - Direct and hosted OpenAI endpoint routing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum OpenAIEndpointConfigurationError: Error, LocalizedError, Sendable {
    case invalidEndpoint(String)
    case missingAzureDeployment
    case unsupportedHostedEndpointKind(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "Invalid Azure OpenAI endpoint: \(endpoint)"
        case .missingAzureDeployment:
            return "Azure OpenAI deployment must not be empty."
        case .unsupportedHostedEndpointKind(let kind):
            return "Unsupported OpenAI hosted endpoint kind: \(kind)"
        }
    }
}

public enum OpenAIEndpointOperation: Sendable {
    case chatCompletions
    case responses
}

public enum OpenAIEndpointConfiguration: Sendable, Equatable {
    public static let defaultOpenAIModel = "gpt-5.5"

    case direct
    case azure(endpoint: URL, deployment: String)

    public static func azure(
        endpointString: String,
        deployment: String
    ) throws -> OpenAIEndpointConfiguration {
        let normalizedEndpoint = normalizeEndpointString(endpointString)
        guard
            let url = URL(string: normalizedEndpoint),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host?.isEmpty == false
        else {
            throw OpenAIEndpointConfigurationError.invalidEndpoint(endpointString)
        }

        let trimmedDeployment = deployment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDeployment.isEmpty else {
            throw OpenAIEndpointConfigurationError.missingAzureDeployment
        }

        return .azure(endpoint: url, deployment: trimmedDeployment)
    }

    public static func normalizeEndpointString(_ endpoint: String) -> String {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    public func effectiveModel(configuredModel: String) -> String {
        switch self {
        case .direct:
            let trimmed = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.defaultOpenAIModel : trimmed
        case .azure(_, let deployment):
            return deployment
        }
    }

    public var supportsResponsesAPI: Bool {
        true
    }

    public var chatCompletionsURL: URL {
        switch self {
        case .direct:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .azure(let endpoint, _):
            return azureV1URL(endpoint: endpoint, pathComponents: ["chat", "completions"])
        }
    }

    public var responsesURL: URL {
        switch self {
        case .direct:
            return URL(string: "https://api.openai.com/v1/responses")!
        case .azure(let endpoint, _):
            return azureV1URL(endpoint: endpoint, pathComponents: ["responses"])
        }
    }

    public func authenticationHeader(apiKey: String) -> (name: String, value: String) {
        switch self {
        case .direct:
            return ("Authorization", "Bearer \(apiKey)")
        case .azure:
            return ("api-key", apiKey)
        }
    }

    public func apiVersionLabel(for operation: OpenAIEndpointOperation) -> String {
        switch operation {
        case .chatCompletions: return "chat.completions.v1"
        case .responses: return "responses.v1"
        }
    }

    private func azureV1URL(
        endpoint: URL,
        pathComponents: [String]
    ) -> URL {
        var url = endpoint.appendingPathComponent("openai").appendingPathComponent("v1")
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return url
    }
}
