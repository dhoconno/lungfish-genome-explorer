// AIProviderTests.swift - Tests for AI provider types and protocol
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class AIProviderTests: XCTestCase {

    // MARK: - JSONValue Tests

    func testJSONValueString() {
        let val = JSONValue.string("hello")
        XCTAssertEqual(val.stringValue, "hello")
        XCTAssertNil(val.intValue)
        XCTAssertNil(val.boolValue)
        XCTAssertEqual(val.description, "\"hello\"")
    }

    func testJSONValueInteger() {
        let val = JSONValue.integer(42)
        XCTAssertEqual(val.intValue, 42)
        XCTAssertEqual(val.doubleValue, 42.0)
        XCTAssertNil(val.stringValue)
        XCTAssertEqual(val.description, "42")
    }

    func testJSONValueNumber() {
        let val = JSONValue.number(3.14)
        XCTAssertEqual(val.doubleValue, 3.14)
        XCTAssertEqual(val.intValue, 3) // truncated
        XCTAssertNil(val.stringValue)
    }

    func testJSONValueBool() {
        let val = JSONValue.bool(true)
        XCTAssertEqual(val.boolValue, true)
        XCTAssertNil(val.stringValue)
    }

    func testJSONValueNull() {
        let val = JSONValue.null
        XCTAssertNil(val.stringValue)
        XCTAssertNil(val.intValue)
        XCTAssertNil(val.boolValue)
        XCTAssertEqual(val.description, "null")
    }

    func testJSONValueArray() {
        let val = JSONValue.array([.string("a"), .integer(1)])
        XCTAssertNotNil(val.arrayValue)
        XCTAssertEqual(val.arrayValue?.count, 2)
        XCTAssertNil(val.stringValue)
    }

    func testJSONValueObject() {
        let val = JSONValue.object(["key": .string("value")])
        XCTAssertNotNil(val.objectValue)
        XCTAssertEqual(val.objectValue?["key"]?.stringValue, "value")
    }

    func testJSONValueEquality() {
        XCTAssertEqual(JSONValue.string("a"), JSONValue.string("a"))
        XCTAssertNotEqual(JSONValue.string("a"), JSONValue.string("b"))
        XCTAssertEqual(JSONValue.integer(1), JSONValue.integer(1))
        XCTAssertEqual(JSONValue.bool(true), JSONValue.bool(true))
        XCTAssertEqual(JSONValue.null, JSONValue.null)
    }

    func testJSONValueCodableRoundTrip() throws {
        let values: [JSONValue] = [
            .string("test"),
            .integer(42),
            .number(3.14),
            .bool(false),
            .null,
            .array([.string("a"), .integer(1)]),
            .object(["key": .string("val"), "num": .integer(2)]),
        ]

        for original in values {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
            XCTAssertEqual(original, decoded, "Round-trip failed for \(original)")
        }
    }

    func testJSONValueDecodingFromJSON() throws {
        let json = """
        {"name": "BRCA1", "count": 42, "score": 3.14, "active": true, "items": [1, 2]}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(decoded["name"]?.stringValue, "BRCA1")
        XCTAssertEqual(decoded["count"]?.intValue, 42)
        XCTAssertEqual(decoded["active"]?.boolValue, true)
        XCTAssertEqual(decoded["items"]?.arrayValue?.count, 2)
    }

    func testJSONObjectStringParsingPreservesIntegerOneInsteadOfBool() throws {
        let parsed = try parseJSONObjectString("""
        {"schemaVersion":1,"ok":true,"count":2,"score":3.5}
        """)

        XCTAssertEqual(parsed["schemaVersion"], .integer(1))
        XCTAssertEqual(parsed["ok"], .bool(true))
        XCTAssertEqual(parsed["count"], .integer(2))
        XCTAssertEqual(parsed["score"], .number(3.5))
    }

    // MARK: - AIMessage Tests

    func testUserMessageCreation() {
        let msg = AIMessage.user("Hello")
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.content, "Hello")
        XCTAssertTrue(msg.toolCalls.isEmpty)
        XCTAssertTrue(msg.toolResults.isEmpty)
    }

    func testAssistantMessageCreation() {
        let msg = AIMessage.assistant("Response text")
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.content, "Response text")
    }

    func testAssistantMessageWithToolCalls() {
        let toolCall = AIToolCall(
            id: "call_1",
            name: "search_genes",
            arguments: ["query": .string("BRCA1")]
        )
        let msg = AIMessage.assistant("", toolCalls: [toolCall])
        XCTAssertEqual(msg.toolCalls.count, 1)
        XCTAssertEqual(msg.toolCalls[0].name, "search_genes")
    }

    func testToolResultMessage() {
        let msg = AIMessage.toolResult(id: "call_1", content: "Gene found: BRCA1")
        XCTAssertEqual(msg.role, .tool)
        XCTAssertEqual(msg.toolResults.count, 1)
        XCTAssertEqual(msg.toolResults[0].toolCallId, "call_1")
        XCTAssertFalse(msg.toolResults[0].isError)
    }

    func testToolResultErrorMessage() {
        let msg = AIMessage.toolResult(id: "call_1", content: "Error: not found", isError: true)
        XCTAssertTrue(msg.toolResults[0].isError)
    }

    // MARK: - AIToolCall Tests

    func testToolCallStringArgument() {
        let call = AIToolCall(
            id: "1",
            name: "search_genes",
            arguments: ["query": .string("BRCA1"), "limit": .integer(10)]
        )
        XCTAssertEqual(call.string("query"), "BRCA1")
        XCTAssertNil(call.string("limit"))
        XCTAssertEqual(call.int("limit"), 10)
        XCTAssertNil(call.int("query"))
    }

    func testToolCallBoolArgument() {
        let call = AIToolCall(
            id: "1",
            name: "test",
            arguments: ["flag": .bool(true)]
        )
        XCTAssertEqual(call.bool("flag"), true)
        XCTAssertNil(call.bool("missing"))
    }

    func testToolCallMissingArgument() {
        let call = AIToolCall(id: "1", name: "test", arguments: [:])
        XCTAssertNil(call.string("anything"))
        XCTAssertNil(call.int("anything"))
        XCTAssertNil(call.bool("anything"))
    }

    // MARK: - AIToolDefinition Tests

    func testToolDefinitionToJSON() {
        let tool = AIToolDefinition(
            name: "search_genes",
            description: "Search for genes",
            parameters: [
                AIToolParameter(name: "query", type: .string, description: "The search query"),
                AIToolParameter(name: "limit", type: .integer, description: "Max results", required: false),
            ]
        )

        let json = tool.toJSON()
        XCTAssertEqual(json["name"] as? String, "search_genes")
        XCTAssertEqual(json["description"] as? String, "Search for genes")

        let schema = json["input_schema"] as? [String: Any]
        XCTAssertNotNil(schema)
        XCTAssertEqual(schema?["type"] as? String, "object")

        let properties = schema?["properties"] as? [String: Any]
        XCTAssertNotNil(properties)
        XCTAssertNotNil(properties?["query"])
        XCTAssertNotNil(properties?["limit"])

        let required = schema?["required"] as? [String]
        XCTAssertNotNil(required)
        XCTAssertTrue(required?.contains("query") == true)
        XCTAssertFalse(required?.contains("limit") == true)
    }

    func testToolDefinitionWithEnumValues() {
        let tool = AIToolDefinition(
            name: "filter_variants",
            description: "Filter by type",
            parameters: [
                AIToolParameter(name: "type", type: .string, description: "Variant type",
                                enumValues: ["SNP", "INS", "DEL"]),
            ]
        )

        let json = tool.toJSON()
        let schema = json["input_schema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let typeProp = properties?["type"] as? [String: Any]
        XCTAssertNotNil(typeProp)
        XCTAssertEqual(typeProp?["enum"] as? [String], ["SNP", "INS", "DEL"])
    }

    // MARK: - AIResponse Tests

    func testResponseWithTextOnly() {
        let response = AIResponse(text: "Hello!", stopReason: .endTurn)
        XCTAssertEqual(response.text, "Hello!")
        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertNil(response.usage)
    }

    func testResponseWithToolCalls() {
        let call = AIToolCall(id: "1", name: "search_genes", arguments: ["query": .string("TP53")])
        let response = AIResponse(
            text: "",
            toolCalls: [call],
            stopReason: .toolUse,
            usage: AIResponse.Usage(inputTokens: 100, outputTokens: 50)
        )
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.usage?.inputTokens, 100)
        XCTAssertEqual(response.usage?.outputTokens, 50)
    }

    // MARK: - AIProviderError Tests

    func testProviderErrorDescriptions() {
        let errors: [(AIProviderError, String)] = [
            (.missingAPIKey, "API key is not configured"),
            (.invalidResponse("bad JSON"), "Invalid response"),
            (.httpError(statusCode: 429, message: "too many"), "HTTP error 429"),
            (.rateLimited(retryAfter: 30), "30 seconds"),
            (.rateLimited(retryAfter: nil), "try again shortly"),
            (.quotaExceeded("billing required"), "quota"),
            (.modelNotAvailable("gpt-5"), "gpt-5"),
            (.contextTooLong(maxTokens: 128000), "128000 tokens"),
            (.networkError("timeout"), "timeout"),
            (.decodingError("missing field"), "missing field"),
        ]

        for (error, substring) in errors {
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains(substring), "Expected '\(substring)' in '\(desc)'")
        }
    }

    // MARK: - AIProviderIdentifier Tests

    func testProviderIdentifierRawValues() {
        XCTAssertEqual(AIProviderIdentifier.anthropic.rawValue, "anthropic")
        XCTAssertEqual(AIProviderIdentifier.openAI.rawValue, "openai")
        XCTAssertEqual(AIProviderIdentifier.gemini.rawValue, "gemini")
    }

    func testProviderIdentifierDisplayNames() {
        XCTAssertEqual(AIProviderIdentifier.anthropic.displayName, "Anthropic Claude")
        XCTAssertEqual(AIProviderIdentifier.openAI.displayName, "OpenAI")
        XCTAssertEqual(AIProviderIdentifier.gemini.displayName, "Google Gemini")
    }

    func testProviderIdentifierFromRawValue() {
        XCTAssertEqual(AIProviderIdentifier(rawValue: "anthropic"), .anthropic)
        XCTAssertEqual(AIProviderIdentifier(rawValue: "openai"), .openAI)
        XCTAssertEqual(AIProviderIdentifier(rawValue: "gemini"), .gemini)
        XCTAssertNil(AIProviderIdentifier(rawValue: "invalid"))
    }

    func testProviderIdentifierAllCases() {
        XCTAssertEqual(AIProviderIdentifier.allCases.count, 3)
    }

    // MARK: - AIRole Tests

    func testAIRoleRawValues() {
        XCTAssertEqual(AIRole.system.rawValue, "system")
        XCTAssertEqual(AIRole.user.rawValue, "user")
        XCTAssertEqual(AIRole.assistant.rawValue, "assistant")
        XCTAssertEqual(AIRole.tool.rawValue, "tool")
    }

    // MARK: - AIToolParameter Tests

    func testParameterTypeRawValues() {
        XCTAssertEqual(AIToolParameter.ParameterType.string.rawValue, "string")
        XCTAssertEqual(AIToolParameter.ParameterType.integer.rawValue, "integer")
        XCTAssertEqual(AIToolParameter.ParameterType.number.rawValue, "number")
        XCTAssertEqual(AIToolParameter.ParameterType.boolean.rawValue, "boolean")
    }

    func testParameterDefaults() {
        let param = AIToolParameter(name: "query", type: .string, description: "Search query")
        XCTAssertTrue(param.required)
        XCTAssertNil(param.enumValues)
    }

    // MARK: - OpenAI Request Parameters

    func testOpenAIGPT5UsesMaxCompletionTokens() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json([
            "choices": [["message": ["content": "ok"], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 1, "completion_tokens": 1],
        ]))
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5-mini", httpClient: mockClient)

        _ = try await provider.sendMessage(
            messages: [.user("hello")],
            systemPrompt: "test",
            tools: []
        )

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first?.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(payload["max_completion_tokens"])
        XCTAssertNil(payload["max_tokens"])
    }

    func testOpenAIGPT41UsesMaxTokens() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json([
            "choices": [["message": ["content": "ok"], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 1, "completion_tokens": 1],
        ]))
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-4.1", httpClient: mockClient)

        _ = try await provider.sendMessage(
            messages: [.user("hello")],
            systemPrompt: "test",
            tools: []
        )

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first?.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(payload["max_tokens"])
        XCTAssertNil(payload["max_completion_tokens"])
    }

    func testOpenAIStructuredResultUsesStrictJSONSchemaResponseFormat() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json([
            "id": "chatcmpl_test",
            "choices": [[
                "message": ["content": #"{"schemaVersion":1,"ok":true}"#],
                "finish_reason": "stop",
            ]],
            "usage": ["prompt_tokens": 11, "completion_tokens": 7],
        ]))
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5-mini", httpClient: mockClient)
        let request = AIStructuredRequest(
            systemPrompt: "Return JSON only.",
            userPrompt: "Classify this evidence.",
            schemaName: "ai_haplotype_result",
            schema: Self.strictHaplotypeSchema,
            maxOutputTokens: 2048,
            temperature: 0,
            attemptIndex: 2,
            fallbackIndex: 1,
            credentialSource: "keychain"
        )

        let response = try await provider.requestStructuredResult(request)

        XCTAssertEqual(response.payload["ok"]?.boolValue, true)
        XCTAssertEqual(response.rawText, #"{"schemaVersion":1,"ok":true}"#)
        XCTAssertEqual(response.usage?.inputTokens, 11)
        XCTAssertEqual(response.usage?.outputTokens, 7)
        XCTAssertEqual(response.attemptMetadata.attemptIndex, 2)
        XCTAssertEqual(response.attemptMetadata.fallbackIndex, 1)
        XCTAssertEqual(response.attemptMetadata.apiVersion, "chat.completions.v1")
        XCTAssertEqual(response.attemptMetadata.credentialSource, "keychain")
        XCTAssertEqual(response.attemptMetadata.apiKeyAvailable, true)
        XCTAssertEqual(response.attemptMetadata.requestID, "chatcmpl_test")
        XCTAssertEqual(response.attemptMetadata.statusCode, 200)

        let requests = await mockClient.requests
        let captured = try XCTUnwrap(requests.first?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["name"] as? String, "ai_haplotype_result")
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testOpenAIStructuredResultUsesResponsesAPIWhenReasoningEffortIsSet() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json([
            "id": "resp_test",
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [[
                    "type": "output_text",
                    "text": #"{"schemaVersion":1,"ok":true}"#,
                ]],
            ]],
            "usage": [
                "input_tokens": 17,
                "output_tokens": 9,
                "input_tokens_details": ["cached_tokens": 1024],
                "output_tokens_details": ["reasoning_tokens": 6],
            ],
        ]))
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5.5", httpClient: mockClient)

        let request = AIStructuredRequest(
            systemPrompt: "Return JSON only.",
            userPrompt: "Classify this evidence.",
            schemaName: "ai_haplotype_result",
            schema: Self.strictHaplotypeSchema,
            maxOutputTokens: 2048,
            temperature: 0,
            reasoningEffort: "low",
            promptCacheRetention: "24h",
            promptCacheKey: "mcm-mhc-miseq-specialist-2026-06-19-1",
            attemptIndex: 2,
            fallbackIndex: 1,
            credentialSource: "keychain"
        )

        let response = try await provider.requestStructuredResult(request)

        XCTAssertEqual(response.payload["ok"]?.boolValue, true)
        XCTAssertEqual(response.rawText, #"{"schemaVersion":1,"ok":true}"#)
        XCTAssertEqual(response.usage?.inputTokens, 17)
        XCTAssertEqual(response.usage?.outputTokens, 9)
        XCTAssertEqual(response.usage?.cachedInputTokens, 1024)
        XCTAssertEqual(response.usage?.reasoningOutputTokens, 6)
        XCTAssertEqual(response.attemptMetadata.apiVersion, "responses.v1")
        XCTAssertEqual(response.attemptMetadata.endpoint, "https://api.openai.com/v1/responses")
        XCTAssertEqual(response.attemptMetadata.stopReason, "completed")
        XCTAssertEqual(response.attemptMetadata.cachedInputTokens, 1024)
        XCTAssertEqual(response.attemptMetadata.reasoningOutputTokens, 6)

        let requests = await mockClient.requests
        let url = try XCTUnwrap(requests.first?.url)
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(requests.first?.timeoutInterval, 600)
        let captured = try XCTUnwrap(requests.first?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2048)
        XCTAssertEqual(body["prompt_cache_retention"] as? String, "24h")
        XCTAssertEqual(body["prompt_cache_key"] as? String, "mcm-mhc-miseq-specialist-2026-06-19-1")
        XCTAssertNil(body["temperature"])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "low")
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["name"] as? String, "ai_haplotype_result")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testAIStructuredRequestPreservesReasoningEffort() {
        let request = AIStructuredRequest(
            systemPrompt: "Return JSON only.",
            userPrompt: "Classify this evidence.",
            schemaName: "ai_haplotype_result",
            schema: Self.strictHaplotypeSchema,
            maxOutputTokens: 2048,
            temperature: 0,
            reasoningEffort: "low",
            attemptIndex: 2,
            fallbackIndex: 1,
            credentialSource: "environment:OPENAI_API_KEY"
        )

        XCTAssertEqual(request.reasoningEffort, "low")
    }

    func testOpenAIAzureEndpointUsesDeploymentURLAndAPIKeyHeader() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json([
            "id": "chatcmpl_azure",
            "choices": [[
                "message": ["content": "OK"],
                "finish_reason": "stop",
            ]],
            "usage": ["prompt_tokens": 3, "completion_tokens": 1],
        ]))
        let provider = OpenAIProvider(
            apiKey: "azure-key",
            modelId: "gpt-5.5",
            endpointConfiguration: .azure(
                endpoint: URL(string: "https://oc-aiservices.openai.azure.com/")!,
                deployment: "gpt-5-mini",
                apiVersion: "2025-01-01-preview"
            ),
            httpClient: mockClient
        )

        _ = try await provider.sendMessage(messages: [AIMessage.user("Hello")], systemPrompt: "Reply.", tools: [])

        XCTAssertEqual(provider.modelId, "gpt-5-mini")
        let requests = await mockClient.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://oc-aiservices.openai.azure.com/openai/deployments/gpt-5-mini/chat/completions?api-version=2025-01-01-preview"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "azure-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let captured = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5-mini")
    }

    func testOpenAIStructuredResultRecordsAzureEndpointMetadata() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json([
            "id": "chatcmpl_azure_structured",
            "choices": [[
                "message": ["content": #"{"schemaVersion":1,"ok":true}"#],
                "finish_reason": "stop",
            ]],
            "usage": ["prompt_tokens": 11, "completion_tokens": 7],
        ]))
        let provider = OpenAIProvider(
            apiKey: "azure-key",
            modelId: "gpt-5.5",
            endpointConfiguration: .azure(
                endpoint: URL(string: "https://oc-aiservices.openai.azure.com")!,
                deployment: "gpt-5-mini",
                apiVersion: "2025-01-01-preview"
            ),
            httpClient: mockClient
        )

        let response = try await provider.requestStructuredResult(AIStructuredRequest.minimalHaplotypeSchemaRequest())

        XCTAssertEqual(response.payload["ok"]?.boolValue, true)
        XCTAssertEqual(response.attemptMetadata.provider, "openai")
        XCTAssertEqual(response.attemptMetadata.model, "gpt-5-mini")
        XCTAssertEqual(
            response.attemptMetadata.endpoint,
            "https://oc-aiservices.openai.azure.com/openai/deployments/gpt-5-mini/chat/completions?api-version=2025-01-01-preview"
        )
        XCTAssertEqual(response.attemptMetadata.apiVersion, "2025-01-01-preview")
    }

    func testOpenAIStructuredResultDistinguishesInsufficientQuotaFromRetryableRateLimit() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json([
            "error": [
                "type": "insufficient_quota",
                "code": "insufficient_quota",
                "message": "You exceeded your current quota, please check your plan and billing details.",
            ],
        ], statusCode: 429))
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5-mini", httpClient: mockClient)

        do {
            _ = try await provider.requestStructuredResult(.minimalHaplotypeSchemaRequest())
            XCTFail("Expected insufficient quota to fail")
        } catch AIProviderError.quotaExceeded(let message) {
            XCTAssertTrue(message.localizedCaseInsensitiveContains("quota"))
            XCTAssertTrue(message.localizedCaseInsensitiveContains("billing"))
        } catch {
            XCTFail("Expected quotaExceeded, got \(error)")
        }
    }

    func testOpenAIStructuredResultMapsTransportFailureToNetworkError() async throws {
        let mockClient = MockHTTPClient()
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5-mini", httpClient: mockClient)

        do {
            _ = try await provider.requestStructuredResult(.minimalHaplotypeSchemaRequest())
            XCTFail("Expected transport failure to fail")
        } catch AIProviderError.networkError(let message) {
            XCTAssertFalse(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch {
            XCTFail("Expected networkError, got \(error)")
        }
    }

    func testAnthropicStructuredResultForcesSingleResultTool() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json([
            "id": "msg_test",
            "content": [[
                "type": "tool_use",
                "id": "toolu_1",
                "name": "ai_haplotype_result",
                "input": ["schemaVersion": 1, "ok": true],
            ]],
            "stop_reason": "tool_use",
            "usage": ["input_tokens": 13, "output_tokens": 9],
        ]))
        let provider = AnthropicProvider(apiKey: "test-key", modelId: "claude-sonnet-4-5-20250929", httpClient: mockClient)
        let request = AIStructuredRequest(
            systemPrompt: "Use the result tool.",
            userPrompt: "Classify this evidence.",
            schemaName: "ai_haplotype_result",
            schema: Self.strictHaplotypeSchema,
            maxOutputTokens: 2048,
            temperature: 0,
            attemptIndex: 3,
            fallbackIndex: 2,
            credentialSource: "environment"
        )

        let response = try await provider.requestStructuredResult(request)

        XCTAssertEqual(response.payload["ok"]?.boolValue, true)
        XCTAssertNil(response.rawText)
        XCTAssertEqual(response.usage?.inputTokens, 13)
        XCTAssertEqual(response.usage?.outputTokens, 9)
        XCTAssertEqual(response.attemptMetadata.attemptIndex, 3)
        XCTAssertEqual(response.attemptMetadata.fallbackIndex, 2)
        XCTAssertEqual(response.attemptMetadata.apiVersion, "2023-06-01")
        XCTAssertEqual(response.attemptMetadata.credentialSource, "environment")
        XCTAssertEqual(response.attemptMetadata.apiKeyAvailable, true)
        XCTAssertEqual(response.attemptMetadata.requestID, "msg_test")
        XCTAssertEqual(response.attemptMetadata.statusCode, 200)

        let requests = await mockClient.requests
        let captured = try XCTUnwrap(requests.first?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        let toolChoice = try XCTUnwrap(body["tool_choice"] as? [String: Any])
        XCTAssertEqual(toolChoice["type"] as? String, "tool")
        XCTAssertEqual(toolChoice["name"] as? String, "ai_haplotype_result")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["name"] as? String, "ai_haplotype_result")
        XCTAssertEqual(tools.first?["strict"] as? Bool, true)
        let schema = try XCTUnwrap(tools.first?["input_schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testOpenAIStructuredResultRejectsTruncationRefusalMalformedNonObjectAndMissingContent() async throws {
        let cases: [(String, [String: Any], String)] = [
            ("length", [
                "choices": [["message": ["content": #"{"schemaVersion":"#], "finish_reason": "length"]],
            ], "truncated"),
            ("refusal", [
                "choices": [["message": ["refusal": "I cannot help with that"], "finish_reason": "stop"]],
            ], "refusal"),
            ("malformed", [
                "choices": [["message": ["content": "not-json"], "finish_reason": "stop"]],
            ], "valid JSON object"),
            ("non-object", [
                "choices": [["message": ["content": "[1,2,3]"], "finish_reason": "stop"]],
            ], "JSON object"),
            ("missing-content", [
                "choices": [["message": [:], "finish_reason": "stop"]],
            ], "content"),
        ]

        for (name, payload, expected) in cases {
            let mockClient = MockHTTPClient()
            await mockClient.setDefault(response: .json(payload))
            let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5-mini", httpClient: mockClient)

            do {
                _ = try await provider.requestStructuredResult(.minimalHaplotypeSchemaRequest())
                XCTFail("Expected OpenAI case \(name) to fail")
            } catch AIProviderError.invalidResponse(let message) {
                XCTAssertTrue(message.localizedCaseInsensitiveContains(expected), "case \(name): \(message)")
            } catch AIProviderError.decodingError(let message) {
                XCTAssertTrue(message.localizedCaseInsensitiveContains(expected), "case \(name): \(message)")
            }
        }
    }

    func testAnthropicStructuredResultRejectsMissingMultipleExtraAndTextOnlyResultBlocks() async throws {
        let cases: [(String, [String: Any], String)] = [
            ("missing-tool", [
                "content": [],
                "stop_reason": "end_turn",
            ], "required result tool"),
            ("multiple-tools", [
                "content": [
                    ["type": "tool_use", "id": "toolu_1", "name": "ai_haplotype_result", "input": ["schemaVersion": 1]],
                    ["type": "tool_use", "id": "toolu_2", "name": "ai_haplotype_result", "input": ["schemaVersion": 1]],
                ],
                "stop_reason": "tool_use",
            ], "exactly one"),
            ("extra-text", [
                "content": [
                    ["type": "text", "text": "Here is a summary"],
                    ["type": "tool_use", "id": "toolu_1", "name": "ai_haplotype_result", "input": ["schemaVersion": 1]],
                ],
                "stop_reason": "tool_use",
            ], "extra content"),
            ("text-only", [
                "content": [["type": "text", "text": "Here is the answer."]],
                "stop_reason": "end_turn",
            ], "required result tool"),
        ]

        for (name, payload, expected) in cases {
            let mockClient = MockHTTPClient()
            await mockClient.setDefault(response: .json(payload))
            let provider = AnthropicProvider(apiKey: "test-key", modelId: "claude-sonnet-4-5-20250929", httpClient: mockClient)

            do {
                _ = try await provider.requestStructuredResult(.minimalHaplotypeSchemaRequest())
                XCTFail("Expected Anthropic case \(name) to fail")
            } catch AIProviderError.invalidResponse(let message) {
                XCTAssertTrue(message.localizedCaseInsensitiveContains(expected), "case \(name): \(message)")
            }
        }
    }

    private static let strictHaplotypeSchema: [String: JSONValue] = [
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("schemaVersion"), .string("ok")]),
        "properties": .object([
            "schemaVersion": .object(["type": .string("integer")]),
            "ok": .object(["type": .string("boolean")]),
        ]),
    ]
}

private extension AIStructuredRequest {
    static func minimalHaplotypeSchemaRequest() -> AIStructuredRequest {
        AIStructuredRequest(
            systemPrompt: "Use the schema.",
            userPrompt: "Return the result.",
            schemaName: "ai_haplotype_result",
            schema: [
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("schemaVersion")]),
                "properties": .object([
                    "schemaVersion": .object(["type": .string("integer")]),
                ]),
            ],
            maxOutputTokens: 512,
            temperature: 0
        )
    }
}
