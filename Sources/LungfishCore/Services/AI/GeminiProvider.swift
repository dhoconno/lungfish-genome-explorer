// GeminiProvider.swift - Google Gemini API implementation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

private let logger = Logger(subsystem: "com.lungfish", category: "GeminiProvider")

/// AI provider implementation for the Google Gemini API.
///
/// Uses the generateContent endpoint with function calling support.
/// Translates between the common `AIMessage` format and Gemini's
/// content/parts format.
public actor GeminiProvider: AIProvider {
    private let apiKey: String
    public let modelId: String
    private let httpClient: HTTPClient

    public nonisolated var name: String { "Google" }

    public init(apiKey: String, modelId: String = "gemini-2.5-flash", httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.httpClient = httpClient
    }

    private var endpointURL: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent?key=\(apiKey)")!
    }

    public func sendMessage(
        messages: [AIMessage],
        systemPrompt: String,
        tools: [AIToolDefinition]
    ) async throws -> AIResponse {
        let requestBody = buildRequestBody(messages: messages, systemPrompt: systemPrompt, tools: tools)
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        case 401, 403:
            throw AIProviderError.missingAPIKey
        case 429:
            throw AIProviderError.rateLimited(retryAfter: nil)
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
        var body: [String: Any] = [
            "contents": buildContents(messages),
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
        ]

        if !tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": tools.map { tool -> [String: Any] in
                    let schema = tool.toJSON()
                    let inputSchema = schema["input_schema"] as? [String: Any] ?? [:]
                    return [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": inputSchema,
                    ]
                }
            ]]
        }

        // Configure generation
        body["generationConfig"] = [
            "maxOutputTokens": 4096,
            "temperature": 0.7,
        ]

        return body
    }

    private func buildContents(_ messages: [AIMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .user:
                if !message.toolResults.isEmpty {
                    let parts: [[String: Any]] = message.toolResults.map { toolResult in
                        [
                            "functionResponse": [
                                "name": extractToolName(from: toolResult.toolCallId),
                                "response": [
                                    "content": toolResult.content
                                ],
                            ]
                        ]
                    }
                    result.append(["role": "user", "parts": parts])
                } else {
                    result.append(["role": "user", "parts": [["text": message.content]]])
                }

            case .assistant:
                var parts: [[String: Any]] = []
                if !message.content.isEmpty {
                    parts.append(["text": message.content])
                }
                for toolCall in message.toolCalls {
                    parts.append([
                        "functionCall": [
                            "name": toolCall.name,
                            "args": encodeArguments(toolCall.arguments),
                        ]
                    ])
                }
                if !parts.isEmpty {
                    result.append(["role": "model", "parts": parts])
                }

            case .tool:
                let parts: [[String: Any]] = message.toolResults.map { toolResult in
                    [
                        "functionResponse": [
                            "name": extractToolName(from: toolResult.toolCallId),
                            "response": [
                                "content": toolResult.content
                            ],
                        ]
                    ]
                }
                if !parts.isEmpty {
                    result.append(["role": "user", "parts": parts])
                }

            case .system:
                break
            }
        }

        return result
    }

    /// Gemini function responses need the function name, not just the call ID.
    /// We store the tool name in the call ID using the format "name:uuid".
    private func extractToolName(from toolCallId: String) -> String {
        if let colonIndex = toolCallId.firstIndex(of: ":") {
            return String(toolCallId[toolCallId.startIndex..<colonIndex])
        }
        return toolCallId
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
        case .object(let o): return o.mapValues { jsonValueToAny($0) }
        }
    }

    // MARK: - Response Parsing

    private func parseResponse(_ data: Data) throws -> AIResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw AIProviderError.decodingError("Invalid Gemini response structure")
        }

        var textParts: [String] = []
        var toolCalls: [AIToolCall] = []

        for part in parts {
            if let text = part["text"] as? String {
                textParts.append(text)
            } else if let functionCall = part["functionCall"] as? [String: Any] {
                let name = functionCall["name"] as? String ?? ""
                let args = functionCall["args"] as? [String: Any] ?? [:]
                let callId = "\(name):\(UUID().uuidString)"
                toolCalls.append(AIToolCall(
                    id: callId,
                    name: name,
                    arguments: args.mapValues { anyToJSONValue($0) }
                ))
            }
        }

        let stopReason: AIResponse.StopReason
        if !toolCalls.isEmpty {
            stopReason = .toolUse
        } else {
            switch firstCandidate["finishReason"] as? String {
            case "STOP": stopReason = .endTurn
            case "MAX_TOKENS": stopReason = .maxTokens
            case "SAFETY": stopReason = .error("Response blocked by safety filters")
            default: stopReason = .endTurn
            }
        }

        var usage: AIResponse.Usage?
        if let usageMetadata = json["usageMetadata"] as? [String: Any] {
            let input = usageMetadata["promptTokenCount"] as? Int ?? 0
            let output = usageMetadata["candidatesTokenCount"] as? Int ?? 0
            usage = AIResponse.Usage(inputTokens: input, outputTokens: output)
        }

        return AIResponse(text: textParts.joined(), toolCalls: toolCalls, stopReason: stopReason, usage: usage)
    }

    private func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let s as String: return .string(s)
        case let i as Int: return .integer(i)
        case let d as Double: return .number(d)
        case let b as Bool: return .bool(b)
        case is NSNull: return .null
        case let a as [Any]: return .array(a.map { anyToJSONValue($0) })
        case let d as [String: Any]: return .object(d.mapValues { anyToJSONValue($0) })
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
