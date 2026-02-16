// AIProvider.swift - Core AI types and provider protocol
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - JSON Value Type

/// A type-safe representation of JSON values that is fully Sendable and Codable.
///
/// Used to represent tool call arguments received from LLM APIs, where values
/// can be strings, numbers, booleans, arrays, or nested objects.
public enum JSONValue: Sendable, Equatable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .integer(let i): return i
        case .number(let d): return Int(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var description: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .number(let d): return "\(d)"
        case .integer(let i): return "\(i)"
        case .bool(let b): return "\(b)"
        case .null: return "null"
        case .array(let a): return "[\(a.map(\.description).joined(separator: ", "))]"
        case .object(let o):
            let pairs = o.map { "\"\($0.key)\": \($0.value.description)" }
            return "{\(pairs.joined(separator: ", "))}"
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .integer(i)
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let d): try container.encode(d)
        case .integer(let i): try container.encode(i)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Message Types

/// The role of a message participant in an AI conversation.
public enum AIRole: String, Sendable, Codable {
    case system
    case user
    case assistant
    case tool
}

/// A single message in an AI conversation.
public struct AIMessage: Sendable, Identifiable {
    public let id: UUID
    public let role: AIRole
    public let content: String
    public let toolCalls: [AIToolCall]
    public let toolResults: [AIToolResult]
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        role: AIRole,
        content: String,
        toolCalls: [AIToolCall] = [],
        toolResults: [AIToolResult] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.timestamp = timestamp
    }

    /// Creates a user message.
    public static func user(_ content: String) -> AIMessage {
        AIMessage(role: .user, content: content)
    }

    /// Creates an assistant message.
    public static func assistant(_ content: String, toolCalls: [AIToolCall] = []) -> AIMessage {
        AIMessage(role: .assistant, content: content, toolCalls: toolCalls)
    }

    /// Creates a tool result message.
    public static func toolResult(id: String, content: String, isError: Bool = false) -> AIMessage {
        AIMessage(role: .tool, content: "", toolResults: [AIToolResult(toolCallId: id, content: content, isError: isError)])
    }
}

/// A tool call requested by the AI model.
public struct AIToolCall: Sendable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let arguments: [String: JSONValue]

    public init(id: String, name: String, arguments: [String: JSONValue]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Gets a string argument by key.
    public func string(_ key: String) -> String? {
        arguments[key]?.stringValue
    }

    /// Gets an integer argument by key.
    public func int(_ key: String) -> Int? {
        arguments[key]?.intValue
    }

    /// Gets a boolean argument by key.
    public func bool(_ key: String) -> Bool? {
        arguments[key]?.boolValue
    }
}

/// The result of executing a tool call.
public struct AIToolResult: Sendable {
    public let toolCallId: String
    public let content: String
    public let isError: Bool

    public init(toolCallId: String, content: String, isError: Bool = false) {
        self.toolCallId = toolCallId
        self.content = content
        self.isError = isError
    }
}

// MARK: - Tool Definition

/// Defines a tool that the AI model can call.
public struct AIToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let parameters: [AIToolParameter]

    public init(name: String, description: String, parameters: [AIToolParameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// Serializes the tool definition to a JSON-compatible dictionary for API requests.
    public func toJSON() -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []

        for param in parameters {
            var prop: [String: Any] = [
                "type": param.type.rawValue,
                "description": param.description,
            ]
            if let enumValues = param.enumValues {
                prop["enum"] = enumValues
            }
            properties[param.name] = prop
            if param.required {
                required.append(param.name)
            }
        }

        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }

        return [
            "name": name,
            "description": description,
            "input_schema": schema,
        ]
    }
}

/// A parameter for an AI tool.
public struct AIToolParameter: Sendable {
    public let name: String
    public let type: ParameterType
    public let description: String
    public let required: Bool
    public let enumValues: [String]?

    public enum ParameterType: String, Sendable {
        case string
        case integer
        case number
        case boolean
    }

    public init(
        name: String,
        type: ParameterType,
        description: String,
        required: Bool = true,
        enumValues: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.enumValues = enumValues
    }
}

// MARK: - AI Response

/// Response from an AI provider.
public struct AIResponse: Sendable {
    public let text: String
    public let toolCalls: [AIToolCall]
    public let stopReason: StopReason
    public let usage: Usage?

    public enum StopReason: Sendable {
        case endTurn
        case toolUse
        case maxTokens
        case error(String)
    }

    public struct Usage: Sendable {
        public let inputTokens: Int
        public let outputTokens: Int

        public init(inputTokens: Int, outputTokens: Int) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
    }

    public init(text: String, toolCalls: [AIToolCall] = [], stopReason: StopReason = .endTurn, usage: Usage? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.stopReason = stopReason
        self.usage = usage
    }
}

// MARK: - AI Provider Protocol

/// Protocol for AI language model providers.
///
/// Implementations handle the HTTP communication with specific LLM APIs
/// (Anthropic, OpenAI, Google Gemini) and translate between the common
/// message format and provider-specific JSON formats.
public protocol AIProvider: Sendable {
    /// Human-readable provider name (e.g., "Anthropic", "OpenAI", "Google").
    var name: String { get }

    /// The model identifier used in API requests.
    var modelId: String { get }

    /// Sends a conversation to the AI model and returns the response.
    ///
    /// - Parameters:
    ///   - messages: The conversation history
    ///   - systemPrompt: The system prompt providing context and instructions
    ///   - tools: Available tools the model can call
    /// - Returns: The model's response, which may include text and/or tool calls
    /// - Throws: `AIProviderError` if the request fails
    func sendMessage(
        messages: [AIMessage],
        systemPrompt: String,
        tools: [AIToolDefinition]
    ) async throws -> AIResponse
}

public extension AIProvider {
    /// Performs a lightweight credential/quota check by issuing a minimal completion request.
    ///
    /// Providers should return success for valid keys with available quota/credits.
    /// This default implementation keeps logic centralized across all providers.
    func validateCredentials() async throws {
        _ = try await sendMessage(
            messages: [.user("Return exactly OK.")],
            systemPrompt: "Credential validation request. Return exactly 'OK'.",
            tools: []
        )
    }
}

// MARK: - AI Provider Error

/// Errors that can occur when communicating with AI providers.
public enum AIProviderError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse(String)
    case httpError(statusCode: Int, message: String)
    case rateLimited(retryAfter: TimeInterval?)
    case modelNotAvailable(String)
    case contextTooLong(maxTokens: Int)
    case networkError(String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is not configured. Please add your API key in Settings > AI Services."
        case .invalidResponse(let detail):
            return "Invalid response from AI provider: \(detail)"
        case .httpError(let code, let message):
            return "HTTP error \(code): \(message)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Please try again in \(Int(seconds)) seconds."
            }
            return "Rate limited. Please try again shortly."
        case .modelNotAvailable(let model):
            return "Model '\(model)' is not available. Please check your settings."
        case .contextTooLong(let max):
            return "Conversation is too long (exceeds \(max) tokens). Please start a new conversation."
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .decodingError(let detail):
            return "Failed to decode response: \(detail)"
        }
    }
}

// MARK: - AI Provider Identifier

/// Identifies which AI provider to use.
public enum AIProviderIdentifier: String, Sendable, Codable, CaseIterable {
    case anthropic = "anthropic"
    case openAI = "openai"
    case gemini = "gemini"

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        }
    }
}
