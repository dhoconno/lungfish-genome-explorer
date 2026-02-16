// AnthropicProvider.swift - Anthropic Claude API implementation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

private let logger = Logger(subsystem: "com.lungfish", category: "AnthropicProvider")

/// AI provider implementation for the Anthropic Claude API.
///
/// Uses the Messages API with tool use support. Translates between
/// the common `AIMessage` format and Claude's content-block format.
public actor AnthropicProvider: AIProvider {
    private let apiKey: String
    public let modelId: String
    private let httpClient: HTTPClient
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    public nonisolated var name: String { "Anthropic" }

    public init(apiKey: String, modelId: String = "claude-sonnet-4-5-20250929", httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.httpClient = httpClient
    }

    public func sendMessage(
        messages: [AIMessage],
        systemPrompt: String,
        tools: [AIToolDefinition]
    ) async throws -> AIResponse {
        let requestBody = buildRequestBody(messages: messages, systemPrompt: systemPrompt, tools: tools)

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("Lungfish Genome Browser", forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 120

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

    // MARK: - Request Building

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

    private func buildMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .user:
                if !message.toolResults.isEmpty {
                    // Tool results are sent as user messages with tool_result content blocks
                    let content: [[String: Any]] = message.toolResults.map { toolResult in
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
                    let content: [[String: Any]] = message.toolResults.map { toolResult in
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
                    result.append(["role": "user", "content": content])
                }

            case .system:
                // System messages are handled via the top-level system parameter
                break
            }
        }

        return result
    }

    private func encodeArguments(_ arguments: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in arguments {
            result[key] = jsonValueToAny(value)
        }
        return result
    }

    private func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let d): return d
        case .integer(let i): return i
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map { jsonValueToAny($0) }
        case .object(let o):
            var dict: [String: Any] = [:]
            for (k, v) in o {
                dict[k] = jsonValueToAny(v)
            }
            return dict
        }
    }

    // MARK: - Response Parsing

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

    private func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let s as String: return .string(s)
        case let i as Int: return .integer(i)
        case let d as Double: return .number(d)
        case let b as Bool: return .bool(b)
        case is NSNull: return .null
        case let a as [Any]: return .array(a.map { anyToJSONValue($0) })
        case let d as [String: Any]:
            var obj: [String: JSONValue] = [:]
            for (k, v) in d {
                obj[k] = anyToJSONValue(v)
            }
            return .object(obj)
        default: return .string("\(value)")
        }
    }

    private func parseErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(data: data, encoding: .utf8)
        }
        return message
    }
}
