import XCTest
import CryptoKit
import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class AIHaplotypingRevisionPublisherTests: XCTestCase {
    func testPublishWritesActiveRevisionFinalProvenanceAndSidecarReview() throws {
        let fixture = try makeFixture()
        let originalManifestData = try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL))
        let originalSidecarData = try Data(contentsOf: fixture.sidecarURL)
        let publisher = AIHaplotypingRevisionPublisher(
            dateProvider: { Self.fixedDate },
            revisionIDProvider: { "haprev-ai-test" }
        )

        let published = try publisher.publish(
            AIHaplotypingRevisionPublishRequest(
                bundleURL: fixture.bundleURL,
                result: fixture.result,
                sidecarURL: fixture.sidecarURL,
                sidecar: fixture.sidecar,
                runnerOutput: fixture.runnerOutput,
                context: makeContext(bundleURL: fixture.bundleURL)
            )
        )

        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        XCTAssertEqual(published.revision.id, "haprev-ai-test")
        XCTAssertEqual(manifest.activeHaplotypeAnalysisRevisionID, "haprev-ai-test")
        XCTAssertEqual(
            manifest.haplotypeAnalysisPath,
            "artifacts/ai-haplotyping/revisions/haprev-ai-test/haplotype-analysis.json"
        )
        XCTAssertEqual(manifest.haplotypeAnalysisRevisions?.map(\.id), ["haprev-det-0001", "haprev-ai-test"])
        let revision = try XCTUnwrap(manifest.haplotypeAnalysisRevisions?.last)
        XCTAssertEqual(revision.method, .aiRefinement)
        XCTAssertEqual(revision.reviewState, .needsReview)
        XCTAssertEqual(revision.predecessorID, "haprev-det-0001")
        XCTAssertEqual(revision.provider, "openai")
        XCTAssertEqual(revision.model, "gpt-5-mini")
        XCTAssertEqual(revision.promptTemplateID, "lungfish.ai-haplotyping.refinement")
        XCTAssertEqual(revision.promptHash, fixture.runnerOutput.chunkOutputs[0].promptMetadata.promptHash)
        XCTAssertEqual(
            revision.provenancePath,
            "artifacts/ai-haplotyping/revisions/haprev-ai-test/ai-haplotyping.lungfish-provenance.json"
        )

        let analysisURL = ONTGenotypeResultBundle.resolvedURL(for: revision.path, in: fixture.bundleURL)
        let analysis = try JSONDecoder().decode(
            GenotypeHaplotypeAnalysis.self,
            from: Data(contentsOf: analysisURL)
        )
        XCTAssertEqual(analysis.source, .ai)
        XCTAssertEqual(analysis.analysisRevisionID, "haprev-ai-test")
        XCTAssertEqual(analysis.definitionSetID, "ai-provisional:haprev-ai-test")
        let dw472B = try XCTUnwrap(analysis.samples.first { $0.sample == "DW472" }?.calls.first { $0.locus == "MHC-B" })
        XCTAssertEqual(dw472B.haplotype1, "M9B")
        XCTAssertEqual(dw472B.haplotype2, "Manual-M7B")
        XCTAssertEqual(dw472B.status, .called)
        XCTAssertEqual(dw472B.aiSlotMetadata.map(\.slot), [.h1, .h2])
        XCTAssertEqual(dw472B.aiSlotMetadata.map(\.metadata.provenancePath), [
            revision.provenancePath,
            revision.provenancePath,
        ])
        XCTAssertFalse(dw472B.aiSlotMetadata.contains {
            $0.metadata.provenancePath == AIHaplotypingPatchValidator.pendingProvenancePath
        })
        let dw473A = try XCTUnwrap(analysis.samples.first { $0.sample == "DW473" }?.calls.first { $0.locus == "MHC-A" })
        XCTAssertEqual(dw473A.haplotype1, "M7A")
        XCTAssertEqual(dw473A.haplotype2, "-")

        let sidecar = try GenotypeAnnotationSidecar.decode(Data(contentsOf: fixture.sidecarURL))
        XCTAssertEqual(sidecar.callOverrides, fixture.sidecar.callOverrides)
        XCTAssertEqual(sidecar.activeAIHaplotypeReviewID, "airev-haprev-ai-test")
        let review = try XCTUnwrap(sidecar.aiHaplotypeReviews.last)
        XCTAssertEqual(review.analysisRevisionID, "haprev-ai-test")
        XCTAssertEqual(review.reviewState, .needsReview)
        XCTAssertEqual(review.callReviews.map { "\($0.sample):\($0.locus):\($0.slot.rawValue)" }, [
            "DW472:MHC-B:h1",
            "DW472:MHC-B:h2",
        ])
        XCTAssertEqual(review.callsPath, "artifacts/ai-haplotyping/revisions/haprev-ai-test/calls.json")
        XCTAssertEqual(review.provenancePath, revision.provenancePath)

        let callsURL = ONTGenotypeResultBundle.resolvedURL(for: review.callsPath, in: fixture.bundleURL)
        let persistedCalls = try JSONDecoder().decode([AIHaplotypingValidatedCall].self, from: Data(contentsOf: callsURL))
        XCTAssertEqual(persistedCalls.map(\.aiMetadata.provenancePath), [
            revision.provenancePath,
            revision.provenancePath,
        ])

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(for: revision.provenancePath, in: fixture.bundleURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.workflowName, "AI Haplotype Revision")
        XCTAssertEqual(envelope.argv, makeContext(bundleURL: fixture.bundleURL).argv)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.resolvedDefaults["knowledgePackID"]?.stringValue, "macaque-mhc")
        XCTAssertEqual(envelope.options.resolvedDefaults["knowledgePackVersion"]?.stringValue, "2026-06-17.3")
        XCTAssertTrue(
            envelope.options.resolvedDefaults["knowledgePackDigest"]?.stringValue?.hasPrefix("sha256:") == true
        )
        let stepInputs = envelope.steps.flatMap(\.inputs)
        let inputDescriptorsByPath = Dictionary(uniqueKeysWithValues: stepInputs.map { ($0.path, $0) })
        let originalManifestInput = try XCTUnwrap(inputDescriptorsByPath[
            ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL).standardizedFileURL.path
        ])
        XCTAssertEqual(originalManifestInput.checksumSHA256, sha256(originalManifestData))
        XCTAssertEqual(originalManifestInput.fileSize, UInt64(originalManifestData.count))
        let originalSidecarInput = try XCTUnwrap(inputDescriptorsByPath[fixture.sidecarURL.standardizedFileURL.path])
        XCTAssertEqual(originalSidecarInput.checksumSHA256, sha256(originalSidecarData))
        XCTAssertEqual(originalSidecarInput.fileSize, UInt64(originalSidecarData.count))
        let outputPaths = Set(envelope.outputs.map(\.path))
        for url in [
            analysisURL,
            callsURL,
            ONTGenotypeResultBundle.resolvedURL(for: review.evidenceSnapshotPath, in: fixture.bundleURL),
            ONTGenotypeResultBundle.resolvedURL(for: review.validationReportPath, in: fixture.bundleURL),
            fixture.sidecarURL,
            ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL),
        ] {
            XCTAssertTrue(outputPaths.contains(url.standardizedFileURL.path), "Missing provenance output \(url.path)")
        }
        for descriptor in envelope.outputs where descriptor.role != .log {
            XCTAssertNotNil(descriptor.checksumSHA256, "Missing checksum for \(descriptor.path)")
            XCTAssertNotNil(descriptor.fileSize, "Missing file size for \(descriptor.path)")
        }

        let revisionDirectory = fixture.bundleURL
            .appendingPathComponent("artifacts/ai-haplotyping/revisions/haprev-ai-test", isDirectory: true)
        let storedText = try recursiveUTF8Text(in: revisionDirectory)
        XCTAssertFalse(storedText.contains("sk-test-secret"))
        XCTAssertFalse(storedText.contains("raw-provider-body"))
        XCTAssertFalse(storedText.contains(AIHaplotypingPatchValidator.pendingProvenancePath))
    }

    func testPublishFailureRestoresManifestSidecarAndDeletesAttemptedRevisionDirectory() throws {
        let fixture = try makeFixture()
        let originalManifest = try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL))
        let originalSidecar = try Data(contentsOf: fixture.sidecarURL)
        let publisher = AIHaplotypingRevisionPublisher(
            dateProvider: { Self.fixedDate },
            revisionIDProvider: { "haprev-ai-failing" },
            provenanceWriter: { _, _ in throw IntentionalPublisherFailure.provenance }
        )

        XCTAssertThrowsError(try publisher.publish(
            AIHaplotypingRevisionPublishRequest(
                bundleURL: fixture.bundleURL,
                result: fixture.result,
                sidecarURL: fixture.sidecarURL,
                sidecar: fixture.sidecar,
                runnerOutput: fixture.runnerOutput,
                context: makeContext(bundleURL: fixture.bundleURL)
            )
        ))

        XCTAssertEqual(try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)), originalManifest)
        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), originalSidecar)
        let revisionDirectory = fixture.bundleURL
            .appendingPathComponent("artifacts/ai-haplotyping/revisions/haprev-ai-failing", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: revisionDirectory.path))
    }

    func testPublishDoesNotEmitMHCLPlaceholderHaplotypeCalls() throws {
        let fixture = try makeFixture(runnerOutput: makeRunnerOutputWithMHCLEvidence())
        let publisher = AIHaplotypingRevisionPublisher(
            dateProvider: { Self.fixedDate },
            revisionIDProvider: { "haprev-ai-test" }
        )

        let published = try publisher.publish(
            AIHaplotypingRevisionPublishRequest(
                bundleURL: fixture.bundleURL,
                result: fixture.result,
                sidecarURL: fixture.sidecarURL,
                sidecar: fixture.sidecar,
                runnerOutput: fixture.runnerOutput,
                context: makeContext(bundleURL: fixture.bundleURL)
            )
        )

        let analysisURL = ONTGenotypeResultBundle.resolvedURL(for: published.revision.path, in: fixture.bundleURL)
        let analysis = try JSONDecoder().decode(
            GenotypeHaplotypeAnalysis.self,
            from: Data(contentsOf: analysisURL)
        )

        XCTAssertFalse(analysis.samples.flatMap(\.calls).contains { $0.locus == "MHC-L" })
    }

    func testPublishStoresMCMSpecialistPromptMarkdownWithRevisionAndProvenance() throws {
        let fixture = try makeFixture(runnerOutput: makeMCMSpecialistRunnerOutput())
        let publisher = AIHaplotypingRevisionPublisher(
            dateProvider: { Self.fixedDate },
            revisionIDProvider: { "haprev-ai-mcm" }
        )

        let published = try publisher.publish(
            AIHaplotypingRevisionPublishRequest(
                bundleURL: fixture.bundleURL,
                result: fixture.result,
                sidecarURL: fixture.sidecarURL,
                sidecar: fixture.sidecar,
                runnerOutput: fixture.runnerOutput,
                context: makeContext(bundleURL: fixture.bundleURL)
            )
        )

        let revision = published.revision
        let promptPath = try XCTUnwrap(revision.promptSnapshotPath)
        XCTAssertEqual(
            promptPath,
            "artifacts/ai-haplotyping/revisions/haprev-ai-mcm/mcm-mhc-haplotyping-specialist-prompt.md"
        )
        let promptURL = ONTGenotypeResultBundle.resolvedURL(for: promptPath, in: fixture.bundleURL)
        XCTAssertEqual(
            try String(contentsOf: promptURL, encoding: .utf8),
            try MCMHaplotypingPreset.mcmMHCmiseq.bundledSpecialistPromptMarkdown()
        )

        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        XCTAssertEqual(manifest.haplotypeAnalysisRevisions?.last?.promptSnapshotPath, promptPath)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: published.provenanceURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["specialistPromptPath"]?.stringValue, promptPath)
        XCTAssertTrue(envelope.outputs.contains { $0.path == promptURL.standardizedFileURL.path })
        XCTAssertTrue(envelope.steps.contains { step in
            step.toolName == "MCM specialist prompt snapshot"
                && step.outputs.contains { $0.path == promptURL.standardizedFileURL.path }
        }, "\(envelope.steps)")
    }
}

