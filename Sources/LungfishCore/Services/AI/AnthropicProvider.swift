// AnthropicProvider.swift - Anthropic Claude API implementation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

private let logger = Logger(subsystem: LogSubsystem.core, category: "AnthropicProvider")

/// AI provider implementation for the Anthropic Claude API.
///
/// Uses the Messages API with tool use support. Translates between
/// the common `AIMessage` format and Claude's content-block format.
public actor AnthropicProvider: StructuredAIProvider {
    private let apiKey: String
    public let modelId: String
    private let httpClient: HTTPClient
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"

    public nonisolated var name: String { "Anthropic" }

    public init(apiKey: String, modelId: String = "claude-sonnet-4-5-20250929", httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.httpClient = httpClient
    }

    /// Builds a POST request to the Messages API with the standard Anthropic headers.
    private func makeRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        request.timeoutInterval = 120
        return request
    }

    public func sendMessage(
        messages: [AIMessage],
        systemPrompt: String,
        tools: [AIToolDefinition]
    ) async throws -> AIResponse {
        let requestBody = buildRequestBody(messages: messages, systemPrompt: systemPrompt, tools: tools)

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        let request = makeRequest(body: jsonData)

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return try parseResponse(data)
        case 401:
            throw AIProviderError.missingAPIKey
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw AIProviderError.rateLimited(retryAfter: retryAfter)
        case 400:
            let errorMessage = parseErrorMessage(data) ?? "Bad request"
            if errorMessage.contains("context") || errorMessage.contains("token") {
                throw AIProviderError.contextTooLong(maxTokens: 200_000)
            }
            throw AIProviderError.httpError(statusCode: 400, message: errorMessage)
        default:
            let errorMessage = parseErrorMessage(data) ?? "Unknown error"
            throw AIProviderError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
    }

    public func requestStructuredResult(_ structuredRequest: AIStructuredRequest) async throws -> AIStructuredResponse {
        let requestBody = buildStructuredRequestBody(structuredRequest)
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        let request = makeRequest(body: jsonData)

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return try parseStructuredResponse(data, httpResponse: httpResponse, request: structuredRequest)
        case 401:
            throw AIProviderError.missingAPIKey
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw AIProviderError.rateLimited(retryAfter: retryAfter)
        case 400:
            let errorMessage = parseErrorMessage(data) ?? "Bad request"
            if errorMessage.contains("context") || errorMessage.contains("token") {
                throw AIProviderError.contextTooLong(maxTokens: 200_000)
            }
            throw AIProviderError.httpError(statusCode: 400, message: errorMessage)
        default:
            let errorMessage = parseErrorMessage(data) ?? "Unknown error"
            throw AIProviderError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
    }

    // MARK: - Request Building

    private func buildStructuredRequestBody(_ request: AIStructuredRequest) -> [String: Any] {
        [
            "model": modelId,
            "max_tokens": request.maxOutputTokens,
            "temperature": request.temperature,
            "system": request.systemPrompt,
            "messages": [
                ["role": "user", "content": request.userPrompt],
            ],
            "tools": [[
                "name": request.schemaName,
                "description": "Return the strict structured result for this Lungfish workflow.",
                "strict": true,
                "input_schema": jsonValueToAny(.object(request.schema)),
            ]],
            "tool_choice": [
                "type": "tool",
                "name": request.schemaName,
            ],
        ]
    }

    private func buildRequestBody(
        messages: [AIMessage],
        systemPrompt: String,
        tools: [AIToolDefinition]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": buildMessages(messages),
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map { $0.toJSON() }
        }

        return body
    }

    /// Builds the `tool_result` content blocks for a set of tool results.
    private func toolResultBlocks(_ results: [AIToolResult]) -> [[String: Any]] {
        results.map { toolResult in
            var block: [String: Any] = [
                "type": "tool_result",
                "tool_use_id": toolResult.toolCallId,
                "content": toolResult.content,
            ]
            if toolResult.isError {
                block["is_error"] = true
            }
            return block
        }
    }

    private func buildMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .user:
                if !message.toolResults.isEmpty {
                    // Tool results are sent as user messages with tool_result content blocks
                    let content = toolResultBlocks(message.toolResults)
                    result.append(["role": "user", "content": content])
                } else {
                    result.append(["role": "user", "content": message.content])
                }

            case .assistant:
                var content: [[String: Any]] = []
                if !message.content.isEmpty {
                    content.append(["type": "text", "text": message.content])
                }
                for toolCall in message.toolCalls {
                    content.append([
                        "type": "tool_use",
                        "id": toolCall.id,
                        "name": toolCall.name,
                        "input": encodeArguments(toolCall.arguments),
                    ])
                }
                if content.isEmpty {
                    continue
                }
                result.append(["role": "assistant", "content": content])

            case .tool:
                // Tool results are combined into the next user message
                // This is handled by the user case above
                if !message.toolResults.isEmpty {
                    let content = toolResultBlocks(message.toolResults)
                    result.append(["role": "user", "content": content])
                }

            case .system:
                // System messages are handled via the top-level system parameter
                break
            }
        }

        return result
    }

    // MARK: - Response Parsing

    private func parseStructuredResponse(
        _ data: Data,
        httpResponse: HTTPURLResponse,
        request: AIStructuredRequest
    ) throws -> AIStructuredResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.decodingError("Response is not valid JSON")
        }

        guard let contentBlocks = json["content"] as? [[String: Any]] else {
            throw AIProviderError.decodingError("Missing 'content' array in response")
        }

        let stopReason = json["stop_reason"] as? String
        if stopReason == "max_tokens" {
            throw AIProviderError.invalidResponse("Structured Anthropic response was truncated before the required result tool")
        }

        var matchingInputs: [[String: JSONValue]] = []
        var hasExtraText = false
        for block in contentBlocks {
            guard let type = block["type"] as? String else {
                throw AIProviderError.invalidResponse("Anthropic structured response contains extra content")
            }

            switch type {
            case "text":
                let text = block["text"] as? String ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasExtraText = true
                }

            case "tool_use":
                guard let name = block["name"] as? String else {
                    throw AIProviderError.invalidResponse("Anthropic structured response contains an unnamed tool result")
                }
                guard name == request.schemaName else {
                    throw AIProviderError.invalidResponse("Anthropic structured response contains extra content from an unexpected tool")
                }
                guard let input = block["input"] as? [String: Any] else {
                    throw AIProviderError.invalidResponse("Anthropic result tool input must be a JSON object")
                }
                matchingInputs.append(input.mapValues { anyToJSONValue($0) })

            default:
                throw AIProviderError.invalidResponse("Anthropic structured response contains extra content")
            }
        }

        guard !matchingInputs.isEmpty else {
            throw AIProviderError.invalidResponse("Anthropic response did not include the required result tool")
        }
        if hasExtraText {
            throw AIProviderError.invalidResponse("Anthropic structured response contains extra content outside the result tool")
        }
        guard matchingInputs.count == 1 else {
            throw AIProviderError.invalidResponse("Anthropic response must include exactly one matching result tool")
        }

        let usage = anthropicUsage(from: json)
        let requestID = httpResponse.value(forHTTPHeaderField: "request-id")
            ?? httpResponse.value(forHTTPHeaderField: "anthropic-request-id")
            ?? json["id"] as? String
        let metadata = AIProviderAttemptMetadata(
            attemptIndex: request.attemptIndex,
            fallbackIndex: request.fallbackIndex,
            provider: "anthropic",
            model: modelId,
            endpoint: baseURL.absoluteString,
            apiVersion: apiVersion,
            credentialSource: request.credentialSource,
            apiKeyAvailable: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            requestID: requestID,
            statusCode: httpResponse.statusCode,
            stopReason: stopReason,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            sanitizedErrorCategory: nil
        )

        return AIStructuredResponse(
            payload: matchingInputs[0],
            rawText: nil,
            usage: usage,
            stopReason: aiStopReason(from: stopReason, toolCallsPresent: true),
            attemptMetadata: metadata
        )
    }

    private func parseResponse(_ data: Data) throws -> AIResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.decodingError("Response is not valid JSON")
        }

        guard let contentBlocks = json["content"] as? [[String: Any]] else {
            throw AIProviderError.decodingError("Missing 'content' array in response")
        }

        var textParts: [String] = []
        var toolCalls: [AIToolCall] = []

        for block in contentBlocks {
            guard let type = block["type"] as? String else { continue }

            switch type {
            case "text":
                if let text = block["text"] as? String {
                    textParts.append(text)
                }
            case "tool_use":
                if let id = block["id"] as? String,
                   let name = block["name"] as? String {
                    let input = block["input"] ?? [:]
                    let arguments = parseToolArguments(input)
                    toolCalls.append(AIToolCall(id: id, name: name, arguments: arguments))
                }
            default:
                logger.debug("Unknown content block type: \(type)")
            }
        }

        let stopReason: AIResponse.StopReason
        switch json["stop_reason"] as? String {
        case "end_turn": stopReason = .endTurn
        case "tool_use": stopReason = .toolUse
        case "max_tokens": stopReason = .maxTokens
        default: stopReason = .endTurn
        }

        var usage: AIResponse.Usage?
        if let usageDict = json["usage"] as? [String: Any] {
            let input = usageDict["input_tokens"] as? Int ?? 0
            let output = usageDict["output_tokens"] as? Int ?? 0
            usage = AIResponse.Usage(inputTokens: input, outputTokens: output)
        }

        return AIResponse(
            text: textParts.joined(),
            toolCalls: toolCalls,
            stopReason: stopReason,
            usage: usage
        )
    }

    private func parseToolArguments(_ input: Any) -> [String: JSONValue] {
        guard let dict = input as? [String: Any] else { return [:] }
        var result: [String: JSONValue] = [:]
        for (key, value) in dict {
            result[key] = anyToJSONValue(value)
        }
        return result
    }
}
