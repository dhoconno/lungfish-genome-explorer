// AIAssistantService.swift - Orchestrates AI conversations with tool execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os

private let logger = Logger(subsystem: "com.lungfish", category: "AIAssistantService")

/// Orchestrates AI conversations by managing the message loop between
/// the user, the LLM provider, and local tool execution.
///
/// The service handles:
/// 1. Building context-aware system prompts
/// 2. Sending messages to the configured AI provider
/// 3. Executing tool calls and returning results
/// 4. Managing conversation history
/// 5. Provider selection and fallback
@MainActor
public final class AIAssistantService {

    /// The tool registry for executing tool calls.
    public let toolRegistry: AIToolRegistry

    /// Current conversation messages.
    public private(set) var messages: [AIMessage] = []

    /// Whether a request is currently in progress.
    public private(set) var isProcessing = false

    /// The last error that occurred.
    public private(set) var lastError: String?

    /// Total tokens used in this conversation.
    public private(set) var totalTokensUsed: Int = 0

    /// Status update callback for UI feedback during tool execution.
    public var onStatusUpdate: ((String) -> Void)?

    /// Maximum tool execution rounds per user message (prevents infinite loops).
    private let maxToolRounds = 8
    private let providerValidationTTL: TimeInterval = 300
    private var providerValidationCache: [String: Date] = [:]

    public init(toolRegistry: AIToolRegistry) {
        self.toolRegistry = toolRegistry
    }

    // MARK: - Conversation Management

    /// Sends a user message and processes the response, including any tool calls.
    ///
    /// - Parameter text: The user's message
    /// - Returns: The final assistant response text
    @discardableResult
    public func sendMessage(_ text: String) async -> String {
        let requestID = String(UUID().uuidString.prefix(8))
        logger.info("AI[\(requestID, privacy: .public)] Received message chars=\(text.count)")
        guard AppSettings.shared.aiSearchEnabled else {
            logger.warning("AI[\(requestID, privacy: .public)] Blocked: AI services disabled")
            return "AI Assistant is disabled. Enable it in Settings > AI Services."
        }
        guard !isProcessing else {
            logger.info("AI[\(requestID, privacy: .public)] Blocked: already processing")
            return "Please wait for the current request to complete."
        }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        // Add user message
        messages.append(.user(text))

        do {
            let providers = try await resolveProviders()
            let systemPrompt = buildSystemPrompt()
            let tools = toolRegistry.toolDefinitions
            let providerSummary = providers.map { "\($0.name)(\($0.modelId))" }.joined(separator: ", ")
            logger.info("AI[\(requestID, privacy: .public)] Using providers: \(providerSummary, privacy: .public)")
            logger.debug("AI[\(requestID, privacy: .public)] Prompt preview: \(self.preview(systemPrompt), privacy: .public)")

            // Conversation loop: send message, execute tools, repeat until done
            var rounds = 0
            var consecutiveAllToolFailureRounds = 0
            while rounds < maxToolRounds {
                rounds += 1
                logger.info("AI[\(requestID, privacy: .public)] Round \(rounds)/\(self.maxToolRounds) start (messages=\(self.messages.count))")

                let response = try await sendWithFallback(
                    providers: providers,
                    messages: messages,
                    systemPrompt: systemPrompt,
                    tools: tools
                )
                logger.info(
                    "AI[\(requestID, privacy: .public)] Round \(rounds) model response stop=\(self.describeStopReason(response.stopReason), privacy: .public) textChars=\(response.text.count) toolCalls=\(response.toolCalls.count)"
                )

                if let usage = response.usage {
                    totalTokensUsed += usage.inputTokens + usage.outputTokens
                    logger.debug(
                        "AI[\(requestID, privacy: .public)] Round \(rounds) usage input=\(usage.inputTokens) output=\(usage.outputTokens) total=\(self.totalTokensUsed)"
                    )
                }

                // Add assistant response to history
                messages.append(.assistant(response.text, toolCalls: response.toolCalls))

                // If no tool calls, we're done
                if response.toolCalls.isEmpty {
                    return response.text
                }

                // Execute tool calls
                logger.info("Executing \(response.toolCalls.count) tool call(s)")
                var toolResults: [AIToolResult] = []
                for toolCall in response.toolCalls {
                    let toolLabel = toolDisplayName(toolCall.name)
                    onStatusUpdate?(toolLabel)
                    logger.info(
                        "AI[\(requestID, privacy: .public)] Round \(rounds) tool call \(toolCall.name, privacy: .public) id=\(toolCall.id, privacy: .public)"
                    )
                    let result = await toolRegistry.execute(toolCall)
                    logger.info(
                        "AI[\(requestID, privacy: .public)] Round \(rounds) tool result \(toolCall.name, privacy: .public) error=\(result.isError) chars=\(result.content.count)"
                    )
                    if result.isError {
                        logger.error(
                            "AI[\(requestID, privacy: .public)] Round \(rounds) tool error detail: \(self.preview(result.content), privacy: .public)"
                        )
                    }
                    toolResults.append(result)
                }

                let failedToolResults = toolResults.filter(\.isError)
                if failedToolResults.count == toolResults.count {
                    consecutiveAllToolFailureRounds += 1
                    if consecutiveAllToolFailureRounds >= 2 {
                        let summary = makeToolFailureSummary(from: failedToolResults)
                        lastError = summary
                        logger.error("AI[\(requestID, privacy: .public)] Stopping due to repeated tool failures: \(summary, privacy: .public)")
                        return summary
                    }
                } else {
                    consecutiveAllToolFailureRounds = 0
                }

                // Add tool results as a message
                let toolMessage = AIMessage(
                    role: .tool,
                    content: "",
                    toolResults: toolResults
                )
                messages.append(toolMessage)

                // Continue the loop - the model will process tool results
            }

            logger.warning("Maximum tool rounds (\(self.maxToolRounds)) reached")
            if let summary = makeRecentToolFailureSummary() {
                lastError = summary
                logger.error("AI[\(requestID, privacy: .public)] Max rounds reached with tool errors: \(summary, privacy: .public)")
                return summary
            }
            logger.warning("AI[\(requestID, privacy: .public)] Max rounds reached without terminal response")
            return messages.last { $0.role == .assistant }?.content ?? "I've been working on your request but reached the maximum number of analysis steps. Here's what I found so far."

        } catch let error as AIProviderError {
            lastError = error.localizedDescription
            logger.error("AI[\(requestID, privacy: .public)] Provider error: \(error.localizedDescription, privacy: .public)")
            // Remove the user message if we failed
            if messages.last?.role == .user {
                messages.removeLast()
            }
            return error.localizedDescription
        } catch {
            lastError = error.localizedDescription
            logger.error("AI[\(requestID, privacy: .public)] Unexpected error: \(error.localizedDescription, privacy: .public)")
            if messages.last?.role == .user {
                messages.removeLast()
            }
            return "An unexpected error occurred: \(error.localizedDescription)"
        }
    }