private enum IntentionalPublisherFailure: Error {
    case provenance
}

private extension AIHaplotypingRevisionPublisherTests {
    static let fixedDate = ISO8601DateFormatter().date(from: "2026-06-14T18:00:00Z")!

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct Fixture {
        let root: URL
        let bundleURL: URL
        let sidecarURL: URL
        let sidecar: GenotypeAnnotationSidecar
        let result: ONTGenotypeResultBundleData
        let runnerOutput: AIHaplotypingRunnerOutput
    }

    func makeFixture(runnerOutput: AIHaplotypingRunnerOutput? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-haplotyping-publisher-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("fixture.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let workbookURL = bundleURL.appendingPathComponent("fixture.xlsx")
        let longCSV = bundleURL.appendingPathComponent("long.csv")
        let sampleCSV = bundleURL.appendingPathComponent("samples.csv")
        let statsURL = bundleURL.appendingPathComponent("stats.json")
        let runProvenanceURL = bundleURL.appendingPathComponent("run.lungfish-provenance.json")
        let predecessorURL = bundleURL.appendingPathComponent("predecessor.haplotype-analysis.json")
        try Data("workbook".utf8).write(to: workbookURL)
        try Data("sample,genotype\n".utf8).write(to: longCSV)
        try Data("sample\nDW472\nDW473\n".utf8).write(to: sampleCSV)
        try Data("{}".utf8).write(to: statsURL)
        try Data("{}".utf8).write(to: runProvenanceURL)

        let predecessor = predecessorAnalysis()
        try prettyJSONEncoder.encode(predecessor).write(to: predecessorURL)
        let predecessorRevision = ONTGenotypeHaplotypeAnalysisRevision(
            id: "haprev-det-0001",
            method: .deterministic,
            path: predecessorURL.lastPathComponent,
            createdAt: "2026-06-14T17:00:00Z",
            reviewState: .reviewed,
            sha256: try ProvenanceFileHasher.sha256(of: predecessorURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: predecessorURL)),
            provenancePath: runProvenanceURL.lastPathComponent
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "fixture",
            analysisName: "Fixture",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: longCSV.lastPathComponent,
            sampleSummaryCSVPath: sampleCSV.lastPathComponent,
            statsJSONPath: statsURL.lastPathComponent,
            provenancePath: runProvenanceURL.lastPathComponent,
            haplotypeAnalysisPath: predecessorURL.lastPathComponent,
            haplotypeDefinitionSetID: "deterministic-definitions",
            haplotypeAssayID: "MHC-exon2-miSeq",
            createdAt: "2026-06-14T17:00:00Z",
            activeHaplotypeAnalysisRevisionID: predecessorRevision.id,
            haplotypeAnalysisRevisions: [predecessorRevision]
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let sidecar = GenotypeAnnotationSidecar(
            schemaVersion: GenotypeAnnotationSidecar.currentSchemaVersion,
            generatedAt: "2026-06-14T17:00:00Z",
            lastEditedAt: "2026-06-14T17:05:00Z",
            lastEditor: "analyst",
            callOverrides: [
                GenotypeAnnotationSidecar.CallOverride(
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: .h2,
                    originalCall: "M7B",
                    overrideCall: "Manual-M7B",
                    reasonTag: .analystJudgment,
                    rationale: "Manual carry-forward.",
                    author: "analyst",
                    timestamp: "2026-06-14T17:05:00Z"
                )
            ],
            cellHighlights: [],
            rowHighlights: [],
            sampleNotes: [],
            cellComments: [],
            sampleStatusFlags: [],
            callStatusFlags: [],
            smartCohorts: [],
            manualHaplotypeAssignments: [],
            settings: .default,
            auditLog: []
        )
        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try sidecar.encoded().write(to: sidecarURL)

        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: workbookURL,
            longSummaryCSVURL: longCSV,
            sampleSummaryCSVURL: sampleCSV,
            statsJSONURL: statsURL,
            provenanceURL: runProvenanceURL,
            haplotypeAnalysisURL: predecessorURL
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            stats: ONTGenotypeRunStats(totalInputReads: 100),
            calls: [
                makeONTCall(sample: "DW472", genotype: "12_M9_B_001_01"),
                makeONTCall(sample: "DW473", genotype: "12_M7_A_001_01"),
            ],
            samples: [],
            haplotypeAnalysis: predecessor
        )
        return Fixture(
            root: root,
            bundleURL: bundleURL,
            sidecarURL: sidecarURL,
            sidecar: sidecar,
            result: result,
            runnerOutput: runnerOutput ?? makeRunnerOutput()
        )
    }

