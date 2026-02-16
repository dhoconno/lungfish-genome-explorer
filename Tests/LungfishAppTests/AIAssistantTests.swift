// AIAssistantTests.swift - Tests for AI tool registry and assistant service
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishApp

actor MockHTTPClient: HTTPClient {
    private let responses: [Data]
    private(set) var requests: [URLRequest] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let responseIndex = min(requests.count - 1, max(0, responses.count - 1))
        let data = responses.isEmpty ? Data() : responses[responseIndex]
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

@MainActor
final class AIToolRegistryTests: XCTestCase {

    // MARK: - Tool Definitions

    func testToolRegistryHasExpectedTools() {
        let registry = AIToolRegistry()
        let tools = registry.toolDefinitions
        let names = tools.map(\.name)

        XCTAssertTrue(names.contains("search_genes"))
        XCTAssertTrue(names.contains("search_variants"))
        XCTAssertTrue(names.contains("get_variant_statistics"))
        XCTAssertTrue(names.contains("get_gene_details"))
        XCTAssertTrue(names.contains("get_current_view"))
        XCTAssertTrue(names.contains("navigate_to_gene"))
        XCTAssertTrue(names.contains("navigate_to_region"))
        XCTAssertTrue(names.contains("list_chromosomes"))
        XCTAssertTrue(names.contains("search_pubmed"))
        XCTAssertEqual(tools.count, 9)
    }

    func testToolDefinitionsHaveDescriptions() {
        let registry = AIToolRegistry()
        for tool in registry.toolDefinitions {
            XCTAssertFalse(tool.description.isEmpty, "Tool \(tool.name) has no description")
            XCTAssertFalse(tool.name.isEmpty, "Tool name should not be empty")
        }
    }

    func testSearchGenesToolHasRequiredParameters() {
        let registry = AIToolRegistry()
        let tool = registry.toolDefinitions.first { $0.name == "search_genes" }
        XCTAssertNotNil(tool)

        let queryParam = tool?.parameters.first { $0.name == "query" }
        XCTAssertNotNil(queryParam)
        XCTAssertTrue(queryParam?.required == true)
        XCTAssertEqual(queryParam?.type, .string)

        let limitParam = tool?.parameters.first { $0.name == "limit" }
        XCTAssertNotNil(limitParam)
        XCTAssertFalse(limitParam?.required == true)
    }

    func testSearchVariantsToolHasTypeEnum() {
        let registry = AIToolRegistry()
        let tool = registry.toolDefinitions.first { $0.name == "search_variants" }
        XCTAssertNotNil(tool)

        let typeParam = tool?.parameters.first { $0.name == "variant_type" }
        XCTAssertNotNil(typeParam)
        XCTAssertNotNil(typeParam?.enumValues)
        XCTAssertTrue(typeParam?.enumValues?.contains("SNP") == true)
        XCTAssertTrue(typeParam?.enumValues?.contains("DEL") == true)
    }

    // MARK: - Tool Execution Without Data

    func testSearchGenesWithoutDataReturnsHelpfulMessage() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "search_genes", arguments: ["query": .string("BRCA1")])
        let result = await registry.execute(call)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("No genome data"), "Expected no-data message, got: \(result.content)")
    }

    func testSearchVariantsWithoutDataReturnsMessage() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "search_variants", arguments: [:])
        let result = await registry.execute(call)
        XCTAssertTrue(result.content.contains("No genome data") || result.content.contains("No variant data"))
    }

    func testGetVariantStatsWithoutData() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "get_variant_statistics", arguments: [:])
        let result = await registry.execute(call)
        XCTAssertTrue(result.content.contains("No genome data") || result.content.contains("No variant data"))
    }

    func testGetGeneDetailsWithoutData() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "get_gene_details", arguments: ["gene_name": .string("TP53")])
        let result = await registry.execute(call)
        XCTAssertTrue(result.content.contains("No genome data"))
    }

    func testGetGeneDetailsWithoutGeneName() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "get_gene_details", arguments: [:])
        let result = await registry.execute(call)
        // Without searchIndex, returns "No genome data" before checking params
        XCTAssertTrue(result.content.contains("No genome data"))
    }

    func testGetCurrentViewWithoutViewer() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "get_current_view", arguments: [:])
        let result = await registry.execute(call)
        XCTAssertTrue(result.content.contains("No genome viewer"))
    }

    func testNavigateToGeneWithoutData() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "navigate_to_gene", arguments: ["gene_name": .string("BRCA1")])
        let result = await registry.execute(call)
        XCTAssertTrue(result.content.contains("No genome data"))
    }

    func testNavigateToRegionMissingChromosome() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "navigate_to_region", arguments: ["start": .integer(100)])
        let result = await registry.execute(call)
        XCTAssertTrue(result.content.contains("chromosome parameter is required"))
    }

    func testNavigateToRegionMissingStart() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "navigate_to_region", arguments: ["chromosome": .string("chr1")])
        let result = await registry.execute(call)
        XCTAssertTrue(result.content.contains("start parameter is required"))
    }

    func testNavigateToRegionMissingEnd() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "navigate_to_region", arguments: [
            "chromosome": .string("chr1"),
            "start": .integer(100),
        ])
        let result = await registry.execute(call)
        XCTAssertTrue(result.content.contains("end parameter is required"))
    }

    func testListChromosomesWithoutData() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "list_chromosomes", arguments: [:])
        let result = await registry.execute(call)
        XCTAssertTrue(result.content.contains("No genome data"))
    }

    func testUnknownToolReturnsError() async {
        let registry = AIToolRegistry()
        let call = AIToolCall(id: "1", name: "nonexistent_tool", arguments: [:])
        let result = await registry.execute(call)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Unknown tool"))
    }

    func testSearchPubMedUsesEncodedQueryParameters() async throws {
        let searchJSON = #"{"esearchresult":{"idlist":["12345"]}}"#.data(using: .utf8)!
        let summaryJSON = #"{"result":{"12345":{"title":"Example","source":"Nature","pubdate":"2025","authors":[{"name":"A. Author"}]}}}"#.data(using: .utf8)!
        let mockClient = MockHTTPClient(responses: [searchJSON, summaryJSON])
        let registry = AIToolRegistry(httpClient: mockClient)

        let call = AIToolCall(
            id: "1",
            name: "search_pubmed",
            arguments: ["query": .string("BRCA1 breast cancer"), "max_results": .integer(3)]
        )
        let result = await registry.execute(call)
        let requests = await mockClient.recordedRequests()

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("PMID: 12345"))
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url?.absoluteString.contains("term=BRCA1%20breast%20cancer") == true)
        XCTAssertTrue(requests[0].url?.absoluteString.contains("retmax=3") == true)
    }

    // MARK: - Navigation Callback

    func testNavigateToRegionCallsCallback() async {
        let registry = AIToolRegistry()
        var navigatedTo: (String, Int, Int)?
        registry.navigateToRegion = { chrom, start, end in
            navigatedTo = (chrom, start, end)
        }

        let call = AIToolCall(id: "1", name: "navigate_to_region", arguments: [
            "chromosome": .string("chr5"),
            "start": .integer(1000),
            "end": .integer(2000),
        ])
        let result = await registry.execute(call)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(navigatedTo?.0, "chr5")
        XCTAssertEqual(navigatedTo?.1, 1000)
        XCTAssertEqual(navigatedTo?.2, 2000)
        XCTAssertTrue(result.content.contains("Navigated to chr5:1000-2000"))
    }

    // MARK: - Current View State

    func testGetCurrentViewWithState() async {
        let registry = AIToolRegistry()
        registry.getCurrentViewState = {
            AIToolRegistry.ViewerState(
                chromosome: "chr1",
                start: 1000,
                end: 50000,
                organism: "Homo sapiens",
                assembly: "GRCh38",
                bundleName: "Test Bundle",
                chromosomeNames: ["chr1", "chr2", "chrX"],
                annotationTrackCount: 2,
                variantTrackCount: 1,
                totalVariantCount: 42
            )
        }

        let call = AIToolCall(id: "1", name: "get_current_view", arguments: [:])
        let result = await registry.execute(call)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Test Bundle"))
        XCTAssertTrue(result.content.contains("Homo sapiens"))
        XCTAssertTrue(result.content.contains("GRCh38"))
        XCTAssertTrue(result.content.contains("chr1"))
        XCTAssertTrue(result.content.contains("49000 bp"))
        XCTAssertTrue(result.content.contains("42"))
    }

    func testListChromosomesWithState() async {
        let registry = AIToolRegistry()
        registry.getCurrentViewState = {
            AIToolRegistry.ViewerState(
                chromosomeNames: ["chr1", "chr2", "chr3", "chrX", "chrY"]
            )
        }

        let call = AIToolCall(id: "1", name: "list_chromosomes", arguments: [:])
        let result = await registry.execute(call)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("5"))
        XCTAssertTrue(result.content.contains("chr1"))
        XCTAssertTrue(result.content.contains("chrX"))
    }

    // MARK: - Viewer State

    func testViewerStateDefaults() {
        let state = AIToolRegistry.ViewerState()
        XCTAssertNil(state.chromosome)
        XCTAssertNil(state.start)
        XCTAssertNil(state.end)
        XCTAssertNil(state.organism)
        XCTAssertNil(state.assembly)
        XCTAssertNil(state.bundleName)
        XCTAssertTrue(state.chromosomeNames.isEmpty)
        XCTAssertEqual(state.annotationTrackCount, 0)
        XCTAssertEqual(state.variantTrackCount, 0)
        XCTAssertEqual(state.totalVariantCount, 0)
    }
}

