import Foundation
import LungfishCore
import LungfishIO

public struct AIHaplotypingRunOptions: Codable, Equatable, Sendable {
    public let mode: AIHaplotypingPromptMode
    public let providerID: AIHaplotypingProviderID
    public let credentialSource: AIHaplotypingCredentialSource?
    public let promptTemplateID: String?
    public let promptTemplateVersion: String?
    public let maxObservationsPerChunk: Int
    public let maxOutputTokens: Int
    public let temperature: Double
    public let maxProviderRetries: Int
    public let provenancePath: String
    public let compactKnowledgePack: Bool
    public let chunkStartIndex: Int
    public let chunkEndIndex: Int

    public init(
        mode: AIHaplotypingPromptMode,
        providerID: AIHaplotypingProviderID,
        credentialSource: AIHaplotypingCredentialSource? = nil,
        promptTemplateID: String? = nil,
        promptTemplateVersion: String? = nil,
        maxObservationsPerChunk: Int = 128,
        maxOutputTokens: Int = 4_096,
        temperature: Double = 0,
        maxProviderRetries: Int = 2,
        provenancePath: String = "ai-haplotyping/provenance.json",
        compactKnowledgePack: Bool = false,
        chunkStartIndex: Int = 1,
        chunkEndIndex: Int = 0
    ) {
        self.mode = mode
        self.providerID = providerID
        self.credentialSource = credentialSource
        self.promptTemplateID = promptTemplateID
        self.promptTemplateVersion = promptTemplateVersion
        self.maxObservationsPerChunk = max(1, maxObservationsPerChunk)
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.temperature = max(0, min(2, temperature))
        self.maxProviderRetries = max(0, maxProviderRetries)
        let trimmedProvenancePath = provenancePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provenancePath = trimmedProvenancePath.isEmpty
            ? "ai-haplotyping/provenance.json"
            : trimmedProvenancePath
        self.compactKnowledgePack = compactKnowledgePack
        self.chunkStartIndex = max(1, chunkStartIndex)
        self.chunkEndIndex = max(0, chunkEndIndex)
    }

    public func generationParameters(schemaName: String) -> [String: String] {
        [
            "chunkEndIndex": String(chunkEndIndex),
            "chunkStartIndex": String(chunkStartIndex),
            "compactKnowledgePack": compactKnowledgePack ? "true" : "false",
            "maxObservationsPerChunk": String(maxObservationsPerChunk),
            "maxOutputTokens": String(maxOutputTokens),
            "maxProviderRetries": String(maxProviderRetries),
            "schemaName": schemaName,
            "temperature": Self.formatNumber(temperature),
        ]
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(value)
    }
}

public struct AIHaplotypingRunnerOutput: Codable, Equatable, Sendable {
    public let mode: AIHaplotypingPromptMode
    public let registry: AIHaplotypingEvidenceRegistry
    public let chunkOutputs: [AIHaplotypingChunkOutput]
    public let normalizedCalls: [AIHaplotypingValidatedCall]
    public let validatedDefinitions: [AIHaplotypingValidatedDefinition]
    public let validationReports: [AIHaplotypingValidationReport]
    public let providerAttempts: [AIProviderAttemptMetadata]

    public init(
        mode: AIHaplotypingPromptMode,
        registry: AIHaplotypingEvidenceRegistry,
        chunkOutputs: [AIHaplotypingChunkOutput],
        normalizedCalls: [AIHaplotypingValidatedCall],
        validatedDefinitions: [AIHaplotypingValidatedDefinition],
        validationReports: [AIHaplotypingValidationReport],
        providerAttempts: [AIProviderAttemptMetadata]
    ) {
        self.mode = mode
        self.registry = registry
        self.chunkOutputs = chunkOutputs
        self.normalizedCalls = normalizedCalls
        self.validatedDefinitions = validatedDefinitions
        self.validationReports = validationReports
        self.providerAttempts = providerAttempts
    }
}

