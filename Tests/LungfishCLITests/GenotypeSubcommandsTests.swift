import XCTest
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class GenotypeSubcommandsTests: XCTestCase {
    func testCLIRegistersGenotypeCommandGroup() {
        let names = LungfishCLI.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("genotype"))
    }

    func testGenotypeGroupRegistersAllSubcommands() {
        let names = GenotypeCommandGroup.configuration.subcommands.map {
            $0.configuration.commandName
        }
        XCTAssertEqual(
            Set(names),
            [
                "list-samples", "list-cohorts", "ai-haplotyping", "apply-annotations",
                "replay-call-overrides", "replay-matrix-annotation",
                "replay-manual-haplotype-assignments",
                "export", "export-xlsx",
                "export-pivot-xlsx", "export-labkey"
            ]
        )
    }

    func testListSamplesParsesBundleOption() throws {
        let command = try GenotypeListSamplesSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
    }

    func testListSamplesRejectsEmptyBundle() {
        XCTAssertThrowsError(
            try GenotypeListSamplesSubcommand.parse(["--bundle", "   "]).validate()
        )
    }

    func testListCohortsParsesBundleOption() throws {
        let command = try GenotypeListCohortsSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
    }

    func testAIHaplotypingParsesModeProviderAndPromptPin() throws {
        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--mode", "ai-discovery",
            "--provider", "openai",
            "--model", "gpt-5-mini",
            "--prompt-template-id", "lungfish.ai-haplotyping.discovery",
            "--prompt-template-version", "2026-06-14.1",
            "--max-observations-per-chunk", "64",
            "--max-output-tokens", "2048",
            "--temperature", "0",
            "--reasoning-effort", "low",
            "--max-provider-retries", "3",
            "--review-scope", "unresolved-only",
            "--azure-openai-endpoint", "https://oc-aiservices.openai.azure.com",
            "--azure-openai-deployment", "gpt-5-mini",
        ])

        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
        XCTAssertEqual(command.mode, .aiDiscovery)
        XCTAssertEqual(command.provider, .openAI)
        XCTAssertEqual(command.model, "gpt-5-mini")
        XCTAssertEqual(command.promptTemplateID, "lungfish.ai-haplotyping.discovery")
        XCTAssertEqual(command.promptTemplateVersion, "2026-06-14.1")
        XCTAssertEqual(command.maxObservationsPerChunk, 64)
        XCTAssertEqual(command.maxOutputTokens, 2048)
        XCTAssertEqual(command.temperature, 0)
        XCTAssertEqual(command.reasoningEffort, "low")
        XCTAssertEqual(command.maxProviderRetries, 3)
        XCTAssertEqual(command.reviewScope, .unresolvedOnly)
        XCTAssertEqual(command.azureOpenAIEndpoint, "https://oc-aiservices.openai.azure.com")
        XCTAssertEqual(command.azureOpenAIDeployment, "gpt-5-mini")
    }

    func testAIHaplotypingDefaultsToSampleLevelReviewChunks() throws {
        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
        ])

        XCTAssertEqual(command.maxObservationsPerChunk, 10_000)
        XCTAssertEqual(command.provider, .openAI)
    }

    func testAIHaplotypingRejectsInvalidReasoningEffort() {
        XCTAssertThrowsError(
            try GenotypeAIHaplotypingSubcommand.parse([
                "--bundle", "/tmp/example.lungfishgenotype",
                "--provider", "openai",
                "--reasoning-effort", "maximum",
            ]).validate()
        )
    }

    func testAIHaplotypingParsesDebugChunkWindowOptions() throws {
        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--provider", "openai",
            "--chunk-start-index", "62",
            "--chunk-end-index", "99",
            "--debug-output", "/tmp/barcode05-ai-debug.json",
        ])

        XCTAssertEqual(command.chunkStartIndex, 62)
        XCTAssertEqual(command.chunkEndIndex, 99)
        XCTAssertEqual(command.debugOutput, "/tmp/barcode05-ai-debug.json")
    }

    func testAIHaplotypingCredentialResolutionPrefersEnvironmentThenFallsBackToKeychain() async throws {
        let environmentCredential = try await GenotypeAIHaplotypingSubcommand.resolveCredential(
            provider: .openAI,
            environment: ["OPENAI_API_KEY": " env-key "],
            keychainLookup: { _ in "keychain-key" }
        )
        XCTAssertEqual(environmentCredential.apiKey, "env-key")
        XCTAssertEqual(environmentCredential.source, .environmentOpenAI)

        let keychainCredential = try await GenotypeAIHaplotypingSubcommand.resolveCredential(
            provider: .openAI,
            environment: [:],
            keychainLookup: { key in
                XCTAssertEqual(key, KeychainSecretStorage.openAIAPIKey)
                return " keychain-key "
            }
        )
        XCTAssertEqual(keychainCredential.apiKey, "keychain-key")
        XCTAssertEqual(keychainCredential.source, .keychainOpenAI)
    }

    func testAIHaplotypingAzureCredentialResolutionPrefersAzureEnvironment() async throws {
        let azureCredential = try await GenotypeAIHaplotypingSubcommand.resolveCredential(
            provider: .openAI,
            environment: [
                "OPENAI_API_KEY": " direct-key ",
                "AZURE_OPENAI_ENDPOINT": " https://oc-aiservices.openai.azure.com ",
                "AZURE_OPENAI_DEPLOYMENT": " gpt-5-mini ",
                "AZURE_OPENAI_API_KEY": " azure-key ",
            ],
            keychainLookup: { _ in "keychain-key" }
        )

        XCTAssertEqual(azureCredential.apiKey, "azure-key")
        XCTAssertEqual(azureCredential.source, .environmentAzureOpenAI)
    }

    func testAIHaplotypingRejectsPartialChunkWindowWithoutDebugOutput() {
        XCTAssertThrowsError(
            try GenotypeAIHaplotypingSubcommand.parse([
                "--bundle", "/tmp/example.lungfishgenotype",
                "--chunk-start-index", "62",
            ]).validate()
        )
        XCTAssertThrowsError(
            try GenotypeAIHaplotypingSubcommand.parse([
                "--bundle", "/tmp/example.lungfishgenotype",
                "--chunk-end-index", "99",
            ]).validate()
        )
    }

    func testAIHaplotypingParsesPromptPreviewInputTableOptions() throws {
        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--input-table", "/tmp/mcm-calls.csv",
            "--preview-prompt",
            "--output", "/tmp/prompt-preview.json",
            "--mode", "ai-discovery",
            "--population", "mcm",
            "--assay-resolution", "short-exon-amplicon",
            "--haplotype-definition", "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            "--haplotype-assay", "MHC-exon2-miSeq",
        ])

        XCTAssertNil(command.bundle)
        XCTAssertEqual(command.inputTable, "/tmp/mcm-calls.csv")
        XCTAssertTrue(command.previewPrompt)
        XCTAssertEqual(command.output, "/tmp/prompt-preview.json")
        XCTAssertEqual(command.population, "mcm")
        XCTAssertEqual(command.assayResolution, "short-exon-amplicon")
        XCTAssertEqual(command.haplotypeDefinition, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
        XCTAssertEqual(command.haplotypeAssay, "MHC-exon2-miSeq")
    }

    func testAIHaplotypingPromptPreviewBuildsFromCSVWithoutProviderCredentials() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIHaplotypingPromptPreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputURL = root.appendingPathComponent("mcm-calls.csv")
        try """
        sample,genotype,passedAlignments,passedUniqueReads,sampleUniqueRetainedReads
        B25276,05_M1M2M3_A1_063g,174,174,13924
        B25276,07_M3_70_156bp,25,25,13924
        """.write(to: inputURL, atomically: true, encoding: .utf8)

        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--input-table", inputURL.path,
            "--preview-prompt",
            "--mode", "ai-discovery",
            "--provider", "openai",
            "--model", "gpt-5-mini",
            "--population", "mcm",
            "--assay-resolution", "short-exon-amplicon",
            "--max-observations-per-chunk", "16",
        ])

        let preview = try command.buildPromptPreview()

        XCTAssertEqual(preview.mode, .aiDiscovery)
        XCTAssertEqual(preview.runContext.populationHint, "mcm")
        XCTAssertEqual(preview.runContext.assayResolution, "short_exon_amplicon")
        XCTAssertEqual(preview.chunkCount, 1)
        XCTAssertEqual(preview.observationCount, 2)
        XCTAssertEqual(preview.promptTemplate.version, "2026-06-18.3")
        XCTAssertEqual(try XCTUnwrap(preview.knowledgePack).version, "2026-06-17.3")
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("DP/DQ linkage"))
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("population novelty prior"))
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("05_M1M2M3_A1_063g"))
        XCTAssertTrue(preview.chunks[0].evidenceRegistry.evidenceIDs.contains("obs:B25276:MHC-A:05_M1M2M3_A1_063g"))
    }

    func testAIHaplotypingPromptPreviewUsesMCMSpecialistPromptWithoutKnowledgePackForPresetDefinition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIHaplotypingPromptPreviewMCMSpecialist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputURL = root.appendingPathComponent("mcm-calls.csv")
        try """
        sample,genotype,passedAlignments,passedUniqueReads,sampleUniqueRetainedReads
        LF2823,MCM_MHC_MiSeq_0069[MHC-A1],174,174,13924
        """.write(to: inputURL, atomically: true, encoding: .utf8)
        let preset = MCMHaplotypingPreset.mcmMHCmiseq

        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--input-table", inputURL.path,
            "--preview-prompt",
            "--mode", "ai-discovery",
            "--provider", "openai",
            "--model", "gpt-5.5",
            "--haplotype-definition", preset.haplotypeDefinitionSetID,
            "--haplotype-assay", preset.haplotypeAssayID,
            "--max-observations-per-chunk", "16",
        ])

        let preview = try command.buildPromptPreview()
        let promptInput = try Self.promptInput(from: preview.chunks[0].userPrompt)

        XCTAssertEqual(preview.promptTemplate.id, preset.aiPromptTemplateID(for: .aiDiscovery))
        XCTAssertEqual(preview.promptTemplate.version, preset.aiPromptTemplateVersion)
        XCTAssertNil(preview.knowledgePack)
        XCTAssertNil(preview.chunks[0].promptMetadata.knowledgePackID)
        XCTAssertNil(promptInput.knowledgePack)
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("MCM MHC MiSeq Haplotyping Specialist Prompt"))
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("M4 and M7 have the same MHC-DP genotypes"))
        XCTAssertFalse(preview.chunks[0].userPrompt.contains("\"knowledgePack\""))
    }

    func testAIHaplotypingPromptPreviewCanCompactKnowledgePackForSmokeRuns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIHaplotypingPromptPreviewCompact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputURL = root.appendingPathComponent("mcm-calls.csv")
        try """
        sample,genotype,passedAlignments,passedUniqueReads,sampleUniqueRetainedReads
        B25276,05_M1M2M3_A1_063g,174,174,13924
        B25276,07_M3_70_156bp,25,25,13924
        """.write(to: inputURL, atomically: true, encoding: .utf8)

        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--input-table", inputURL.path,
            "--preview-prompt",
            "--mode", "ai-discovery",
            "--provider", "openai",
            "--model", "gpt-5-mini",
            "--population", "mcm",
            "--assay-resolution", "short-exon-amplicon",
            "--max-observations-per-chunk", "16",
            "--compact-knowledge-pack",
        ])

        let preview = try command.buildPromptPreview()

        let promptInput = try Self.promptInput(from: preview.chunks[0].userPrompt)

        let previewKnowledgePack = try XCTUnwrap(preview.knowledgePack)
        let promptKnowledgePack = try XCTUnwrap(promptInput.knowledgePack)
        XCTAssertTrue(previewKnowledgePack.digest.hasPrefix("sha256:"))
        XCTAssertEqual(previewKnowledgePack.digest.count, "sha256:".count + 64)
        XCTAssertLessThan(
            promptKnowledgePack.haplotypeBlockDefinitions.count,
            previewKnowledgePack.haplotypeBlockDefinitionCount
        )
        XCTAssertLessThan(preview.chunks[0].userPrompt.count, 80_000)
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("\"haplotypeBlockDefinitions\""))
        XCTAssertFalse(preview.chunks[0].userPrompt.contains("\"legacyBlockDefinitions\""))
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("05_M1M2M3_A1_063g"))
        XCTAssertTrue(promptKnowledgePack.haplotypeBlockDefinitions.contains { $0.reportLabel == "M3A" })
        XCTAssertFalse(Self.knowledgePackRecordText(promptKnowledgePack).contains("A008.01"))
    }

    func testAIHaplotypingPromptPreviewWritesProvenanceSidecarForOutputFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIHaplotypingPromptPreviewOutput-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputURL = root.appendingPathComponent("mamu-calls.tsv")
        let outputURL = root.appendingPathComponent("prompt-preview.json")
        try """
        sample\tgenotype\treads
        R001\tMamu-A1_001g1\t99
        """.write(to: inputURL, atomically: true, encoding: .utf8)

        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--input-table", inputURL.path,
            "--preview-prompt",
            "--output", outputURL.path,
            "--mode", "ai-discovery",
            "--population", "indian-rhesus",
            "--assay-resolution", "short-exon-amplicon",
            "--haplotype-definition", "MHC-exon2-miSeq.indian-rhesus",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--max-observations-per-chunk", "32",
            "--max-output-tokens", "2048",
            "--temperature", "0.1",
            "--compact-knowledge-pack",
        ])
        try await command.run()

        let preview = try JSONDecoder().decode(AIHaplotypingCLIPromptPreview.self, from: Data(contentsOf: outputURL))
        XCTAssertEqual(preview.runContext.populationHint, "indian-rhesus")
        XCTAssertEqual(preview.observationCount, 1)

        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.workflowName, "lungfish genotype ai-haplotyping preview-prompt")
        XCTAssertTrue(envelope.argv.contains("--input-table"))
        XCTAssertTrue(envelope.files.contains { $0.path == inputURL.path && $0.role == .input })
        XCTAssertTrue(envelope.files.contains { $0.path == outputURL.path && $0.role == .output })
        XCTAssertEqual(envelope.options.explicit["compactKnowledgePack"], .string("true"))
        XCTAssertEqual(envelope.options.explicit["maxObservationsPerChunk"], .integer(32))
        XCTAssertEqual(envelope.options.explicit["maxOutputTokens"], .integer(2048))
        XCTAssertEqual(envelope.options.explicit["temperature"], .number(0.1))
        XCTAssertEqual(envelope.options.explicit["promptTemplateID"], .null)
        XCTAssertEqual(envelope.options.explicit["promptTemplateVersion"], .null)
        XCTAssertEqual(envelope.options.explicit["assayResolution"], .string("short-exon-amplicon"))
        XCTAssertEqual(envelope.options.explicit["haplotypeDefinition"], .string("MHC-exon2-miSeq.indian-rhesus"))
        XCTAssertEqual(envelope.options.explicit["haplotypeAssay"], .string("MHC-exon2-miSeq"))
        XCTAssertEqual(envelope.options.resolvedDefaults["maxObservationsPerChunk"], .integer(32))
        XCTAssertEqual(envelope.options.resolvedDefaults["compactKnowledgePack"], .string("true"))
    }

    func testAIHaplotypingDebugOutputWritesJSONAndProvenanceSidecar() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIHaplotypingDebugOutput-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let outputURL = root.appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("barcode05-chunk-62.json")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--bundle", bundleURL.path,
            "--mode", "ai-refinement",
            "--provider", "openai",
            "--model", "gpt-5-mini",
            "--chunk-start-index", "62",
            "--chunk-end-index", "62",
            "--debug-output", outputURL.path,
            "--compact-knowledge-pack",
            "--max-provider-retries", "5",
        ])
        let runnerOutput = AIHaplotypingRunnerOutput(
            mode: .aiRefinement,
            registry: AIHaplotypingEvidenceRegistry(
                mode: .aiRefinement,
                parentRevisionID: "deterministic-parent",
                inputSnapshotDigest: "sha256:input",
                samples: [],
                loci: [],
                observations: [],
                digest: "sha256:registry"
            ),
            chunkOutputs: [],
            normalizedCalls: [],
            validatedDefinitions: [],
            validationReports: [],
            providerAttempts: []
        )

        let summary = try await command.writeDebugOutput(
            bundleURL: bundleURL,
            runnerOutput: runnerOutput,
            modelID: "gpt-5-mini",
            credentialSource: AIHaplotypingCredentialSource.environmentOpenAI.rawValue,
            promptSelection: AIHaplotypingPromptSelection(
                promptTemplateID: command.promptTemplateID,
                promptTemplateVersion: command.promptTemplateVersion,
                includeKnowledgePack: true,
                compactKnowledgePack: command.compactKnowledgePack,
                usesSpecialistPrompt: false
            ),
            startedAt: Date()
        )

        XCTAssertEqual(summary.debugOutput, outputURL.path)
        XCTAssertEqual(summary.chunkStartIndex, 62)
        XCTAssertEqual(summary.chunkEndIndex, 62)
        XCTAssertEqual(summary.callCount, 0)
        XCTAssertEqual(summary.chunkCount, 0)

        let artifact = try JSONDecoder().decode(
            AIHaplotypingCLIDebugOutput.self,
            from: Data(contentsOf: outputURL)
        )
        XCTAssertEqual(artifact.summary, summary)
        XCTAssertEqual(artifact.runnerOutput.registry.digest, "sha256:registry")

        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.workflowName, "lungfish genotype ai-haplotyping debug-output")
        XCTAssertTrue(envelope.argv.contains("--debug-output"))
        XCTAssertTrue(envelope.argv.contains("--chunk-start-index"))
        XCTAssertTrue(envelope.files.contains { $0.path == bundleURL.path && $0.role == .input })
        XCTAssertTrue(envelope.files.contains { $0.path == outputURL.path && $0.role == .output })
        XCTAssertEqual(envelope.options.explicit["chunkStartIndex"], .integer(62))
        XCTAssertEqual(envelope.options.explicit["chunkEndIndex"], .integer(62))
        XCTAssertEqual(envelope.options.explicit["compactKnowledgePack"], .string("true"))
        XCTAssertEqual(envelope.options.resolvedDefaults["model"], .string("gpt-5-mini"))
        XCTAssertEqual(envelope.options.resolvedDefaults["debugOutput"], .file(outputURL))
    }

    func testAIHaplotypingAzureOptionsAreRecordedInDebugProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIHaplotypingDebugOutputAzure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let outputURL = root.appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("barcode05-chunk-62.json")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--bundle", bundleURL.path,
            "--mode", "ai-refinement",
            "--provider", "openai",
            "--debug-output", outputURL.path,
            "--azure-openai-endpoint", "https://oc-aiservices.openai.azure.com/",
            "--azure-openai-deployment", "gpt-5-mini",
        ])
        let runnerOutput = AIHaplotypingRunnerOutput(
            mode: .aiRefinement,
            registry: AIHaplotypingEvidenceRegistry(
                mode: .aiRefinement,
                parentRevisionID: "deterministic-parent",
                inputSnapshotDigest: "sha256:input",
                samples: [],
                loci: [],
                observations: [],
                digest: "sha256:registry"
            ),
            chunkOutputs: [],
            normalizedCalls: [],
            validatedDefinitions: [],
            validationReports: [],
            providerAttempts: []
        )

        _ = try await command.writeDebugOutput(
            bundleURL: bundleURL,
            runnerOutput: runnerOutput,
            modelID: "gpt-5-mini",
            credentialSource: AIHaplotypingCredentialSource.environmentAzureOpenAI.rawValue,
            promptSelection: AIHaplotypingPromptSelection(
                promptTemplateID: command.promptTemplateID,
                promptTemplateVersion: command.promptTemplateVersion,
                includeKnowledgePack: true,
                compactKnowledgePack: command.compactKnowledgePack,
                usesSpecialistPrompt: false
            ),
            startedAt: Date()
        )

        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertTrue(envelope.argv.contains("--azure-openai-endpoint"))
        XCTAssertTrue(envelope.argv.contains("--azure-openai-deployment"))
        XCTAssertFalse(envelope.argv.contains("--azure-openai-api-version"))
        XCTAssertFalse(envelope.argv.contains("azure-key"))
        XCTAssertEqual(envelope.options.explicit["azureOpenAIEndpoint"], .string("https://oc-aiservices.openai.azure.com"))
        XCTAssertEqual(envelope.options.explicit["azureOpenAIDeployment"], .string("gpt-5-mini"))
        XCTAssertNil(envelope.options.explicit["azureOpenAIAPIVersion"])
        XCTAssertEqual(envelope.options.resolvedDefaults["azureOpenAIEndpoint"], .string("https://oc-aiservices.openai.azure.com"))
        XCTAssertEqual(envelope.options.resolvedDefaults["azureOpenAIDeployment"], .string("gpt-5-mini"))
        XCTAssertNil(envelope.options.resolvedDefaults["azureOpenAIAPIVersion"])
        XCTAssertEqual(envelope.options.resolvedDefaults["credentialSource"], .string("environment:AZURE_OPENAI_API_KEY"))
    }

    func testAIHaplotypingAzureV1DefaultOmitsAPIVersionFlagInDebugProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIHaplotypingDebugOutputAzureV1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let outputURL = root.appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("barcode05-chunk-62.json")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let command = try GenotypeAIHaplotypingSubcommand.parse([
            "--bundle", bundleURL.path,
            "--mode", "ai-refinement",
            "--provider", "openai",
            "--debug-output", outputURL.path,
            "--azure-openai-endpoint", "https://oc-aiservices.cognitiveservices.azure.com/",
            "--azure-openai-deployment", "gpt-5-5",
        ])
        let runnerOutput = AIHaplotypingRunnerOutput(
            mode: .aiRefinement,
            registry: AIHaplotypingEvidenceRegistry(
                mode: .aiRefinement,
                parentRevisionID: "deterministic-parent",
                inputSnapshotDigest: "sha256:input",
                samples: [],
                loci: [],
                observations: [],
                digest: "sha256:registry"
            ),
            chunkOutputs: [],
            normalizedCalls: [],
            validatedDefinitions: [],
            validationReports: [],
            providerAttempts: []
        )

        _ = try await command.writeDebugOutput(
            bundleURL: bundleURL,
            runnerOutput: runnerOutput,
            modelID: "gpt-5-5",
            credentialSource: AIHaplotypingCredentialSource.environmentAzureOpenAI.rawValue,
            promptSelection: AIHaplotypingPromptSelection(
                promptTemplateID: command.promptTemplateID,
                promptTemplateVersion: command.promptTemplateVersion,
                includeKnowledgePack: true,
                compactKnowledgePack: command.compactKnowledgePack,
                usesSpecialistPrompt: false
            ),
            startedAt: Date()
        )

        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertTrue(envelope.argv.contains("--azure-openai-endpoint"))
        XCTAssertTrue(envelope.argv.contains("--azure-openai-deployment"))
        XCTAssertFalse(envelope.argv.contains("--azure-openai-api-version"))
        XCTAssertEqual(envelope.options.explicit["azureOpenAIEndpoint"], .string("https://oc-aiservices.cognitiveservices.azure.com"))
        XCTAssertEqual(envelope.options.explicit["azureOpenAIDeployment"], .string("gpt-5-5"))
        XCTAssertNil(envelope.options.explicit["azureOpenAIAPIVersion"])
        XCTAssertEqual(envelope.options.resolvedDefaults["azureOpenAIEndpoint"], .string("https://oc-aiservices.cognitiveservices.azure.com"))
        XCTAssertEqual(envelope.options.resolvedDefaults["azureOpenAIDeployment"], .string("gpt-5-5"))
        XCTAssertNil(envelope.options.resolvedDefaults["azureOpenAIAPIVersion"])
    }

    func testAIHaplotypingRequiresPromptTemplateIDAndVersionTogether() {
        XCTAssertThrowsError(try GenotypeAIHaplotypingSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--prompt-template-id", "lungfish.ai-haplotyping.discovery",
        ]).validate())
        XCTAssertThrowsError(try GenotypeAIHaplotypingSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--prompt-template-version", "2026-06-14.1",
        ]).validate())
    }

    func testApplyAnnotationsParsesBundleAndPatch() throws {
        let command = try GenotypeApplyAnnotationsSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--patch", "/tmp/patch.json",
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
        XCTAssertEqual(command.patch, "/tmp/patch.json")
    }

    func testApplyAnnotationsRejectsEmptyPatch() {
        XCTAssertThrowsError(
            try GenotypeApplyAnnotationsSubcommand.parse([
                "--bundle", "/tmp/example.lungfishgenotype",
                "--patch", "",
            ]).validate()
        )
    }

    func testApplyAnnotationsWritesAnnotationSidecarProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeApplyAnnotationsProvenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
            .encoded()
            .write(to: annotationURL)
        var patch = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        patch.sampleNotes = [
            GenotypeAnnotationSidecar.SampleNote(
                sample: "DW472",
                body: "manual review",
                author: "analyst",
                timestamp: "2026-05-23T00:01:00Z"
            )
        ]
        let patchURL = root.appendingPathComponent("patch.json")
        try patch.encoded().write(to: patchURL)

        let command = try GenotypeApplyAnnotationsSubcommand.parse([
            "--bundle", bundleURL.path,
            "--patch", patchURL.path,
        ])
        try await command.run()

        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.workflowName, "lungfish genotype apply-annotations")
        XCTAssertEqual(envelope.argv, [
            "lungfish-cli",
            "genotype",
            "apply-annotations",
            "--bundle", bundleURL.path,
            "--patch", patchURL.path,
        ])
        XCTAssertTrue(envelope.files.contains { file in
            file.path == patchURL.path && file.role == .input && file.checksumSHA256 != nil
        })
        XCTAssertTrue(envelope.files.contains { file in
            file.path == annotationURL.path && file.role == .output && file.checksumSHA256 != nil
        })
        XCTAssertEqual(envelope.options.explicit["appendedSampleNotes"], .integer(1))
    }

    func testMergeAppendsNewEntriesAndSkipsDuplicates() throws {
        let now = "2026-05-22T10:00:00Z"
        let later = "2026-05-22T11:00:00Z"

        let existingOverride = GenotypeAnnotationSidecar.CallOverride(
            sample: "H1", locus: "MHC-A", slot: .h1,
            originalCall: "Mafa-A1*063:02_M1A", overrideCall: "Mafa-A1*063:03_M1A",
            reasonTag: .misCall, rationale: "Manual review",
            author: "alice", timestamp: now
        )

        let duplicateOverride = existingOverride
        let newOverride = GenotypeAnnotationSidecar.CallOverride(
            sample: "H2", locus: "MHC-A", slot: .h1,
            originalCall: "Mafa-A1*063:02_M1A", overrideCall: "Mafa-A1*063:03_M1A",
            reasonTag: .misCall, rationale: "Manual review",
            author: "alice", timestamp: later
        )

        let existing = GenotypeAnnotationSidecar(
            schemaVersion: GenotypeAnnotationSidecar.currentSchemaVersion,
            generatedAt: now,
            lastEditedAt: nil, lastEditor: nil,
            callOverrides: [existingOverride], cellHighlights: [], rowHighlights: [],
            sampleNotes: [], cellComments: [],
            sampleStatusFlags: [], callStatusFlags: [],
            smartCohorts: [], manualHaplotypeAssignments: [],
            settings: .default, auditLog: []
        )

        let patch = GenotypeAnnotationSidecar(
            schemaVersion: GenotypeAnnotationSidecar.currentSchemaVersion,
            generatedAt: now,
            lastEditedAt: nil, lastEditor: nil,
            callOverrides: [duplicateOverride, newOverride],
            cellHighlights: [], rowHighlights: [],
            sampleNotes: [], cellComments: [],
            sampleStatusFlags: [], callStatusFlags: [],
            smartCohorts: [], manualHaplotypeAssignments: [],
            settings: .default, auditLog: []
        )

        let result = try GenotypeApplyAnnotationsSubcommand.merge(existing: existing, patch: patch)
        XCTAssertEqual(result.sidecar.callOverrides.count, 2)
        XCTAssertEqual(result.appendedCounts.callOverrides, 1)
        XCTAssertEqual(result.skippedDuplicateCounts.callOverrides, 1)
    }

    func testMergeIncludesMatrixStylesAndComments() throws {
        let now = "2026-06-30T10:00:00Z"
        let later = "2026-06-30T10:05:00Z"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-B",
            genotype: "Mamu-I*expected",
            sample: "AR3628"
        )
        var existing = GenotypeAnnotationSidecar.empty(generatedAt: now)
        existing.matrixStyles = [
            .init(
                target: target,
                style: .init(fillColor: "#FFF2CC"),
                author: "alice",
                timestamp: now
            )
        ]
        existing.matrixComments = [
            .init(target: target, body: "Expected genotype.", author: "alice", timestamp: now)
        ]

        var patch = GenotypeAnnotationSidecar.empty(generatedAt: later)
        patch.matrixStyles = [
            .init(
                target: target,
                style: .init(fillColor: "#D9EAD3", textColor: "#C00000", isBold: true),
                author: "alice",
                timestamp: later
            )
        ]
        patch.matrixComments = [
            .init(target: target, body: "Expected genotype.", author: "alice", timestamp: now),
            .init(target: .row(locus: "MHC-B", genotype: "Mamu-I*expected"), body: "Review row.", author: "bob", timestamp: later),
        ]

        let result = try GenotypeApplyAnnotationsSubcommand.merge(existing: existing, patch: patch)

        XCTAssertEqual(result.sidecar.matrixStyles.count, 1)
        XCTAssertEqual(result.sidecar.matrixStyles.first?.style.fillColor, "#D9EAD3")
        XCTAssertEqual(result.sidecar.matrixStyles.first?.style.textColor, "#C00000")
        XCTAssertEqual(result.sidecar.matrixComments.count, 2)
        XCTAssertEqual(result.appendedCounts.matrixStyles, 1)
        XCTAssertEqual(result.skippedDuplicateCounts.matrixStyles, 0)
        XCTAssertEqual(result.appendedCounts.matrixComments, 1)
        XCTAssertEqual(result.skippedDuplicateCounts.matrixComments, 1)
    }

    func testApplyAnnotationsMergesMatrixReviewsByExactTarget() throws {
        let firstTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*018:01:01:01_5nt_nov",
            sample: "AnimalA",
            stableClusterID: "cluster-a"
        )
        let sameGenotypeDifferentTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*018:01:01:01_5nt_nov",
            sample: "AnimalA",
            stableClusterID: "cluster-b"
        )
        var existing = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-01T00:00:00Z")
        let unrelatedReview = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: sameGenotypeDifferentTarget,
            disposition: .falsePositive,
            author: "carol",
            timestamp: "2026-07-01T10:05:00Z"
        )
        existing.matrixReviews = [
            .init(target: firstTarget, disposition: .falsePositive, author: "alice", timestamp: "2026-07-01T10:00:00Z"),
            unrelatedReview,
        ]
        var patch = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-01T11:00:00Z")
        patch.matrixReviews = [
            .init(target: firstTarget, disposition: .falseNegative, author: "bob", timestamp: "2026-07-01T11:00:00Z"),
        ]

        let result = try GenotypeApplyAnnotationsSubcommand.merge(existing: existing, patch: patch)

        XCTAssertEqual(result.sidecar.matrixReviews.count, 2)
        XCTAssertEqual(result.sidecar.matrixReviews.first { $0.target == firstTarget }?.disposition, .falseNegative)
        XCTAssertEqual(result.sidecar.matrixReviews.first { $0.target == sameGenotypeDifferentTarget }, unrelatedReview)
        XCTAssertEqual(result.appendedCounts.matrixReviews, 1)
    }

    func testApplyAnnotationsAdvancesV1SidecarSchemaForReviewPatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeApplyAnnotationsSchemaUpgrade-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)

        let existingV1Data = Data("""
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-01T00:00:00Z"
        }
        """.utf8)
        try existingV1Data.write(to: annotationURL)
        XCTAssertEqual(
            try GenotypeAnnotationSidecar.decode(Data(contentsOf: annotationURL)).schemaVersion,
            1
        )

        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*018:01:01:01_5nt_nov",
            sample: "AnimalA",
            stableClusterID: "cluster-a"
        )
        var patch = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-01T11:00:00Z")
        patch.matrixReviews = [
            .init(target: target, disposition: .falseNegative, author: "bob", timestamp: "2026-07-01T11:00:00Z"),
        ]
        let patchURL = root.appendingPathComponent("patch.json")
        try patch.encoded().write(to: patchURL)

        let command = try GenotypeApplyAnnotationsSubcommand.parse([
            "--bundle", bundleURL.path,
            "--patch", patchURL.path,
        ])
        try await command.run()

        let stored = try GenotypeAnnotationSidecar.decode(Data(contentsOf: annotationURL))
        XCTAssertEqual(stored.schemaVersion, GenotypeAnnotationSidecar.currentSchemaVersion)
        XCTAssertEqual(stored.matrixReviews, patch.matrixReviews)

        var newerExisting = stored
        newerExisting.schemaVersion = GenotypeAnnotationSidecar.currentSchemaVersion + 1
        XCTAssertThrowsError(
            try GenotypeApplyAnnotationsSubcommand.merge(
                existing: newerExisting,
                patch: patch
            )
        ) { error in
            XCTAssertEqual(
                error as? GenotypeAnnotationSidecar.SchemaMutationError,
                .unsupportedFutureSchemaVersion(
                    found: newerExisting.schemaVersion,
                    current: GenotypeAnnotationSidecar.currentSchemaVersion
                )
            )
        }
    }

    func testApplyAnnotationsRejectsFutureSchemaBeforeDiskOrProvenanceWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeApplyAnnotationsFutureSchema-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "test.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let annotationURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        var future = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-01T00:00:00Z"
        )
        future.schemaVersion = GenotypeAnnotationSidecar.currentSchemaVersion + 1
        let originalData = try future.encoded()
        try originalData.write(to: annotationURL, options: .atomic)
        let originalHash = try ProvenanceFileHasher.sha256(of: annotationURL)

        let patch = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-01T11:00:00Z"
        )
        let patchURL = root.appendingPathComponent("patch.json")
        try patch.encoded().write(to: patchURL)
        let command = try GenotypeApplyAnnotationsSubcommand.parse([
            "--bundle", bundleURL.path,
            "--patch", patchURL.path,
        ])

        do {
            try await command.run()
            XCTFail("Expected a future-schema mutation error")
        } catch {
            XCTAssertEqual(
                error as? GenotypeAnnotationSidecar.SchemaMutationError,
                .unsupportedFutureSchemaVersion(
                    found: future.schemaVersion,
                    current: GenotypeAnnotationSidecar.currentSchemaVersion
                )
            )
        }

        XCTAssertEqual(try Data(contentsOf: annotationURL), originalData)
        XCTAssertEqual(
            try ProvenanceFileHasher.sha256(of: annotationURL),
            originalHash
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: provenanceURL.path))
    }

    func testApplyAnnotationsRejectsFutureSchemaInstalledAfterSnapshot() async throws {
        try await assertApplyAnnotationsRejectsConcurrentReplacement(
            replacementSchemaVersion:
                GenotypeAnnotationSidecar.currentSchemaVersion + 1,
            expectedError: { replacement, _ in
                .unsupportedFutureSchemaVersion(
                    found: replacement.schemaVersion,
                    current: GenotypeAnnotationSidecar.currentSchemaVersion
                )
            }
        )
    }

    func testApplyAnnotationsRejectsSupportedConcurrentChangeAfterSnapshot() async throws {
        try await assertApplyAnnotationsRejectsConcurrentReplacement(
            replacementSchemaVersion:
                GenotypeAnnotationSidecar.currentSchemaVersion,
            expectedError: nil
        )
    }

    private func assertApplyAnnotationsRejectsConcurrentReplacement(
        replacementSchemaVersion: Int,
        expectedError: ((
            GenotypeAnnotationSidecar,
            GenotypeAnnotationSidecarRevision
        ) -> GenotypeAnnotationSidecar.SchemaMutationError)?
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeApplyAnnotationsConcurrent-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "test.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let annotationURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let initial = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-01T00:00:00Z"
        )
        try initial.encoded().write(to: annotationURL, options: .atomic)
        var replacement = initial
        replacement.schemaVersion = replacementSchemaVersion
        replacement.sampleNotes = [
            .init(
                sample: "Concurrent",
                body: "must survive",
                author: "other",
                timestamp: "2026-07-01T10:00:00Z"
            ),
        ]
        let replacementData = try replacement.encoded()
        let replacementRevision = GenotypeAnnotationSidecarRevision.sha256(
            SHA256.hash(data: replacementData)
                .map { String(format: "%02x", $0) }
                .joined()
        )
        var patch = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-01T11:00:00Z"
        )
        patch.sampleNotes = [
            .init(
                sample: "Patch",
                body: "stale",
                author: "analyst",
                timestamp: "2026-07-01T11:00:00Z"
            ),
        ]
        let patchURL = root.appendingPathComponent("patch.json")
        try patch.encoded().write(to: patchURL)

        do {
            _ = try await GenotypeApplyAnnotationsSubcommand.apply(
                bundleURL: bundleURL,
                patchURL: patchURL,
                beforePublication: {
                    try replacementData.write(
                        to: annotationURL,
                        options: .atomic
                    )
                }
            )
            XCTFail("Expected concurrent annotation publication rejection")
        } catch {
            if let expectedError {
                XCTAssertEqual(
                    error as? GenotypeAnnotationSidecar.SchemaMutationError,
                    expectedError(replacement, replacementRevision)
                )
            } else {
                let stale = try XCTUnwrap(
                    error as? GenotypeAnnotationSidecarPublicationError
                )
                guard case .staleRevision(_, let actual) = stale else {
                    return XCTFail("Expected stale revision, got \(stale)")
                }
                XCTAssertEqual(actual, replacementRevision)
            }
        }

        XCTAssertEqual(try Data(contentsOf: annotationURL), replacementData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: provenanceURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: bundleURL
                    .appendingPathComponent(
                        ProvenanceRecorder.provenanceFilename
                    ).path
            )
        )
    }

    func testApplyAnnotationsReplacesMatrixCommentsByExactTarget() throws {
        let firstTarget = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: "Mafa-A1*018:01:01:01_5nt_nov",
            stableClusterID: "cluster-a"
        )
        let sameGenotypeDifferentTarget = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-B",
            genotype: "Mafa-A1*018:01:01:01_5nt_nov",
            stableClusterID: "cluster-a"
        )
        var existing = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-01T00:00:00Z")
        existing.matrixComments = [
            .init(target: firstTarget, body: "Old current.", author: "alice", timestamp: "2026-07-01T10:00:00Z"),
            .init(target: sameGenotypeDifferentTarget, body: "Legacy duplicate one.", author: "alice", timestamp: "2026-07-01T10:00:00Z"),
            .init(target: sameGenotypeDifferentTarget, body: "Keep this.", author: "alice", timestamp: "2026-07-01T10:01:00Z"),
        ]
        var patch = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-01T11:00:00Z")
        patch.matrixComments = [
            .init(target: firstTarget, body: "Replacement.", author: "bob", timestamp: "2026-07-01T11:00:00Z"),
        ]

        let result = try GenotypeApplyAnnotationsSubcommand.merge(existing: existing, patch: patch)

        XCTAssertEqual(result.sidecar.matrixComments.count, 3)
        XCTAssertEqual(result.sidecar.resolvedMatrixComments[firstTarget]?.body, "Replacement.")
        XCTAssertEqual(result.sidecar.resolvedMatrixComments[sameGenotypeDifferentTarget]?.body, "Keep this.")
        XCTAssertEqual(result.appendedCounts.matrixComments, 1)
    }

    func testApplyAnnotationsReportsReviewAndCurrentCommentCounts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeApplyAnnotationsReviewCounts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*018:01:01:01_5nt_nov",
            sample: "AnimalA",
            stableClusterID: "cluster-a"
        )
        var existing = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-01T00:00:00Z")
        existing.matrixComments = [
            .init(target: target, body: "Old.", author: "alice", timestamp: "2026-07-01T10:00:00Z"),
        ]
        try existing.encoded().write(to: annotationURL)
        var patch = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-01T11:00:00Z")
        patch.matrixComments = [
            .init(target: target, body: "Current.", author: "bob", timestamp: "2026-07-01T11:00:00Z"),
        ]
        patch.matrixReviews = [
            .init(target: target, disposition: .falseNegative, author: "bob", timestamp: "2026-07-01T11:00:00Z"),
        ]
        let patchURL = root.appendingPathComponent("patch.json")
        try patch.encoded().write(to: patchURL)

        let command = try GenotypeApplyAnnotationsSubcommand.parse([
            "--bundle", bundleURL.path,
            "--patch", patchURL.path,
        ])
        try await command.run()

        let stored = try GenotypeAnnotationSidecar.decode(Data(contentsOf: annotationURL))
        XCTAssertEqual(stored.matrixReviews.count, 1)
        XCTAssertEqual(stored.resolvedMatrixComments[target]?.body, "Current.")
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.options.explicit["appendedMatrixReviews"], .integer(1))
        XCTAssertEqual(envelope.options.explicit["appendedMatrixComments"], .integer(1))
        let output = try XCTUnwrap(envelope.files.first { $0.path == annotationURL.path && $0.role == .output })
        XCTAssertEqual(output.checksumSHA256, try ProvenanceFileHasher.sha256(of: annotationURL))
    }

    func testReplayMatrixAnnotationCommandReconstructsFinalBytesAndWritesProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixAnnotationReplay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-1",
            stableClusterID: "candidate-17"
        )
        let timestamp = "2026-07-24T12:00:00Z"
        let prior = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T11:00:00Z")
        let review = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: target,
            disposition: .falsePositive,
            author: "Resolved Reviewer",
            timestamp: timestamp
        )
        let audit = GenotypeAnnotationSidecar.AuditEntry(
            action: "setMatrixReview",
            sample: target.auditSample,
            locus: target.locus,
            slot: nil,
            before: nil,
            after: "falsePositive",
            color: nil,
            reason: "matrix-review",
            rationale: target.stableAuditDescription,
            author: "Resolved Reviewer",
            timestamp: timestamp
        )
        let replayPayload = GenotypeMatrixAnnotationReplayPayload(
            action: .setMatrixReview,
            author: "Resolved Reviewer",
            timestamp: timestamp,
            targetMutations: [
                .init(
                    target: target,
                    beforeComments: nil,
                    resolvedCurrentComment: nil,
                    afterComments: nil,
                    beforeReviews: [],
                    afterReviews: [review],
                    canonicalizationAudits: [],
                    actionAudit: audit
                ),
            ]
        )
        let priorData = try prior.encoded()
        let replayData = try replayPayload.encoded()
        let finalSidecar = try replayPayload.applying(to: prior)
        let finalData = try finalSidecar.encoded()
        let finalStoredURL = root.appendingPathComponent("final-stored-annotations.json")
        try finalData.write(to: finalStoredURL)

        let provenanceURL = root.appendingPathComponent("annotations.json.lungfish-provenance.json")
        let replayOutputURL = root.appendingPathComponent("reconstructed-annotations.json")
        let replayProvenanceURL = root.appendingPathComponent("replay-output.provenance.json")
        let priorChecksum = SHA256.hash(data: priorData)
            .map { String(format: "%02x", $0) }
            .joined()
        let replayChecksum = SHA256.hash(data: replayData)
            .map { String(format: "%02x", $0) }
            .joined()
        let originalEnvelope = ProvenanceEnvelope(
            workflowName: "Genotype annotation sidecar edit",
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            options: ProvenanceOptions(explicit: [
                "action": .string("setMatrixReview"),
                "replayFormat": .string(GenotypeMatrixAnnotationReplayPayload.format),
                "replayPriorSidecarBase64": .string(priorData.base64EncodedString()),
                "replayPayloadBase64": .string(replayData.base64EncodedString()),
                "replayPayloadSHA256": .string(replayChecksum),
            ]),
            files: [
                ProvenanceFileDescriptor(
                    path: provenanceURL.path + "#/options/explicit/replayPriorSidecarBase64",
                    checksumSHA256: priorChecksum,
                    fileSize: UInt64(priorData.count),
                    format: .json,
                    role: .input,
                    originPath: root.appendingPathComponent("annotations.json").path
                ),
                try .file(url: finalStoredURL, format: .json, role: .output),
            ],
            output: try .file(url: finalStoredURL, format: .json, role: .output),
            outputs: [try .file(url: finalStoredURL, format: .json, role: .output)],
            exitStatus: 0
        )
        try ProvenanceJSON.encoder.encode(originalEnvelope).write(to: provenanceURL)
        let originalProvenanceData = try Data(contentsOf: provenanceURL)

        let parsed = try GenotypeReplayMatrixAnnotationSubcommand.parse([
            "--provenance", provenanceURL.path,
            "--output", replayOutputURL.path,
            "--output-provenance", replayProvenanceURL.path,
        ])
        try await parsed.run()

        XCTAssertEqual(try Data(contentsOf: replayOutputURL), finalData)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), originalProvenanceData)
        XCTAssertNotEqual(provenanceURL.standardizedFileURL, replayProvenanceURL.standardizedFileURL)
        let replayEnvelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: replayProvenanceURL)
        )
        let expectedArgv = [
            "lungfish-cli",
            "genotype",
            "replay-matrix-annotation",
            "--provenance", provenanceURL.path,
            "--output", replayOutputURL.path,
            "--output-provenance", replayProvenanceURL.path,
        ]
        XCTAssertEqual(replayEnvelope.argv, expectedArgv)
        XCTAssertEqual(replayEnvelope.durableReplayArgv, expectedArgv)
        XCTAssertEqual(
            replayEnvelope.reproducibleCommand,
            expectedArgv.map(shellEscape).joined(separator: " ")
        )
        XCTAssertEqual(replayEnvelope.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(replayEnvelope.wallTimeSeconds ?? -1, 0)
        XCTAssertEqual(replayEnvelope.stderr, "")
        XCTAssertEqual(
            replayEnvelope.options.explicit["provenance"]?.fileValue?.path,
            provenanceURL.path
        )
        XCTAssertEqual(
            replayEnvelope.options.explicit["output"]?.fileValue?.path,
            replayOutputURL.path
        )
        XCTAssertEqual(
            replayEnvelope.options.explicit["outputProvenance"]?.fileValue?.path,
            replayProvenanceURL.path
        )
        let recordedInput = try XCTUnwrap(replayEnvelope.files.first {
            $0.path == provenanceURL.path && $0.role == .input
        })
        XCTAssertEqual(
            recordedInput.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: provenanceURL)
        )
        XCTAssertEqual(
            recordedInput.fileSize,
            try ProvenanceFileHasher.fileSize(of: provenanceURL)
        )
        let recordedOutput = try XCTUnwrap(replayEnvelope.files.first {
            $0.path == replayOutputURL.path && $0.role == .output
        })
        XCTAssertEqual(
            recordedOutput.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: replayOutputURL)
        )
        XCTAssertEqual(
            recordedOutput.fileSize,
            try ProvenanceFileHasher.fileSize(of: replayOutputURL)
        )
        XCTAssertEqual(replayEnvelope.steps.first?.argv, expectedArgv)
        XCTAssertEqual(replayEnvelope.steps.first?.durableReplayArgv, expectedArgv)
        XCTAssertEqual(replayEnvelope.steps.first?.stderr, "")
        XCTAssertEqual(
            replayEnvelope.steps.first?.reproducibleCommand,
            expectedArgv.map(shellEscape).joined(separator: " ")
        )
    }

    func testReplayMatrixAnnotationCommandRejectsTamperedPayloadChecksumWithoutOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixAnnotationTamper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let provenanceURL = root.appendingPathComponent("annotations.json.lungfish-provenance.json")
        let outputURL = root.appendingPathComponent("reconstructed-annotations.json")
        let outputProvenanceURL =
            GenotypeMatrixAnnotationReplayPayload.replayOutputProvenanceURL(for: outputURL)
        let priorData = try GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-24T11:00:00Z"
        ).encoded()
        let payloadData = Data("tampered replay payload".utf8)
        let priorChecksum = SHA256.hash(data: priorData)
            .map { String(format: "%02x", $0) }
            .joined()
        let actualPayloadChecksum = SHA256.hash(data: payloadData)
            .map { String(format: "%02x", $0) }
            .joined()
        let recordedPayloadChecksum = String(repeating: "0", count: 64)
        let envelope = ProvenanceEnvelope(
            workflowName: "Genotype annotation sidecar edit",
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            options: ProvenanceOptions(explicit: [
                "replayFormat": .string(GenotypeMatrixAnnotationReplayPayload.format),
                "replayPriorSidecarBase64": .string(priorData.base64EncodedString()),
                "replayPayloadBase64": .string(payloadData.base64EncodedString()),
                "replayPayloadSHA256": .string(recordedPayloadChecksum),
            ]),
            files: [
                ProvenanceFileDescriptor(
                    path: provenanceURL.path + "#/options/explicit/replayPriorSidecarBase64",
                    checksumSHA256: priorChecksum,
                    fileSize: UInt64(priorData.count),
                    format: .json,
                    role: .input
                ),
            ],
            exitStatus: 0
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: provenanceURL)

        let parsed = try GenotypeReplayMatrixAnnotationSubcommand.parse([
            "--provenance", provenanceURL.path,
            "--output", outputURL.path,
        ])
        do {
            try await parsed.run()
            XCTFail("Expected tampered replay payload checksum to be rejected")
        } catch {
            XCTAssertEqual(
                error as? GenotypeReplayMatrixAnnotationError,
                .checksumMismatch(
                    name: "Replay payload",
                    expected: recordedPayloadChecksum,
                    actual: actualPayloadChecksum
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputProvenanceURL.path))
    }

    func testReplayMatrixAnnotationRejectsUnsignedSignatureArtifactOutputCollision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixAnnotationUnsignedCollision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceProvenanceURL = root.appendingPathComponent("source.lungfish-provenance.json")
        try writeReplayProvenanceFixture(to: sourceProvenanceURL)
        let sourceData = try Data(contentsOf: sourceProvenanceURL)
        let outputProvenanceURL = root.appendingPathComponent("replay")
        let outputURL = root.appendingPathComponent("replay.signature.json")
        XCTAssertEqual(
            outputURL.standardizedFileURL,
            ProvenanceSigningConfiguration.signatureURL(for: outputProvenanceURL)
                .standardizedFileURL
        )
        let scientificOutputSentinel = Data("existing scientific output".utf8)
        try scientificOutputSentinel.write(to: outputURL)

        var command = GenotypeReplayMatrixAnnotationSubcommand()
        command.provenance = sourceProvenanceURL.path
        command.output = outputURL.path
        command.outputProvenance = outputProvenanceURL.path
        command.force = true
        let thrownError: Error?
        do {
            try await command.run()
            thrownError = nil
        } catch {
            thrownError = error
        }

        guard case .pathCollision? = thrownError as? GenotypeReplayMatrixAnnotationError else {
            return XCTFail("Expected derived output-provenance signature collision, got \(String(describing: thrownError))")
        }
        XCTAssertEqual(try? Data(contentsOf: outputURL), scientificOutputSentinel)
        XCTAssertEqual(try Data(contentsOf: sourceProvenanceURL), sourceData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputProvenanceURL.path))
    }

    func testReplayMatrixAnnotationRejectsOutputCollisionWithSignedSourceArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixAnnotationSignedCollision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceProvenanceURL = root.appendingPathComponent("source.lungfish-provenance.json")
        try writeReplayProvenanceFixture(
            to: sourceProvenanceURL,
            signingProvider: LocalProvenanceSigningProvider(privateKey: "replay-source-collision-key")
        )
        let protectedArtifacts = ProvenancePublicationArtifacts.sidecarArtifacts(
            for: sourceProvenanceURL
        )
        let protectedBytes = try Dictionary(uniqueKeysWithValues: protectedArtifacts.map {
            ($0.standardizedFileURL.path, try Data(contentsOf: $0))
        })
        let outputURL = ProvenanceSigningConfiguration.signatureURL(for: sourceProvenanceURL)
        let outputProvenanceURL = root.appendingPathComponent("replay-output.provenance.json")

        var command = GenotypeReplayMatrixAnnotationSubcommand()
        command.provenance = sourceProvenanceURL.path
        command.output = outputURL.path
        command.outputProvenance = outputProvenanceURL.path
        command.force = true
        let thrownError: Error?
        do {
            try await command.run()
            thrownError = nil
        } catch {
            thrownError = error
        }

        guard case .pathCollision? = thrownError as? GenotypeReplayMatrixAnnotationError else {
            return XCTFail("Expected signed source-provenance artifact collision, got \(String(describing: thrownError))")
        }
        for artifactURL in protectedArtifacts {
            XCTAssertEqual(
                try Data(contentsOf: artifactURL),
                protectedBytes[artifactURL.standardizedFileURL.path]
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputProvenanceURL.path))
    }

    func testReplayMatrixAnnotationChecksEveryWritableProvenanceArtifactWithoutForce() async throws {
        for artifactKind in ["signature", "public-key"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "GenotypeMatrixAnnotationArtifactAvailability-\(artifactKind)-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let sourceProvenanceURL = root.appendingPathComponent("source.lungfish-provenance.json")
            try writeReplayProvenanceFixture(to: sourceProvenanceURL)
            let sourceData = try Data(contentsOf: sourceProvenanceURL)
            let outputURL = root.appendingPathComponent("reconstructed.json")
            let outputProvenanceURL = root.appendingPathComponent("replay.provenance.json")
            let artifactURL = artifactKind == "signature"
                ? ProvenanceSigningConfiguration.signatureURL(for: outputProvenanceURL)
                : ProvenanceSigningConfiguration.publicKeyURL(for: outputProvenanceURL)
            let artifactSentinel = Data("existing \(artifactKind) artifact".utf8)
            try artifactSentinel.write(to: artifactURL)

            let parsed = try GenotypeReplayMatrixAnnotationSubcommand.parse([
                "--provenance", sourceProvenanceURL.path,
                "--output", outputURL.path,
                "--output-provenance", outputProvenanceURL.path,
            ])
            let thrownError: Error?
            do {
                try await parsed.run()
                thrownError = nil
            } catch {
                thrownError = error
            }

            XCTAssertEqual(
                thrownError as? GenotypeReplayMatrixAnnotationError,
                .outputExists(artifactURL.path)
            )
            XCTAssertEqual(try? Data(contentsOf: artifactURL), artifactSentinel)
            XCTAssertEqual(try Data(contentsOf: sourceProvenanceURL), sourceData)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputProvenanceURL.path))
        }
    }

    private func writeReplayProvenanceFixture(
        to provenanceURL: URL,
        signingProvider: (any ProvenanceSigningProvider)? = nil
    ) throws {
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-1",
            stableClusterID: "candidate-17"
        )
        let timestamp = "2026-07-24T12:00:00Z"
        let prior = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T11:00:00Z")
        let audit = GenotypeAnnotationSidecar.AuditEntry(
            action: "clearMatrixReview",
            sample: target.auditSample,
            locus: target.locus,
            slot: nil,
            before: nil,
            after: nil,
            color: nil,
            reason: "matrix-review",
            rationale: target.stableAuditDescription,
            author: "Resolved Reviewer",
            timestamp: timestamp
        )
        let replayPayload = GenotypeMatrixAnnotationReplayPayload(
            action: .clearMatrixReview,
            author: "Resolved Reviewer",
            timestamp: timestamp,
            targetMutations: [
                .init(
                    target: target,
                    beforeComments: nil,
                    resolvedCurrentComment: nil,
                    afterComments: nil,
                    beforeReviews: [],
                    afterReviews: [],
                    canonicalizationAudits: [],
                    actionAudit: audit
                ),
            ]
        )
        let priorData = try prior.encoded()
        let replayData = try replayPayload.encoded()
        let priorChecksum = SHA256.hash(data: priorData)
            .map { String(format: "%02x", $0) }
            .joined()
        let replayChecksum = SHA256.hash(data: replayData)
            .map { String(format: "%02x", $0) }
            .joined()
        let envelope = ProvenanceEnvelope(
            workflowName: "Genotype annotation sidecar edit",
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            options: ProvenanceOptions(explicit: [
                "replayFormat": .string(GenotypeMatrixAnnotationReplayPayload.format),
                "replayPriorSidecarBase64": .string(priorData.base64EncodedString()),
                "replayPayloadBase64": .string(replayData.base64EncodedString()),
                "replayPayloadSHA256": .string(replayChecksum),
            ]),
            files: [
                ProvenanceFileDescriptor(
                    path: provenanceURL.path + "#/options/explicit/replayPriorSidecarBase64",
                    checksumSHA256: priorChecksum,
                    fileSize: UInt64(priorData.count),
                    format: .json,
                    role: .input
                ),
            ],
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: signingProvider).write(
            envelope,
            toSidecar: provenanceURL
        )
    }

    // MARK: - export-pivot-xlsx

    func testExportPivotXlsxParsesBundleAndOutput() throws {
        let command = try GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--output", "/tmp/example.pivot.xlsx",
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
        XCTAssertEqual(command.output, "/tmp/example.pivot.xlsx")
    }

    func testExportPivotXlsxRejectsEmptyBundleOrOutput() {
        XCTAssertThrowsError(
            try GenotypeExportPivotXlsxSubcommand.parse([
                "--bundle", "", "--output", "/tmp/out.xlsx",
            ]).validate()
        )
        XCTAssertThrowsError(
            try GenotypeExportPivotXlsxSubcommand.parse([
                "--bundle", "/tmp/example.lungfishgenotype", "--output", "  ",
            ]).validate()
        )
    }

    func testPivotWorkbookBuilderLaysOutSamplesHaplotypesAndAlleleGroups() {
        // Build a small bundle data model directly so the test is hermetic.
        let bundleURL = URL(fileURLWithPath: "/tmp/dummy.lungfishgenotype", isDirectory: true)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "test", analysisName: "TestRun",
            primaryWorkbookPath: "test.xlsx",
            longSummaryCSVPath: "g.csv", sampleSummaryCSVPath: "s.csv",
            statsJSONPath: "stats.json", provenancePath: "prov.json"
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: bundleURL.appendingPathComponent("test.xlsx"),
            longSummaryCSVURL: bundleURL.appendingPathComponent("g.csv"),
            sampleSummaryCSVURL: bundleURL.appendingPathComponent("s.csv"),
            statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
            provenanceURL: bundleURL.appendingPathComponent("prov.json")
        )
        let stats = ONTGenotypeRunStats()
        let calls: [ONTGenotypeCall] = [
            ONTGenotypeCall(
                sample: "Animal1", genotype: "01_M1_F_01_w_06",
                passedAlignments: 100, passedUniqueReads: 80,
                sampleTotalReads: 200, sampleUniqueRetainedReads: 150,
                sampleUniqueRetainedPercent: 75.0,
                overallInputReads: nil, overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "Animal1", genotype: "02_M1_G_02_07_2mis_156bp",
                passedAlignments: 50, passedUniqueReads: 40,
                sampleTotalReads: 200, sampleUniqueRetainedReads: 150,
                sampleUniqueRetainedPercent: 75.0,
                overallInputReads: nil, overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "Animal2", genotype: "01_M1_F_01_w_06",
                passedAlignments: 25, passedUniqueReads: 20,
                sampleTotalReads: 100, sampleUniqueRetainedReads: 60,
                sampleUniqueRetainedPercent: 60.0,
                overallInputReads: nil, overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        let samples: [ONTGenotypeSampleResult] = [
            ONTGenotypeSampleResult(
                sample: "Animal1", passedAlignments: 150, passedUniqueReads: 120,
                sampleTotalReads: 200, sampleUniqueRetainedPercent: 75.0,
                calls: calls.filter { $0.sample == "Animal1" }
            ),
            ONTGenotypeSampleResult(
                sample: "Animal2", passedAlignments: 25, passedUniqueReads: 20,
                sampleTotalReads: 100, sampleUniqueRetainedPercent: 60.0,
                calls: calls.filter { $0.sample == "Animal2" }
            ),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "ont-macaque", definitionSetID: "mafa-mhc",
            definitionSetName: "Mafa MHC", speciesName: "Macaca fascicularis",
            samples: [
                GenotypeHaplotypeSampleAnalysis(sample: "Animal1", calls: [
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-A", sourceLocus: "Mafa-A",
                        haplotype1: "M1A", haplotype2: "M2A",
                        status: .called, matchedHaplotypes: [],
                        observedGenotypeCount: 2, observedGenotypes: []
                    ),
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-B", sourceLocus: "Mafa-B",
                        haplotype1: "ERR: NO HAP", haplotype2: "ERR: NO HAP",
                        status: .noHaplotype, matchedHaplotypes: [],
                        observedGenotypeCount: 0, observedGenotypes: []
                    ),
                ]),
                GenotypeHaplotypeSampleAnalysis(sample: "Animal2", calls: []),
            ]
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: bundleURL, manifest: manifest, artifacts: artifacts,
            stats: stats, calls: calls, samples: samples,
            haplotypeAnalysis: analysis
        )

        let workbook = GenotypeExportPivotXlsxSubcommand.PivotWorkbookBuilder.build(from: result)

        XCTAssertEqual(workbook.samples, ["Animal1", "Animal2"])
        XCTAssertEqual(workbook.sheetName, "TestRun")
        XCTAssertEqual(workbook.mappedReadCounts, [150, 25])
        XCTAssertEqual(workbook.totalReadCounts, [200, 100])
        XCTAssertEqual(workbook.percentReadsUnmapped, [25.0, 40.0])

        // 14 haplotype rows in canonical locus order.
        XCTAssertEqual(workbook.haplotypeRows.count, 14)
        XCTAssertEqual(workbook.haplotypeRows[0].label, "MHC-A Haplotype 1")
        XCTAssertEqual(workbook.haplotypeRows[0].values, ["M1A", nil])
        XCTAssertEqual(workbook.haplotypeRows[1].label, "MHC-A Haplotype 2")
        XCTAssertEqual(workbook.haplotypeRows[1].values, ["M2A", nil])
        XCTAssertEqual(workbook.haplotypeRows[2].label, "MHC-B Haplotype 1")
        XCTAssertEqual(workbook.haplotypeRows[2].values, ["ERR: NO HAP", nil])

        // Comments row reports the non-called locus for Animal1.
        XCTAssertEqual(workbook.commentsRow[0], "MHC-B: ERR: NO HAP")
        XCTAssertNil(workbook.commentsRow[1])

        // Two allele groups (Mafa-F + Mafa-G) seen in calls.
        XCTAssertEqual(workbook.groups.map(\.label), ["Mafa-F alleles", "Mafa-G alleles"])
        XCTAssertEqual(workbook.groups[0].alleles.map(\.name), ["01_M1_F_01_w_06"])
        XCTAssertEqual(workbook.groups[0].alleles[0].counts, [80, 20])
        XCTAssertEqual(workbook.groups[1].alleles[0].counts, [40, nil])
    }

    func testPivotWorkbookUsesSidecarActiveCustomHaplotypeDefinition() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pivot-active-definition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definition = customDefinition(id: "custom.pivot.definition", haplotypeName: "NewB")
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(definition)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-24T00:00:00Z")
        sidecar.settings.activeHaplotypeDefinitionSetID = definition.id
        let result = activeDefinitionResult(bundleURL: bundleURL)

        let workbook = GenotypeExportPivotXlsxSubcommand.PivotWorkbookBuilder.build(from: result, sidecar: sidecar)

        XCTAssertEqual(workbook.haplotypeRows[2].label, "MHC-B Haplotype 1")
        XCTAssertEqual(workbook.haplotypeRows[2].values, ["NewB"])
    }

    func testPivotWorkbookIncludesGroupedClassIILociFromActiveAnalysis() {
        let bundleURL = URL(fileURLWithPath: "/tmp/grouped-class-ii.lungfishgenotype", isDirectory: true)
        let manifest = ONTGenotypeResultBundleManifest(
            kind: "ont-barcode-genotype",
            outputName: "Grouped",
            analysisName: "Grouped",
            primaryWorkbookPath: "grouped.xlsx",
            longSummaryCSVPath: "genotypes.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: bundleURL.appendingPathComponent("grouped.xlsx"),
            longSummaryCSVURL: bundleURL.appendingPathComponent("genotypes.csv"),
            sampleSummaryCSVURL: bundleURL.appendingPathComponent("samples.csv"),
            statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
            provenanceURL: bundleURL.appendingPathComponent("provenance.json")
        )
        let samples = [
            ONTGenotypeSampleResult(
                sample: "Animal1",
                passedAlignments: 100,
                passedUniqueReads: 100,
                sampleTotalReads: 100,
                sampleUniqueRetainedPercent: 100,
                calls: []
            ),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "mcm-mhc-miseq-20260617",
            definitionSetName: "MCM MHC miSeq haplotype associations",
            speciesName: "Mauritian cynomolgus macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(sample: "Animal1", calls: [
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-DR",
                        sourceLocus: "MHC-DR",
                        haplotype1: "M1",
                        haplotype2: "M2",
                        status: .called,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: []
                    ),
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-DQ",
                        sourceLocus: "MHC-DQ",
                        haplotype1: "M1",
                        haplotype2: "M2",
                        status: .called,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: []
                    ),
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-DP",
                        sourceLocus: "MHC-DP",
                        haplotype1: "M1",
                        haplotype2: "M2",
                        status: .called,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: []
                    ),
                ]),
            ]
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            stats: ONTGenotypeRunStats(),
            calls: [],
            samples: samples,
            haplotypeAnalysis: analysis
        )

        let workbook = GenotypeExportPivotXlsxSubcommand.PivotWorkbookBuilder.build(from: result)
        let rowsByLabel = Dictionary(uniqueKeysWithValues: workbook.haplotypeRows.map { ($0.label, $0.values) })

        XCTAssertEqual(rowsByLabel["MHC-DR Haplotype 1"], ["M1"])
        XCTAssertEqual(rowsByLabel["MHC-DR Haplotype 2"], ["M2"])
        XCTAssertEqual(rowsByLabel["MHC-DQ Haplotype 1"], ["M1"])
        XCTAssertEqual(rowsByLabel["MHC-DQ Haplotype 2"], ["M2"])
        XCTAssertEqual(rowsByLabel["MHC-DP Haplotype 1"], ["M1"])
        XCTAssertEqual(rowsByLabel["MHC-DP Haplotype 2"], ["M2"])
    }

    func testPlainXlsxMatrixUsesSidecarActiveCustomHaplotypeDefinition() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx-active-definition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definition = customDefinition(id: "custom.xlsx.definition", haplotypeName: "NewB")
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(definition)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-24T00:00:00Z")
        sidecar.settings.activeHaplotypeDefinitionSetID = definition.id
        let result = activeDefinitionResult(bundleURL: bundleURL)

        let matrix = GenotypeXlsxWorkbookWriter.MatrixBuilder.build(from: result, sidecar: sidecar)

        XCTAssertEqual(matrix.loci, ["MHC-B"])
        XCTAssertEqual(matrix.rows.first?.cells.first?.label, "NewB")
    }

    func testPivotWorkbookSheetNameSanitization() {
        let sanitized = GenotypeExportPivotXlsxSubcommand.PivotWorkbookBuilder.sanitizedSheetName(
            "Long/Name:With*Illegal[Chars]/AndMoreCharactersThan31"
        )
        XCTAssertLessThanOrEqual(sanitized.count, 31)
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains(":"))
        XCTAssertFalse(sanitized.contains("*"))
        XCTAssertFalse(sanitized.contains("["))
        XCTAssertFalse(sanitized.contains("]"))
        XCTAssertEqual(
            GenotypeExportPivotXlsxSubcommand.PivotWorkbookBuilder.sanitizedSheetName("   "),
            "Genotype"
        )
    }

    private func activeDefinitionResult(bundleURL: URL) -> ONTGenotypeResultBundleData {
        let calls = [makeCall(sample: "AnimalA", genotype: "12_M9_B_001_01", reads: 150)]
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "test",
                analysisName: "TestRun",
                primaryWorkbookPath: "test.xlsx",
                longSummaryCSVPath: "test.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "test.retained-demux-samples.csv",
                statsJSONPath: "test.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: bundleURL.appendingPathComponent("test.xlsx"),
                longSummaryCSVURL: bundleURL.appendingPathComponent("test.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("test.retained-demux-samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("test.retained-demux-stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 150),
            calls: calls,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 150,
                    passedUniqueReads: 150,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                assayID: "custom-assay",
                definitionSetID: "old.definition",
                definitionSetName: "Old Definition",
                speciesName: "Test macaque",
                samples: [
                    GenotypeHaplotypeSampleAnalysis(
                        sample: "AnimalA",
                        calls: [
                            GenotypeHaplotypeLocusCall(
                                locus: "MHC-B",
                                sourceLocus: "Mafa-B",
                                haplotype1: "OldB",
                                haplotype2: "-",
                                status: .called,
                                matchedHaplotypes: [],
                                observedGenotypeCount: 1,
                                observedGenotypes: ["12_OLD_B_001_01"]
                            )
                        ]
                    )
                ]
            )
        )
    }

    private func customDefinition(id: String, haplotypeName: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "custom-assay",
            displayName: "Custom Export Definition",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: haplotypeName, diagnosticAlleles: ["12_M9_B_001_01"])
                    ]
                )
            ]
        )
    }

    private func makeCall(sample: String, genotype: String, reads: Int) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }
}

