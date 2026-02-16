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

    /// Maximum tool execution rounds per user message (prevents infinite loops).
    private let maxToolRounds = 8

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
        guard !isProcessing else {
            return "Please wait for the current request to complete."
        }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        // Add user message
        messages.append(.user(text))

        do {
            let provider = try await resolveProvider()
            let systemPrompt = buildSystemPrompt()
            let tools = toolRegistry.toolDefinitions

            // Conversation loop: send message, execute tools, repeat until done
            var rounds = 0
            while rounds < maxToolRounds {
                rounds += 1

                let response = try await provider.sendMessage(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    tools: tools
                )

                if let usage = response.usage {
                    totalTokensUsed += usage.inputTokens + usage.outputTokens
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
                    let result = await toolRegistry.execute(toolCall)
                    toolResults.append(result)
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
            return messages.last { $0.role == .assistant }?.content ?? "I've been working on your request but reached the maximum number of analysis steps. Here's what I found so far."

        } catch let error as AIProviderError {
            lastError = error.localizedDescription
            logger.error("AI provider error: \(error)")
            // Remove the user message if we failed
            if messages.last?.role == .user {
                messages.removeLast()
            }
            return error.localizedDescription ?? "An error occurred."
        } catch {
            lastError = error.localizedDescription
            logger.error("Unexpected error: \(error)")
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
    private func resolveProvider() async throws -> any AIProvider {
        let settings = AppSettings.shared
        let keychain = KeychainSecretStorage.shared

        let preferred = AIProviderIdentifier(rawValue: settings.preferredAIProvider) ?? .anthropic

        // Try preferred provider first
        if let provider = try await makeProvider(preferred, settings: settings, keychain: keychain) {
            return provider
        }

        // Fallback to any configured provider
        let fallbackOrder: [AIProviderIdentifier] = [.anthropic, .openAI, .gemini].filter { $0 != preferred }
        for providerId in fallbackOrder {
            if let provider = try await makeProvider(providerId, settings: settings, keychain: keychain) {
                logger.info("Falling back to \(providerId.displayName)")
                return provider
            }
        }

        throw AIProviderError.missingAPIKey
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
                query: "How do I load a genome into Lungfish?",
                icon: "questionmark.circle"
            ))
            return queries
        }

        // Basic exploration
        queries.append(SuggestedQuery(
            title: "Overview",
            query: "Give me an overview of the loaded genome data. What chromosomes, genes, and variants are available?",
            icon: "doc.text.magnifyingglass"
        ))

        if state.totalVariantCount > 0 {
            queries.append(SuggestedQuery(
                title: "Variant summary",
                query: "Summarize the variants in this dataset. What types of variants are present and how many?",
                icon: "chart.bar"
            ))

            queries.append(SuggestedQuery(
                title: "High-impact variants",
                query: "Are there any high-impact or potentially deleterious variants? What genes are they in?",
                icon: "exclamationmark.triangle"
            ))
        }

        if let organism = state.organism {
            queries.append(SuggestedQuery(
                title: "Disease genes",
                query: "What are the most studied disease-associated genes in \(organism)? Are any of them present in my data?",
                icon: "stethoscope"
            ))
        }

        // Gene exploration
        queries.append(SuggestedQuery(
            title: "Find a gene",
            query: "Search for immune-related genes in my data",
            icon: "magnifyingglass"
        ))

        return queries
    }
}

/// A suggested query shown in the AI assistant panel.
public struct SuggestedQuery: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let query: String
    public let icon: String
}