    /// Clears the conversation history.
    public func clearConversation() {
        messages.removeAll()
        totalTokensUsed = 0
        lastError = nil
    }

    // MARK: - Provider Resolution

    /// Resolves which AI provider to use based on settings and available API keys.
    private func resolveProviders() async throws -> [any AIProvider] {
        let settings = AppSettings.shared
        let keychain = KeychainSecretStorage.shared

        let preferred = AIProviderIdentifier(rawValue: settings.preferredAIProvider) ?? .anthropic
        let fallbackOrder: [AIProviderIdentifier] = [preferred] + [.anthropic, .openAI, .gemini].filter { $0 != preferred }
        var providers: [any AIProvider] = []
        for providerId in fallbackOrder {
            if let provider = try await makeProvider(providerId, settings: settings, keychain: keychain) {
                logger.debug("Resolved provider \(providerId.displayName, privacy: .public) with model \(provider.modelId, privacy: .public)")
                providers.append(provider)
            }
        }
        guard !providers.isEmpty else {
            throw AIProviderError.missingAPIKey
        }
        let validated = try await filterValidProviders(providers)
        guard !validated.isEmpty else {
            throw AIProviderError.invalidResponse("No configured AI provider has a valid API key with available credits.")
        }
        return validated
    }

    private func makeProvider(
        _ providerId: AIProviderIdentifier,
        settings: AppSettings,
        keychain: KeychainSecretStorage
    ) async throws -> (any AIProvider)? {
        let keychainKey: String
        switch providerId {
        case .anthropic: keychainKey = KeychainSecretStorage.anthropicAPIKey
        case .openAI: keychainKey = KeychainSecretStorage.openAIAPIKey
        case .gemini: keychainKey = KeychainSecretStorage.geminiAPIKey
        }

        guard let apiKey = try await keychain.retrieve(forKey: keychainKey), !apiKey.isEmpty else {
            return nil
        }

        switch providerId {
        case .anthropic:
            return AnthropicProvider(apiKey: apiKey, modelId: settings.anthropicModel)
        case .openAI:
            return OpenAIProvider(apiKey: apiKey, modelId: settings.openAIModel)
        case .gemini:
            return GeminiProvider(apiKey: apiKey, modelId: settings.geminiModel)
        }
    }

