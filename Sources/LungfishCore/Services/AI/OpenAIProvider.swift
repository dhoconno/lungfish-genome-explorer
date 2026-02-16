// OpenAIProvider.swift - OpenAI API implementation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

private let logger = Logger(subsystem: "com.lungfish", category: "OpenAIProvider")

/// AI provider implementation for the OpenAI Chat Completions API.
///
/// Supports GPT-4o, GPT-4.1, and newer models with function calling.
/// Translates between the common `AIMessage` format and OpenAI's
/// message/tool_calls format.
public actor OpenAIProvider: AIProvider {
    private let apiKey: String
    public let modelId: String
    private let httpClient: HTTPClient
    private let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    public nonisolated var name: String { "OpenAI" }

    public init(apiKey: String, modelId: String = "gpt-5-mini", httpClient: HTTPClient = URLSessionHTTPClient()) {
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        var openAIMessages = buildMessages(messages, systemPrompt: systemPrompt)
        // Insert system prompt at the beginning
        openAIMessages.insert(["role": "system", "content": systemPrompt], at: 0)

        var body: [String: Any] = [
            "model": modelId,
            "messages": openAIMessages,
        ]
        if usesMaxCompletionTokensParameter {
            body["max_completion_tokens"] = 4096
        } else {
            body["max_tokens"] = 4096
        }

        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                let schema = tool.toJSON()
                // OpenAI uses "parameters" instead of "input_schema" and wraps in "function"
                var params = schema["input_schema"] as? [String: Any] ?? [:]
                // Ensure additionalProperties is set for strict mode
                params["additionalProperties"] = false
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": params,
                    ],
                ]
            }
        }

        return body
    }

    private var usesMaxCompletionTokensParameter: Bool {
        modelId.lowercased().hasPrefix("gpt-5")
    }

    private func buildMessages(_ messages: [AIMessage], systemPrompt: String) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .user:
                if !message.toolResults.isEmpty {
                    // OpenAI sends tool results as individual "tool" role messages
                    for toolResult in message.toolResults {
                        result.append([
                            "role": "tool",
                            "tool_call_id": toolResult.toolCallId,
                            "content": toolResult.content,
                        ])
                    }
                } else {
                    result.append(["role": "user", "content": message.content])
                }

            case .assistant:
                var msg: [String: Any] = ["role": "assistant"]
                if !message.content.isEmpty {
                    msg["content"] = message.content
                }
                if !message.toolCalls.isEmpty {
                    msg["tool_calls"] = message.toolCalls.map { call -> [String: Any] in
                        let argsData = try? JSONSerialization.data(
                            withJSONObject: encodeArguments(call.arguments))
                        let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        return [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": argsString,
                            ],
                        ]
                    }
                }
                result.append(msg)

            case .tool:
                for toolResult in message.toolResults {
                    result.append([
                        "role": "tool",
                        "tool_call_id": toolResult.toolCallId,
                        "content": toolResult.content,
                    ])
                }

            case .system:
                // Handled separately
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
            for (k, v) in o { dict[k] = jsonValueToAny(v) }
            return dict
        }
    }

    // MARK: - Response Parsing

    private func parseResponse(_ data: Data) throws -> AIResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw AIProviderError.decodingError("Invalid OpenAI response structure")
        }

        let text = message["content"] as? String ?? ""
        var toolCalls: [AIToolCall] = []

        if let rawToolCalls = message["tool_calls"] as? [[String: Any]] {
            for rawCall in rawToolCalls {
                guard let callId = rawCall["id"] as? String,
                      let function = rawCall["function"] as? [String: Any],
                      let funcName = function["name"] as? String else { continue }

                let argsString = function["arguments"] as? String ?? "{}"
                let arguments: [String: JSONValue]
                if let argsData = argsString.data(using: .utf8),
                   let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    arguments = argsDict.mapValues { anyToJSONValue($0) }
                } else {
                    arguments = [:]
                }

                toolCalls.append(AIToolCall(id: callId, name: funcName, arguments: arguments))
            }
        }

        let stopReason: AIResponse.StopReason
        switch firstChoice["finish_reason"] as? String {
        case "stop": stopReason = .endTurn
        case "tool_calls": stopReason = .toolUse
        case "length": stopReason = .maxTokens
        default: stopReason = toolCalls.isEmpty ? .endTurn : .toolUse
        }

        var usage: AIResponse.Usage?
        if let usageDict = json["usage"] as? [String: Any] {
            let input = usageDict["prompt_tokens"] as? Int ?? 0
            let output = usageDict["completion_tokens"] as? Int ?? 0
            usage = AIResponse.Usage(inputTokens: input, outputTokens: output)
        }

        return AIResponse(text: text, toolCalls: toolCalls, stopReason: stopReason, usage: usage)
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
            return .object(d.mapValues { anyToJSONValue($0) })
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
