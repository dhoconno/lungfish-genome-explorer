import XCTest
import LungfishCore
@testable import LungfishOperations

/// Pins the words the AI Assistant shows when every configured provider fails its check before a request.
/// The check is injected, so no test reads the Keychain or contacts a provider.
@MainActor
final class AIAssistantValidationTests: XCTestCase {
    private var savedAISearchEnabled = false

    override func setUp() async throws {
        try await super.setUp()
        savedAISearchEnabled = AppSettings.shared.aiSearchEnabled
        AppSettings.shared.aiSearchEnabled = true
    }

    override func tearDown() async throws {
        AppSettings.shared.aiSearchEnabled = savedAISearchEnabled
        try await super.tearDown()
    }

    func testProcessMessageNamesQuotaWhenEveryProviderFailsValidationWithQuota() async {
        let service = makeService(providerNames: ["OpenAI"]) { _ in
            throw AIProviderError.quotaExceeded("You have no credits remaining.")
        }

        let reply = await service.sendMessage("Hello")

        XCTAssertTrue(reply.localizedCaseInsensitiveContains("quota exceeded"), reply)
        XCTAssertTrue(reply.localizedCaseInsensitiveContains("no credits remaining"), reply)
        XCTAssertFalse(reply.contains("Invalid response"), reply)
    }

    func testProcessMessageNamesQuotaWhenOnlyOneOfTwoProvidersHasNoCredits() async {
        let service = makeService(providerNames: ["Anthropic", "OpenAI"]) { provider in
            if provider.name == "OpenAI" {
                throw AIProviderError.quotaExceeded("You have no credits remaining.")
            }
            throw AIProviderError.httpError(statusCode: 401, message: "invalid x-api-key")
        }

        let reply = await service.sendMessage("Hello")

        XCTAssertTrue(reply.localizedCaseInsensitiveContains("quota exceeded"), reply)
        XCTAssertTrue(reply.localizedCaseInsensitiveContains("no credits remaining"), reply)
        XCTAssertFalse(reply.contains("Invalid response"), reply)
    }

    func testProcessMessageKeepsGenericTextWhenValidationFailsForAnotherReason() async {
        let service = makeService(providerNames: ["OpenAI"]) { _ in
            throw AIProviderError.networkError("x")
        }

        let reply = await service.sendMessage("Hello")

        XCTAssertTrue(
            reply.contains("No configured AI provider has a valid API key with available credits"),
            reply
        )
        XCTAssertFalse(reply.localizedCaseInsensitiveContains("quota"), reply)
    }

    private func makeService(
        providerNames: [String],
        validator: @escaping @MainActor @Sendable (any AIProvider) async throws -> Void
    ) -> AIAssistantService {
        AIAssistantService(
            toolRegistry: AIToolRegistry(),
            providerResolver: { providerNames.map { StubProvider(name: $0) } },
            providerValidator: validator
        )
    }
}

/// A provider that never receives a request, because its check fails first.
private struct StubProvider: AIProvider {
    let name: String
    let modelId = "stub-model"

    func sendMessage(
        messages: [AIMessage],
        systemPrompt: String,
        tools: [AIToolDefinition]
    ) async throws -> AIResponse {
        throw AIProviderError.invalidResponse("StubProvider received a request.")
    }
}
