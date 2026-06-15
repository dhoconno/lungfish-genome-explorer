import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AIHaplotypingRunnerTests: XCTestCase {
    func testRunnerBuildsChunkedStructuredRequestsAndReducesValidatedCalls() async throws {
        let provider = MockStructuredProvider { request in
            let registry = try Self.registry(from: request)
            let sample = try XCTUnwrap(registry.samples.first?.sample)
            let locus = try XCTUnwrap(registry.loci.first?.locus)
            let observationID = try XCTUnwrap(registry.observations.first?.id)
            let chunkID = sample == "DW473" ? "chunk-0001" : "chunk-0002"
            let label = sample == "DW473" ? "M8A" : "M9B"
            return try Self.response(
                request: request,
                chunkID: chunkID,
                registry: registry,
                calls: [
                    Self.structuredCall(
                        sample: sample,
                        locus: locus,
                        slot: "h1",
                        label: label,
                        evidenceID: observationID
                    ),
                ]
            )
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)

        let output = try await runner.run(
            result: makeResult(calls: [
                makeCall(sample: "DW472", genotype: "12_M9_B_001_01"),
                makeCall(sample: "DW473", genotype: "12_M8_A_001_01"),
            ]),
            sidecar: nil,
            options: AIHaplotypingRunOptions(
                mode: .aiDiscovery,
                providerID: .openAI,
                credentialSource: .environmentOpenAI,
                maxObservationsPerChunk: 1,
                maxOutputTokens: 2_048,
                temperature: 0,
                provenancePath: "ai-haplotyping/runs/test/provenance.json"
            )
        )

        let requests = await provider.recordedRequests()
        let expectedRuns = try requests.map { try Self.expectedRun(from: $0) }
        let promptInputs = try requests.map { try Self.promptInput(from: $0) }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.schemaName), ["lungfish_ai_haplotyping_result", "lungfish_ai_haplotyping_result"])
        XCTAssertEqual(requests.map(\.credentialSource), [
            AIHaplotypingCredentialSource.environmentOpenAI.rawValue,
            AIHaplotypingCredentialSource.environmentOpenAI.rawValue,
        ])
        XCTAssertEqual(requests.map(\.maxOutputTokens), [2_048, 2_048])
        XCTAssertEqual(requests.map(\.temperature), [0, 0])
        XCTAssertTrue(requests.allSatisfy { $0.schema == AIHaplotypingResultSchema.jsonSchema() })
        XCTAssertTrue(requests[0].userPrompt.contains("\"chunkID\":\"chunk-0001\""))
        XCTAssertTrue(requests[1].userPrompt.contains("\"chunkID\":\"chunk-0002\""))
        XCTAssertEqual(expectedRuns.map(\.promptTemplateID), [
            "lungfish.ai-haplotyping.discovery",
            "lungfish.ai-haplotyping.discovery",
        ])
        XCTAssertEqual(expectedRuns.map(\.provider), ["openai", "openai"])
        XCTAssertEqual(expectedRuns.map(\.model), ["gpt-5-mini", "gpt-5-mini"])
        XCTAssertEqual(expectedRuns[0].generationParameters["schemaName"], "lungfish_ai_haplotyping_result")
        XCTAssertEqual(expectedRuns[0].generationParameters["maxObservationsPerChunk"], "1")
        XCTAssertEqual(promptInputs[0].knowledgePack.id, "macaque-mhc")
        XCTAssertEqual(promptInputs[0].knowledgePack.version, "2026-06-15.2")
        XCTAssertEqual(promptInputs[0].runContext.assayResolution, "short_exon_amplicon")
        XCTAssertEqual(promptInputs[0].runContext.populationHint, "mcm")
        XCTAssertTrue(promptInputs[0].knowledgePack.legacyBlockDefinitions.contains { $0.reportLabel == "M1A" })

        XCTAssertEqual(output.mode, .aiDiscovery)
        XCTAssertEqual(output.registry.observations.count, 2)
        XCTAssertEqual(output.chunkOutputs.map(\.chunkID), ["chunk-0001", "chunk-0002"])
        XCTAssertEqual(output.chunkOutputs.map(\.promptMetadata.promptTemplateID), [
            "lungfish.ai-haplotyping.discovery",
            "lungfish.ai-haplotyping.discovery",
        ])
        XCTAssertEqual(output.chunkOutputs[0].promptMetadata.knowledgePackID, "macaque-mhc")
        XCTAssertEqual(output.chunkOutputs[0].promptMetadata.knowledgePackVersion, "2026-06-15.2")
        XCTAssertTrue(output.chunkOutputs[0].promptMetadata.knowledgePackDigest?.hasPrefix("sha256:") == true)
        XCTAssertTrue(output.chunkOutputs.allSatisfy { $0.payloadDigest.hasPrefix("sha256:") })
        XCTAssertEqual(output.providerAttempts.map(\.provider), ["openai", "openai"])
        XCTAssertTrue(output.normalizedCalls.allSatisfy {
            $0.aiMetadata.provenancePath == "ai-haplotyping/runs/test/provenance.json"
        })
        XCTAssertFalse(output.normalizedCalls.contains {
            $0.aiMetadata.provenancePath == AIHaplotypingPatchValidator.pendingProvenancePath
        })
        XCTAssertEqual(
            output.normalizedCalls.map { "\($0.sample):\($0.locus):\($0.slot):\($0.primaryHaplotypeLabel ?? "")" },
            ["DW473:MHC-A:h1:M8A", "DW472:MHC-B:h1:M9B"]
        )
        XCTAssertEqual(output.validationReports.map(\.accepted), [true, true])
    }

    func testRunnerRejectsResultWhenRunMetadataDoesNotMatchPrompt() async throws {
        let provider = MockStructuredProvider { request in
            let registry = try Self.registry(from: request)
            var result = try Self.structuredResult(
                request: request,
                chunkID: "chunk-0001",
                registry: registry,
                calls: [
                    Self.structuredCall(
                        sample: "DW472",
                        locus: "MHC-B",
                        slot: "h1",
                        label: "M9B",
                        evidenceID: "obs:DW472:MHC-B:12_M9_B_001_01"
                    ),
                ]
            )
            result = AIHaplotypingStructuredResult(
                schemaVersion: result.schemaVersion,
                run: AIHaplotypingRunMetadata(
                    mode: result.run.mode,
                    promptTemplateID: result.run.promptTemplateID,
                    promptTemplateVersion: result.run.promptTemplateVersion,
                    promptHash: "sha256:wrong",
                    provider: result.run.provider,
                    model: result.run.model,
                    generationParameters: result.run.generationParameters,
                    parentRevisionID: result.run.parentRevisionID,
                    registryDigest: result.run.registryDigest,
                    inputSnapshotDigest: result.run.inputSnapshotDigest
                ),
                registryDigest: result.registryDigest,
                inputSnapshotDigest: result.inputSnapshotDigest,
                chunkID: result.chunkID,
                discoveredDefinitions: result.discoveredDefinitions,
                calls: result.calls,
                warnings: result.warnings
            )
            return try Self.response(request: request, result: result)
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)

        do {
            _ = try await runner.run(
                result: makeResult(calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")]),
                sidecar: nil,
                options: AIHaplotypingRunOptions(
                    mode: .aiDiscovery,
                    providerID: .openAI,
                    credentialSource: .environmentOpenAI,
                    maxObservationsPerChunk: 1
                )
            )
            XCTFail("Expected run metadata mismatch")
        } catch let failure as AIHaplotypingRunFailure {
            XCTAssertEqual(failure.stage, .runMetadata)
            XCTAssertEqual(failure.sanitizedErrorCategory, "run_metadata_mismatch")
            XCTAssertTrue(failure.message.contains("promptHash"))
            XCTAssertEqual(failure.attemptMetadata?.provider, "openai")
        }
    }

    func testRunnerRejectsProviderAttemptMetadataMismatchBeforeAcceptingCalls() async throws {
        let provider = MockStructuredProvider { request in
            let registry = try Self.registry(from: request)
            return try Self.response(
                request: request,
                chunkID: "chunk-0001",
                registry: registry,
                calls: [
                    Self.structuredCall(
                        sample: "DW472",
                        locus: "MHC-B",
                        slot: "h1",
                        label: "M9B",
                        evidenceID: "obs:DW472:MHC-B:12_M9_B_001_01"
                    ),
                ],
                providerAttempt: Self.attemptMetadata(
                    request: request,
                    provider: "anthropic",
                    model: "claude-sonnet-4-5"
                )
            )
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)

        do {
            _ = try await runner.run(
                result: makeResult(calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")]),
                sidecar: nil,
                options: AIHaplotypingRunOptions(
                    mode: .aiDiscovery,
                    providerID: .openAI,
                    maxObservationsPerChunk: 1
                )
            )
            XCTFail("Expected provider attempt mismatch")
        } catch let failure as AIHaplotypingRunFailure {
            XCTAssertEqual(failure.stage, .runMetadata)
            XCTAssertEqual(failure.sanitizedErrorCategory, "provider_attempt_mismatch")
            XCTAssertEqual(failure.validationReport?.errors, [.runMetadataMismatch("provider")])
            XCTAssertEqual(failure.attemptMetadata?.provider, "anthropic")
        }
    }

    func testRunnerThrowsValidationFailureWhenModelUsesUnknownEvidence() async throws {
        let provider = MockStructuredProvider { request in
            let registry = try Self.registry(from: request)
            return try Self.response(
                request: request,
                chunkID: "chunk-0001",
                registry: registry,
                calls: [
                    Self.structuredCall(
                        sample: "DW472",
                        locus: "MHC-B",
                        slot: "h1",
                        label: "M9B",
                        evidenceID: "obs:not-in-registry"
                    ),
                ]
            )
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)

        do {
            _ = try await runner.run(
                result: makeResult(calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")]),
                sidecar: nil,
                options: AIHaplotypingRunOptions(
                    mode: .aiDiscovery,
                    providerID: .openAI,
                    maxObservationsPerChunk: 1
                )
            )
            XCTFail("Expected validation rejection")
        } catch let failure as AIHaplotypingRunFailure {
            XCTAssertEqual(failure.stage, .validation)
            XCTAssertEqual(failure.sanitizedErrorCategory, "validation_rejected")
            XCTAssertEqual(failure.validationReport?.accepted, false)
            XCTAssertEqual(failure.validationReport?.errors, [.unknownEvidenceID("obs:not-in-registry")])
        }
    }

    func testRunnerReportsProviderErrorsWithSanitizedCategory() async throws {
        let provider = MockStructuredProvider { _ in
            throw AIProviderError.httpError(statusCode: 400, message: "raw provider body with secret-token")
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)

        do {
            _ = try await runner.run(
                result: makeResult(calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")]),
                sidecar: nil,
                options: AIHaplotypingRunOptions(
                    mode: .aiDiscovery,
                    providerID: .openAI,
                    maxObservationsPerChunk: 10
                )
            )
            XCTFail("Expected provider failure")
        } catch let failure as AIHaplotypingRunFailure {
            XCTAssertEqual(failure.stage, .provider)
            XCTAssertEqual(failure.sanitizedErrorCategory, "http_error")
            XCTAssertEqual(failure.message, "AI provider returned an HTTP error.")
            XCTAssertFalse(failure.message.contains("secret-token"))
            XCTAssertNil(failure.attemptMetadata)
        }
    }

    func testRunnerRejectsDuplicateDiscoveredDefinitionsAcrossChunks() async throws {
        let provider = MockStructuredProvider { request in
            let registry = try Self.registry(from: request)
            let sample = try XCTUnwrap(registry.samples.first?.sample)
            let locus = try XCTUnwrap(registry.loci.first?.locus)
            let observationID = try XCTUnwrap(registry.observations.first?.id)
            return try Self.response(
                request: request,
                chunkID: sample == "DW473" ? "chunk-0001" : "chunk-0002",
                registry: registry,
                discoveredDefinitions: [
                    Self.discoveredDefinition(locus: locus, evidenceID: observationID)
                ],
                calls: [
                    Self.structuredCall(
                        sample: sample,
                        locus: locus,
                        slot: "h1",
                        label: sample == "DW473" ? "M8A" : "M9B",
                        evidenceID: observationID
                    ),
                ]
            )
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)

        do {
            _ = try await runner.run(
                result: makeResult(calls: [
                    makeCall(sample: "DW472", genotype: "12_M9_B_001_01"),
                    makeCall(sample: "DW473", genotype: "12_M8_A_001_01"),
                ]),
                sidecar: nil,
                options: AIHaplotypingRunOptions(
                    mode: .aiDiscovery,
                    providerID: .openAI,
                    maxObservationsPerChunk: 1
                )
            )
            XCTFail("Expected cross-chunk duplicate definition rejection")
        } catch let failure as AIHaplotypingRunFailure {
            XCTAssertEqual(failure.stage, .validation)
            XCTAssertEqual(failure.sanitizedErrorCategory, "validation_rejected")
            XCTAssertEqual(failure.validationReport?.errors, [.duplicateDiscoveredDefinition("def-shared")])
        }
    }

    private func makeCall(
        sample: String,
        genotype: String,
        passedAlignments: Int = 42,
        passedUniqueReads: Int = 21
    ) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: passedAlignments,
            passedUniqueReads: passedUniqueReads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    private func makeResult(calls: [ONTGenotypeCall]) -> ONTGenotypeResultBundleData {
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "out",
            analysisName: "Test",
            primaryWorkbookPath: "workbook.xlsx",
            longSummaryCSVPath: "long.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json",
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            haplotypeAssayID: "MHC-exon2-miSeq"
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: URL(fileURLWithPath: "/tmp/workbook.xlsx"),
            longSummaryCSVURL: URL(fileURLWithPath: "/tmp/long.csv"),
            sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/samples.csv"),
            statsJSONURL: URL(fileURLWithPath: "/tmp/stats.json"),
            provenanceURL: URL(fileURLWithPath: "/tmp/provenance.json")
        )
        return ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/out.lungfishgenotype"),
            manifest: manifest,
            artifacts: artifacts,
            stats: ONTGenotypeRunStats(),
            calls: calls,
            samples: []
        )
    }
}

private actor MockStructuredProvider: StructuredAIProvider {
    nonisolated let name = "OpenAI"
    nonisolated let modelId = "gpt-5-mini"

    private let handler: @Sendable (AIStructuredRequest) async throws -> AIStructuredResponse
    private var requests: [AIStructuredRequest] = []

    init(handler: @escaping @Sendable (AIStructuredRequest) async throws -> AIStructuredResponse) {
        self.handler = handler
    }

    func sendMessage(
        messages: [AIMessage],
        systemPrompt: String,
        tools: [AIToolDefinition]
    ) async throws -> AIResponse {
        throw AIProviderError.invalidResponse("MockStructuredProvider only supports structured requests.")
    }

    func requestStructuredResult(_ request: AIStructuredRequest) async throws -> AIStructuredResponse {
        requests.append(request)
        return try await handler(request)
    }

    func recordedRequests() -> [AIStructuredRequest] {
        requests
    }
}

private extension AIHaplotypingRunnerTests {
    static func registry(from request: AIStructuredRequest) throws -> AIHaplotypingEvidenceRegistry {
        try promptInput(from: request).evidenceRegistry
    }

    static func expectedRun(from request: AIStructuredRequest) throws -> AIHaplotypingRunMetadata {
        try promptInput(from: request).expectedRun
    }

    static func promptInput(from request: AIStructuredRequest) throws -> PromptInput {
        let markerRange = request.userPrompt.range(of: "Prompt input JSON:")
            ?? request.userPrompt.range(of: "Evidence registry JSON:")
        guard let markerRange else {
            throw AIProviderError.invalidResponse("Missing prompt input marker")
        }
        let suffix = request.userPrompt[markerRange.upperBound...]
        guard let start = suffix.firstIndex(of: "{") else {
            throw AIProviderError.invalidResponse("Missing prompt input JSON")
        }
        var depth = 0
        var end: String.Index?
        var index = start
        while index < suffix.endIndex {
            let character = suffix[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    end = index
                    break
                }
            }
            index = suffix.index(after: index)
        }
        guard let end else {
            throw AIProviderError.invalidResponse("Unterminated prompt input JSON")
        }
        let json = String(suffix[start...end])
        return try JSONDecoder().decode(PromptInput.self, from: Data(json.utf8))
    }

    static func response(
        request: AIStructuredRequest,
        chunkID: String,
        registry: AIHaplotypingEvidenceRegistry,
        discoveredDefinitions: [AIHaplotypingDiscoveredDefinition] = [],
        calls: [AIHaplotypingStructuredCall],
        providerAttempt: AIProviderAttemptMetadata? = nil
    ) throws -> AIStructuredResponse {
        try response(
            request: request,
            result: structuredResult(
                request: request,
                chunkID: chunkID,
                registry: registry,
                discoveredDefinitions: discoveredDefinitions,
                calls: calls
            ),
            providerAttempt: providerAttempt
        )
    }

    static func response(
        request: AIStructuredRequest,
        result: AIHaplotypingStructuredResult,
        providerAttempt: AIProviderAttemptMetadata? = nil
    ) throws -> AIStructuredResponse {
        let payload = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: JSONEncoder().encode(result)
        )
        return AIStructuredResponse(
            payload: payload,
            rawText: String(data: try JSONEncoder().encode(result), encoding: .utf8),
            usage: AIResponse.Usage(inputTokens: 100, outputTokens: 50),
            stopReason: .endTurn,
            attemptMetadata: providerAttempt ?? attemptMetadata(request: request)
        )
    }

    static func structuredResult(
        request: AIStructuredRequest,
        chunkID: String,
        registry: AIHaplotypingEvidenceRegistry,
        discoveredDefinitions: [AIHaplotypingDiscoveredDefinition] = [],
        calls: [AIHaplotypingStructuredCall]
    ) throws -> AIHaplotypingStructuredResult {
        let expectedRun = try expectedRun(from: request)
        return AIHaplotypingStructuredResult(
            schemaVersion: 1,
            run: expectedRun,
            registryDigest: registry.digest,
            inputSnapshotDigest: registry.inputSnapshotDigest,
            chunkID: chunkID,
            discoveredDefinitions: discoveredDefinitions,
            calls: calls,
            warnings: []
        )
    }

    static func structuredCall(
        sample: String,
        locus: String,
        slot: String,
        label: String,
        evidenceID: String
    ) -> AIHaplotypingStructuredCall {
        AIHaplotypingStructuredCall(
            patchOpID: "patch-\(sample)-\(locus)-\(slot)",
            sample: sample,
            locus: locus,
            slot: slot,
            haplotypeLabel: label,
            normalizedFamily: nil,
            source: .ai,
            sourceState: .raw,
            reviewState: .needsReview,
            callState: .called,
            confidenceTier: .high,
            supportEvidenceRefs: [evidenceID],
            counterevidenceRefs: [evidenceID],
            alternates: [],
            rationaleCode: "direct_observation",
            rationale: "Supported by direct observation evidence."
        )
    }

    static func discoveredDefinition(
        locus: String,
        evidenceID: String
    ) -> AIHaplotypingDiscoveredDefinition {
        AIHaplotypingDiscoveredDefinition(
            definitionID: "def-shared",
            locus: locus,
            proposedLabel: "AI-Novel-1",
            normalizedFamily: nil,
            supportEvidenceRefs: [evidenceID],
            counterevidenceRefs: ["locus:\(locus)"],
            confidenceTier: .medium,
            rationaleCode: "direct_observation",
            rationale: "Candidate definition supported by direct observation."
        )
    }

    static func attemptMetadata(
        request: AIStructuredRequest,
        provider: String = "openai",
        model: String = "gpt-5-mini"
    ) -> AIProviderAttemptMetadata {
        AIProviderAttemptMetadata(
            attemptIndex: request.attemptIndex,
            fallbackIndex: request.fallbackIndex,
            provider: provider,
            model: model,
            endpoint: "mock://structured",
            apiVersion: "test",
            credentialSource: request.credentialSource,
            apiKeyAvailable: true,
            requestID: UUID().uuidString,
            statusCode: 200,
            stopReason: "end_turn",
            inputTokens: 100,
            outputTokens: 50,
            sanitizedErrorCategory: nil
        )
    }

    struct PromptInput: Decodable {
        let chunkID: String
        let expectedRun: AIHaplotypingRunMetadata
        let runContext: AIHaplotypingRunContext
        let knowledgePack: AIHaplotypingKnowledgePack
        let evidenceRegistry: AIHaplotypingEvidenceRegistry
    }
}