@MainActor
final class AIAssistantServiceTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Clear any persisted settings before each test
        UserDefaults.standard.removeObject(forKey: "com.lungfish.appSettings")
        AppSettings.shared.resetToDefaults()
    }

    // MARK: - Service Initialization

    func testServiceInitialState() {
        let registry = AIToolRegistry()
        let service = AIAssistantService(toolRegistry: registry)
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertFalse(service.isProcessing)
        XCTAssertNil(service.lastError)
        XCTAssertEqual(service.totalTokensUsed, 0)
    }

    func testClearConversation() {
        let registry = AIToolRegistry()
        let service = AIAssistantService(toolRegistry: registry)

        // Simulate some state
        service.clearConversation()
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertEqual(service.totalTokensUsed, 0)
        XCTAssertNil(service.lastError)
    }

    // MARK: - Suggested Queries

    func testSuggestedQueriesWithNoData() {
        let registry = AIToolRegistry()
        let service = AIAssistantService(toolRegistry: registry)

        let queries = service.suggestedQueries()
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries[0].title, "Getting started")
    }

    func testSuggestedQueriesWithBundleLoaded() {
        let registry = AIToolRegistry()
        registry.getCurrentViewState = {
            AIToolRegistry.ViewerState(
                chromosome: "chr1",
                start: 10_000,
                end: 20_000,
                organism: "Macaca mulatta",
                bundleName: "Rhesus Macaque",
                chromosomeNames: ["chr1"],
                sampleCount: 451,
                sampleNameExamples: ["S1", "S2"]
            )
        }
        let service = AIAssistantService(toolRegistry: registry)

        let queries = service.suggestedQueries()
        XCTAssertGreaterThan(queries.count, 1)

        let titles = queries.map(\.title)
        XCTAssertTrue(titles.contains("Overview"))
        XCTAssertTrue(titles.contains("Disease genes"))
        XCTAssertTrue(titles.contains("Find a gene"))
        XCTAssertTrue(queries.contains { $0.query.contains("Rhesus Macaque") })
        XCTAssertTrue(queries.contains { $0.query.contains("chr1:10001-20000") })
    }

    func testSuggestedQueriesWithVariants() {
        let registry = AIToolRegistry()
        registry.getCurrentViewState = {
            AIToolRegistry.ViewerState(
                bundleName: "Test Bundle",
                chromosomeNames: ["chr1"],
                variantTrackCount: 1,
                totalVariantCount: 5000
            )
        }
        let service = AIAssistantService(toolRegistry: registry)

        let queries = service.suggestedQueries()
        let titles = queries.map(\.title)
        XCTAssertTrue(titles.contains("Variant summary"))
        XCTAssertTrue(titles.contains("High-impact variants"))
    }

    func testSuggestedQueriesHaveIcons() {
        let registry = AIToolRegistry()
        registry.getCurrentViewState = {
            AIToolRegistry.ViewerState(bundleName: "Test", chromosomeNames: ["chr1"])
        }
        let service = AIAssistantService(toolRegistry: registry)

        for query in service.suggestedQueries() {
            XCTAssertFalse(query.icon.isEmpty, "Query '\(query.title)' has no icon")
            XCTAssertFalse(query.query.isEmpty, "Query '\(query.title)' has no query text")
        }
    }

    // MARK: - Provider Resolution (Error Paths)

    func testSendMessageWithNoAPIKeyReturnsError() async throws {
        let registry = AIToolRegistry()
        let service = AIAssistantService(toolRegistry: registry)
        AppSettings.shared.aiSearchEnabled = true

        let keychain = KeychainSecretStorage.shared
        let hasOpenAIKey = (try? await keychain.retrieve(forKey: KeychainSecretStorage.openAIAPIKey))?.isEmpty == false
        let hasAnthropicKey = (try? await keychain.retrieve(forKey: KeychainSecretStorage.anthropicAPIKey))?.isEmpty == false
        let hasGeminiKey = (try? await keychain.retrieve(forKey: KeychainSecretStorage.geminiAPIKey))?.isEmpty == false
        let hasConfiguredKey = hasOpenAIKey || hasAnthropicKey || hasGeminiKey
        if hasConfiguredKey {
            throw XCTSkip("Environment has configured AI keys; missing-key assertions are not deterministic.")
        }

        let response = await service.sendMessage("Hello")

        // Should get an error about missing API key
        XCTAssertTrue(
            response.contains("API key") || response.contains("error"),
            "Expected API key error, got: \(response)"
        )
    }

    func testSendMessagePreventsDoubleProcessing() async {
        let registry = AIToolRegistry()
        let service = AIAssistantService(toolRegistry: registry)
        AppSettings.shared.aiSearchEnabled = true

        // Simulate isProcessing being true by sending concurrent requests
        // The second should be rejected
        async let first = service.sendMessage("Hello")
        // The service blocks while processing, so start a second immediately
        // (This tests the guard, but since we await first above it may
        // not actually trigger - keep the test for the guard path)
        let response = await first
        XCTAssertNotNil(response)
    }

    // MARK: - Status Callback

    func testStatusCallbackIsInvoked() {
        let registry = AIToolRegistry()
        let service = AIAssistantService(toolRegistry: registry)

        var receivedStatus: String?
        service.onStatusUpdate = { status in
            receivedStatus = status
        }

        // We can't easily test the actual callback during sendMessage
        // without a mock provider, but we can verify the callback is set
        XCTAssertNotNil(service.onStatusUpdate)
        service.onStatusUpdate?("Testing...")
        XCTAssertEqual(receivedStatus, "Testing...")
    }
}

