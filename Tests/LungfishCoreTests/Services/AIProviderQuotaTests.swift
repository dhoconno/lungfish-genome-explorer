// AIProviderQuotaTests.swift - Quota and permission errors for the AI providers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// GitHub issue 35. A provider that refuses a request because the account has no credits, or
/// has reached a spend or usage limit, must throw `.quotaExceeded` with the provider's own
/// message, since waiting and retrying cannot help. A true rate limit keeps `.rateLimited`.
final class AIProviderQuotaTests: XCTestCase {

    // MARK: - Helpers

    /// Runs `operation` and returns the `AIProviderError` it throws. The test fails when the
    /// request succeeds or throws something else, and the result is then nil.
    private func thrownProviderError(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> AIProviderError? {
        do {
            try await operation()
            XCTFail("Expected the request to fail", file: file, line: line)
        } catch let error as AIProviderError {
            return error
        } catch {
            XCTFail("Expected AIProviderError, got \(error)", file: file, line: line)
        }
        return nil
    }

    private func assertQuotaExceeded(
        _ error: AIProviderError?,
        mentioning expected: String,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let error else { return }
        guard case .quotaExceeded(let detail) = error else {
            return XCTFail("Expected quotaExceeded, got \(error) (\(context))", file: file, line: line)
        }
        XCTAssertTrue(detail.contains(expected), "\(detail) (\(context))", file: file, line: line)
    }

    private func assertRateLimited(
        _ error: AIProviderError?,
        retryAfter expected: TimeInterval?,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let error else { return }
        guard case .rateLimited(let retryAfter) = error else {
            return XCTFail("Expected rateLimited, got \(error) (\(context))", file: file, line: line)
        }
        XCTAssertEqual(retryAfter, expected, context, file: file, line: line)
    }

    private func jsonResponse(
        _ body: [String: Any],
        statusCode: Int,
        headers: [String: String]
    ) throws -> MockHTTPClient.MockResponse {
        let data = try JSONSerialization.data(withJSONObject: body)
        return MockHTTPClient.MockResponse(
            data: data,
            statusCode: statusCode,
            headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current }
        )
    }

    private func openAIErrorBody(type: String, code: String, message: String) -> [String: Any] {
        ["error": ["message": message, "type": type, "param": NSNull(), "code": code]]
    }

    // MARK: - OpenAI