public enum AIHaplotypingProgressEvent: Equatable, Sendable {
    case runStarted(chunkCount: Int, observationCount: Int)
    case chunkStarted(chunkID: String, chunkIndex: Int, chunkCount: Int, observationCount: Int)
    case providerRetry(chunkID: String, retryIndex: Int, maxRetries: Int, errorCategory: String)
    case chunkFinished(chunkID: String, chunkIndex: Int, chunkCount: Int, callCount: Int, definitionCount: Int)
    case runFinished(chunkCount: Int, callCount: Int, definitionCount: Int)
}

public struct AIHaplotypingChunkOutput: Codable, Equatable, Sendable {
    public let chunkID: String
    public let registryDigest: String
    public let inputSnapshotDigest: String
    public let promptMetadata: AIHaplotypingPromptMetadata
    public let payloadDigest: String
    public let validationReport: AIHaplotypingValidationReport
    public let providerAttempt: AIProviderAttemptMetadata

    public init(
        chunkID: String,
        registryDigest: String,
        inputSnapshotDigest: String,
        promptMetadata: AIHaplotypingPromptMetadata,
        payloadDigest: String,
        validationReport: AIHaplotypingValidationReport,
        providerAttempt: AIProviderAttemptMetadata
    ) {
        self.chunkID = chunkID
        self.registryDigest = registryDigest
        self.inputSnapshotDigest = inputSnapshotDigest
        self.promptMetadata = promptMetadata
        self.payloadDigest = payloadDigest
        self.validationReport = validationReport
        self.providerAttempt = providerAttempt
    }
}

public enum AIHaplotypingRunFailureStage: String, Codable, Equatable, Sendable {
    case evidence
    case prompt
    case provider
    case decoding
    case runMetadata
    case validation
}

public struct AIHaplotypingRunFailure: Error, LocalizedError, Codable, Equatable, Sendable {
    public let stage: AIHaplotypingRunFailureStage
    public let sanitizedErrorCategory: String
    public let message: String
    public let attemptMetadata: AIProviderAttemptMetadata?
    public let validationReport: AIHaplotypingValidationReport?

    public init(
        stage: AIHaplotypingRunFailureStage,
        sanitizedErrorCategory: String,
        message: String,
        attemptMetadata: AIProviderAttemptMetadata? = nil,
        validationReport: AIHaplotypingValidationReport? = nil
    ) {
        self.stage = stage
        self.sanitizedErrorCategory = sanitizedErrorCategory
        self.message = message
        self.attemptMetadata = attemptMetadata
        self.validationReport = validationReport
    }

    public var errorDescription: String? { message }
}

public struct AIHaplotypingRunner: Sendable {
    public static let schemaName = "lungfish_ai_haplotyping_result"

    private let provider: any StructuredAIProvider
    private let promptRegistry: AIHaplotypingPromptRegistry
    private let progressHandler: (@Sendable (AIHaplotypingProgressEvent) -> Void)?

    public init(
        provider: any StructuredAIProvider,
        promptRegistry: AIHaplotypingPromptRegistry = .builtIn,
        progressHandler: (@Sendable (AIHaplotypingProgressEvent) -> Void)? = nil
    ) {
        self.provider = provider
        self.promptRegistry = promptRegistry
        self.progressHandler = progressHandler
    }

