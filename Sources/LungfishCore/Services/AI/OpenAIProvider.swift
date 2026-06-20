// OpenAIProvider.swift - OpenAI API implementation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

private let logger = Logger(subsystem: LogSubsystem.core, category: "OpenAIProvider")

/// AI provider implementation for the OpenAI Chat Completions API.
///
/// Supports GPT-4o, GPT-4.1, and newer models with function calling.
/// Translates between the common `AIMessage` format and OpenAI's
/// message/tool_calls format.
public actor OpenAIProvider: StructuredAIProvider {
    private let apiKey: String
    public nonisolated let modelId: String
    private let httpClient: HTTPClient
    private let endpointConfiguration: OpenAIEndpointConfiguration
    private let chatCompletionsURL: URL
    private let responsesURL: URL

    public nonisolated var name: String { "OpenAI" }

    public init(
        apiKey: String,
        modelId: String = OpenAIEndpointConfiguration.defaultOpenAIModel,
        endpointConfiguration: OpenAIEndpointConfiguration = .direct,
        httpClient: HTTPClient = URLSessionHTTPClient()
    ) {
        self.apiKey = apiKey
        self.modelId = endpointConfiguration.effectiveModel(configuredModel: modelId)
        self.endpointConfiguration = endpointConfiguration
        self.chatCompletionsURL = endpointConfiguration.chatCompletionsURL
        self.responsesURL = endpointConfiguration.responsesURL
        self.httpClient = httpClient
    }

    public func sendMessage(
        messages: [AIMessage],
        systemPrompt: String,
        tools: [AIToolDefinition]
    ) async throws -> AIResponse {
        let requestBody = buildRequestBody(messages: messages, systemPrompt: systemPrompt, tools: tools)
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        applyCommonHeaders(to: &request)
        request.httpBody = jsonData
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch let providerError as AIProviderError {
            throw providerError
        } catch {
            throw AIProviderError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return try parseResponse(data)
        case 401:
            throw AIProviderError.missingAPIKey
        case 429:
            if parseErrorCode(data) == "insufficient_quota" {
                throw AIProviderError.quotaExceeded(parseErrorMessage(data) ?? "OpenAI reported insufficient quota.")
            }
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

    public func requestStructuredResult(_ structuredRequest: AIStructuredRequest) async throws -> AIStructuredResponse {
        let useResponsesAPI = endpointConfiguration.supportsResponsesAPI && structuredRequest.reasoningEffort != nil
        let requestBody = useResponsesAPI
            ? buildResponsesStructuredRequestBody(structuredRequest)
            : buildStructuredRequestBody(structuredRequest)
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: useResponsesAPI ? responsesURL : chatCompletionsURL)
        request.httpMethod = "POST"
        applyCommonHeaders(to: &request)
        request.httpBody = jsonData
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch let providerError as AIProviderError {
            throw providerError
        } catch {
            throw AIProviderError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200...299:
            if useResponsesAPI {
                return try parseResponsesStructuredResponse(data, httpResponse: httpResponse, request: structuredRequest)
            }
            return try parseStructuredResponse(data, httpResponse: httpResponse, request: structuredRequest)
        case 401:
            throw AIProviderError.missingAPIKey
        case 429:
            if parseErrorCode(data) == "insufficient_quota" {
                throw AIProviderError.quotaExceeded(parseErrorMessage(data) ?? "OpenAI reported insufficient quota.")
            }
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

    private func applyCommonHeaders(to request: inout URLRequest) {
        let authHeader = endpointConfiguration.authenticationHeader(apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader.value, forHTTPHeaderField: authHeader.name)
        request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
    }

    private func buildStructuredRequestBody(_ request: AIStructuredRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userPrompt],
            ],
            "temperature": request.temperature,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": request.schemaName,
                    "strict": true,
                    "schema": jsonValueToAny(.object(request.schema)),
                ],
            ],
        ]
        if usesMaxCompletionTokensParameter {
            body["max_completion_tokens"] = request.maxOutputTokens
        } else {
            body["max_tokens"] = request.maxOutputTokens
        }
        return body
    }

    private func buildResponsesStructuredRequestBody(_ request: AIStructuredRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelId,
            "input": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userPrompt],
            ],
            "max_output_tokens": request.maxOutputTokens,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": request.schemaName,
                    "strict": true,
                    "schema": jsonValueToAny(.object(request.schema)),
                ],
            ],
        ]
        if let reasoningEffort = request.reasoningEffort {
            body["reasoning"] = ["effort": reasoningEffort]
        }
        return body
    }

    private func buildRequestBody(
        messages: [AIMessage],
        systemPrompt: String,
        tools: [AIToolDefinition]
    ) -> [String: Any] {
        var openAIMessages = buildMessages(messages)
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

    private func buildMessages(_ messages: [AIMessage]) -> [[String: Any]] {
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

    // MARK: - Response Parsing

    private func parseStructuredResponse(
        _ data: Data,
        httpResponse: HTTPURLResponse,
        request: AIStructuredRequest
    ) throws -> AIStructuredResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw AIProviderError.decodingError("Invalid OpenAI response structure")
        }

        let finishReason = firstChoice["finish_reason"] as? String
        if finishReason == "length" {
            throw AIProviderError.invalidResponse("Structured response was truncated before a complete JSON object was returned")
        }

        if let refusal = message["refusal"] as? String, !refusal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIProviderError.invalidResponse("OpenAI returned a refusal instead of structured content")
        }
        if message["refusal"] != nil, !(message["refusal"] is NSNull) {
            throw AIProviderError.invalidResponse("OpenAI returned a refusal instead of structured content")
        }

        guard let rawText = message["content"] as? String else {
            throw AIProviderError.invalidResponse("Structured OpenAI response is missing content")
        }

        let payload = try parseJSONObjectString(rawText)
        let usage = openAIUsage(from: json)
        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id")
            ?? httpResponse.value(forHTTPHeaderField: "request-id")
            ?? json["id"] as? String
        let metadata = AIProviderAttemptMetadata(
            attemptIndex: request.attemptIndex,
            fallbackIndex: request.fallbackIndex,
            provider: "openai",
            model: modelId,
            endpoint: chatCompletionsURL.absoluteString,
            apiVersion: endpointConfiguration.apiVersionLabel(for: .chatCompletions),
            credentialSource: request.credentialSource,
            apiKeyAvailable: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            requestID: requestID,
            statusCode: httpResponse.statusCode,
            stopReason: finishReason,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            sanitizedErrorCategory: nil
        )

        return AIStructuredResponse(
            payload: payload,
            rawText: rawText,
            usage: usage,
            stopReason: aiStopReason(from: finishReason),
            attemptMetadata: metadata
        )
    }

    private func parseResponsesStructuredResponse(
        _ data: Data,
        httpResponse: HTTPURLResponse,
        request: AIStructuredRequest
    ) throws -> AIStructuredResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.decodingError("Invalid OpenAI Responses response structure")
        }

        let status = json["status"] as? String
        if status == "incomplete" {
            throw AIProviderError.invalidResponse("Structured response was incomplete before a complete JSON object was returned")
        }

        let rawText = try responsesOutputText(from: json)
        let payload = try parseJSONObjectString(rawText)
        let usage = openAIResponsesUsage(from: json)
        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id")
            ?? httpResponse.value(forHTTPHeaderField: "request-id")
            ?? json["id"] as? String
        let metadata = AIProviderAttemptMetadata(
            attemptIndex: request.attemptIndex,
            fallbackIndex: request.fallbackIndex,
            provider: "openai",
            model: modelId,
            endpoint: responsesURL.absoluteString,
            apiVersion: endpointConfiguration.apiVersionLabel(for: .responses),
            credentialSource: request.credentialSource,
            apiKeyAvailable: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            requestID: requestID,
            statusCode: httpResponse.statusCode,
            stopReason: status,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            sanitizedErrorCategory: nil
        )

        return AIStructuredResponse(
            payload: payload,
            rawText: rawText,
            usage: usage,
            stopReason: status == "completed" ? .endTurn : .maxTokens,
            attemptMetadata: metadata
        )
    }

    private func responsesOutputText(from json: [String: Any]) throws -> String {
        if let outputText = json["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }
        guard let output = json["output"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse("Structured OpenAI Responses result is missing output")
        }
        let texts = output.flatMap { item -> [String] in
            guard let content = item["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "output_text" else { return nil }
                return block["text"] as? String
            }
        }
        let rawText = texts.joined()
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse("Structured OpenAI Responses result is missing output_text content")
        }
        return rawText
    }

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
}