private extension GenotypeSubcommandsTests {
    struct PromptInput: Decodable {
        let knowledgePack: AIHaplotypingKnowledgePack?
    }

    enum PromptInputDecodeError: Error {
        case missingMarker
        case missingJSON
        case unterminatedJSON
    }

    static func promptInput(from userPrompt: String) throws -> PromptInput {
        guard let markerRange = userPrompt.range(of: "Prompt input JSON:") else {
            throw PromptInputDecodeError.missingMarker
        }
        let suffix = userPrompt[markerRange.upperBound...]
        guard let start = suffix.firstIndex(of: "{") else {
            throw PromptInputDecodeError.missingJSON
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
            throw PromptInputDecodeError.unterminatedJSON
        }
        let json = String(suffix[start...end])
        return try JSONDecoder().decode(PromptInput.self, from: Data(json.utf8))
    }

    static func knowledgePackRecordText(_ pack: AIHaplotypingKnowledgePack) -> String {
        let blockText = pack.haplotypeBlockDefinitions.flatMap { definition in
            [
                definition.id,
                definition.internalID,
                definition.displayLabel,
                definition.reportLabel,
                definition.extendedHaplotype,
                definition.notes,
            ].compactMap { $0 }
        }
        let markerText = pack.haplotypeBlockDefinitions.flatMap { definition in
            definition.definingMarkers.flatMap { marker in
                [marker.marker, marker.locus, marker.notes]
            }
        }
        let alleleText = pack.alleleRecords.flatMap { record in
            [
                record.id,
                record.officialDesignation,
                record.accession,
                record.comment,
                record.previousName,
                record.status,
            ].compactMap { $0 } + record.haplotypes
        }
        return (blockText + markerText + alleleText).joined(separator: "\n")
    }
}