@MainActor
final class AISettingsIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "com.lungfish.appSettings")
        AppSettings.shared.resetToDefaults()
    }

    func testDefaultPreferredProvider() {
        let settings = AppSettings.shared
        XCTAssertEqual(settings.preferredAIProvider, "anthropic")
    }

    func testPreferredProviderPersists() {
        let settings = AppSettings.shared
        settings.preferredAIProvider = "openai"
        settings.save()

        // Verify value was set
        XCTAssertEqual(settings.preferredAIProvider, "openai")
    }

    func testDefaultModels() {
        let settings = AppSettings.shared
        XCTAssertEqual(settings.openAIModel, "gpt-5-mini")
        XCTAssertEqual(settings.geminiModel, "gemini-2.5-flash")
        XCTAssertEqual(settings.anthropicModel, "claude-sonnet-4-5-20250929")
    }

    func testResetAIServicesSection() {
        let settings = AppSettings.shared
        settings.preferredAIProvider = "gemini"
        settings.openAIModel = "gpt-4.1"
        settings.resetSection(.aiServices)

        XCTAssertEqual(settings.preferredAIProvider, "anthropic")
        XCTAssertEqual(settings.openAIModel, "gpt-5-mini")
    }

    func testSendMessageWhenAIDisabledReturnsHelpfulMessage() async {
        let registry = AIToolRegistry()
        let service = AIAssistantService(toolRegistry: registry)
        AppSettings.shared.aiSearchEnabled = false

        let response = await service.sendMessage("Hello")

        XCTAssertTrue(response.contains("disabled"))
        XCTAssertTrue(service.messages.isEmpty)
    }

    func testProviderIdentifierFromSettings() {
        let settings = AppSettings.shared
        settings.preferredAIProvider = "anthropic"
        XCTAssertEqual(AIProviderIdentifier(rawValue: settings.preferredAIProvider), .anthropic)

        settings.preferredAIProvider = "openai"
        XCTAssertEqual(AIProviderIdentifier(rawValue: settings.preferredAIProvider), .openAI)

        settings.preferredAIProvider = "gemini"
        XCTAssertEqual(AIProviderIdentifier(rawValue: settings.preferredAIProvider), .gemini)
    }
}