    /// The reporter's test from issue 35, verbatim.
    func testOpenAI429WithInsufficientQuotaTypeThrowsQuotaExceeded() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json([
            "error": [
                "message": "You have no credits remaining. Add credits to continue using the API.",
                "type": "insufficient_quota",
                "param": NSNull(),
                "code": "credit_balance_exhausted",
            ],
        ], statusCode: 429))
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5.1", httpClient: mockClient)

        do {
            _ = try await provider.sendMessage(messages: [.user("hello")], systemPrompt: "test", tools: [])
            XCTFail("Expected quotaExceeded")
        } catch let error as AIProviderError {
            guard case .quotaExceeded(let detail) = error else {
                return XCTFail("Expected quotaExceeded, got \(error)")
            }
            XCTAssertTrue(detail.contains("no credits remaining"), detail)
        }
    }

    func testOpenAIStructuredResult429WithInsufficientQuotaTypeThrowsQuotaExceeded() async throws {
        let mockClient = MockHTTPClient()
        let message = "You have no credits remaining. Add credits to continue using the API."
        await mockClient.setDefault(response: .json(
            openAIErrorBody(type: "insufficient_quota", code: "credit_balance_exhausted", message: message),
            statusCode: 429
        ))
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5.1", httpClient: mockClient)

        let error = await thrownProviderError {
            _ = try await provider.requestStructuredResult(.quotaProbe())
        }
        assertQuotaExceeded(error, mentioning: "no credits remaining", "requestStructuredResult")
    }

    func testOpenAI429QuotaCodesThrowQuotaExceededOnBothRequestPaths() async throws {
        let cases: [(type: String, code: String)] = [
            ("rate_limit_error", "credit_balance_exhausted"),
            ("rate_limit_error", "organization_spend_limit_exceeded"),
            ("rate_limit_error", "project_spend_limit_exceeded"),
            ("rate_limit_error", "organization_usage_limit_exceeded"),
            ("insufficient_quota", "a_code_added_after_this_release"),
        ]
        for entry in cases {
            let message = "Account refused: \(entry.code)"
            let mockClient = MockHTTPClient()
            await mockClient.setDefault(response: .json(
                openAIErrorBody(type: entry.type, code: entry.code, message: message),
                statusCode: 429
            ))
            let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5.1", httpClient: mockClient)

            let chatError = await thrownProviderError {
                _ = try await provider.sendMessage(messages: [.user("hello")], systemPrompt: "test", tools: [])
            }
            let structuredError = await thrownProviderError {
                _ = try await provider.requestStructuredResult(.quotaProbe())
            }
            assertQuotaExceeded(chatError, mentioning: message, "sendMessage \(entry)")
            assertQuotaExceeded(structuredError, mentioning: message, "requestStructuredResult \(entry)")
        }
    }

    func testOpenAI429WithRateLimitCodeStaysRateLimited() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: try jsonResponse(
            openAIErrorBody(
                type: "requests",
                code: "rate_limit_exceeded",
                message: "Rate limit reached for gpt-5.1 on requests per min. Please try again in 7s."
            ),
            statusCode: 429,
            headers: ["Retry-After": "7"]
        ))
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5.1", httpClient: mockClient)

        let chatError = await thrownProviderError {
            _ = try await provider.sendMessage(messages: [.user("hello")], systemPrompt: "test", tools: [])
        }
        let structuredError = await thrownProviderError {
            _ = try await provider.requestStructuredResult(.quotaProbe())
        }
        assertRateLimited(chatError, retryAfter: 7, "sendMessage")
        assertRateLimited(structuredError, retryAfter: 7, "requestStructuredResult")
    }

    func testOpenAI429WithSlowDownCodeStaysRateLimited() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json(
            openAIErrorBody(type: "rate_limit_error", code: "slow_down", message: "Slow down."),
            statusCode: 429
        ))
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5.1", httpClient: mockClient)

        let chatError = await thrownProviderError {
            _ = try await provider.sendMessage(messages: [.user("hello")], systemPrompt: "test", tools: [])
        }
        let structuredError = await thrownProviderError {
            _ = try await provider.requestStructuredResult(.quotaProbe())
        }
        assertRateLimited(chatError, retryAfter: nil, "sendMessage")
        assertRateLimited(structuredError, retryAfter: nil, "requestStructuredResult")
    }

    func testOpenAINoCreditsReadsAsQuotaNotRateLimit() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json(
            openAIErrorBody(
                type: "insufficient_quota",
                code: "credit_balance_exhausted",
                message: "You have no credits remaining. Add credits to continue using the API at https://platform.openai.com/settings/organization/billing/."
            ),
            statusCode: 429
        ))
        let provider = OpenAIProvider(apiKey: "test-key", modelId: "gpt-5.1", httpClient: mockClient)

        let error = await thrownProviderError {
            _ = try await provider.sendMessage(messages: [.user("hello")], systemPrompt: "test", tools: [])
        }
        let words = error?.errorDescription ?? ""
        XCTAssertTrue(words.contains("no credits remaining"), words)
        XCTAssertTrue(words.contains("billing"), words)
        XCTAssertFalse(words.localizedCaseInsensitiveContains("rate limited"), words)
    }

    // MARK: - Anthropic

    /// Shared by the Anthropic and Gemini tests.
    private func assertHTTPError(
        _ error: AIProviderError?,
        status expectedStatus: Int,
        message expected: String,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let error else { return }
        guard case .httpError(let statusCode, let detail) = error else {
            return XCTFail("Expected httpError, got \(error) (\(context))", file: file, line: line)
        }
        XCTAssertEqual(statusCode, expectedStatus, context, file: file, line: line)
        XCTAssertEqual(detail, expected, context, file: file, line: line)
    }

    private func anthropicProvider(_ mockClient: MockHTTPClient) -> AnthropicProvider {
        AnthropicProvider(apiKey: "test-key", modelId: "claude-sonnet-4-5-20250929", httpClient: mockClient)
    }

    func testAnthropic429WithEnforcedSpendLimitThrowsQuotaExceeded() async throws {
        let mockClient = MockHTTPClient()
        let message = "You have reached your API usage limits: the monthly spend cap for this tier is used up."
        await mockClient.setDefault(response: .json([
            "type": "error",
            "error": [
                "type": "rate_limit_error",
                "message": message,
                "details": ["error_code": "enforced_spend_limit_reached"],
            ],
            "request_id": "req_quota_test",
        ], statusCode: 429))
        let provider = anthropicProvider(mockClient)

        let chatError = await thrownProviderError {
            _ = try await provider.sendMessage(messages: [.user("hello")], systemPrompt: "test", tools: [])
        }
        let structuredError = await thrownProviderError {
            _ = try await provider.requestStructuredResult(.quotaProbe())
        }
        assertQuotaExceeded(chatError, mentioning: message, "sendMessage")
        assertQuotaExceeded(structuredError, mentioning: message, "requestStructuredResult")
    }

    func testAnthropic429WithRetryAfterStaysRateLimited() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: try jsonResponse(
            [
                "type": "error",
                "error": [
                    "type": "rate_limit_error",
                    "message": "Number of request tokens has exceeded your per-minute rate limit.",
                ],
                "request_id": "req_rate_test",
            ],
            statusCode: 429,
            headers: ["retry-after": "12"]
        ))
        let provider = anthropicProvider(mockClient)

        let chatError = await thrownProviderError {
            _ = try await provider.sendMessage(messages: [.user("hello")], systemPrompt: "test", tools: [])
        }
        let structuredError = await thrownProviderError {
            _ = try await provider.requestStructuredResult(.quotaProbe())
        }
        assertRateLimited(chatError, retryAfter: 12, "sendMessage")
        assertRateLimited(structuredError, retryAfter: 12, "requestStructuredResult")
    }

    func testAnthropic429WithOtherDetailCodeStaysRateLimited() async throws {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json([
            "type": "error",
            "error": [
                "type": "rate_limit_error",
                "message": "This request would exceed the rate limit for your organization.",
                "details": ["error_code": "some_other_limit"],
            ],
            "request_id": "req_rate_test",
        ], statusCode: 429))
        let provider = anthropicProvider(mockClient)

        let error = await thrownProviderError {
            _ = try await provider.sendMessage(messages: [.user("hello")], systemPrompt: "test", tools: [])
        }
        assertRateLimited(error, retryAfter: nil, "sendMessage")
    }

    /// A pin of words. The 400 for a limit the person set has no "context" or "token" in its
    /// message, so the provider's message must reach the person and not `contextTooLong`.
    func testAnthropic400SpecifiedUsageLimitKeepsProviderMessage() async throws {
        let mockClient = MockHTTPClient()
        let message = "You have reached your specified API usage limits. You will regain access on 2026-12-01 at 00:00 UTC."
        await mockClient.setDefault(response: .json([
            "type": "error",
            "error": ["type": "invalid_request_error", "message": message],
            "request_id": "req_limit_test",
        ], statusCode: 400))
        let provider = anthropicProvider(mockClient)

        let chatError = await thrownProviderError {
            _ = try await provider.sendMessage(messages: [.user("hello")], systemPrompt: "test", tools: [])
        }
        let structuredError = await thrownProviderError {
            _ = try await provider.requestStructuredResult(.quotaProbe())
        }
        assertHTTPError(chatError, status: 400, message: message, "sendMessage")
        assertHTTPError(structuredError, status: 400, message: message, "requestStructuredResult")
    }

    // MARK: - Gemini

    private func geminiError(
        statusCode: Int,
        body: [String: Any]
    ) async -> AIProviderError? {
        let mockClient = MockHTTPClient()
        await mockClient.setDefault(response: .json(body, statusCode: statusCode))
        let provider = GeminiProvider(apiKey: "test-key", httpClient: mockClient)
        return await thrownProviderError {
            _ = try await provider.sendMessage(messages: [.user("hello")], systemPrompt: "test", tools: [])
        }
    }

    func testGemini429WithQuotaExceededCodeThrowsQuotaExceeded() async throws {
        let message = "You exceeded your daily quota for this model. Wait for the quota to reset or upgrade the plan."
        let error = await geminiError(
            statusCode: 429,
            body: ["error": ["code": "quota_exceeded", "message": message]]
        )
        assertQuotaExceeded(error, mentioning: message, "quota_exceeded")
    }

    func testGemini429WithPerMinuteAndBurstCodesStaysRateLimited() async throws {
        for code in ["rate_limit_exceeded", "too_many_requests"] {
            let error = await geminiError(
                statusCode: 429,
                body: ["error": ["code": code, "message": "Too many requests, slow down."]]
            )
            assertRateLimited(error, retryAfter: nil, code)
        }
    }

    /// Older Gemini replies carry a numeric `code` and a string `status`. They keep today's
    /// behaviour, which is a rate limit.
    func testGemini429WithNumericCodeKeepsRateLimited() async throws {
        let error = await geminiError(
            statusCode: 429,
            body: ["error": [
                "code": 429,
                "message": "Resource has been exhausted (e.g. check quota).",
                "status": "RESOURCE_EXHAUSTED",
            ]]
        )
        assertRateLimited(error, retryAfter: nil, "numeric code")
    }

    func testGemini403ThrowsHTTPErrorWithProviderMessage() async throws {
        let message = "Your project does not have access to this model. Check the API key permissions and billing status."
        let error = await geminiError(
            statusCode: 403,
            body: ["error": ["code": "permission_denied", "message": message]]
        )
        assertHTTPError(error, status: 403, message: message, "403")
    }

    func testGemini401StillThrowsMissingAPIKey() async throws {
        let error = await geminiError(
            statusCode: 401,
            body: ["error": ["code": "unauthenticated", "message": "API key not valid."]]
        )
        guard let error else { return }
        guard case .missingAPIKey = error else {
            return XCTFail("Expected missingAPIKey, got \(error)")
        }
    }
}

private extension AIStructuredRequest {
    static func quotaProbe() -> AIStructuredRequest {
        AIStructuredRequest(
            systemPrompt: "Use the schema.",
            userPrompt: "Return the result.",
            schemaName: "ai_quota_probe",
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
