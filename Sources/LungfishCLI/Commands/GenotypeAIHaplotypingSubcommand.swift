import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

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

    @Option(name: .customLong("mode"), help: "AI haplotyping mode: ai-discovery or ai-refinement.")
    var mode: AIHaplotypingModeArgument = .aiRefinement

    @Option(name: .customLong("provider"), help: "AI provider: openai or anthropic.")
    var provider: AIHaplotypingProviderArgument = .anthropic

    @Option(name: .customLong("model"), help: "Provider model override. Defaults to the provider's app default.")
    var model: String?

    @Option(name: .customLong("prompt-template-id"), help: "Prompt template ID to pin for this run.")
    var promptTemplateID: String?

    @Option(name: .customLong("prompt-template-version"), help: "Prompt template version to pin for this run.")
    var promptTemplateVersion: String?

    @Option(name: .customLong("max-observations-per-chunk"), help: "Maximum observation evidence records per AI request.")
    var maxObservationsPerChunk: Int = 128

    @Option(name: .customLong("max-output-tokens"), help: "Maximum provider output tokens per chunk.")
    var maxOutputTokens: Int = 4096

    @Option(name: .customLong("temperature"), help: "Provider sampling temperature.")
    var temperature: Double = 0

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
        if let output, output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--output must not be empty when supplied.")
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
    }

    func run() async throws {
        if previewPrompt {
            let startedAt = Date()
            let preview = try buildPromptPreview()
            try await writePromptPreview(preview, startedAt: startedAt)
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
        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        let activeResult = GenotypeHaplotypeAnalysisResolver.resultByResolvingActiveAnalysis(
            for: result,
            bundleURL: bundleURL,
            sidecar: sidecar
        )
        if mode.promptMode == .aiRefinement, activeResult.haplotypeAnalysis == nil {
            throw ValidationError("AI refinement requires an existing deterministic, manual, or AI haplotype analysis in the bundle.")
        }
        let credential = try resolvedCredential()
        let providerInstance = makeProvider(apiKey: credential.apiKey)
        let runOptions = AIHaplotypingRunOptions(
            mode: mode.promptMode,
            providerID: provider.providerID,
            credentialSource: credential.source,
            promptTemplateID: promptTemplateID,
            promptTemplateVersion: promptTemplateVersion,
            maxObservationsPerChunk: maxObservationsPerChunk,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            provenancePath: AIHaplotypingPatchValidator.pendingProvenancePath
        )
        let runnerOutput = try await AIHaplotypingRunner(provider: providerInstance).run(
            result: activeResult,
            sidecar: sidecar,
            options: runOptions
        )
        let context = AIHaplotypingRevisionPublishContext(
            toolName: "lungfish-cli genotype ai-haplotyping",
            toolKind: "cli",
            argv: Self.sanitizedCommandLineArguments(),
            explicitOptions: explicitOptions(bundleURL: bundleURL, credentialSource: credential.source.rawValue),
            defaultOptions: defaultOptions(),
            resolvedOptions: resolvedOptions(
                bundleURL: bundleURL,
                modelID: providerInstance.modelId,
                credentialSource: credential.source.rawValue
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

    func buildPromptPreview() throws -> AIHaplotypingCLIPromptPreview {
        let input = try previewInput()
        return try AIHaplotypingPromptPreviewBuilder().build(AIHaplotypingPromptPreviewRequest(
            result: input.result,
            sidecar: input.sidecar,
            mode: mode.promptMode,
            providerID: provider.providerID,
            modelID: modelValue(default: provider.defaultPreviewModel),
            credentialSource: provider.credentialSource,
            promptTemplateID: promptTemplateID,
            promptTemplateVersion: promptTemplateVersion,
            maxObservationsPerChunk: maxObservationsPerChunk,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            provenancePath: AIHaplotypingPatchValidator.pendingProvenancePath
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
            "model": .string(modelValue(default: provider.defaultPreviewModel)),
            "output": .file(outputURL),
            "previewPrompt": .string("true"),
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
            toolName: "lungfish-cli",
            toolVersion: WorkflowRun.currentAppVersion,
            command: previewCommand(outputURL: outputURL),
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

    private func resolvedCredential() throws -> (apiKey: String, source: AIHaplotypingCredentialSource) {
        let environmentName = provider.defaultEnvironmentVariable
        let apiKey = ProcessInfo.processInfo.environment[environmentName]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw ValidationError("Missing API key. Set \(environmentName) before running AI haplotyping.")
        }
        return (apiKey, provider.credentialSource)
    }

    private func makeProvider(apiKey: String) -> any StructuredAIProvider {
        switch provider {
        case .openAI:
            return OpenAIProvider(apiKey: apiKey, modelId: modelValue(default: "gpt-5-mini"))
        case .anthropic:
            return AnthropicProvider(apiKey: apiKey, modelId: modelValue(default: "claude-sonnet-4-5-20250929"))
        }
    }

    private func modelValue(default defaultModel: String) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    private func previewCommand(outputURL: URL) -> [String] {
        var command = ["lungfish", "genotype", "ai-haplotyping"]
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
            "--model", modelValue(default: provider.defaultPreviewModel),
            "--max-observations-per-chunk", String(maxObservationsPerChunk),
            "--max-output-tokens", String(maxOutputTokens),
            "--temperature", String(temperature),
        ]
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

    private func explicitOptions(bundleURL: URL, credentialSource: String) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "mode": .string(mode.promptMode.rawValue),
            "provider": .string(provider.providerID.rawValue),
            "credentialSource": .string(credentialSource),
            "maxObservationsPerChunk": .integer(maxObservationsPerChunk),
            "maxOutputTokens": .integer(maxOutputTokens),
            "temperature": .number(temperature),
        ]
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options["model"] = .string(model)
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
            "provider": .string(AIHaplotypingProviderArgument.anthropic.providerID.rawValue),
            "openAIModel": .string("gpt-5-mini"),
            "anthropicModel": .string("claude-sonnet-4-5-20250929"),
            "maxObservationsPerChunk": .integer(128),
            "maxOutputTokens": .integer(4096),
            "temperature": .number(0),
        ]
    }

    private func resolvedOptions(
        bundleURL: URL,
        modelID: String,
        credentialSource: String
    ) -> [String: ParameterValue] {
        [
            "bundle": .file(bundleURL),
            "mode": .string(mode.promptMode.rawValue),
            "provider": .string(provider.providerID.rawValue),
            "model": .string(modelID),
            "credentialSource": .string(credentialSource),
            "promptTemplateID": promptTemplateID.map(ParameterValue.string) ?? .null,
            "promptTemplateVersion": promptTemplateVersion.map(ParameterValue.string) ?? .null,
            "maxObservationsPerChunk": .integer(maxObservationsPerChunk),
            "maxOutputTokens": .integer(maxOutputTokens),
            "temperature": .number(temperature),
        ]
    }

    private static func sanitizedCommandLineArguments() -> [String] {
        CommandLine.arguments
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
        switch self {
        case .openAI: return .environmentOpenAI
        case .anthropic: return .environmentAnthropic
        }
    }

    var defaultPreviewModel: String {
        switch self {
        case .openAI: return "gpt-5-mini"
        case .anthropic: return "claude-sonnet-4-5-20250929"
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
