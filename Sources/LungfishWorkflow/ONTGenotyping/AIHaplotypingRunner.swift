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
    public let provenancePath: String

    public init(
        mode: AIHaplotypingPromptMode,
        providerID: AIHaplotypingProviderID,
        credentialSource: AIHaplotypingCredentialSource? = nil,
        promptTemplateID: String? = nil,
        promptTemplateVersion: String? = nil,
        maxObservationsPerChunk: Int = 128,
        maxOutputTokens: Int = 4_096,
        temperature: Double = 0,
        provenancePath: String = "ai-haplotyping/provenance.json"
    ) {
        self.mode = mode
        self.providerID = providerID
        self.credentialSource = credentialSource
        self.promptTemplateID = promptTemplateID
        self.promptTemplateVersion = promptTemplateVersion
        self.maxObservationsPerChunk = max(1, maxObservationsPerChunk)
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.temperature = max(0, min(2, temperature))
        let trimmedProvenancePath = provenancePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provenancePath = trimmedProvenancePath.isEmpty
            ? "ai-haplotyping/provenance.json"
            : trimmedProvenancePath
    }

    public func generationParameters(schemaName: String) -> [String: String] {
        [
            "maxObservationsPerChunk": String(maxObservationsPerChunk),
            "maxOutputTokens": String(maxOutputTokens),
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

    public init(
        provider: any StructuredAIProvider,
        promptRegistry: AIHaplotypingPromptRegistry = .builtIn
    ) {
        self.provider = provider
        self.promptRegistry = promptRegistry
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

        for (offset, chunk) in chunks.enumerated() {
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
                            knowledgePack: knowledgePack
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
                response = try await provider.requestStructuredResult(request)
            } catch {
                throw AIHaplotypingRunFailure(
                    stage: .provider,
                    sanitizedErrorCategory: sanitizedProviderErrorCategory(error),
                    message: sanitizedProviderFailureMessage(error)
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
                    message: error.localizedDescription,
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
        }

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
        case .invalidResponse:
            return "AI provider returned an invalid structured response."
        case .httpError:
            return "AI provider returned an HTTP error."
        case .rateLimited:
            return "Rate limited by AI provider. Try again later."
        case .modelNotAvailable:
            return "Configured AI model is not available."
        case .contextTooLong:
            return "AI haplotyping prompt exceeded the provider context limit."
        case .networkError:
            return "AI provider network request failed."
        case .decodingError:
            return "AI provider response could not be decoded."
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
