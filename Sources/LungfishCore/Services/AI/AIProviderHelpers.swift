// AIProviderHelpers.swift - Shared helpers for AI provider implementations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - JSONValue / Any Conversion

/// Converts a ``JSONValue`` to its untyped `Any` equivalent for use
/// with `JSONSerialization`.
///
/// - Parameter value: The strongly-typed JSON value to convert.
/// - Returns: An `Any` suitable for inclusion in a `JSONSerialization`-compatible dictionary.
func jsonValueToAny(_ value: JSONValue) -> Any {
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

/// Converts an untyped `Any` (from `JSONSerialization`) back to a
/// strongly-typed ``JSONValue``.
///
/// Unknown types are coerced to their `String` description.
///
/// - Parameter value: The untyped value to convert.
/// - Returns: A ``JSONValue`` representation.
func anyToJSONValue(_ value: Any) -> JSONValue {
    switch value {
    case let s as String: return .string(s)
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() {
            return .bool(n.boolValue)
        }
        let doubleValue = n.doubleValue
        if doubleValue.rounded(.towardZero) == doubleValue,
           doubleValue >= Double(Int.min),
           doubleValue <= Double(Int.max) {
            return .integer(n.intValue)
        }
        return .number(doubleValue)
    case let b as Bool: return .bool(b)
    case let i as Int: return .integer(i)
    case let d as Double: return .number(d)
    case is NSNull: return .null
    case let a as [Any]: return .array(a.map { anyToJSONValue($0) })
    case let d as [String: Any]: return .object(d.mapValues { anyToJSONValue($0) })
    default: return .string("\(value)")
    }
}

// MARK: - Argument Encoding

/// Encodes a dictionary of ``JSONValue`` entries into a plain `[String: Any]`
/// dictionary suitable for `JSONSerialization`.
///
/// - Parameter arguments: The tool-call arguments to encode.
/// - Returns: An untyped dictionary ready for JSON serialization.
func encodeArguments(_ arguments: [String: JSONValue]) -> [String: Any] {
    arguments.mapValues { jsonValueToAny($0) }
}

/// Parses a UTF-8 JSON string and accepts only a top-level object.
func parseJSONObjectString(_ text: String) throws -> [String: JSONValue] {
    guard let data = text.data(using: .utf8) else {
        throw AIProviderError.decodingError("Structured response content is not valid UTF-8")
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AIProviderError.invalidResponse("Structured response must be a valid JSON object")
    }
    return object.mapValues { anyToJSONValue($0) }
}

/// Converts common provider stop reasons to the shared response enum.
func aiStopReason(from raw: String?, toolCallsPresent: Bool = false) -> AIResponse.StopReason {
    switch raw {
    case "stop", "end_turn": return .endTurn
    case "tool_calls", "tool_use": return .toolUse
    case "length", "max_tokens": return .maxTokens
    case .some(let value): return .error(value)
    case .none: return toolCallsPresent ? .toolUse : .endTurn
    }
}

/// Extracts usage from OpenAI-style response usage.
func openAIUsage(from json: [String: Any]) -> AIResponse.Usage? {
    guard let usage = json["usage"] as? [String: Any] else { return nil }
    return AIResponse.Usage(
        inputTokens: usage["prompt_tokens"] as? Int ?? 0,
        outputTokens: usage["completion_tokens"] as? Int ?? 0
    )
}

/// Extracts usage from Anthropic-style response usage.
func anthropicUsage(from json: [String: Any]) -> AIResponse.Usage? {
    guard let usage = json["usage"] as? [String: Any] else { return nil }
    return AIResponse.Usage(
        inputTokens: usage["input_tokens"] as? Int ?? 0,
        outputTokens: usage["output_tokens"] as? Int ?? 0
    )
}

// MARK: - Error Parsing

/// Attempts to extract a human-readable error message from an API error
/// response body.
///
/// Looks for the common `{ "error": { "message": "..." } }` structure used
/// by Anthropic, OpenAI, and Google Gemini APIs. Falls back to the raw
/// UTF-8 body text if parsing fails.
///
/// - Parameter data: The raw HTTP response body.
/// - Returns: The extracted error message, or `nil` if the data cannot be decoded.
func parseErrorMessage(_ data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = json["error"] as? [String: Any],
          let message = error["message"] as? String else {
        return String(data: data, encoding: .utf8)
    }
    return message
}

func parseErrorCode(_ data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = json["error"] as? [String: Any] else {
        return nil
    }
    return (error["code"] as? String) ?? (error["type"] as? String)
}
