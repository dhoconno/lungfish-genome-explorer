// OpenAIEndpointConfiguration.swift - Direct and hosted OpenAI endpoint routing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum OpenAIEndpointConfigurationError: Error, LocalizedError, Sendable {
    case invalidEndpoint(String)
    case missingAzureDeployment
    case missingAzureAPIVersion
    case unsupportedHostedEndpointKind(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "Invalid Azure OpenAI endpoint: \(endpoint)"
        case .missingAzureDeployment:
            return "Azure OpenAI deployment must not be empty."
        case .missingAzureAPIVersion:
            return "Azure OpenAI API version must not be empty."
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
    public static let defaultAzureAPIVersion = "2025-01-01-preview"

    case direct
    case azure(endpoint: URL, deployment: String, apiVersion: String)

    public static func azure(
        endpointString: String,
        deployment: String,
        apiVersion: String
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

        let trimmedAPIVersion = apiVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIVersion.isEmpty else {
            throw OpenAIEndpointConfigurationError.missingAzureAPIVersion
        }

        return .azure(endpoint: url, deployment: trimmedDeployment, apiVersion: trimmedAPIVersion)
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
        case .azure(_, let deployment, _):
            return deployment
        }
    }

    public var supportsResponsesAPI: Bool {
        switch self {
        case .direct: return true
        case .azure: return false
        }
    }

    public var chatCompletionsURL: URL {
        switch self {
        case .direct:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .azure(let endpoint, let deployment, let apiVersion):
            return azureDeploymentURL(
                endpoint: endpoint,
                deployment: deployment,
                pathComponents: ["chat", "completions"],
                apiVersion: apiVersion
            )
        }
    }

    public var responsesURL: URL {
        switch self {
        case .direct:
            return URL(string: "https://api.openai.com/v1/responses")!
        case .azure(let endpoint, _, let apiVersion):
            var url = endpoint
                .appendingPathComponent("openai")
                .appendingPathComponent("v1")
                .appendingPathComponent("responses")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
            url = components.url ?? url
            return url
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
        switch self {
        case .direct:
            switch operation {
            case .chatCompletions: return "chat.completions.v1"
            case .responses: return "responses.v1"
            }
        case .azure(_, _, let apiVersion):
            return apiVersion
        }
    }

    private func azureDeploymentURL(
        endpoint: URL,
        deployment: String,
        pathComponents: [String],
        apiVersion: String
    ) -> URL {
        var url = endpoint
            .appendingPathComponent("openai")
            .appendingPathComponent("deployments")
            .appendingPathComponent(deployment)
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        return components.url ?? url
    }
}
