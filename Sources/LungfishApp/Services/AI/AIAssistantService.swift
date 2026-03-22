// AIAssistantService.swift - Orchestrates AI conversations with tool execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os

private let logger = Logger(subsystem: LogSubsystem.app, category: "AIAssistantService")

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
    private let providerRequestTimeout: TimeInterval = 150
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
            let systemPrompt = buildSystemPrompt(for: text)
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
                    let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return response.text
                    }
                    let fallback = makeEmptyAssistantResponseSummary()
                    lastError = fallback
                    logger.error("AI[\(requestID, privacy: .public)] Model returned empty terminal response")
                    return fallback
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
            if let lastNonEmptyAssistantResponse = messages.reversed().first(where: {
                $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?.content {
                logger.warning("AI[\(requestID, privacy: .public)] Max rounds reached; returning latest non-empty assistant response")
                return lastNonEmptyAssistantResponse
            }
            logger.warning("AI[\(requestID, privacy: .public)] Max rounds reached without terminal response")
            let fallback = "I reached the maximum analysis steps without a final text response. Please try again with a narrower query, fewer requested actions, or a different AI provider."
            lastError = fallback
            return fallback

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
                return try await withProviderTimeout(seconds: providerRequestTimeout) {
                    try await provider.sendMessage(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools
                    )
                }
            } catch {
                let providerError = normalizeProviderError(error)
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

    private func normalizeProviderError(_ error: Error) -> AIProviderError {
        if let providerError = error as? AIProviderError {
            return providerError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .networkError("AI request timed out.")
            case .notConnectedToInternet:
                return .networkError("No internet connection.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .networkError("Unable to reach AI provider host (\(urlError.code.rawValue)).")
            case .networkConnectionLost:
                return .networkError("Network connection was lost.")
            default:
                return .networkError("Network error (\(urlError.code.rawValue)): \(urlError.localizedDescription)")
            }
        }
        return .networkError(error.localizedDescription)
    }

    private func withProviderTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let nanos = UInt64(max(1, Int(seconds * 1_000_000_000)))
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                throw AIProviderError.networkError("AI request timed out after \(Int(seconds)) seconds.")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func makeToolFailureSummary(from failures: [AIToolResult]) -> String {
        let messages = Set(failures.map { $0.content.replacingOccurrences(of: "Error: ", with: "") })
        let joined = messages.prefix(3).joined(separator: " | ")
        return "The requested tools failed repeatedly: \(joined). Please check your network/proxy settings or try a non-PubMed query."
    }

    private func makeEmptyAssistantResponseSummary() -> String {
        if let toolSummary = makeRecentToolFailureSummary() {
            return toolSummary
        }
        return "The AI model did not return a final text response. Please retry with a narrower query or switch AI providers in Settings > AI Services."
    }

    private func makeRecentToolFailureSummary() -> String? {
        let recentToolResults = messages.reversed().first(where: { $0.role == .tool })?.toolResults ?? []
        let failures = recentToolResults.filter(\.isError)
        guard !failures.isEmpty else { return nil }
        return makeToolFailureSummary(from: failures)
    }

    // MARK: - System Prompt

    /// Builds a context-aware system prompt based on the current app state.
    private func buildSystemPrompt(for userMessage: String) -> String {
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
                contextLines.append("Visible region (display, 1-based): \(chrom):\(start + 1)-\(end)")
                contextLines.append("Visible region (tool calls, 0-based start): \(chrom):\(start)-\(end)")
            }
        }
        if viewerState.sampleCount > 0 {
            contextLines.append("Samples: \(viewerState.sampleCount)")
            if !viewerState.sampleNameExamples.isEmpty {
                contextLines.append("Sample examples: \(viewerState.sampleNameExamples.joined(separator: ", "))")
            }
            contextLines.append("Visible samples in viewer: \(viewerState.visibleSampleCount)")
            if !viewerState.visibleSampleExamples.isEmpty {
                contextLines.append("Visible sample examples: \(viewerState.visibleSampleExamples.joined(separator: ", "))")
            }
        }
        if viewerState.variantTableRowCount > 0 {
            contextLines.append("Variant table rows currently shown: \(viewerState.variantTableRowCount)")
            if !viewerState.variantTableExamples.isEmpty {
                contextLines.append("Variant table examples: \(viewerState.variantTableExamples.joined(separator: " | "))")
            }
        }
        if viewerState.sampleTableRowCount > 0 {
            contextLines.append("Sample table rows currently shown: \(viewerState.sampleTableRowCount)")
            if !viewerState.sampleTableExamples.isEmpty {
                contextLines.append("Sample table examples: \(viewerState.sampleTableExamples.joined(separator: ", "))")
            }
        }

        let dataContext = contextLines.isEmpty
            ? "No genome data is currently loaded."
            : contextLines.joined(separator: "\n")
        let assayGuidance = speciesAwareAssayAndReagentGuidance(
            organism: viewerState.organism,
            assembly: viewerState.assembly
        )

        var prompt = """
        You are a genomics research assistant built into the Lungfish genome browser application. \
        Your role is to help researchers explore and understand genomic data, especially those who \
        may not have extensive experience with genome browsers or bioinformatics.

        ## Your Capabilities
        You have access to tools that can:
        - Search for genes and annotations in the loaded genome data
        - Search for genetic variants (SNPs, insertions, deletions) from VCF files
        - Get variant statistics and gene details
        - Read currently selected/visible rows from the Variants and Samples tables
        - Navigate the genome browser to specific genes or regions
        - Search PubMed for relevant scientific literature

        ## Currently Loaded Data
        \(dataContext)

        ## Experimental Follow-Up Guidance
        \(assayGuidance)

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

        9. **Use loaded table state**: If variant/sample table row summaries are present in context, \
        treat them as the user's current filtered working set and discuss those first before broadening \
        to genome-wide searches.

        10. **For table-focused questions, call table tools first**: If the user asks about \
        selected/visible variants or samples in the UI table, call `get_variant_table_context` \
        and/or `get_sample_table_context` before forming conclusions.

        11. **Suggest assays and reagents**: When discussing a genomic feature (gene, variant, \
        region), include practical wet-lab follow-up options (e.g., expression assays, protein assays, \
        functional assays) and species-appropriate reagents. Prefer species-validated monoclonal \
        antibodies or explicitly note when only cross-reactive antibodies are likely. State that reagent \
        clone compatibility must be verified against vendor datasheets and recent literature.
        """

        let lowered = userMessage.lowercased()
        let variantTablePhrases = [
            "variant table",
            "selected variant",
            "selected variants",
            "visible variant",
            "visible variants",
            "shown variant",
            "shown variants",
            "displayed variant",
            "displayed variants",
            "table variants",
            "variant rows",
            "rows in the variant table",
            "these variants",
            "those variants",
            "current variants",
            "listed variants",
        ]
        let sampleTablePhrases = [
            "sample table",
            "selected sample",
            "selected samples",
            "visible sample",
            "visible samples",
            "shown sample",
            "shown samples",
            "displayed sample",
            "displayed samples",
            "table samples",
            "sample rows",
            "rows in the sample table",
            "these samples",
            "those samples",
            "current samples",
            "listed samples",
        ]
        let referencesVariantTable = variantTablePhrases.contains(where: lowered.contains)
        let referencesSampleTable = sampleTablePhrases.contains(where: lowered.contains)

        if referencesVariantTable {
            prompt += """

            ## Mandatory Step For This Request
            Before answering this request, call `get_variant_table_context` with \
            `selection_scope=\"selected_or_visible\"`.
            """
            if let variantSnapshot = toolRegistry.getVariantTableContext?("selected_or_visible", 25),
               !variantSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                prompt += """

                ## Variant Table Snapshot (Current UI)
                \(variantSnapshot)
                """
            }
        }

        if referencesSampleTable {
            prompt += """

            ## Mandatory Step For This Request
            Before answering this request, call `get_sample_table_context` with \
            `selection_scope=\"selected_or_visible\"`.
            """
            if let sampleSnapshot = toolRegistry.getSampleTableContext?("selected_or_visible", 50, true),
               !sampleSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                prompt += """

                ## Sample Table Snapshot (Current UI)
                \(sampleSnapshot)
                """
            }
        }

        return prompt
    }

    private func speciesAwareAssayAndReagentGuidance(organism: String?, assembly: String?) -> String {
        let organismLower = organism?.lowercased() ?? ""
        let assemblyLower = assembly?.lowercased() ?? ""

        func containsAny(_ text: String, _ values: [String]) -> Bool {
            values.contains { text.contains($0) }
        }

        if containsAny(organismLower, ["macaca mulatta", "rhesus"]) || containsAny(assemblyLower, ["mmul", "rhe"]) {
            return """
            Current dataset appears to be **rhesus macaque (Macaca mulatta)**. \
            Prioritize macaque-validated assays and reagents. \
            For immunology-focused genes/variants, suggest flow cytometry, ICS, ELISpot, qPCR/RNA-seq, \
            and protein-level validation with macaque-compatible monoclonal antibodies. \
            Include rhesus-relevant clone examples where appropriate (for example, CD3 clone SP34-2 and \
            other documented macaque-compatible clones), and clearly tell the user to verify clone and \
            epitope compatibility before use.
            """
        }

        if containsAny(organismLower, ["homo sapiens", "human"]) || containsAny(assemblyLower, ["grch", "hg"]) {
            return """
            Current dataset appears to be **human**. Suggest standard human assays first \
            (RNA-seq/qPCR, targeted sequencing, western blot, flow cytometry, functional perturbation assays) \
            and clinically relevant reagents when appropriate. Highlight orthogonal validation strategies.
            """
        }

        if containsAny(organismLower, ["mus musculus", "mouse"]) || containsAny(assemblyLower, ["grcm", "mm10", "mm39"]) {
            return """
            Current dataset appears to be **mouse**. Favor mouse-validated antibodies and assay panels \
            (including strain-aware considerations where relevant), and suggest orthogonal validation \
            at transcript and protein levels.
            """
        }

        let speciesDescriptor: String
        if let organism, !organism.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speciesDescriptor = organism
        } else if let assembly, !assembly.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speciesDescriptor = "assembly \(assembly)"
        } else {
            speciesDescriptor = "the loaded dataset"
        }

        return """
        Use **species-aware reagent recommendations** based on \(speciesDescriptor). \
        Suggest assays that match the genomic question (expression, protein abundance, functional impact, \
        and phenotype association) and prioritize reagents validated in the same species. \
        If species-matched reagents are limited, explicitly state cross-reactivity uncertainty and propose \
        validation controls.
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
            regionDescription = "\(chromosome):\(start + 1)-\(end) (display coordinates)"
        } else {
            regionDescription = chromosome
        }
        let sampleContext: String = state.sampleCount > 0
            ? "There are \(state.sampleCount) samples\(state.sampleNameExamples.isEmpty ? "" : " (e.g., \(state.sampleNameExamples.joined(separator: ", ")))")."
            : "No sample metadata is available."

        // 1. Bundle overview
        queries.append(SuggestedQuery(
            title: "Data overview",
            query: "Summarize '\(bundleName)' (\(organism), \(assembly)): chromosome count, annotation tracks, variant tracks, total variants, and recommend what to explore first.",
            icon: "doc.text.magnifyingglass"
        ))

        // 2. Current region exploration
        queries.append(SuggestedQuery(
            title: "Explore current view",
            query: "What genes and annotations are visible in my current view around \(regionDescription)? List them with their positions and types. Use display coordinates in the response.",
            icon: "eye"
        ))

        // 3. Gene search
        queries.append(SuggestedQuery(
            title: "Search for a gene",
            query: "Search for immune-related genes in \(organism). List any matches found in '\(bundleName)' with their chromosome locations, then navigate me to the most interesting one.",
            icon: "magnifyingglass"
        ))

        // 4. Navigate to gene
        queries.append(SuggestedQuery(
            title: "Navigate to a gene",
            query: "Find the gene closest to the center of \(regionDescription) and navigate there. Show me its exon-intron structure and any nearby variants.",
            icon: "location"
        ))

        if state.totalVariantCount > 0 {
            // 5. Variant summary
            queries.append(SuggestedQuery(
                title: "Variant statistics",
                query: "Give me a breakdown of all \(state.totalVariantCount) variants: how many SNPs, insertions, deletions, and other types? Which chromosomes have the highest variant density? \(sampleContext)",
                icon: "chart.bar"
            ))

            // 6. Variants in region
            queries.append(SuggestedQuery(
                title: "Variants in this region",
                query: "Find all variants in \(regionDescription). Group them by type (SNP, insertion, deletion) and list the top 10 by position with their REF>ALT changes in display coordinates.",
                icon: "list.bullet.rectangle"
            ))

            // 7. Gene-variant connection
            queries.append(SuggestedQuery(
                title: "Variants in a gene",
                query: "Pick a well-known disease-associated gene for \(organism), check if it exists in '\(bundleName)', and if so list all variants within that gene's coordinates.",
                icon: "bolt.trianglebadge.exclamationmark"
            ))
        }

        // 8. Disease gene screening
        queries.append(SuggestedQuery(
            title: "Disease gene check",
            query: "List 5 well-studied disease genes for \(organism), check whether each appears in '\(bundleName)', and if present summarize the gene details and nearby variants.",
            icon: "stethoscope"
        ))

        // 9. PubMed literature
        queries.append(SuggestedQuery(
            title: "Find related research",
            query: "Search PubMed for recent papers about \(organism) genomics. Summarize the top 3 most relevant papers and explain how they relate to the data in '\(bundleName)'.",
            icon: "book"
        ))

        // 10. Chromosome overview
        queries.append(SuggestedQuery(
            title: "Chromosome guide",
            query: "List all chromosomes in '\(bundleName)' and tell me which ones are largest. Then navigate me to the beginning of the largest chromosome.",
            icon: "list.number"
        ))

        return queries
    }

    /// Contextual welcome text shown when opening the AI assistant panel.
    public func welcomeMessage() -> String {
        let state = toolRegistry.getCurrentViewState?() ?? AIToolRegistry.ViewerState()

        if state.bundleName == nil {
            return """
            Welcome to the Lungfish AI Assistant.

            No genome bundle is currently loaded. Open or create a bundle first, then ask me to help you explore it.

            I can help you:
            - **Search genes** and annotations in your data
            - **Find variants** (SNPs, insertions, deletions)
            - **Navigate** the genome browser to regions of interest
            - **Search PubMed** for relevant research literature

            Configure API keys in **Settings > AI Services** before using AI features.
            """
        }

        let bundle = state.bundleName ?? "loaded bundle"
        let organism = state.organism ?? "loaded organism"
        let chromosome = state.chromosome ?? state.chromosomeNames.first ?? "current chromosome"
        let regionText: String
        if let start = state.start, let end = state.end {
            regionText = "\(chromosome):\(start + 1)-\(end) (display coordinates)"
        } else {
            regionText = chromosome
        }

        var lines: [String] = []
        lines.append("Welcome. You are exploring **\(bundle)** (\(organism)).")
        lines.append("Current view: **\(regionText)**")
        lines.append("")
        lines.append("Here are some things you can ask me:")
        lines.append("- \"What genes are in my current view?\"")
        lines.append("- \"Search for BRCA1 in this genome\"")
        if state.totalVariantCount > 0 {
            lines.append("- \"Show me variant statistics\"")
            lines.append("- \"Find variants near gene X\"")
        }
        lines.append("- \"Navigate to \(chromosome)\"")
        lines.append("- \"Find PubMed papers about \(organism) genomics\"")
        lines.append("")
        lines.append("Coordinate note: user-visible positions are 1-based; internal tool calls use 0-based starts.")
        lines.append("")
        lines.append("Or try the suggested questions below.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Human-readable label for a tool name, shown during execution.
    private func toolDisplayName(_ name: String) -> String {
        switch name {
        case "search_genes": return "Searching genes..."
        case "search_variants": return "Searching variants..."
        case "get_variant_statistics": return "Getting variant stats..."
        case "get_gene_details": return "Looking up gene details..."
        case "get_variant_table_context": return "Reading variant table..."
        case "get_sample_table_context": return "Reading sample table..."
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
