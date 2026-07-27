import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

private struct AzureOpenAISettings {
    let endpoint: String
    let deployment: String
}

struct GenotypeAIHaplotypingSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai-haplotyping",
        abstract: "Run AI discovery or AI refinement haplotyping on a genotype bundle."
    )

    @Option(name: .customLong("bundle"), help: "Path to the `.lungfishgenotype` result bundle.")
    var bundle: String?

    @Option(name: .customLong("input-table"), help: "Long-form CSV/TSV/JSON genotype rows for prompt preview testing.")
    var inputTable: String?

    @Option(name: .customLong("input-format"), help: "Input table format: auto, csv, tsv, or json.")
    var inputFormat: AIHaplotypingInputTableFormatArgument = .auto

    @Flag(name: .customLong("preview-prompt"), help: "Render prompt/evidence JSON without contacting an AI provider or publishing a revision.")
    var previewPrompt = false

    @Option(name: .customLong("output"), help: "Optional output JSON path for prompt preview artifacts.")
    var output: String?

    @Option(name: .customLong("debug-output"), help: "Write validated AI haplotyping debug JSON without publishing a haplotype revision.")
    var debugOutput: String?

    @Option(name: .customLong("mode"), help: "AI haplotyping mode: ai-discovery or ai-refinement.")
    var mode: AIHaplotypingModeArgument = .aiRefinement

    @Option(name: .customLong("provider"), help: "AI provider: openai or anthropic.")
    var provider: AIHaplotypingProviderArgument = .openAI

    @Option(name: .customLong("model"), help: "Provider model override. Defaults to the provider's app default.")
    var model: String?

    @Option(name: .customLong("azure-openai-endpoint"), help: "Azure OpenAI endpoint, such as https://example.openai.azure.com.")
    var azureOpenAIEndpoint: String?

    @Option(name: .customLong("azure-openai-deployment"), help: "Azure OpenAI deployment name to use instead of a direct OpenAI model.")
    var azureOpenAIDeployment: String?

    @Option(name: .customLong("prompt-template-id"), help: "Prompt template ID to pin for this run.")
    var promptTemplateID: String?

    @Option(name: .customLong("prompt-template-version"), help: "Prompt template version to pin for this run.")
    var promptTemplateVersion: String?

    @Option(
        name: .customLong("max-observations-per-chunk"),
        help: "Maximum observation evidence records per AI request. Defaults high enough to keep each sample in one review chunk."
    )
    var maxObservationsPerChunk: Int = 10_000

    @Option(name: .customLong("max-output-tokens"), help: "Maximum provider output tokens per chunk.")
    var maxOutputTokens: Int = 4096

    @Option(name: .customLong("temperature"), help: "Provider sampling temperature.")
    var temperature: Double = 0

    @Option(name: .customLong("reasoning-effort"), help: "OpenAI Responses API reasoning effort: none, minimal, low, medium, high, or xhigh.")
    var reasoningEffort: String?

    @Option(name: .customLong("max-provider-retries"), help: "Maximum retry attempts for transient AI provider failures per chunk.")
    var maxProviderRetries: Int = 2

    @Flag(name: .customLong("compact-knowledge-pack"), help: "Retrieve only prompt-relevant knowledge-pack records before contacting the AI provider.")
    var compactKnowledgePack = false

    @Option(name: .customLong("review-scope"), help: "AI refinement review scope: all or unresolved-only.")
    var reviewScope: AIHaplotypingReviewScopeArgument = .all

    @Option(name: .customLong("chunk-start-index"), help: "1-based first evidence chunk to run for debug-output smoke runs.")
    var chunkStartIndex: Int = 1

    @Option(name: .customLong("chunk-end-index"), help: "1-based last evidence chunk to run for debug-output smoke runs; 0 means through the final chunk.")
    var chunkEndIndex: Int = 0

    @Option(name: .customLong("population"), help: "Population hint for input-table prompt previews, such as mcm or indian-rhesus.")
    var population: String?

    @Option(name: .customLong("assay-resolution"), help: "Assay resolution hint for input-table prompt previews, such as short-exon-amplicon or full-length.")
    var assayResolution: String?

    @Option(name: .customLong("haplotype-definition"), help: "Haplotype definition/framework hint for input-table prompt previews.")
    var haplotypeDefinition: String?

    @Option(name: .customLong("haplotype-assay"), help: "Haplotype assay hint for input-table prompt previews.")
    var haplotypeAssay: String?

    func validate() throws {
        let trimmedBundle = bundle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInputTable = inputTable?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBundle = !(trimmedBundle ?? "").isEmpty
        let hasInputTable = !(trimmedInputTable ?? "").isEmpty
        if hasBundle == hasInputTable {
            throw ValidationError("Provide exactly one of --bundle or --input-table.")
        }
        if hasInputTable && !previewPrompt {
            throw ValidationError("--input-table is currently supported with --preview-prompt.")
        }
        if hasInputTable && mode == .aiRefinement {
            throw ValidationError("--input-table prompt previews currently support --mode ai-discovery.")
        }
        if debugOutput != nil && previewPrompt {
            throw ValidationError("--debug-output cannot be combined with --preview-prompt.")
        }
        if debugOutput != nil && !hasBundle {
            throw ValidationError("--debug-output requires --bundle.")
        }
        if let output, output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--output must not be empty when supplied.")
        }
        if let debugOutput, debugOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--debug-output must not be empty when supplied.")
        }
        if promptTemplateID != nil && promptTemplateVersion == nil {
            throw ValidationError("--prompt-template-version is required when --prompt-template-id is supplied.")
        }
        if promptTemplateVersion != nil && promptTemplateID == nil {
            throw ValidationError("--prompt-template-id is required when --prompt-template-version is supplied.")
        }
        if maxObservationsPerChunk < 1 {
            throw ValidationError("--max-observations-per-chunk must be at least 1.")
        }
        if maxOutputTokens < 1 {
            throw ValidationError("--max-output-tokens must be at least 1.")
        }
        if temperature < 0 || temperature > 2 {
            throw ValidationError("--temperature must be between 0 and 2.")
        }
        if reasoningEffort != nil && reasoningEffortValue() == nil {
            throw ValidationError("--reasoning-effort must be one of none, minimal, low, medium, high, or xhigh.")
        }
        if let trimmed = reasoningEffortValue() {
            let allowedEfforts: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh"]
            if !allowedEfforts.contains(trimmed) {
                throw ValidationError("--reasoning-effort must be one of none, minimal, low, medium, high, or xhigh.")
            }
        }
        if maxProviderRetries < 0 {
            throw ValidationError("--max-provider-retries must be at least 0.")
        }
        let explicitAzureValues = [
            azureOpenAIEndpoint,
            azureOpenAIDeployment,
        ].contains { value in
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
        if explicitAzureValues && provider != .openAI {
            throw ValidationError("--azure-openai-* options can only be used with --provider openai.")
        }
        if explicitAzureValues {
            _ = try resolvedAzureOpenAISettings(environment: [:])
        }
        if chunkStartIndex < 1 {
            throw ValidationError("--chunk-start-index must be at least 1.")
        }
        if chunkEndIndex < 0 {
            throw ValidationError("--chunk-end-index must be at least 0.")
        }
        if chunkEndIndex > 0 && chunkEndIndex < chunkStartIndex {
            throw ValidationError("--chunk-end-index must be 0 or greater than or equal to --chunk-start-index.")
        }
        if (chunkStartIndex != 1 || chunkEndIndex != 0) && debugOutput == nil {
            throw ValidationError("--debug-output is required when selecting a partial chunk window.")
        }
    }

    func run() async throws {
        if previewPrompt {
            let startedAt = Date()
            let preview = try buildPromptPreview()
            try await writePromptPreview(preview, startedAt: startedAt)
            return
        }
        if debugOutput != nil {
            let summary = try await runReturningDebugSummary()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(summary)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        let summary = try await runReturningSummary()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    func runReturningSummary() async throws -> AIHaplotypingCLISummary {
        let startedAt = Date()
        guard let bundle else {
            throw ValidationError("--bundle is required unless --preview-prompt is supplied.")
        }
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)
        let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        let sidecarSnapshot = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: bundleURL)
        let sidecar = sidecarSnapshot.sidecar
        let activeResult = GenotypeHaplotypeAnalysisResolver.resultByResolvingActiveAnalysis(
            for: result,
            bundleURL: bundleURL,
            sidecar: sidecar
        )
        if mode.promptMode == .aiRefinement, activeResult.haplotypeAnalysis == nil {
            throw ValidationError("AI refinement requires an existing deterministic, manual, or AI haplotype analysis in the bundle.")
        }
        let credential = try await resolvedCredential()
        let providerInstance = try makeProvider(apiKey: credential.apiKey)
        let promptSelection = resolvedPromptSelection(for: activeResult)
        let runOptions = AIHaplotypingRunOptions(
            mode: mode.promptMode,
            providerID: provider.providerID,
            credentialSource: credential.source,
            promptTemplateID: promptSelection.promptTemplateID,
            promptTemplateVersion: promptSelection.promptTemplateVersion,
            maxObservationsPerChunk: maxObservationsPerChunk,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            reasoningEffort: effectiveReasoningEffortValue(),
            maxProviderRetries: maxProviderRetries,
            provenancePath: AIHaplotypingPatchValidator.pendingProvenancePath,
            compactKnowledgePack: promptSelection.compactKnowledgePack,
            includeKnowledgePack: promptSelection.includeKnowledgePack,
            chunkStartIndex: chunkStartIndex,
            chunkEndIndex: chunkEndIndex,
            reviewScope: reviewScope.workflowScope
        )
        let runnerOutput = try await AIHaplotypingRunner(
            provider: providerInstance,
            progressHandler: { Self.writeProgressEventToStandardError($0) }
        ).run(
            result: activeResult,
            sidecar: sidecar,
            options: runOptions
        )
        let context = AIHaplotypingRevisionPublishContext(
            toolName: "lungfish-cli genotype ai-haplotyping",
            toolKind: "cli",
            argv: Self.sanitizedCommandLineArguments(),
            explicitOptions: explicitOptions(
                bundleURL: bundleURL,
                credentialSource: credential.source.rawValue,
                promptSelection: promptSelection
            ),
            defaultOptions: defaultOptions(),
            resolvedOptions: resolvedOptions(
                bundleURL: bundleURL,
                modelID: providerInstance.modelId,
                credentialSource: credential.source.rawValue,
                promptSelection: promptSelection
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            startedAt: startedAt
        )
        let published = try AIHaplotypingRevisionPublisher().publish(
            AIHaplotypingRevisionPublishRequest(
                bundleURL: bundleURL,
                result: activeResult,
                sidecarURL: sidecarURL,
                sidecar: sidecar,
                expectedSidecarRevision: sidecarSnapshot.revision,
                runnerOutput: runnerOutput,
                context: context
            )
        )
        return AIHaplotypingCLISummary(
            bundle: bundleURL.path,
            mode: mode.rawValue,
            provider: provider.providerID.rawValue,
            model: providerInstance.modelId,
            revisionID: published.revision.id,
            analysisPath: published.revision.path,
            reviewState: published.revision.reviewState.rawValue,
            callCount: runnerOutput.normalizedCalls.count,
            discoveredDefinitionCount: runnerOutput.validatedDefinitions.count,
            provenancePath: published.revision.provenancePath
        )
    }

    func runReturningDebugSummary() async throws -> AIHaplotypingCLIDebugSummary {
        let startedAt = Date()
        guard let bundle else {
            throw ValidationError("--bundle is required for --debug-output.")
        }
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)
        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        let activeResult = GenotypeHaplotypeAnalysisResolver.resultByResolvingActiveAnalysis(
            for: result,
            bundleURL: bundleURL,
            sidecar: sidecar
        )
        if mode.promptMode == .aiRefinement, activeResult.haplotypeAnalysis == nil {
            throw ValidationError("AI refinement requires an existing deterministic, manual, or AI haplotype analysis in the bundle.")
        }
        let credential = try await resolvedCredential()
        let providerInstance = try makeProvider(apiKey: credential.apiKey)
        let promptSelection = resolvedPromptSelection(for: activeResult)
        let runOptions = AIHaplotypingRunOptions(
            mode: mode.promptMode,
            providerID: provider.providerID,
            credentialSource: credential.source,
            promptTemplateID: promptSelection.promptTemplateID,
            promptTemplateVersion: promptSelection.promptTemplateVersion,
            maxObservationsPerChunk: maxObservationsPerChunk,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            reasoningEffort: effectiveReasoningEffortValue(),
            maxProviderRetries: maxProviderRetries,
            provenancePath: AIHaplotypingPatchValidator.pendingProvenancePath,
            compactKnowledgePack: promptSelection.compactKnowledgePack,
            includeKnowledgePack: promptSelection.includeKnowledgePack,
            chunkStartIndex: chunkStartIndex,
            chunkEndIndex: chunkEndIndex,
            reviewScope: reviewScope.workflowScope
        )
        let runnerOutput = try await AIHaplotypingRunner(
            provider: providerInstance,
            progressHandler: { Self.writeProgressEventToStandardError($0) }
        ).run(
            result: activeResult,
            sidecar: sidecar,
            options: runOptions
        )
        return try await writeDebugOutput(
            bundleURL: bundleURL,
            runnerOutput: runnerOutput,
            modelID: providerInstance.modelId,
            credentialSource: credential.source.rawValue,
            promptSelection: promptSelection,
            startedAt: startedAt
        )
    }

    func buildPromptPreview() throws -> AIHaplotypingCLIPromptPreview {
        let input = try previewInput()
        let promptSelection = resolvedPromptSelection(for: input.result)
        return try AIHaplotypingPromptPreviewBuilder().build(AIHaplotypingPromptPreviewRequest(
            result: input.result,
            sidecar: input.sidecar,
            mode: mode.promptMode,
            providerID: provider.providerID,
            modelID: try previewModelID(),
            credentialSource: provider.credentialSource,
            promptTemplateID: promptSelection.promptTemplateID,
            promptTemplateVersion: promptSelection.promptTemplateVersion,
            maxObservationsPerChunk: maxObservationsPerChunk,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            reasoningEffort: effectiveReasoningEffortValue(),
            maxProviderRetries: maxProviderRetries,
            provenancePath: AIHaplotypingPatchValidator.pendingProvenancePath,
            compactKnowledgePack: promptSelection.compactKnowledgePack,
            includeKnowledgePack: promptSelection.includeKnowledgePack
        ))
    }

    private func previewInput() throws -> (result: ONTGenotypeResultBundleData, sidecar: GenotypeAnnotationSidecar?) {
        if let inputTable {
            let inputURL = URL(fileURLWithPath: inputTable).standardizedFileURL
            let calls = try AIHaplotypingInputTableLoader.loadCalls(
                from: inputURL,
                format: inputFormat.tableFormat
            )
            return (
                result: Self.tablePreviewResult(
                    inputURL: inputURL,
                    calls: calls,
                    population: population,
                    assayResolution: assayResolution,
                    haplotypeDefinition: haplotypeDefinition,
                    haplotypeAssay: haplotypeAssay
                ),
                sidecar: nil
            )
        }

        guard let bundle else {
            throw ValidationError("Provide --bundle or --input-table for --preview-prompt.")
        }
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)
        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        return (
            result: GenotypeHaplotypeAnalysisResolver.resultByResolvingActiveAnalysis(
                for: result,
                bundleURL: bundleURL,
                sidecar: sidecar
            ),
            sidecar: sidecar
        )
    }

    private static func tablePreviewResult(
        inputURL: URL,
        calls: [ONTGenotypeCall],
        population: String?,
        assayResolution: String?,
        haplotypeDefinition: String?,
        haplotypeAssay: String?
    ) -> ONTGenotypeResultBundleData {
        let definitionHint = nonEmpty(haplotypeDefinition) ?? nonEmpty(population)
        let assayHint = nonEmpty(haplotypeAssay) ?? nonEmpty(assayResolution)
        let manifest = ONTGenotypeResultBundleManifest(
            kind: "ai-haplotyping-table-preview",
            outputName: inputURL.deletingPathExtension().lastPathComponent,
            analysisName: "AI haplotyping prompt preview",
            primaryWorkbookPath: "",
            longSummaryCSVPath: inputURL.lastPathComponent,
            sampleSummaryCSVPath: "",
            statsJSONPath: "",
            provenancePath: "",
            haplotypeDefinitionSetID: definitionHint,
            haplotypeAssayID: assayHint
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: inputURL,
            longSummaryCSVURL: inputURL,
            sampleSummaryCSVURL: inputURL,
            statsJSONURL: inputURL,
            provenanceURL: inputURL
        )
        return ONTGenotypeResultBundleData(
            bundleURL: inputURL.deletingLastPathComponent(),
            manifest: manifest,
            artifacts: artifacts,
            stats: ONTGenotypeRunStats(),
            calls: calls,
            samples: [],
            haplotypeAnalysis: nil
        )
    }

    private func writePromptPreview(
        _ preview: AIHaplotypingCLIPromptPreview,
        startedAt: Date
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preview)
        if let output {
            let outputURL = URL(fileURLWithPath: output).standardizedFileURL
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
            try await recordPromptPreviewProvenance(outputURL: outputURL, preview: preview, startedAt: startedAt)
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func recordPromptPreviewProvenance(
        outputURL: URL,
        preview: AIHaplotypingCLIPromptPreview,
        startedAt: Date
    ) async throws {
        let inputURL = inputTable.map { URL(fileURLWithPath: $0).standardizedFileURL }
        var parameters: [String: ParameterValue] = [
            "mode": .string(mode.promptMode.rawValue),
            "provider": .string(provider.providerID.rawValue),
            "model": .string(try previewModelID()),
            "output": .file(outputURL),
            "previewPrompt": .string("true"),
            "compactKnowledgePack": .string(compactKnowledgePack ? "true" : "false"),
            "maxObservationsPerChunk": .integer(maxObservationsPerChunk),
            "maxOutputTokens": .integer(maxOutputTokens),
            "temperature": .number(temperature),
            "reasoningEffort": effectiveReasoningEffortValue().map(ParameterValue.string) ?? .null,
            "maxProviderRetries": .integer(maxProviderRetries),
            "chunkStartIndex": .integer(chunkStartIndex),
            "chunkEndIndex": .integer(chunkEndIndex),
            "promptTemplateID": promptTemplateID.map(ParameterValue.string) ?? .null,
            "promptTemplateVersion": promptTemplateVersion.map(ParameterValue.string) ?? .null,
            "resolvedPromptTemplateID": .string(preview.promptTemplate.id),
            "resolvedPromptTemplateVersion": .string(preview.promptTemplate.version),
            "includeKnowledgePack": .string(preview.knowledgePack == nil ? "false" : "true"),
            "resolvedCompactKnowledgePack": .string(preview.knowledgePack == nil ? "false" : (compactKnowledgePack ? "true" : "false")),
            "chunkCount": .integer(preview.chunkCount),
            "observationCount": .integer(preview.observationCount),
        ]
        if let inputURL {
            parameters["inputTable"] = .file(inputURL)
            parameters["inputFormat"] = .string(inputFormat.rawValue)
        }
        if let bundle {
            parameters["bundle"] = .file(URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL)
        }
        if let population, !population.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parameters["population"] = .string(population)
        }
        if let assayResolution, !assayResolution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parameters["assayResolution"] = .string(assayResolution)
        }
        if let haplotypeDefinition, !haplotypeDefinition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parameters["haplotypeDefinition"] = .string(haplotypeDefinition)
        }
        if let haplotypeAssay, !haplotypeAssay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parameters["haplotypeAssay"] = .string(haplotypeAssay)
        }
        if let azure = try resolvedAzureOpenAISettings(environment: ProcessInfo.processInfo.environment) {
            addAzureOpenAIOptions(azure, to: &parameters)
        }

        let inputs = [inputURL].compactMap { url in
            url.map { ProvenanceRecorder.fileRecord(url: $0, role: .input) }
        }
        let outputs = [
            ProvenanceRecorder.fileRecord(url: outputURL, format: .json, role: .output),
        ]
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish genotype ai-haplotyping preview-prompt",
            parameters: parameters,
            defaults: defaultOptions(),
            resolved: parameters,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: previewCommand(outputURL: outputURL, preview: preview),
            inputs: inputs,
            outputs: outputs,
            exitCode: 0,
            wallTime: max(0, Date().timeIntervalSince(startedAt)),
            stderr: nil,
            status: .completed,
            outputDirectory: outputURL.deletingLastPathComponent(),
            writeFileSidecars: true
        )
    }

    func writeDebugOutput(
        bundleURL: URL,
        runnerOutput: AIHaplotypingRunnerOutput,
        modelID: String,
        credentialSource: String,
        promptSelection: AIHaplotypingPromptSelection,
        startedAt: Date
    ) async throws -> AIHaplotypingCLIDebugSummary {
        guard let debugOutput else {
            throw ValidationError("--debug-output is required.")
        }
        let outputURL = URL(fileURLWithPath: debugOutput).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let summary = AIHaplotypingCLIDebugSummary(
            bundle: bundleURL.path,
            mode: mode.rawValue,
            provider: provider.providerID.rawValue,
            model: modelID,
            debugOutput: outputURL.path,
            chunkStartIndex: chunkStartIndex,
            chunkEndIndex: chunkEndIndex,
            chunkCount: runnerOutput.chunkOutputs.count,
            chunkIDs: runnerOutput.chunkOutputs.map(\.chunkID),
            callCount: runnerOutput.normalizedCalls.count,
            discoveredDefinitionCount: runnerOutput.validatedDefinitions.count,
            provenancePath: provenanceURL.path
        )
        let artifact = AIHaplotypingCLIDebugOutput(summary: summary, runnerOutput: runnerOutput)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(artifact)
        try data.write(to: outputURL, options: .atomic)
        try await recordDebugOutputProvenance(
            outputURL: outputURL,
            bundleURL: bundleURL,
            summary: summary,
            modelID: modelID,
            credentialSource: credentialSource,
            promptSelection: promptSelection,
            startedAt: startedAt
        )
        return summary
    }

    private func recordDebugOutputProvenance(
        outputURL: URL,
        bundleURL: URL,
        summary: AIHaplotypingCLIDebugSummary,
        modelID: String,
        credentialSource: String,
        promptSelection: AIHaplotypingPromptSelection,
        startedAt: Date
    ) async throws {
        var explicit = explicitOptions(
            bundleURL: bundleURL,
            credentialSource: credentialSource,
            promptSelection: promptSelection
        )
        explicit["debugOutput"] = .file(outputURL)
        explicit["chunkCount"] = .integer(summary.chunkCount)
        explicit["chunkIDs"] = .array(summary.chunkIDs.map(ParameterValue.string))
        explicit["callCount"] = .integer(summary.callCount)
        explicit["discoveredDefinitionCount"] = .integer(summary.discoveredDefinitionCount)

        var resolved = resolvedOptions(
            bundleURL: bundleURL,
            modelID: modelID,
            credentialSource: credentialSource,
            promptSelection: promptSelection
        )
        resolved["debugOutput"] = .file(outputURL)
        resolved["chunkCount"] = .integer(summary.chunkCount)
        resolved["chunkIDs"] = .array(summary.chunkIDs.map(ParameterValue.string))
        resolved["callCount"] = .integer(summary.callCount)
        resolved["discoveredDefinitionCount"] = .integer(summary.discoveredDefinitionCount)

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish genotype ai-haplotyping debug-output",
            parameters: explicit,
            defaults: defaultOptions(),
            resolved: resolved,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: debugCommand(outputURL: outputURL, modelID: modelID, promptSelection: promptSelection),
            inputs: [
                ProvenanceRecorder.fileOrDirectoryRecord(url: bundleURL, role: .input),
            ],
            outputs: [
                ProvenanceRecorder.fileRecord(url: outputURL, format: .json, role: .output),
            ],
            exitCode: 0,
            wallTime: max(0, Date().timeIntervalSince(startedAt)),
            stderr: nil,
            status: .completed,
            outputDirectory: outputURL.deletingLastPathComponent(),
            writeFileSidecars: true
        )
    }

    private func resolvedCredential() async throws -> (apiKey: String, source: AIHaplotypingCredentialSource) {
        let prefersAzureOpenAI: Bool
        if provider == .openAI {
            prefersAzureOpenAI = try resolvedAzureOpenAISettings(environment: ProcessInfo.processInfo.environment) != nil
        } else {
            prefersAzureOpenAI = false
        }
        return try await Self.resolveCredential(
            provider: provider,
            environment: ProcessInfo.processInfo.environment,
            preferAzureOpenAI: prefersAzureOpenAI,
            keychainLookup: { key in
                try await KeychainSecretStorage.shared.retrieve(forKey: key)
            }
        )
    }

    static func resolveCredential(
        provider: AIHaplotypingProviderArgument,
        environment: [String: String],
        preferAzureOpenAI: Bool? = nil,
        keychainLookup: (String) async throws -> String?
    ) async throws -> (apiKey: String, source: AIHaplotypingCredentialSource) {
        let shouldUseAzureOpenAI = preferAzureOpenAI ?? environmentHasAzureOpenAISettings(environment)
        if provider == .openAI && shouldUseAzureOpenAI {
            let azureAPIKey = environment["AZURE_OPENAI_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !azureAPIKey.isEmpty {
                return (azureAPIKey, .environmentAzureOpenAI)
            }
        }

        let environmentName = provider.defaultEnvironmentVariable
        let environmentAPIKey = environment[environmentName]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !environmentAPIKey.isEmpty {
            return (environmentAPIKey, provider.environmentCredentialSource)
        }

        let keychainAPIKey = try await keychainLookup(provider.keychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !keychainAPIKey.isEmpty {
            return (keychainAPIKey, provider.keychainCredentialSource)
        }

        throw ValidationError("Missing API key. Set \(environmentName) or configure \(provider.keychainKey) in the app settings.")
    }

    private func openAIEndpointConfiguration(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> OpenAIEndpointConfiguration {
        guard provider == .openAI else {
            return .direct
        }
        guard let azure = try resolvedAzureOpenAISettings(environment: environment) else {
            return .direct
        }
        return try .azure(
            endpointString: azure.endpoint,
            deployment: azure.deployment
        )
    }

    private func resolvedAzureOpenAISettings(environment: [String: String]) throws -> AzureOpenAISettings? {
        let endpoint = Self.nonEmpty(azureOpenAIEndpoint)
            ?? Self.nonEmpty(environment["AZURE_OPENAI_ENDPOINT"])
        let deployment = Self.nonEmpty(azureOpenAIDeployment)
            ?? Self.nonEmpty(environment["AZURE_OPENAI_DEPLOYMENT"])

        let hasAnyAzureSetting = endpoint != nil
            || deployment != nil
        guard hasAnyAzureSetting else {
            return nil
        }
        guard provider == .openAI else {
            throw ValidationError("Azure OpenAI settings can only be used with --provider openai.")
        }
        guard let endpoint else {
            throw ValidationError("Azure OpenAI endpoint is required when Azure OpenAI settings are supplied.")
        }
        guard let deployment else {
            throw ValidationError("Azure OpenAI deployment is required when Azure OpenAI settings are supplied.")
        }
        _ = try OpenAIEndpointConfiguration.azure(
            endpointString: endpoint,
            deployment: deployment
        )
        return AzureOpenAISettings(
            endpoint: OpenAIEndpointConfiguration.normalizeEndpointString(endpoint),
            deployment: deployment
        )
    }

    private static func environmentHasAzureOpenAISettings(_ environment: [String: String]) -> Bool {
        nonEmpty(environment["AZURE_OPENAI_ENDPOINT"]) != nil
            || nonEmpty(environment["AZURE_OPENAI_DEPLOYMENT"]) != nil
    }

    private func makeProvider(apiKey: String) throws -> any StructuredAIProvider {
        switch provider {
        case .openAI:
            return OpenAIProvider(
                apiKey: apiKey,
                modelId: modelValue(default: MCMHaplotypingPreset.mcmMHCmiseq.aiOpenAIModel),
                endpointConfiguration: try openAIEndpointConfiguration()
            )
        case .anthropic:
            return AnthropicProvider(apiKey: apiKey, modelId: modelValue(default: "claude-sonnet-4-6"))
        }
    }

    private func previewModelID(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if provider == .openAI, let azure = try resolvedAzureOpenAISettings(environment: environment) {
            return azure.deployment
        }
        return modelValue(default: provider.defaultPreviewModel)
    }

    private func modelValue(default defaultModel: String) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    private func reasoningEffortValue() -> String? {
        let trimmed = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func effectiveReasoningEffortValue() -> String? {
        if let reasoningEffort = reasoningEffortValue() {
            return reasoningEffort
        }
        return provider == .openAI ? MCMHaplotypingPreset.mcmMHCmiseq.aiReasoningEffort : nil
    }

    private func previewCommand(outputURL: URL, preview: AIHaplotypingCLIPromptPreview) -> [String] {
        var command = [CLICommandIdentity.executableName, "genotype", "ai-haplotyping"]
        if let bundle {
            command += ["--bundle", URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL.path]
        }
        if let inputTable {
            command += ["--input-table", URL(fileURLWithPath: inputTable).standardizedFileURL.path]
            command += ["--input-format", inputFormat.rawValue]
        }
        command += [
            "--preview-prompt",
            "--output", outputURL.path,
            "--mode", mode.rawValue,
            "--provider", provider.rawValue,
            "--model", (try? previewModelID()) ?? modelValue(default: provider.defaultPreviewModel),
            "--max-observations-per-chunk", String(maxObservationsPerChunk),
            "--max-output-tokens", String(maxOutputTokens),
            "--temperature", String(temperature),
            "--max-provider-retries", String(maxProviderRetries),
        ]
        appendAzureOpenAIArguments(to: &command)
        if let reasoningEffort = effectiveReasoningEffortValue() {
            command += ["--reasoning-effort", reasoningEffort]
        }
        command += [
            "--prompt-template-id", preview.promptTemplate.id,
            "--prompt-template-version", preview.promptTemplate.version,
        ]
        if compactKnowledgePack && preview.knowledgePack != nil {
            command += ["--compact-knowledge-pack"]
        }
        if let population, !population.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command += ["--population", population]
        }
        if let assayResolution, !assayResolution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command += ["--assay-resolution", assayResolution]
        }
        if let haplotypeDefinition, !haplotypeDefinition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command += ["--haplotype-definition", haplotypeDefinition]
        }
        if let haplotypeAssay, !haplotypeAssay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command += ["--haplotype-assay", haplotypeAssay]
        }
        return command
    }

    private func debugCommand(
        outputURL: URL,
        modelID: String,
        promptSelection: AIHaplotypingPromptSelection
    ) -> [String] {
        var command = [CLICommandIdentity.executableName, "genotype", "ai-haplotyping"]
        if let bundle {
            command += ["--bundle", URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL.path]
        }
        command += [
            "--debug-output", outputURL.path,
            "--mode", mode.rawValue,
            "--provider", provider.rawValue,
            "--model", modelID,
            "--max-observations-per-chunk", String(maxObservationsPerChunk),
            "--max-output-tokens", String(maxOutputTokens),
            "--temperature", String(temperature),
            "--max-provider-retries", String(maxProviderRetries),
            "--chunk-start-index", String(chunkStartIndex),
            "--chunk-end-index", String(chunkEndIndex),
        ]
        appendAzureOpenAIArguments(to: &command)
        if let reasoningEffort = effectiveReasoningEffortValue() {
            command += ["--reasoning-effort", reasoningEffort]
        }
        if promptSelection.compactKnowledgePack {
            command += ["--compact-knowledge-pack"]
        }
        if let promptTemplateID = promptSelection.promptTemplateID {
            command += ["--prompt-template-id", promptTemplateID]
        }
        if let promptTemplateVersion = promptSelection.promptTemplateVersion {
            command += ["--prompt-template-version", promptTemplateVersion]
        }
        return command
    }

    private func explicitOptions(
        bundleURL: URL,
        credentialSource: String,
        promptSelection: AIHaplotypingPromptSelection
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "mode": .string(mode.promptMode.rawValue),
            "provider": .string(provider.providerID.rawValue),
            "credentialSource": .string(credentialSource),
            "maxObservationsPerChunk": .integer(maxObservationsPerChunk),
            "maxOutputTokens": .integer(maxOutputTokens),
            "temperature": .number(temperature),
            "reasoningEffort": reasoningEffortValue().map(ParameterValue.string) ?? .null,
            "resolvedReasoningEffort": effectiveReasoningEffortValue().map(ParameterValue.string) ?? .null,
            "maxProviderRetries": .integer(maxProviderRetries),
            "compactKnowledgePack": .string(compactKnowledgePack ? "true" : "false"),
            "includeKnowledgePack": .string(promptSelection.includeKnowledgePack ? "true" : "false"),
            "resolvedPromptTemplateID": promptSelection.promptTemplateID.map(ParameterValue.string) ?? .null,
            "resolvedPromptTemplateVersion": promptSelection.promptTemplateVersion.map(ParameterValue.string) ?? .null,
            "resolvedCompactKnowledgePack": .string(promptSelection.compactKnowledgePack ? "true" : "false"),
            "reviewScope": .string(reviewScope.workflowScope.rawValue),
            "chunkStartIndex": .integer(chunkStartIndex),
            "chunkEndIndex": .integer(chunkEndIndex),
        ]
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options["model"] = .string(model)
        }
        if let azure = try? resolvedAzureOpenAISettings(environment: ProcessInfo.processInfo.environment) {
            addAzureOpenAIOptions(azure, to: &options)
        }
        if let promptTemplateID {
            options["promptTemplateID"] = .string(promptTemplateID)
        }
        if let promptTemplateVersion {
            options["promptTemplateVersion"] = .string(promptTemplateVersion)
        }
        return options
    }

    private func defaultOptions() -> [String: ParameterValue] {
        [
            "provider": .string(AIHaplotypingProviderArgument.openAI.providerID.rawValue),
            "openAIModel": .string(MCMHaplotypingPreset.mcmMHCmiseq.aiOpenAIModel),
            "anthropicModel": .string("claude-sonnet-4-6"),
            "azureOpenAIEndpoint": .null,
            "azureOpenAIDeployment": .null,
            "maxObservationsPerChunk": .integer(10_000),
            "maxOutputTokens": .integer(4096),
            "temperature": .number(0),
            "reasoningEffort": .string(MCMHaplotypingPreset.mcmMHCmiseq.aiReasoningEffort),
            "maxProviderRetries": .integer(2),
            "compactKnowledgePack": .string("false"),
            "includeKnowledgePack": .string("true"),
            "reviewScope": .string(AIHaplotypingReviewScope.all.rawValue),
            "chunkStartIndex": .integer(1),
            "chunkEndIndex": .integer(0),
        ]
    }

    private func resolvedOptions(
        bundleURL: URL,
        modelID: String,
        credentialSource: String,
        promptSelection: AIHaplotypingPromptSelection
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "mode": .string(mode.promptMode.rawValue),
            "provider": .string(provider.providerID.rawValue),
            "model": .string(modelID),
            "credentialSource": .string(credentialSource),
            "promptTemplateID": promptSelection.promptTemplateID.map(ParameterValue.string) ?? .null,
            "promptTemplateVersion": promptSelection.promptTemplateVersion.map(ParameterValue.string) ?? .null,
            "maxObservationsPerChunk": .integer(maxObservationsPerChunk),
            "maxOutputTokens": .integer(maxOutputTokens),
            "temperature": .number(temperature),
            "reasoningEffort": effectiveReasoningEffortValue().map(ParameterValue.string) ?? .null,
            "maxProviderRetries": .integer(maxProviderRetries),
            "compactKnowledgePack": .string(promptSelection.compactKnowledgePack ? "true" : "false"),
            "includeKnowledgePack": .string(promptSelection.includeKnowledgePack ? "true" : "false"),
            "usesSpecialistPrompt": .string(promptSelection.usesSpecialistPrompt ? "true" : "false"),
            "reviewScope": .string(reviewScope.workflowScope.rawValue),
            "chunkStartIndex": .integer(chunkStartIndex),
            "chunkEndIndex": .integer(chunkEndIndex),
        ]
        if let azure = try? resolvedAzureOpenAISettings(environment: ProcessInfo.processInfo.environment) {
            addAzureOpenAIOptions(azure, to: &options)
        }
        return options
    }

    private func appendAzureOpenAIArguments(
        to command: inout [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let azure = try? resolvedAzureOpenAISettings(environment: environment) else {
            return
        }
        command += [
            "--azure-openai-endpoint", azure.endpoint,
            "--azure-openai-deployment", azure.deployment,
        ]
    }

    private func addAzureOpenAIOptions(
        _ azure: AzureOpenAISettings,
        to options: inout [String: ParameterValue]
    ) {
        options["azureOpenAIEndpoint"] = .string(azure.endpoint)
        options["azureOpenAIDeployment"] = .string(azure.deployment)
    }

    private func resolvedPromptSelection(for result: ONTGenotypeResultBundleData) -> AIHaplotypingPromptSelection {
        AIHaplotypingPromptSelectionResolver.resolve(
            result: result,
            mode: mode.promptMode,
            requestedPromptTemplateID: promptTemplateID,
            requestedPromptTemplateVersion: promptTemplateVersion,
            compactKnowledgePack: compactKnowledgePack
        )
    }

    private static func sanitizedCommandLineArguments() -> [String] {
        CommandLine.arguments
    }

    private static func writeProgressEventToStandardError(_ event: AIHaplotypingProgressEvent) {
        let line: String
        switch event {
        case .runStarted(let chunkCount, let observationCount):
            line = "AI haplotyping: starting \(chunkCount) chunk(s), \(observationCount) observation(s)"
        case .chunkStarted(let chunkID, let chunkIndex, let chunkCount, let observationCount):
            line = "AI haplotyping: \(chunkID) \(chunkIndex)/\(chunkCount) started (\(observationCount) observation(s))"
        case .providerRetry(let chunkID, let retryIndex, let maxRetries, let errorCategory):
            line = "AI haplotyping: \(chunkID) retry \(retryIndex)/\(maxRetries) after \(errorCategory)"
        case .chunkFinished(let chunkID, let chunkIndex, let chunkCount, let callCount, let definitionCount):
            line = "AI haplotyping: \(chunkID) \(chunkIndex)/\(chunkCount) accepted (\(callCount) call(s), \(definitionCount) definition(s))"
        case .runFinished(let chunkCount, let callCount, let definitionCount):
            line = "AI haplotyping: finished \(chunkCount) chunk(s), \(callCount) call(s), \(definitionCount) definition(s)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

enum AIHaplotypingModeArgument: String, CaseIterable, ExpressibleByArgument {
    case aiDiscovery = "ai-discovery"
    case aiRefinement = "ai-refinement"

    var promptMode: AIHaplotypingPromptMode {
        switch self {
        case .aiDiscovery: return .aiDiscovery
        case .aiRefinement: return .aiRefinement
        }
    }
}

enum AIHaplotypingReviewScopeArgument: String, CaseIterable, ExpressibleByArgument {
    case all
    case unresolvedOnly = "unresolved-only"

    var workflowScope: AIHaplotypingReviewScope {
        switch self {
        case .all: return .all
        case .unresolvedOnly: return .unresolvedOnly
        }
    }
}

enum AIHaplotypingProviderArgument: String, CaseIterable, ExpressibleByArgument {
    case openAI = "openai"
    case anthropic

    var providerID: AIHaplotypingProviderID {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        }
    }

    var defaultEnvironmentVariable: String {
        switch self {
        case .openAI: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }

    var credentialSource: AIHaplotypingCredentialSource {
        environmentCredentialSource
    }

    var environmentCredentialSource: AIHaplotypingCredentialSource {
        switch self {
        case .openAI: return .environmentOpenAI
        case .anthropic: return .environmentAnthropic
        }
    }

    var keychainCredentialSource: AIHaplotypingCredentialSource {
        switch self {
        case .openAI: return .keychainOpenAI
        case .anthropic: return .keychainAnthropic
        }
    }

    var keychainKey: String {
        switch self {
        case .openAI: return KeychainSecretStorage.openAIAPIKey
        case .anthropic: return KeychainSecretStorage.anthropicAPIKey
        }
    }

    var defaultPreviewModel: String {
        switch self {
        case .openAI: return MCMHaplotypingPreset.mcmMHCmiseq.aiOpenAIModel
        case .anthropic: return "claude-sonnet-4-6"
        }
    }
}

struct AIHaplotypingCLISummary: Codable, Equatable {
    let bundle: String
    let mode: String
    let provider: String
    let model: String
    let revisionID: String
    let analysisPath: String
    let reviewState: String
    let callCount: Int
    let discoveredDefinitionCount: Int
    let provenancePath: String
}

struct AIHaplotypingCLIDebugSummary: Codable, Equatable {
    let bundle: String
    let mode: String
    let provider: String
    let model: String
    let debugOutput: String
    let chunkStartIndex: Int
    let chunkEndIndex: Int
    let chunkCount: Int
    let chunkIDs: [String]
    let callCount: Int
    let discoveredDefinitionCount: Int
    let provenancePath: String
}

struct AIHaplotypingCLIDebugOutput: Codable, Equatable {
    let summary: AIHaplotypingCLIDebugSummary
    let runnerOutput: AIHaplotypingRunnerOutput
}

typealias AIHaplotypingCLIPromptPreview = AIHaplotypingPromptPreview

enum AIHaplotypingInputTableFormatArgument: String, CaseIterable, ExpressibleByArgument {
    case auto
    case csv
    case tsv
    case json

    var tableFormat: AIHaplotypingInputTableFormat {
        switch self {
        case .auto: return .auto
        case .csv: return .csv
        case .tsv: return .tsv
        case .json: return .json
        }
    }
}

enum AIHaplotypingInputTableFormat: Equatable {
    case auto
    case csv
    case tsv
    case json
}

enum AIHaplotypingInputTableLoader {
    static func loadCalls(
        from url: URL,
        format: AIHaplotypingInputTableFormat
    ) throws -> [ONTGenotypeCall] {
        let resolvedFormat = try resolveFormat(format, url: url)
        switch resolvedFormat {
        case .json:
            return try loadJSONCalls(from: url)
        case .csv:
            return try loadDelimitedCalls(from: url, delimiter: ",")
        case .tsv:
            return try loadDelimitedCalls(from: url, delimiter: "\t")
        case .auto:
            preconditionFailure("auto format should be resolved before loading")
        }
    }

    private static func resolveFormat(
        _ format: AIHaplotypingInputTableFormat,
        url: URL
    ) throws -> AIHaplotypingInputTableFormat {
        guard format == .auto else { return format }
        switch url.pathExtension.lowercased() {
        case "csv":
            return .csv
        case "tsv", "tab":
            return .tsv
        case "json":
            return .json
        default:
            throw ValidationError("Could not infer --input-format from \(url.lastPathComponent); use --input-format csv, tsv, or json.")
        }
    }

    private static func loadJSONCalls(from url: URL) throws -> [ONTGenotypeCall] {
        let data = try Data(contentsOf: url)
        if let calls = try? JSONDecoder().decode([ONTGenotypeCall].self, from: data) {
            return calls
        }
        let rows = try JSONDecoder().decode([LooseJSONRow].self, from: data)
        return try rows.enumerated().compactMap { offset, row in
            try row.call(rowNumber: offset + 1)
        }
    }

    private static func loadDelimitedCalls(from url: URL, delimiter: Character) throws -> [ONTGenotypeCall] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let rows = parseDelimited(content, delimiter: delimiter)
        guard let header = rows.first, !header.isEmpty else {
            throw ValidationError("Input table \(url.path) does not contain a header row.")
        }
        let headerIndex = Dictionary(uniqueKeysWithValues: header.enumerated().map { offset, name in
            (normalizedHeader(name), offset)
        })
        let sampleColumn = try requiredColumn(
            aliases: ["sample", "sampleid", "clientid", "gsid", "animal", "animalid"],
            in: headerIndex,
            label: "sample"
        )
        let genotypeColumn = try requiredColumn(
            aliases: ["genotype", "allele", "marker", "sequence", "call", "genotypelabel"],
            in: headerIndex,
            label: "genotype"
        )
        let alignmentsColumn = optionalColumn(
            aliases: ["passedalignments", "alignments", "mappedreadcount", "readcount", "reads", "count"],
            in: headerIndex
        )
        let uniqueColumn = optionalColumn(
            aliases: ["passeduniquereads", "uniquereads", "unique", "observations"],
            in: headerIndex
        )
        let sampleUniqueColumn = optionalColumn(
            aliases: ["sampleuniqueretainedreads", "uniqueretainedreads", "sampleunique"],
            in: headerIndex
        )

        let calls = try rows.dropFirst().enumerated().compactMap { offset, row -> ONTGenotypeCall? in
            let sample = value(at: sampleColumn, in: row).trimmingCharacters(in: .whitespacesAndNewlines)
            let genotype = value(at: genotypeColumn, in: row).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sample.isEmpty || !genotype.isEmpty else { return nil }
            guard !sample.isEmpty else {
                throw ValidationError("Input table row \(offset + 2) is missing a sample value.")
            }
            guard !genotype.isEmpty else {
                throw ValidationError("Input table row \(offset + 2) is missing a genotype value.")
            }
            let alignments = integerValue(at: alignmentsColumn, in: row) ?? 0
            let uniqueReads = integerValue(at: uniqueColumn, in: row) ?? alignments
            return ONTGenotypeCall(
                sample: sample,
                genotype: genotype,
                passedAlignments: alignments,
                passedUniqueReads: uniqueReads,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: integerValue(at: sampleUniqueColumn, in: row),
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
        guard !calls.isEmpty else {
            throw ValidationError("Input table \(url.path) did not contain any genotype rows.")
        }
        return calls
    }

    private static func requiredColumn(
        aliases: [String],
        in headerIndex: [String: Int],
        label: String
    ) throws -> Int {
        if let column = optionalColumn(aliases: aliases, in: headerIndex) {
            return column
        }
        throw ValidationError("Input table is missing a \(label) column.")
    }

    private static func optionalColumn(aliases: [String], in headerIndex: [String: Int]) -> Int? {
        aliases.compactMap { headerIndex[$0] }.first
    }

    private static func value(at index: Int?, in row: [String]) -> String {
        guard let index, row.indices.contains(index) else { return "" }
        return row[index]
    }

    private static func integerValue(at index: Int?, in row: [String]) -> Int? {
        let raw = value(at: index, in: row)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !raw.isEmpty else { return nil }
        return Int(raw)
    }

    private static func normalizedHeader(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func parseDelimited(_ content: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = content.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        consume(character: next, delimiter: delimiter, row: &row, field: &field, rows: &rows, inQuotes: &inQuotes)
                    }
                } else {
                    inQuotes.toggle()
                }
            } else {
                consume(character: character, delimiter: delimiter, row: &row, field: &field, rows: &rows, inQuotes: &inQuotes)
            }
        }
        appendField(&field, to: &row)
        appendRow(row, to: &rows)
        return rows
    }

    private static func consume(
        character: Character,
        delimiter: Character,
        row: inout [String],
        field: inout String,
        rows: inout [[String]],
        inQuotes: inout Bool
    ) {
        if character == delimiter && !inQuotes {
            appendField(&field, to: &row)
        } else if character == "\n" && !inQuotes {
            appendField(&field, to: &row)
            appendRow(row, to: &rows)
            row.removeAll()
        } else if character == "\r" && !inQuotes {
            return
        } else {
            field.append(character)
        }
    }

    private static func appendField(_ field: inout String, to row: inout [String]) {
        row.append(field)
        field.removeAll(keepingCapacity: true)
    }

    private static func appendRow(_ row: [String], to rows: inout [[String]]) {
        guard row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return
        }
        rows.append(row)
    }

    private struct LooseJSONRow: Decodable {
        let sample: String?
        let sampleID: String?
        let genotype: String?
        let allele: String?
        let passedAlignments: Int?
        let passedUniqueReads: Int?
        let reads: Int?
        let sampleUniqueRetainedReads: Int?

        func call(rowNumber: Int) throws -> ONTGenotypeCall? {
            let sampleValue = (sample ?? sampleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let genotypeValue = (genotype ?? allele ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sampleValue.isEmpty || !genotypeValue.isEmpty else { return nil }
            guard !sampleValue.isEmpty else {
                throw ValidationError("Input JSON row \(rowNumber) is missing a sample value.")
            }
            guard !genotypeValue.isEmpty else {
                throw ValidationError("Input JSON row \(rowNumber) is missing a genotype value.")
            }
            let alignments = passedAlignments ?? reads ?? 0
            return ONTGenotypeCall(
                sample: sampleValue,
                genotype: genotypeValue,
                passedAlignments: alignments,
                passedUniqueReads: passedUniqueReads ?? alignments,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: sampleUniqueRetainedReads,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
    }
}
