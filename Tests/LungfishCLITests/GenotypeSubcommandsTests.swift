import XCTest
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
                "export", "export-xlsx", "export-pivot-xlsx", "export-labkey"
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
            "--max-provider-retries", "3",
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
        XCTAssertEqual(command.maxProviderRetries, 3)
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
        XCTAssertEqual(preview.promptTemplate.version, "2026-06-15.16")
        XCTAssertEqual(preview.knowledgePack.version, "2026-06-15.2")
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("DP/DQ linkage"))
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("population novelty prior"))
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("05_M1M2M3_A1_063g"))
        XCTAssertTrue(preview.chunks[0].evidenceRegistry.evidenceIDs.contains("obs:B25276:MHC-A:05_M1M2M3_A1_063g"))
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

        XCTAssertTrue(preview.knowledgePack.digest.hasPrefix("sha256:"))
        XCTAssertEqual(preview.knowledgePack.digest.count, "sha256:".count + 64)
        XCTAssertLessThan(
            promptInput.knowledgePack.haplotypeBlockDefinitions.count,
            preview.knowledgePack.haplotypeBlockDefinitionCount
        )
        XCTAssertLessThan(preview.chunks[0].userPrompt.count, 80_000)
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("\"haplotypeBlockDefinitions\""))
        XCTAssertFalse(preview.chunks[0].userPrompt.contains("\"legacyBlockDefinitions\""))
        XCTAssertTrue(preview.chunks[0].userPrompt.contains("05_M1M2M3_A1_063g"))
        XCTAssertTrue(promptInput.knowledgePack.haplotypeBlockDefinitions.contains { $0.reportLabel == "M3A" })
        XCTAssertFalse(Self.knowledgePackRecordText(promptInput.knowledgePack).contains("A008.01"))
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
            "lungfish",
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

        let result = GenotypeApplyAnnotationsSubcommand.merge(existing: existing, patch: patch)
        XCTAssertEqual(result.sidecar.callOverrides.count, 2)
        XCTAssertEqual(result.appendedCounts.callOverrides, 1)
        XCTAssertEqual(result.skippedDuplicateCounts.callOverrides, 1)
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
        let knowledgePack: AIHaplotypingKnowledgePack
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