    public func run(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar?,
        options: AIHaplotypingRunOptions
    ) async throws -> AIHaplotypingRunnerOutput {
        let registry: AIHaplotypingEvidenceRegistry
        do {
            registry = try AIHaplotypingEvidenceBuilder.build(
                result: result,
                sidecar: sidecar,
                mode: options.mode,
                parentRevisionID: result.manifest.activeHaplotypeAnalysisRevisionID
                    ?? result.haplotypeAnalysis?.analysisRevisionID
            )
        } catch {
            throw AIHaplotypingRunFailure(
                stage: .evidence,
                sanitizedErrorCategory: "evidence_build_failed",
                message: error.localizedDescription
            )
        }

        let chunks: [AIHaplotypingEvidenceChunk]
        do {
            chunks = try AIHaplotypingEvidenceChunker(
                maxObservationsPerChunk: options.maxObservationsPerChunk
            ).chunks(from: registry)
        } catch {
            throw AIHaplotypingRunFailure(
                stage: .evidence,
                sanitizedErrorCategory: "evidence_chunk_failed",
                message: error.localizedDescription
            )
        }

        let template: AIHaplotypingPromptTemplate
        do {
            if let promptTemplateID = options.promptTemplateID,
               let promptTemplateVersion = options.promptTemplateVersion {
                template = try promptRegistry.template(id: promptTemplateID, version: promptTemplateVersion)
            } else {
                template = try promptRegistry.currentTemplate(for: options.mode)
            }
        } catch {
            throw AIHaplotypingRunFailure(
                stage: .prompt,
                sanitizedErrorCategory: "prompt_template_missing",
                message: error.localizedDescription
            )
        }

        let runContext = AIHaplotypingRunContext.infer(from: result)
        let knowledgePack: AIHaplotypingKnowledgePack
        do {
            knowledgePack = try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()
        } catch {
            throw AIHaplotypingRunFailure(
                stage: .prompt,
                sanitizedErrorCategory: "knowledge_pack_load_failed",
                message: error.localizedDescription
            )
        }

        var chunkOutputs: [AIHaplotypingChunkOutput] = []
        var normalizedCalls: [AIHaplotypingValidatedCall] = []
        var validatedDefinitions: [AIHaplotypingValidatedDefinition] = []
        var validationReports: [AIHaplotypingValidationReport] = []
        var providerAttempts: [AIProviderAttemptMetadata] = []
        var seenDefinitionIDs: Set<String> = []
        var seenDefinitionKeys: Set<String> = []

        let selectedChunks = selectedChunkOffsets(from: chunks, options: options)
        let selectedObservationCount = selectedChunks.reduce(0) { total, item in
            total + item.chunk.registry.observations.count
        }
        emit(.runStarted(chunkCount: selectedChunks.count, observationCount: selectedObservationCount))
        for (offset, chunk) in selectedChunks {
            let chunkIndex = offset + 1
            emit(.chunkStarted(
                chunkID: chunk.id,
                chunkIndex: chunkIndex,
                chunkCount: chunks.count,
                observationCount: chunk.registry.observations.count
            ))
            let promptKnowledgePack = options.compactKnowledgePack
                ? AIHaplotypingKnowledgePackRetriever.compact(
                    knowledgePack,
                    for: chunk.registry,
                    runContext: runContext
                )
                : knowledgePack
            let promptMetadata = template.metadata(
                registryDigest: chunk.registry.digest,
                inputSnapshotDigest: chunk.registry.inputSnapshotDigest,
                evidenceSnapshotPath: "ai-haplotyping/evidence/\(chunk.id).json",
                knowledgePack: knowledgePack
            )
            let generationParameters = options.generationParameters(schemaName: Self.schemaName)
            let expectedRun = AIHaplotypingRunMetadata(
                mode: options.mode,
                promptTemplateID: template.id,
                promptTemplateVersion: template.version,
                promptHash: template.promptHash,
                provider: options.providerID.rawValue,
                model: provider.modelId,
                generationParameters: generationParameters,
                parentRevisionID: chunk.registry.parentRevisionID,
                registryDigest: chunk.registry.digest,
                inputSnapshotDigest: chunk.registry.inputSnapshotDigest
            )
            let request: AIStructuredRequest
            do {
                request = AIStructuredRequest(
                    systemPrompt: template.systemPrompt,
                    userPrompt: template.render(
                        promptInputJSON: try promptInputJSONString(
                            chunk: chunk,
                            expectedRun: expectedRun,
                            runContext: runContext,
                            knowledgePack: promptKnowledgePack
                        ),
                        evidenceRegistryJSON: chunk.registry.canonicalJSONString()
                    ),
                    schemaName: Self.schemaName,
                    schema: AIHaplotypingResultSchema.jsonSchema(),
                    maxOutputTokens: options.maxOutputTokens,
                    temperature: options.temperature,
                    attemptIndex: offset,
                    fallbackIndex: 0,
                    credentialSource: options.credentialSource?.rawValue
                )
            } catch {
                throw AIHaplotypingRunFailure(
                    stage: .prompt,
                    sanitizedErrorCategory: "prompt_render_failed",
                    message: error.localizedDescription
                )
            }

            let response: AIStructuredResponse
            do {
                response = try await requestStructuredResultWithRetries(
                    request,
                    chunkID: chunk.id,
                    provider: provider,
                    maxRetries: options.maxProviderRetries
                )
            } catch {
                throw AIHaplotypingRunFailure(
                    stage: .provider,
                    sanitizedErrorCategory: sanitizedProviderErrorCategory(error),
                    message: "AI provider request for \(chunk.id) failed: \(sanitizedProviderFailureMessage(error))"
                )
            }
            if let mismatch = providerAttemptMismatch(
                response.attemptMetadata,
                expectedProvider: options.providerID.rawValue,
                expectedModel: provider.modelId
            ) {
                throw AIHaplotypingRunFailure(
                    stage: .runMetadata,
                    sanitizedErrorCategory: "provider_attempt_mismatch",
                    message: "AI provider attempt metadata did not match the configured AI haplotyping provider.",
                    attemptMetadata: response.attemptMetadata,
                    validationReport: AIHaplotypingValidationReport(
                        accepted: false,
                        run: expectedRun,
                        chunkID: chunk.id,
                        registryDigest: chunk.registry.digest,
                        inputSnapshotDigest: chunk.registry.inputSnapshotDigest,
                        normalizedCalls: [],
                        validatedDefinitions: [],
                        warnings: [],
                        errors: [.runMetadataMismatch(mismatch)]
                    )
                )
            }
            providerAttempts.append(response.attemptMetadata)

            let structuredResult: AIHaplotypingStructuredResult
            do {
                let data = try JSONEncoder().encode(response.payload)
                structuredResult = try JSONDecoder().decode(AIHaplotypingStructuredResult.self, from: data)
            } catch {
                throw AIHaplotypingRunFailure(
                    stage: .decoding,
                    sanitizedErrorCategory: "decode_structured_result",
                    message: "AI structured result for \(chunk.id) could not be decoded: \(Self.decodingErrorDescription(error))",
                    attemptMetadata: response.attemptMetadata
                )
            }

            let report = AIHaplotypingPatchValidator(
                registry: chunk.registry,
                expectedRun: expectedRun,
                expectedChunkID: chunk.id,
                provenancePath: options.provenancePath
            ).validate(structuredResult)
            guard report.accepted else {
                let stage: AIHaplotypingRunFailureStage
                let category: String
                if isRunMetadataFailure(report) {
                    stage = .runMetadata
                    category = "run_metadata_mismatch"
                } else {
                    stage = .validation
                    category = "validation_rejected"
                }
                throw AIHaplotypingRunFailure(
                    stage: stage,
                    sanitizedErrorCategory: category,
                    message: report.errors.first?.message ?? "AI haplotyping structured result was rejected.",
                    attemptMetadata: response.attemptMetadata,
                    validationReport: report
                )
            }
            for definition in report.validatedDefinitions {
                if !seenDefinitionIDs.insert(definition.definitionID).inserted {
                    let reducerReport = reducerRejectedReport(
                        from: report,
                        error: .duplicateDiscoveredDefinition(definition.definitionID)
                    )
                    throw AIHaplotypingRunFailure(
                        stage: .validation,
                        sanitizedErrorCategory: "validation_rejected",
                        message: reducerReport.errors[0].message,
                        attemptMetadata: response.attemptMetadata,
                        validationReport: reducerReport
                    )
                }
                let definitionKey = "\(definition.locus):\(definition.proposedLabel)"
                if !seenDefinitionKeys.insert(definitionKey).inserted {
                    let reducerReport = reducerRejectedReport(
                        from: report,
                        error: .provisionalDefinitionCollision(definitionKey)
                    )
                    throw AIHaplotypingRunFailure(
                        stage: .validation,
                        sanitizedErrorCategory: "validation_rejected",
                        message: reducerReport.errors[0].message,
                        attemptMetadata: response.attemptMetadata,
                        validationReport: reducerReport
                    )
                }
            }

            let payloadDigest = AIHaplotypingCanonicalJSON.sha256Digest(of: response.payload)
            let output = AIHaplotypingChunkOutput(
                chunkID: chunk.id,
                registryDigest: chunk.registry.digest,
                inputSnapshotDigest: chunk.registry.inputSnapshotDigest,
                promptMetadata: promptMetadata,
                payloadDigest: payloadDigest,
                validationReport: report,
                providerAttempt: response.attemptMetadata
            )
            chunkOutputs.append(output)
            validationReports.append(report)
            normalizedCalls.append(contentsOf: report.normalizedCalls)
            validatedDefinitions.append(contentsOf: report.validatedDefinitions)
            emit(.chunkFinished(
                chunkID: chunk.id,
                chunkIndex: chunkIndex,
                chunkCount: chunks.count,
                callCount: report.normalizedCalls.count,
                definitionCount: report.validatedDefinitions.count
            ))
        }

        emit(.runFinished(
            chunkCount: selectedChunks.count,
            callCount: normalizedCalls.count,
            definitionCount: validatedDefinitions.count
        ))
        return AIHaplotypingRunnerOutput(
            mode: options.mode,
            registry: registry,
            chunkOutputs: chunkOutputs,
            normalizedCalls: normalizedCalls,
            validatedDefinitions: validatedDefinitions,
            validationReports: validationReports,
            providerAttempts: providerAttempts
        )
    }

