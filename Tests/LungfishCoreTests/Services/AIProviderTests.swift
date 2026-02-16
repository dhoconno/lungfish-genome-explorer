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
}