    private func sendWithFallback(
        providers: [any AIProvider],
        messages: [AIMessage],
        systemPrompt: String,
        tools: [AIToolDefinition]
    ) async throws -> AIResponse {
        var firstError: AIProviderError?
        var lastError: AIProviderError?

        for (idx, provider) in providers.enumerated() {
            do {
                logger.info("Attempting provider \(provider.name, privacy: .public) model=\(provider.modelId, privacy: .public)")
                return try await provider.sendMessage(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    tools: tools
                )
            } catch let providerError as AIProviderError {
                if firstError == nil { firstError = providerError }
                lastError = providerError
                guard shouldFallback(for: providerError), idx + 1 < providers.count else {
                    throw providerError
                }
                logger.warning("Provider \(provider.name, privacy: .public) failed (\(providerError.localizedDescription, privacy: .public)); trying fallback")
            }
        }

        throw lastError ?? firstError ?? AIProviderError.networkError("No provider response")
    }

    private func filterValidProviders(_ providers: [any AIProvider]) async throws -> [any AIProvider] {
        var valid: [any AIProvider] = []
        for provider in providers {
            if try await isProviderValidated(provider) {
                valid.append(provider)
            }
        }
        return valid
    }

    private func isProviderValidated(_ provider: any AIProvider) async throws -> Bool {
        let cacheKey = "\(provider.name)|\(provider.modelId)"
        if let lastValidatedAt = providerValidationCache[cacheKey],
           Date().timeIntervalSince(lastValidatedAt) < providerValidationTTL {
            logger.debug("Provider validation cache hit for \(provider.name, privacy: .public) model=\(provider.modelId, privacy: .public)")
            return true
        }

        do {
            logger.debug("Validating provider \(provider.name, privacy: .public) model=\(provider.modelId, privacy: .public)")
            try await provider.validateCredentials()
            providerValidationCache[cacheKey] = Date()
            return true
        } catch let providerError as AIProviderError {
            logger.warning("Provider validation failed for \(provider.name, privacy: .public): \(providerError.localizedDescription, privacy: .public)")
            return false
        } catch {
            logger.warning("Provider validation failed for \(provider.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func shouldFallback(for error: AIProviderError) -> Bool {
        switch error {
        case .rateLimited, .networkError, .modelNotAvailable:
            return true
        case .httpError(let statusCode, _):
            return statusCode >= 500
        case .missingAPIKey, .invalidResponse, .contextTooLong, .decodingError:
            return false
        }
    }

    private func makeToolFailureSummary(from failures: [AIToolResult]) -> String {
        let messages = Set(failures.map { $0.content.replacingOccurrences(of: "Error: ", with: "") })
        let joined = messages.prefix(3).joined(separator: " | ")
        return "The requested tools failed repeatedly: \(joined). Please check your network/proxy settings or try a non-PubMed query."
    }

    private func makeRecentToolFailureSummary() -> String? {
        let recentToolResults = messages.reversed().first(where: { $0.role == .tool })?.toolResults ?? []
        let failures = recentToolResults.filter(\.isError)
        guard !failures.isEmpty else { return nil }
        return makeToolFailureSummary(from: failures)
    }

    // MARK: - System Prompt

    /// Builds a context-aware system prompt based on the current app state.
    private func buildSystemPrompt() -> String {
        let viewerState = toolRegistry.getCurrentViewState?() ?? AIToolRegistry.ViewerState()

        var contextLines: [String] = []

        if let organism = viewerState.organism {
            contextLines.append("Organism: \(organism)")
        }
        if let assembly = viewerState.assembly {
            contextLines.append("Assembly: \(assembly)")
        }
        if let bundle = viewerState.bundleName {
            contextLines.append("Loaded bundle: \(bundle)")
        }
        contextLines.append("Chromosomes available: \(viewerState.chromosomeNames.count)")
        contextLines.append("Annotation tracks: \(viewerState.annotationTrackCount)")
        contextLines.append("Variant tracks: \(viewerState.variantTrackCount)")
        if viewerState.totalVariantCount > 0 {
            contextLines.append("Total variants: \(viewerState.totalVariantCount)")
        }
        if let chrom = viewerState.chromosome {
            contextLines.append("Currently viewing: \(chrom)")
            if let start = viewerState.start, let end = viewerState.end {
                contextLines.append("Visible region: \(chrom):\(start)-\(end)")
            }
        }
        if viewerState.sampleCount > 0 {
            contextLines.append("Samples: \(viewerState.sampleCount)")
            if !viewerState.sampleNameExamples.isEmpty {
                contextLines.append("Sample examples: \(viewerState.sampleNameExamples.joined(separator: ", "))")
            }
        }

        let dataContext = contextLines.isEmpty
            ? "No genome data is currently loaded."
            : contextLines.joined(separator: "\n")

        return """
        You are a genomics research assistant built into the Lungfish genome browser application. \
        Your role is to help researchers explore and understand genomic data, especially those who \
        may not have extensive experience with genome browsers or bioinformatics.

        ## Your Capabilities
        You have access to tools that can:
        - Search for genes and annotations in the loaded genome data
        - Search for genetic variants (SNPs, insertions, deletions) from VCF files
        - Get variant statistics and gene details
        - Navigate the genome browser to specific genes or regions
        - Search PubMed for relevant scientific literature

        ## Currently Loaded Data
        \(dataContext)

        ## Guidelines
        1. **Be approachable**: Explain genomics concepts in clear, accessible language. \
        Avoid jargon when possible, and define technical terms when you must use them.

        2. **Use your tools**: When a user asks about genes, variants, or genomic regions, \
        use the available tools to search the loaded data. Don't just rely on general knowledge — \
        check what's actually in their data.

        3. **Be proactive with context**: When discussing a gene or variant, use PubMed to find \
        relevant literature that helps the user understand the biological significance.

        4. **Navigate for the user**: When you find something interesting, offer to navigate \
        the browser to that location so the user can see it visually.

        5. **Connect the dots**: Help users see relationships between their data and published \
        research. For example, if they ask about a disease, search for known associated genes, \
        then check if those genes have variants in their loaded data.

        6. **Be honest about limitations**: If a question requires data that isn't loaded, \
        or if you're uncertain about a genomics fact, say so clearly.

        7. **Format responses clearly**: Use markdown formatting for readability. Use bullet \
        points for gene lists, bold for important terms, and organize long responses with headers.

        8. **Reference positions correctly**: Genomic positions in the data are 0-based. \
        When displaying positions to users, add 1 to convert to 1-based coordinates (the standard \
        convention in genomics).
        """
    }

    // MARK: - Suggested Queries

    /// Returns context-aware suggested queries based on the current data state.
    public func suggestedQueries() -> [SuggestedQuery] {
        let state = toolRegistry.getCurrentViewState?() ?? AIToolRegistry.ViewerState()

        var queries: [SuggestedQuery] = []

        if state.bundleName == nil {
            queries.append(SuggestedQuery(
                title: "Getting started",
                query: "I have no bundle loaded. Give me exact step-by-step instructions to load FASTA + GFF3 + VCF in Lungfish, including menu items to click.",
                icon: "questionmark.circle"
            ))
            return queries
        }

        let bundleName = state.bundleName ?? "loaded bundle"
        let organism = state.organism ?? "loaded organism"
        let assembly = state.assembly ?? "unknown assembly"
        let chromosome = state.chromosome ?? state.chromosomeNames.first ?? "the current chromosome"
        let regionDescription: String
        if let start = state.start, let end = state.end {
            regionDescription = "\(chromosome):\(start + 1)-\(end)"
        } else {
            regionDescription = chromosome
        }
        let sampleContext: String = state.sampleCount > 0
            ? "There are \(state.sampleCount) samples\(state.sampleNameExamples.isEmpty ? "" : " (e.g., \(state.sampleNameExamples.joined(separator: ", ")))")."
            : "No sample metadata is available."

        // Basic exploration
        queries.append(SuggestedQuery(
            title: "Overview",
            query: "For bundle '\(bundleName)' (\(organism), \(assembly)), summarize exactly what is loaded: chromosome count, annotation tracks, variant tracks, and what I should query next.",
            icon: "doc.text.magnifyingglass"
        ))

        if state.totalVariantCount > 0 {
            queries.append(SuggestedQuery(
                title: "Variant summary",
                query: "Using the \(state.totalVariantCount) loaded variants, report variant type counts and which chromosomes have the highest variant density. \(sampleContext)",
                icon: "chart.bar"
            ))

            queries.append(SuggestedQuery(
                title: "High-impact variants",
                query: "Find the highest-impact variants and return the top 10 genes with chromosome position, REF>ALT, and consequence details. Prioritize hits in the current view around \(regionDescription).",
                icon: "exclamationmark.triangle"
            ))
        }

        queries.append(SuggestedQuery(
            title: "Disease genes",
            query: "List 5 well-studied disease genes for \(organism), check whether each appears in '\(bundleName)', and if present summarize nearby variants.",
            icon: "stethoscope"
        ))

        // Gene exploration
        queries.append(SuggestedQuery(
            title: "Find a gene",
            query: "In \(regionDescription), find immune-related or receptor/signaling genes and navigate to the most biologically interesting hit.",
            icon: "magnifyingglass"
        ))

        queries.append(SuggestedQuery(
            title: "PubMed context",
            query: "Search PubMed for recent papers linking high-impact variants in \(organism) to neurological or immune phenotypes, then connect findings to variants in '\(bundleName)'.",
            icon: "book"
        ))

        return queries
    }

    /// Contextual welcome text shown when opening the AI assistant panel.
    public func welcomeMessage() -> String {
        let state = toolRegistry.getCurrentViewState?() ?? AIToolRegistry.ViewerState()
        let questions = suggestedQueries().map(\.query).prefix(4)

        if state.bundleName == nil {
            return """
            Welcome. No genome bundle is currently loaded.

            Start with a concrete prompt like:
            \(questions.map { "- \"\($0)\"" }.joined(separator: "\n"))

            Configure API keys in **Settings > AI Services** before running AI searches.
            """
        }

        let bundle = state.bundleName ?? "loaded bundle"
        let organism = state.organism ?? "loaded organism"
        let chromosome = state.chromosome ?? state.chromosomeNames.first ?? "current chromosome"
        let regionText: String
        if let start = state.start, let end = state.end {
            regionText = "\(chromosome):\(start + 1)-\(end)"
        } else {
            regionText = chromosome
        }

        return """
        Welcome. You are currently exploring **\(bundle)** (\(organism)).
        Current focus: **\(regionText)**.

        Try one of these concrete prompts:
        \(questions.map { "- \"\($0)\"" }.joined(separator: "\n"))
        """
    }

    // MARK: - Helpers

    /// Human-readable label for a tool name, shown during execution.
    private func toolDisplayName(_ name: String) -> String {
        switch name {
        case "search_genes": return "Searching genes..."
        case "search_variants": return "Searching variants..."
        case "get_variant_statistics": return "Getting variant stats..."
        case "get_gene_details": return "Looking up gene details..."
        case "get_current_view": return "Reading viewer state..."
        case "navigate_to_gene": return "Navigating to gene..."
        case "navigate_to_region": return "Navigating to region..."
        case "list_chromosomes": return "Listing chromosomes..."
        case "search_pubmed": return "Searching PubMed..."
        default: return "Running \(name)..."
        }
    }

    private func describeStopReason(_ reason: AIResponse.StopReason) -> String {
        switch reason {
        case .endTurn: return "end_turn"
        case .toolUse: return "tool_use"
        case .maxTokens: return "max_tokens"
        case .error(let message): return "error:\(message)"
        }
    }

    private func preview(_ text: String, limit: Int = 220) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= limit { return singleLine }
        return String(singleLine.prefix(limit)) + "..."
    }
}

/// A suggested query shown in the AI assistant panel.
public struct SuggestedQuery: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let query: String
    public let icon: String
}
