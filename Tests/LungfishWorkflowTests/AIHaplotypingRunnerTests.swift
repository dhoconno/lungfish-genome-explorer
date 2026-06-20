import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AIHaplotypingRunnerTests: XCTestCase {
    func testRunnerBuildsChunkedStructuredRequestsAndReducesValidatedCalls() async throws {
        let provider = MockStructuredProvider { request in
            let registry = try Self.registry(from: request)
            let sample = try XCTUnwrap(registry.samples.first?.sample)
            let (locus, observationID) = try Self.firstObservationLocusAndID(in: registry)
            let chunkID = sample == "DW472" ? "chunk-0001" : "chunk-0002"
            let label = sample == "DW472" ? "M9B" : "M8A"
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
        XCTAssertEqual(expectedRuns[0].generationParameters["reasoningEffort"], "none")
        XCTAssertEqual(expectedRuns[0].generationParameters["reviewScope"], "all")
        let knowledgePack = try XCTUnwrap(promptInputs[0].knowledgePack)
        XCTAssertEqual(knowledgePack.id, "macaque-mhc")
        XCTAssertEqual(knowledgePack.version, "2026-06-17.3")
        XCTAssertEqual(promptInputs[0].runContext.assayResolution, "short_exon_amplicon")
        XCTAssertEqual(promptInputs[0].runContext.populationHint, "mcm")
        XCTAssertTrue(knowledgePack.haplotypeBlockDefinitions.contains { $0.reportLabel == "M1A" })

        XCTAssertEqual(output.mode, .aiDiscovery)
        XCTAssertEqual(output.registry.observations.count, 2)
        XCTAssertEqual(output.chunkOutputs.map(\.chunkID), ["chunk-0001", "chunk-0002"])
        XCTAssertEqual(output.chunkOutputs.map(\.promptMetadata.promptTemplateID), [
            "lungfish.ai-haplotyping.discovery",
            "lungfish.ai-haplotyping.discovery",
        ])
        XCTAssertEqual(output.chunkOutputs[0].promptMetadata.knowledgePackID, "macaque-mhc")
        XCTAssertEqual(output.chunkOutputs[0].promptMetadata.knowledgePackVersion, "2026-06-17.3")
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
            ["DW472:MHC-B:h1:M9B", "DW473:MHC-A:h1:M8A"]
        )
        XCTAssertEqual(output.validationReports.map(\.accepted), [true, true])
    }

    func testRunnerCanUseMCMSpecialistPromptWithCompactEvidenceTransport() async throws {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        let provider = MockStructuredProvider { request in
            let promptInput = try Self.compactPromptInput(from: request)
            XCTAssertTrue(request.userPrompt.contains("MCM MHC MiSeq Haplotyping Specialist Prompt"))
            XCTAssertTrue(request.userPrompt.contains("M4 and M7 have the same MHC-DP genotypes"))
            XCTAssertFalse(request.userPrompt.contains("\"knowledgePack\""))
            XCTAssertFalse(request.userPrompt.contains("source_loci="))
            XCTAssertFalse(request.userPrompt.contains("accessions="))
            XCTAssertNil(promptInput.knowledgePack)
            XCTAssertEqual(promptInput.evidenceRegistry.encoding, "mcm-mhc-miseq-compact-v1")
            XCTAssertEqual(promptInput.evidenceRegistry.samples.map(\.sample), ["LF2823"])
            XCTAssertEqual(promptInput.evidenceRegistry.loci.map(\.locus), ["MHC-A"])
            let observation = try XCTUnwrap(promptInput.evidenceRegistry.observations.first)
            XCTAssertEqual(observation.id, "o1")
            XCTAssertEqual(observation.sample, "LF2823")
            XCTAssertEqual(observation.locus, "MHC-A")
            XCTAssertEqual(observation.target, "0069")
            XCTAssertEqual(observation.genotype, "0069[MHC-A1]")
            XCTAssertEqual(observation.reads, 21)
            XCTAssertEqual(promptInput.evidenceRegistry.evidenceIDs, [
                "locus:MHC-A",
                "o1",
                "sample:LF2823",
            ])
            let result = AIHaplotypingStructuredResult(
                schemaVersion: 1,
                run: promptInput.expectedRun,
                registryDigest: promptInput.expectedRun.registryDigest,
                inputSnapshotDigest: promptInput.expectedRun.inputSnapshotDigest,
                chunkID: promptInput.chunkID,
                discoveredDefinitions: [],
                calls: [
                    Self.structuredCall(
                        sample: "LF2823",
                        locus: "MHC-A",
                        slot: "h1",
                        label: "M4A",
                        evidenceID: "o1"
                    ),
                ],
                warnings: []
            )
            return try Self.response(
                request: request,
                result: result
            )
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)

        let output = try await runner.run(
            result: makeResult(
                calls: [makeCall(sample: "LF2823", genotype: Self.mcm0069Header)],
                haplotypeDefinitionSetID: preset.haplotypeDefinitionSetID
            ),
            sidecar: nil,
            options: AIHaplotypingRunOptions(
                mode: .aiDiscovery,
                providerID: .openAI,
                promptTemplateID: preset.aiPromptTemplateID(for: .aiDiscovery),
                promptTemplateVersion: preset.aiPromptTemplateVersion,
                maxObservationsPerChunk: 16,
                includeKnowledgePack: false
            )
        )

        XCTAssertEqual(output.chunkOutputs.map(\.promptMetadata.promptTemplateID), [
            preset.aiPromptTemplateID(for: .aiDiscovery),
        ])
        XCTAssertNil(output.chunkOutputs[0].promptMetadata.knowledgePackID)
        XCTAssertNil(output.chunkOutputs[0].promptMetadata.knowledgePackVersion)
        XCTAssertNil(output.chunkOutputs[0].promptMetadata.knowledgePackDigest)
        XCTAssertEqual(output.chunkOutputs[0].promptMetadata.promptTemplateVersion, preset.aiPromptTemplateVersion)
        XCTAssertEqual(output.normalizedCalls.first?.supportEvidenceRefs, [
            "obs:LF2823:MHC-A:\(Self.mcm0069Header)",
        ])
        XCTAssertEqual(output.normalizedCalls.first?.aiMetadata.supportEvidenceRefs, [
            "obs:LF2823:MHC-A:\(Self.mcm0069Header)",
        ])
    }

    func testRunnerEnablesPromptCacheRetentionForOpenAIGPT55MCMSpecialistRuns() async throws {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        let provider = MockStructuredProvider(modelId: "gpt-5.5") { request in
            XCTAssertEqual(request.promptCacheRetention, "24h")
            XCTAssertEqual(request.promptCacheKey, "mcm-mhc-miseq-specialist-2026-06-19-1")
            let promptInput = try Self.compactPromptInput(from: request)
            XCTAssertEqual(promptInput.expectedRun.generationParameters["promptCacheRetention"], "24h")
            XCTAssertEqual(
                promptInput.expectedRun.generationParameters["promptCacheKey"],
                "mcm-mhc-miseq-specialist-2026-06-19-1"
            )
            let result = AIHaplotypingStructuredResult(
                schemaVersion: 1,
                run: promptInput.expectedRun,
                registryDigest: promptInput.expectedRun.registryDigest,
                inputSnapshotDigest: promptInput.expectedRun.inputSnapshotDigest,
                chunkID: promptInput.chunkID,
                discoveredDefinitions: [],
                calls: [
                    Self.structuredCall(
                        sample: "LF2823",
                        locus: "MHC-A",
                        slot: "h1",
                        label: "M4A",
                        evidenceID: "o1"
                    ),
                ],
                warnings: []
            )
            return try Self.response(
                request: request,
                result: result,
                providerAttempt: Self.attemptMetadata(request: request, model: "gpt-5.5")
            )
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)

        _ = try await runner.run(
            result: makeResult(
                calls: [makeCall(sample: "LF2823", genotype: Self.mcm0069Header)],
                haplotypeDefinitionSetID: preset.haplotypeDefinitionSetID
            ),
            sidecar: nil,
            options: AIHaplotypingRunOptions(
                mode: .aiDiscovery,
                providerID: .openAI,
                promptTemplateID: preset.aiPromptTemplateID(for: .aiDiscovery),
                promptTemplateVersion: preset.aiPromptTemplateVersion,
                maxObservationsPerChunk: 16,
                reasoningEffort: "medium",
                includeKnowledgePack: false
            )
        )
    }

    func testRunnerStampsExpectedRunMetadataBeforeValidation() async throws {
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

        let output = try await runner.run(
            result: makeResult(calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")]),
            sidecar: nil,
            options: AIHaplotypingRunOptions(
                mode: .aiDiscovery,
                providerID: .openAI,
                credentialSource: .environmentOpenAI,
                maxObservationsPerChunk: 1
            )
        )

        let requests = await provider.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let expectedRun = try Self.expectedRun(from: request)
        XCTAssertEqual(output.validationReports.map(\.accepted), [true])
        XCTAssertEqual(output.validationReports[0].run, expectedRun)
        XCTAssertEqual(output.chunkOutputs[0].promptMetadata.promptHash, expectedRun.promptHash)
    }

    func testRefinementUnresolvedOnlyScopeSkipsFullyCalledCurrentLoci() async throws {
        let provider = MockStructuredProvider { request in
            let registry = try Self.registry(from: request)
            let sample = try XCTUnwrap(registry.samples.first?.sample)
            let (locus, observationID) = try Self.firstObservationLocusAndID(in: registry)
            XCTAssertEqual(sample, "DW473")
            XCTAssertEqual(locus, "MHC-A")
            return try Self.response(
                request: request,
                chunkID: "chunk-0001",
                registry: registry,
                calls: [
                    Self.structuredCall(
                        sample: sample,
                        locus: locus,
                        slot: "h1",
                        label: "M4A",
                        evidenceID: observationID
                    ),
                ]
            )
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Test definitions",
            speciesName: "Macaca fascicularis",
            generatedAt: "2026-06-18T00:00:00Z",
            analysisRevisionID: "deterministic-1",
            source: .deterministic,
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "MHC-B",
                            haplotype1: "M9B",
                            haplotype2: "M7B",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_001_01"]
                        ),
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW473",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "ERR: TMH (M2, M4)",
                            haplotype2: "ERR: TMH (M2, M4)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M4_A1_031_01"]
                        ),
                    ]
                ),
            ]
        )

        let output = try await runner.run(
            result: makeResult(
                calls: [
                    makeCall(sample: "DW472", genotype: "12_M9_B_001_01"),
                    makeCall(sample: "DW473", genotype: "05_M4_A1_031_01"),
                ],
                activeHaplotypeAnalysisRevisionID: "deterministic-1",
                haplotypeAnalysis: analysis
            ),
            sidecar: nil,
            options: AIHaplotypingRunOptions(
                mode: .aiRefinement,
                providerID: .openAI,
                maxObservationsPerChunk: 1,
                reviewScope: .unresolvedOnly
            )
        )

        let requests = await provider.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests[0].userPrompt.contains("DW472"))
        XCTAssertTrue(requests[0].userPrompt.contains("DW473"))
        XCTAssertEqual(output.registry.observations.map(\.sampleID), ["sample:DW473"])
        XCTAssertEqual(output.normalizedCalls.map(\.sample), ["DW473"])
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
            XCTAssertEqual(
                failure.message,
                "AI provider request for chunk-0001 failed: AI provider returned an HTTP error."
            )
            XCTAssertFalse(failure.message.contains("secret-token"))
            XCTAssertNil(failure.attemptMetadata)
        }
    }

    func testRunnerReportsInvalidStructuredProviderResponseDetail() async throws {
        let provider = MockStructuredProvider { _ in
            throw AIProviderError.invalidResponse(
                "Structured response was truncated before a complete JSON object was returned"
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
                    maxObservationsPerChunk: 10
                )
            )
            XCTFail("Expected provider failure")
        } catch let failure as AIHaplotypingRunFailure {
            XCTAssertEqual(failure.stage, .provider)
            XCTAssertEqual(failure.sanitizedErrorCategory, "invalid_response")
            XCTAssertTrue(failure.message.contains("truncated"))
            XCTAssertTrue(failure.message.contains("chunk-0001"))
        }
    }

    func testRunnerReportsNetworkProviderErrorDetail() async throws {
        let provider = MockStructuredProvider { _ in
            throw AIProviderError.networkError("The request timed out.")
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
            XCTAssertEqual(failure.sanitizedErrorCategory, "network_error")
            XCTAssertTrue(failure.message.contains("timed out"))
            XCTAssertTrue(failure.message.contains("chunk-0001"))
        }
    }

    func testRunnerRetriesTransientNetworkProviderErrors() async throws {
        let attempts = RetryAttemptCounter()
        let provider = MockStructuredProvider { request in
            let attempt = await attempts.next()
            if attempt == 1 {
                throw AIProviderError.networkError("The network connection was lost.")
            }
            let registry = try Self.registry(from: request)
            let sample = try XCTUnwrap(registry.samples.first?.sample)
            let (locus, observationID) = try Self.firstObservationLocusAndID(in: registry)
            return try Self.response(
                request: request,
                chunkID: "chunk-0001",
                registry: registry,
                calls: [
                    Self.structuredCall(
                        sample: sample,
                        locus: locus,
                        slot: "h1",
                        label: "M9B",
                        evidenceID: observationID
                    ),
                ]
            )
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)

        let output = try await runner.run(
            result: makeResult(calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")]),
            sidecar: nil,
            options: AIHaplotypingRunOptions(
                mode: .aiDiscovery,
                providerID: .openAI,
                maxObservationsPerChunk: 10,
                maxProviderRetries: 1
            )
        )

        let requests = await provider.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(output.providerAttempts.count, 1)
        XCTAssertEqual(output.chunkOutputs.count, 1)
        XCTAssertEqual(output.validationReports.map { $0.accepted }, [true])
        XCTAssertEqual(try Self.expectedRun(from: requests[0]).generationParameters["maxProviderRetries"], "1")
        XCTAssertEqual(try Self.expectedRun(from: requests[1]).generationParameters["maxProviderRetries"], "1")
    }

    func testRunnerRetriesRetryableStructuredValidationFailures() async throws {
        let attempts = RetryAttemptCounter()
        let provider = MockStructuredProvider { request in
            let attempt = await attempts.next()
            let registry = try Self.registry(from: request)
            let sample = try XCTUnwrap(registry.samples.first?.sample)
            let (locus, observationID) = try Self.firstObservationLocusAndID(in: registry)
            var result = try Self.structuredResult(
                request: request,
                chunkID: "chunk-0001",
                registry: registry,
                calls: [
                    Self.structuredCall(
                        sample: sample,
                        locus: locus,
                        slot: "h1",
                        label: "M9B",
                        evidenceID: observationID
                    ),
                ]
            )
            if attempt == 1 {
                result = AIHaplotypingStructuredResult(
                    schemaVersion: result.schemaVersion,
                    run: result.run,
                    registryDigest: "sha256:bad-registry-digest",
                    inputSnapshotDigest: result.inputSnapshotDigest,
                    chunkID: result.chunkID,
                    discoveredDefinitions: result.discoveredDefinitions,
                    calls: result.calls,
                    warnings: result.warnings
                )
            }
            return try Self.response(request: request, result: result)
        }
        let runner = AIHaplotypingRunner(provider: provider, promptRegistry: .builtIn)

        let output = try await runner.run(
            result: makeResult(calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")]),
            sidecar: nil,
            options: AIHaplotypingRunOptions(
                mode: .aiDiscovery,
                providerID: .openAI,
                maxObservationsPerChunk: 10,
                maxProviderRetries: 1
            )
        )

        let requests = await provider.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(output.chunkOutputs.count, 1)
        XCTAssertEqual(output.validationReports.map { $0.accepted }, [true])
    }

    func testRunnerEmitsProgressEventsForChunkLifecycleAndRetries() async throws {
        let attempts = RetryAttemptCounter()
        let events = LockedProgressEvents()
        let provider = MockStructuredProvider { request in
            let attempt = await attempts.next()
            if attempt == 1 {
                throw AIProviderError.networkError("The network connection was lost.")
            }
            let registry = try Self.registry(from: request)
            let sample = try XCTUnwrap(registry.samples.first?.sample)
            let (locus, observationID) = try Self.firstObservationLocusAndID(in: registry)
            return try Self.response(
                request: request,
                chunkID: "chunk-0001",
                registry: registry,
                calls: [
                    Self.structuredCall(
                        sample: sample,
                        locus: locus,
                        slot: "h1",
                        label: "M9B",
                        evidenceID: observationID
                    ),
                ]
            )
        }
        let runner = AIHaplotypingRunner(
            provider: provider,
            promptRegistry: .builtIn,
            progressHandler: { events.append($0) }
        )

        _ = try await runner.run(
            result: makeResult(calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")]),
            sidecar: nil,
            options: AIHaplotypingRunOptions(
                mode: .aiDiscovery,
                providerID: .openAI,
                maxObservationsPerChunk: 10,
                maxProviderRetries: 1
            )
        )

        XCTAssertEqual(events.snapshot(), [
            .runStarted(chunkCount: 1, observationCount: 1),
            .chunkStarted(chunkID: "chunk-0001", chunkIndex: 1, chunkCount: 1, observationCount: 1),
            .providerRetry(chunkID: "chunk-0001", retryIndex: 1, maxRetries: 1, errorCategory: "network_error"),
            .chunkFinished(chunkID: "chunk-0001", chunkIndex: 1, chunkCount: 1, callCount: 1, definitionCount: 0),
            .runFinished(chunkCount: 1, callCount: 1, definitionCount: 0),
        ])
    }

    func testRunnerCanStartAtLaterChunkForDebugSmokeRuns() async throws {
        let provider = MockStructuredProvider { request in
            let registry = try Self.registry(from: request)
            let sample = try XCTUnwrap(registry.samples.first?.sample)
            let (locus, observationID) = try Self.firstObservationLocusAndID(in: registry)
            return try Self.response(
                request: request,
                chunkID: "chunk-0002",
                registry: registry,
                calls: [
                    Self.structuredCall(
                        sample: sample,
                        locus: locus,
                        slot: "h1",
                        label: "M9B",
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
                maxObservationsPerChunk: 1,
                chunkStartIndex: 2,
                chunkEndIndex: 2
            )
        )

        let requests = await provider.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(output.chunkOutputs.map(\.chunkID), ["chunk-0002"])
        XCTAssertEqual(output.providerAttempts.map(\.attemptIndex), [1])
        XCTAssertEqual(output.normalizedCalls.count, 1)
    }

    func testRunnerRejectsDuplicateDiscoveredDefinitionsAcrossChunks() async throws {
        let provider = MockStructuredProvider { request in
            let registry = try Self.registry(from: request)
            let sample = try XCTUnwrap(registry.samples.first?.sample)
            let (locus, observationID) = try Self.firstObservationLocusAndID(in: registry)
            return try Self.response(
                request: request,
                chunkID: sample == "DW472" ? "chunk-0001" : "chunk-0002",
                registry: registry,
                discoveredDefinitions: [
                    Self.discoveredDefinition(locus: locus, evidenceID: observationID)
                ],
                calls: [
                    Self.structuredCall(
                        sample: sample,
                        locus: locus,
                        slot: "h1",
                        label: sample == "DW472" ? "M9B" : "M8A",
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

    private func makeResult(
        calls: [ONTGenotypeCall],
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil,
        haplotypeDefinitionSetID: String = "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
    ) -> ONTGenotypeResultBundleData {
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "out",
            analysisName: "Test",
            primaryWorkbookPath: "workbook.xlsx",
            longSummaryCSVPath: "long.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json",
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: "MHC-exon2-miSeq",
            activeHaplotypeAnalysisRevisionID: activeHaplotypeAnalysisRevisionID
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
            samples: [],
            haplotypeAnalysis: haplotypeAnalysis
        )
    }

    private static let mcm0069Header = "MCM_MHC_MiSeq_0069|source_loci=MHC-A1|haplotype_groups=MHC-A|haplotypes=M4|alleles=Mafa-A1_031:01:01:01|accessions=OR823430|length=156|evidence_classes=primary_expressed|max_evidence_weight=1.00|evidence_weight_sum=1.00"
}

private actor MockStructuredProvider: StructuredAIProvider {
    nonisolated let name = "OpenAI"
    nonisolated let modelId: String

    private let handler: @Sendable (AIStructuredRequest) async throws -> AIStructuredResponse
    private var requests: [AIStructuredRequest] = []

    init(
        modelId: String = "gpt-5-mini",
        handler: @escaping @Sendable (AIStructuredRequest) async throws -> AIStructuredResponse
    ) {
        self.modelId = modelId
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

private actor RetryAttemptCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private final class LockedProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AIHaplotypingProgressEvent] = []

    func append(_ event: AIHaplotypingProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [AIHaplotypingProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private extension AIHaplotypingRunnerTests {
    static func registry(from request: AIStructuredRequest) throws -> AIHaplotypingEvidenceRegistry {
        try promptInput(from: request).evidenceRegistry
    }

    static func expectedRun(from request: AIStructuredRequest) throws -> AIHaplotypingRunMetadata {
        try promptInputMetadata(from: request).expectedRun
    }

    static func firstObservationLocusAndID(
        in registry: AIHaplotypingEvidenceRegistry
    ) throws -> (locus: String, evidenceID: String) {
        let observation = try XCTUnwrap(registry.observations.first)
        let locus = try XCTUnwrap(
            registry.loci.first { $0.id == observation.locusID }?.locus
        )
        return (locus, observation.id)
    }

    static func promptInput(from request: AIStructuredRequest) throws -> PromptInput {
        try decodePromptInput(PromptInput.self, from: request)
    }

    static func compactPromptInput(from request: AIStructuredRequest) throws -> CompactPromptInput {
        try decodePromptInput(CompactPromptInput.self, from: request)
    }

    static func promptInputMetadata(from request: AIStructuredRequest) throws -> PromptInputMetadata {
        try decodePromptInput(PromptInputMetadata.self, from: request)
    }

    static func decodePromptInput<T: Decodable>(_ type: T.Type, from request: AIStructuredRequest) throws -> T {
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
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
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
            cachedInputTokens: nil,
            reasoningOutputTokens: nil,
            sanitizedErrorCategory: nil
        )
    }

    struct PromptInputMetadata: Decodable {
        let chunkID: String
        let expectedRun: AIHaplotypingRunMetadata
        let runContext: AIHaplotypingRunContext
        let knowledgePack: JSONValue?
    }

    struct PromptInput: Decodable {
        let chunkID: String
        let expectedRun: AIHaplotypingRunMetadata
        let runContext: AIHaplotypingRunContext
        let knowledgePack: AIHaplotypingKnowledgePack?
        let evidenceRegistry: AIHaplotypingEvidenceRegistry
    }

    struct CompactPromptInput: Decodable {
        let chunkID: String
        let expectedRun: AIHaplotypingRunMetadata
        let runContext: AIHaplotypingRunContext
        let knowledgePack: AIHaplotypingKnowledgePack?
        let evidenceRegistry: CompactEvidenceRegistry
    }

    struct CompactEvidenceRegistry: Decodable {
        let schemaVersion: Int
        let encoding: String
        let evidenceIDs: [String]
        let samples: [CompactSample]
        let loci: [CompactLocus]
        let observations: [CompactObservation]
    }

    struct CompactSample: Decodable {
        let id: String
        let sample: String
    }

    struct CompactLocus: Decodable {
        let id: String
        let locus: String
    }

    struct CompactObservation: Decodable {
        let id: String
        let sample: String
        let locus: String
        let target: String
        let genotype: String
        let reads: Int
    }
}