    func makeContext(bundleURL: URL) -> AIHaplotypingRevisionPublishContext {
        AIHaplotypingRevisionPublishContext(
            toolName: "lungfish-cli genotype ai-haplotyping",
            toolKind: "cli",
            argv: [
                "lungfish-cli",
                "genotype",
                "ai-haplotyping",
                "--bundle",
                bundleURL.path,
                "--mode",
                "ai-refinement",
                "--provider",
                "openai",
                "--model",
                "gpt-5-mini",
            ],
            durableReplayArgv: [
                "lungfish-cli",
                "genotype",
                "ai-haplotyping",
                "--bundle",
                bundleURL.path,
                "--mode",
                "ai-refinement",
                "--provider",
                "openai",
                "--model",
                "gpt-5-mini",
            ],
            explicitOptions: [
                "mode": .string("aiRefinement"),
                "provider": .string("openai"),
                "credentialSource": .string("environment:OPENAI_API_KEY"),
            ],
            defaultOptions: [
                "temperature": .number(0),
                "maxOutputTokens": .integer(4096),
            ],
            resolvedOptions: [
                "promptTemplateID": .string("lungfish.ai-haplotyping.refinement"),
                "promptTemplateVersion": .string("2026-06-14.1"),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(user: "tests"),
            startedAt: Self.fixedDate
        )
    }

    func makeRunnerOutput() -> AIHaplotypingRunnerOutput {
        let registry = makeRegistry()
        let run = makeRunMetadata(registry: registry)
        let validatedCalls = [
            validatedCall(
                patchOpID: "patch-h1",
                slot: "h1",
                status: .called,
                primaryLabel: "M9B",
                proposedLabel: "M9B",
                callState: .called,
                sourceState: .current,
                support: ["obs:DW472:MHC-B:12_M9_B_001_01"],
                counter: ["sample:DW472"]
            ),
            validatedCall(
                patchOpID: "patch-h2-retain",
                slot: "h2",
                status: .called,
                primaryLabel: nil,
                proposedLabel: "Manual-M7B",
                callState: .retainCurrent,
                sourceState: .manual,
                support: ["manual:DW472:MHC-B:h2"],
                counter: ["sample:DW472"]
            ),
        ]
        let report = AIHaplotypingValidationReport(
            accepted: true,
            run: run,
            chunkID: "chunk-0001",
            registryDigest: registry.digest,
            inputSnapshotDigest: registry.inputSnapshotDigest,
            normalizedCalls: validatedCalls,
            validatedDefinitions: [
                AIHaplotypingValidatedDefinition(
                    definitionID: "def-ai-m9b",
                    locus: "MHC-B",
                    proposedLabel: "M9B",
                    normalizedFamily: "M9",
                    supportEvidenceRefs: ["obs:DW472:MHC-B:12_M9_B_001_01"],
                    counterevidenceRefs: ["locus:MHC-B"],
                    confidenceTier: .high
                )
            ],
            warnings: ["review required"],
            errors: []
        )
        let knowledgePack = try! AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()
        let prompt = AIHaplotypingPromptMetadata(
            promptTemplateID: run.promptTemplateID,
            promptTemplateVersion: run.promptTemplateVersion,
            promptHash: run.promptHash,
            evidenceSchemaVersion: 1,
            registryDigest: registry.digest,
            inputSnapshotDigest: registry.inputSnapshotDigest,
            evidenceSnapshotPath: "ai-haplotyping/evidence/chunk-0001.json",
            knowledgePackID: knowledgePack.id,
            knowledgePackVersion: knowledgePack.version,
            knowledgePackDigest: knowledgePack.digest
        )
        let attempt = AIProviderAttemptMetadata(
            attemptIndex: 0,
            fallbackIndex: 0,
            provider: "openai",
            model: "gpt-5-mini",
            endpoint: "/v1/responses",
            apiVersion: "2026-01-01",
            credentialSource: "environment:OPENAI_API_KEY",
            apiKeyAvailable: true,
            requestID: "req-123",
            statusCode: 200,
            stopReason: "stop",
            inputTokens: 1200,
            outputTokens: 300,
            sanitizedErrorCategory: nil
        )
        return AIHaplotypingRunnerOutput(
            mode: .aiRefinement,
            registry: registry,
            chunkOutputs: [
                AIHaplotypingChunkOutput(
                    chunkID: "chunk-0001",
                    registryDigest: registry.digest,
                    inputSnapshotDigest: registry.inputSnapshotDigest,
                    promptMetadata: prompt,
                    payloadDigest: "sha256:\(String(repeating: "3", count: 64))",
                    validationReport: report,
                    providerAttempt: attempt
                )
            ],
            normalizedCalls: validatedCalls,
            validatedDefinitions: report.validatedDefinitions,
            validationReports: [report],
            providerAttempts: [attempt]
        )
    }

    func makeRunnerOutputWithMHCLEvidence() -> AIHaplotypingRunnerOutput {
        let base = makeRunnerOutput()
        let registry = AIHaplotypingEvidenceRegistry(
            schemaVersion: base.registry.schemaVersion,
            mode: base.registry.mode,
            parentRevisionID: base.registry.parentRevisionID,
            inputSnapshotDigest: base.registry.inputSnapshotDigest,
            samples: base.registry.samples,
            loci: base.registry.loci + [
                LocusEvidence(id: "locus:MHC-L", locus: "MHC-L")
            ],
            observations: base.registry.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-L:Mafa-L*01:06:01:01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-L",
                    genotype: "Mafa-L*01:06:01:01",
                    passedAlignments: 38,
                    passedUniqueReads: 20,
                    sampleUniqueRetainedReads: 100
                )
            ],
            currentCalls: base.registry.currentCalls,
            manualReviews: base.registry.manualReviews
        )
        return AIHaplotypingRunnerOutput(
            mode: base.mode,
            registry: registry,
            chunkOutputs: base.chunkOutputs,
            normalizedCalls: base.normalizedCalls,
            validatedDefinitions: base.validatedDefinitions,
            validationReports: base.validationReports,
            providerAttempts: base.providerAttempts
        )
    }

    func makeMCMSpecialistRunnerOutput() -> AIHaplotypingRunnerOutput {
        let base = makeRunnerOutput()
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        let registry = base.registry
        let run = AIHaplotypingRunMetadata(
            mode: base.mode,
            promptTemplateID: preset.aiPromptTemplateID(for: base.mode),
            promptTemplateVersion: preset.aiPromptTemplateVersion,
            promptHash: "sha256:\(String(repeating: "4", count: 64))",
            provider: "openai",
            model: preset.aiOpenAIModel,
            generationParameters: [
                "maxObservationsPerChunk": "128",
                "maxOutputTokens": "1024",
                "reasoningEffort": preset.aiReasoningEffort,
                "schemaName": AIHaplotypingRunner.minimalMCMSchemaName,
                "temperature": "0",
            ],
            parentRevisionID: "haprev-det-0001",
            registryDigest: registry.digest,
            inputSnapshotDigest: registry.inputSnapshotDigest
        )
        let report = AIHaplotypingValidationReport(
            accepted: true,
            run: run,
            chunkID: "chunk-0001",
            registryDigest: registry.digest,
            inputSnapshotDigest: registry.inputSnapshotDigest,
            normalizedCalls: base.normalizedCalls,
            validatedDefinitions: base.validatedDefinitions,
            warnings: [],
            errors: []
        )
        let prompt = AIHaplotypingPromptMetadata(
            promptTemplateID: run.promptTemplateID,
            promptTemplateVersion: run.promptTemplateVersion,
            promptHash: run.promptHash,
            evidenceSchemaVersion: 1,
            registryDigest: registry.digest,
            inputSnapshotDigest: registry.inputSnapshotDigest,
            evidenceSnapshotPath: "ai-haplotyping/evidence/chunk-0001.json",
            knowledgePackID: nil,
            knowledgePackVersion: nil,
            knowledgePackDigest: nil
        )
        let attempt = AIProviderAttemptMetadata(
            attemptIndex: 0,
            fallbackIndex: 0,
            provider: "openai",
            model: preset.aiOpenAIModel,
            endpoint: "/v1/responses",
            apiVersion: "2026-01-01",
            credentialSource: "environment:OPENAI_API_KEY",
            apiKeyAvailable: true,
            requestID: "req-mcm",
            statusCode: 200,
            stopReason: "stop",
            inputTokens: 27000,
            outputTokens: 800,
            sanitizedErrorCategory: nil
        )
        return AIHaplotypingRunnerOutput(
            mode: base.mode,
            registry: registry,
            chunkOutputs: [
                AIHaplotypingChunkOutput(
                    chunkID: "chunk-0001",
                    registryDigest: registry.digest,
                    inputSnapshotDigest: registry.inputSnapshotDigest,
                    promptMetadata: prompt,
                    payloadDigest: "sha256:\(String(repeating: "5", count: 64))",
                    validationReport: report,
                    providerAttempt: attempt
                )
            ],
            normalizedCalls: base.normalizedCalls,
            validatedDefinitions: base.validatedDefinitions,
            validationReports: [report],
            providerAttempts: [attempt]
        )
    }

    func makeRegistry() -> AIHaplotypingEvidenceRegistry {
        AIHaplotypingEvidenceRegistry(
            mode: .aiRefinement,
            parentRevisionID: "haprev-det-0001",
            inputSnapshotDigest: "sha256:\(String(repeating: "1", count: 64))",
            samples: [
                SampleEvidence(id: "sample:DW472", sample: "DW472"),
                SampleEvidence(id: "sample:DW473", sample: "DW473"),
            ],
            loci: [
                LocusEvidence(id: "locus:MHC-A", locus: "MHC-A"),
                LocusEvidence(id: "locus:MHC-B", locus: "MHC-B"),
            ],
            observations: [
                ObservationEvidence(
                    id: "obs:DW472:MHC-B:12_M9_B_001_01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW472",
                    locusID: "locus:MHC-B",
                    genotype: "12_M9_B_001_01",
                    passedAlignments: 40,
                    passedUniqueReads: 22,
                    sampleUniqueRetainedReads: 100
                ),
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:12_M7_A_001_01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "12_M7_A_001_01",
                    passedAlignments: 44,
                    passedUniqueReads: 24,
                    sampleUniqueRetainedReads: 100
                ),
            ],
            currentCalls: [
                CurrentCallEvidence(
                    id: "current:DW472:MHC-B:h1",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h1",
                    haplotypeLabel: "M9B",
                    source: .deterministic,
                    parentRevisionID: "haprev-det-0001"
                ),
            ],
            manualReviews: [
                ManualReviewEvidence(
                    id: "manual:DW472:MHC-B:h2",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h2",
                    overrideCall: "Manual-M7B",
                    rationale: "Manual carry-forward."
                ),
            ]
        )
    }

    func makeRunMetadata(registry: AIHaplotypingEvidenceRegistry) -> AIHaplotypingRunMetadata {
        AIHaplotypingRunMetadata(
            mode: .aiRefinement,
            promptTemplateID: "lungfish.ai-haplotyping.refinement",
            promptTemplateVersion: "2026-06-14.1",
            promptHash: "sha256:\(String(repeating: "2", count: 64))",
            provider: "openai",
            model: "gpt-5-mini",
            generationParameters: [
                "maxObservationsPerChunk": "128",
                "maxOutputTokens": "4096",
                "schemaName": AIHaplotypingRunner.schemaName,
                "temperature": "0",
            ],
            parentRevisionID: "haprev-det-0001",
            registryDigest: registry.digest,
            inputSnapshotDigest: registry.inputSnapshotDigest
        )
    }

    func validatedCall(
        patchOpID: String,
        slot: String,
        status: GenotypeHaplotypeCallStatus,
        primaryLabel: String?,
        proposedLabel: String,
        callState: GenotypeHaplotypeAICallState,
        sourceState: GenotypeHaplotypeAICallSourceState,
        support: [String],
        counter: [String]
    ) -> AIHaplotypingValidatedCall {
        let metadata = GenotypeHaplotypeAICallMetadata(
            patchOpID: patchOpID,
            source: .ai,
            sourceState: sourceState,
            reviewState: .needsReview,
            callState: callState,
            confidenceTier: .high,
            proposedHaplotypeLabel: proposedLabel,
            supportEvidenceRefs: support,
            counterevidenceRefs: counter,
            alternates: [],
            rationaleCode: "direct_observation",
            rationale: "AI review required.",
            provenancePath: AIHaplotypingPatchValidator.pendingProvenancePath
        )
        return AIHaplotypingValidatedCall(
            patchOpID: patchOpID,
            sample: "DW472",
            locus: "MHC-B",
            slot: slot,
            status: status,
            primaryHaplotypeLabel: primaryLabel,
            proposedHaplotypeLabel: proposedLabel,
            aiMetadata: metadata,
            supportEvidenceRefs: support,
            counterevidenceRefs: counter
        )
    }

    func predecessorAnalysis() -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "deterministic-definitions",
            definitionSetName: "Deterministic definitions",
            speciesName: "Test macaque",
            generatedAt: "2026-06-14T17:00:00Z",
            analysisRevisionID: "haprev-det-0001",
            source: .deterministic,
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "MHC-B",
                            haplotype1: "M9B",
                            haplotype2: "Manual-M7B",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_001_01"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW473",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "M7A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M7_A_001_01"]
                        )
                    ]
                ),
            ]
        )
    }

    func makeONTCall(sample: String, genotype: String) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: 40,
            passedUniqueReads: 20,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    var prettyJSONEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    func recursiveUTF8Text(in directory: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return ""
        }
        var text = ""
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if let chunk = try? String(contentsOf: url, encoding: .utf8) {
                text += chunk
            }
        }
        return text
    }
}