    private func selectedChunkOffsets(
        from chunks: [AIHaplotypingEvidenceChunk],
        options: AIHaplotypingRunOptions
    ) -> [(offset: Int, chunk: AIHaplotypingEvidenceChunk)] {
        let start = max(1, options.chunkStartIndex)
        let end = options.chunkEndIndex == 0 ? chunks.count : min(options.chunkEndIndex, chunks.count)
        guard start <= end else {
            return []
        }
        return chunks.enumerated().compactMap { offset, chunk in
            let oneBasedIndex = offset + 1
            guard oneBasedIndex >= start && oneBasedIndex <= end else {
                return nil
            }
            return (offset, chunk)
        }
    }

    private func promptInputJSONString(
        chunk: AIHaplotypingEvidenceChunk,
        expectedRun: AIHaplotypingRunMetadata,
        runContext: AIHaplotypingRunContext,
        knowledgePack: AIHaplotypingKnowledgePack
    ) throws -> String {
        let input = PromptInput(
            chunkID: chunk.id,
            expectedRun: expectedRun,
            runContext: runContext,
            knowledgePack: knowledgePack,
            evidenceRegistry: chunk.registry
        )
        let data = AIHaplotypingCanonicalJSON.canonicalData(of: input)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AIProviderError.decodingError("AI haplotyping prompt input was not UTF-8.")
        }
        return json
    }

    private func isRunMetadataFailure(_ report: AIHaplotypingValidationReport) -> Bool {
        guard let firstError = report.errors.first else {
            return false
        }
        switch firstError {
        case .runMetadataMismatch, .chunkIDMismatch, .registryDigestMismatch, .inputSnapshotDigestMismatch:
            return true
        default:
            return false
        }
    }

    private func reducerRejectedReport(
        from acceptedReport: AIHaplotypingValidationReport,
        error: AIHaplotypingValidationError
    ) -> AIHaplotypingValidationReport {
        AIHaplotypingValidationReport(
            accepted: false,
            run: acceptedReport.run,
            chunkID: acceptedReport.chunkID,
            registryDigest: acceptedReport.registryDigest,
            inputSnapshotDigest: acceptedReport.inputSnapshotDigest,
            normalizedCalls: [],
            validatedDefinitions: [],
            warnings: acceptedReport.warnings,
            errors: [error]
        )
    }

    private func providerAttemptMismatch(
        _ attempt: AIProviderAttemptMetadata,
        expectedProvider: String,
        expectedModel: String
    ) -> String? {
        if attempt.provider != expectedProvider {
            return "provider"
        }
        if attempt.model != expectedModel {
            return "model"
        }
        return nil
    }

    private func requestStructuredResultWithRetries(
        _ request: AIStructuredRequest,
        chunkID: String,
        provider: any StructuredAIProvider,
        maxRetries: Int
    ) async throws -> AIStructuredResponse {
        var retriesRemaining = max(0, maxRetries)
        var retryIndex = 0
        while true {
            do {
                return try await provider.requestStructuredResult(request)
            } catch {
                guard retriesRemaining > 0, shouldRetryProviderError(error) else {
                    throw error
                }
                retriesRemaining -= 1
                retryIndex += 1
                emit(.providerRetry(
                    chunkID: chunkID,
                    retryIndex: retryIndex,
                    maxRetries: max(0, maxRetries),
                    errorCategory: sanitizedProviderErrorCategory(error)
                ))
                let delay = retryDelay(for: error)
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
    }

    private func emit(_ event: AIHaplotypingProgressEvent) {
        progressHandler?(event)
    }

    private func shouldRetryProviderError(_ error: Error) -> Bool {
        guard let providerError = error as? AIProviderError else {
            return false
        }
        switch providerError {
        case .networkError, .rateLimited:
            return true
        case .httpError(let statusCode, _):
            return statusCode >= 500 && statusCode < 600
        case .missingAPIKey,
             .invalidResponse,
             .quotaExceeded,
             .modelNotAvailable,
             .contextTooLong,
             .decodingError:
            return false
        }
    }

    private func retryDelay(for error: Error) -> UInt64 {
        guard let providerError = error as? AIProviderError else {
            return 0
        }
        guard case .rateLimited(let retryAfter) = providerError,
              let retryAfter,
              retryAfter > 0 else {
            return 0
        }
        let cappedSeconds = min(retryAfter, 5)
        return UInt64(cappedSeconds * 1_000_000_000)
    }

    private func sanitizedProviderErrorCategory(_ error: Error) -> String {
        guard let providerError = error as? AIProviderError else {
            return "provider_error"
        }
        switch providerError {
        case .missingAPIKey:
            return "missing_api_key"
        case .invalidResponse:
            return "invalid_response"
        case .httpError:
            return "http_error"
        case .rateLimited:
            return "rate_limited"
        case .quotaExceeded:
            return "quota_exceeded"
        case .modelNotAvailable:
            return "model_not_available"
        case .contextTooLong:
            return "context_too_long"
        case .networkError:
            return "network_error"
        case .decodingError:
            return "decoding_error"
        }
    }

    private func sanitizedProviderFailureMessage(_ error: Error) -> String {
        guard let providerError = error as? AIProviderError else {
            return "AI provider request failed."
        }
        switch providerError {
        case .missingAPIKey:
            return "AI provider API key is not configured."
        case .invalidResponse(let detail):
            return "AI provider returned an invalid structured response: \(detail)"
        case .httpError:
            return "AI provider returned an HTTP error."
        case .rateLimited:
            return "Rate limited by AI provider. Try again later."
        case .quotaExceeded:
            return "AI provider quota is exhausted. Check provider billing or use another configured provider."
        case .modelNotAvailable:
            return "Configured AI model is not available."
        case .contextTooLong:
            return "AI haplotyping prompt exceeded the provider context limit."
        case .networkError(let detail):
            return "AI provider network request failed: \(detail)"
        case .decodingError:
            return "AI provider response could not be decoded."
        }
    }

    private static func decodingErrorDescription(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ codingPath: [CodingKey]) -> String {
            let value = codingPath.map(\.stringValue).joined(separator: ".")
            return value.isEmpty ? "<root>" : value
        }
        switch decodingError {
        case .typeMismatch(let type, let context):
            return "type mismatch for \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "missing value for \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "missing key at \(path(context.codingPath + [key])): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "data corrupted at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    private struct PromptInput: Encodable {
        let chunkID: String
        let expectedRun: AIHaplotypingRunMetadata
        let runContext: AIHaplotypingRunContext
        let knowledgePack: AIHaplotypingKnowledgePack
        let evidenceRegistry: AIHaplotypingEvidenceRegistry
    }
}
