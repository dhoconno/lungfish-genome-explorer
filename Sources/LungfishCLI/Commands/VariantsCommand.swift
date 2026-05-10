import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct VariantsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variants",
        abstract: "Call viral variants from a bundle-owned alignment track",
        subcommands: [CallSubcommand.self, ExtractSampleSubcommand.self, QuerySubcommand.self]
    )

    struct Runtime {
        typealias Preflight = (BundleVariantCallingRequest) async throws -> BAMVariantCallingPreflightResult
        typealias PipelineRunner = (
            BundleVariantCallingRequest,
            BAMVariantCallingPreflightResult,
            CallContext
        ) async throws -> ViralVariantCallingPipelineResult
        typealias SQLiteImporter = (
            VariantSQLiteImportRequest,
            CallContext
        ) async throws -> VariantSQLiteImportResult
        typealias TrackAttacher = (
            BundleVariantTrackAttachmentRequest
        ) async throws -> BundleVariantTrackAttachmentResult

        let preflight: Preflight
        let runPipeline: PipelineRunner
        let importSQLite: SQLiteImporter
        let attachTrack: TrackAttacher

        static func live() -> Runtime {
            Runtime(
                preflight: { request in
                    for tool in requiredTools(for: request.caller) {
                        do {
                            _ = try await NativeToolRunner.shared.findTool(tool)
                        } catch {
                            throw CLIError.workflowFailed(reason: "Required managed tool is not available: \(tool.executableName)")
                        }
                    }
                    return try await BAMVariantCallingPreflight().validate(request)
                },
                runPipeline: { request, preflight, context in
                    let pipeline = ViralVariantCallingPipeline(
                        request: request,
                        preflight: preflight,
                        stagingRoot: context.stagingRoot
                    )
                    return try await pipeline.run(progress: context.emitStageProgress)
                },
                importSQLite: { request, context in
                    try await VariantSQLiteImportCoordinator().importNormalizedVCF(
                        request: request,
                        progressHandler: context.emitStageProgress,
                        shouldCancel: context.shouldCancel
                    )
                },
                attachTrack: { request in
                    try await BundleVariantTrackAttachmentService().attach(request: request)
                }
            )
        }
    }

    struct CallContext {
        let stagingRoot: URL
        let emitStageProgress: @Sendable (Double, String) -> Void
        let shouldCancel: @Sendable () -> Bool
    }

    struct VariantCallingEvent: Codable, Sendable {
        let event: String
        let progress: Double?
        let message: String
        let bundlePath: String?
        let variantTrackID: String?
        let variantTrackName: String?
        let caller: String?
        let vcfPath: String?
        let tbiPath: String?
        let databasePath: String?
        let importedVariantCount: Int?
    }

    private static func requiredTools(for caller: ViralVariantCaller) -> [NativeTool] {
        [
            .samtools,
            .bcftools,
            .bgzip,
            .tabix,
            nativeTool(for: caller),
        ]
    }

    private static func nativeTool(for caller: ViralVariantCaller) -> NativeTool {
        switch caller {
        case .lofreq:
            return .lofreq
        case .ivar:
            return .ivar
        case .medaka:
            return .medaka
        }
    }
}

extension VariantsCommand {
    fileprivate struct OpenedVariantDatabase {
        let manifest: BundleManifest
        let track: VariantTrackInfo
        let databaseURL: URL
        let db: VariantDatabase
    }

    fileprivate static func openDefaultVariantDatabase(bundleURL: URL) throws -> OpenedVariantDatabase {
        let manifest = try BundleManifest.load(from: bundleURL)
        guard let track = manifest.variants.first(where: { $0.databasePath != nil }) else {
            throw CLIError.validationFailed(errors: ["Bundle has no SQLite-backed variant track: \(bundleURL.path)"])
        }
        guard let databasePath = track.databasePath else {
            throw CLIError.validationFailed(errors: ["Variant track '\(track.id)' has no SQLite database path."])
        }
        let databaseURL = bundleURL.appendingPathComponent(databasePath)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CLIError.inputFileNotFound(path: databaseURL.path)
        }
        return OpenedVariantDatabase(
            manifest: manifest,
            track: track,
            databaseURL: databaseURL,
            db: try VariantDatabase(url: databaseURL)
        )
    }

    fileprivate static func writeProvenance(
        workflowName: String,
        command: [String],
        bundleURL: URL,
        databaseURL: URL,
        outputURL: URL,
        options: [String: String],
        startedAt: Date
    ) throws {
        let endedAt = Date()
        let inputRecords = [
            fileRecord(url: bundleURL, format: nil, role: .input),
            fileRecord(url: databaseURL, format: nil, role: .input),
        ]
        let outputRecord = fileRecord(url: outputURL, format: .vcf, role: .output)
        let step = StepExecution(
            toolName: workflowName,
            toolVersion: LungfishCLI.configuration.version,
            command: command,
            inputs: inputRecords,
            outputs: [outputRecord],
            exitCode: 0,
            wallTime: endedAt.timeIntervalSince(startedAt),
            startTime: startedAt,
            endTime: endedAt
        )
        var parameters = options.reduce(into: [String: ParameterValue]()) { result, pair in
            result[pair.key] = .string(pair.value)
        }
        parameters["bundle"] = .string(bundleURL.path)
        parameters["database"] = .string(databaseURL.path)
        parameters["output"] = .string(outputURL.path)
        let run = WorkflowRun(
            name: workflowName,
            startTime: startedAt,
            endTime: endedAt,
            status: .completed,
            steps: [step],
            parameters: parameters
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: outputURL.appendingPathExtension("lungfish-provenance.json"), options: .atomic)
    }

    private static func fileRecord(url: URL, format: FileFormat?, role: FileRole) -> FileRecord {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? UInt64
        return FileRecord(
            path: url.path,
            sha256: ProvenanceRecorder.sha256(of: url),
            sizeBytes: size,
            format: format,
            role: role
        )
    }

    struct ExtractSampleSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "extract-sample",
            abstract: "Export one sample from a bundle variant track as VCF"
        )

        @Argument(help: "Path to a .lungfishref bundle with a SQLite variant track")
        var bundlePath: String

        @Option(name: .customLong("sample"), help: "Sample name to export")
        var sample: String

        @Option(name: .shortAndLong, help: "Output VCF path")
        var output: String

        @OptionGroup var globalOptions: GlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName ? Array(arguments.dropFirst()) : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse variants extract-sample arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting()
        }

        func executeForTesting() async throws {
            let startedAt = Date()
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let outputURL = URL(fileURLWithPath: output)
            let opened = try VariantsCommand.openDefaultVariantDatabase(bundleURL: bundleURL)
            guard opened.db.sampleNames().contains(sample) else {
                throw CLIError.validationFailed(errors: ["Sample '\(sample)' was not found in \(bundlePath)"])
            }
            let records = opened.db.queryForTable(sampleNames: [sample], limit: Int.max)
            try opened.db.writeVCF(records: records, sampleNames: [sample], to: outputURL)
            try VariantsCommand.writeProvenance(
                workflowName: "lungfish variants extract-sample",
                command: ["lungfish", "variants", "extract-sample", bundlePath, "--sample", sample, "--output", output],
                bundleURL: bundleURL,
                databaseURL: opened.databaseURL,
                outputURL: outputURL,
                options: ["sample": sample, "track": opened.track.id],
                startedAt: startedAt
            )
            if !globalOptions.quiet {
                print("Exported \(records.count) variants for \(sample) to \(output)")
            }
        }
    }

    struct QuerySubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "query",
            abstract: "Filter a bundle variant track with smart-filter syntax"
        )

        @Argument(help: "Path to a .lungfishref bundle with a SQLite variant track")
        var bundlePath: String

        @Option(name: .customLong("filter"), help: "Smart-filter expression, for example Sample[NA12878].GT=1/1")
        var filter: String

        @Option(name: .shortAndLong, help: "Output VCF path")
        var output: String

        @Option(name: .customLong("limit"), help: "Maximum variants to export")
        var limit: Int = 5000

        @OptionGroup var globalOptions: GlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName ? Array(arguments.dropFirst()) : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse variants query arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting()
        }

        func executeForTesting() async throws {
            let startedAt = Date()
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let outputURL = URL(fileURLWithPath: output)
            let opened = try VariantsCommand.openDefaultVariantDatabase(bundleURL: bundleURL)
            let records = try opened.db.query(smartFilter: filter, limit: limit)
            try opened.db.writeVCF(records: records, sampleNames: opened.db.sampleNames(), to: outputURL)
            try VariantsCommand.writeProvenance(
                workflowName: "lungfish variants query",
                command: ["lungfish", "variants", "query", bundlePath, "--filter", filter, "--output", output, "--limit", String(limit)],
                bundleURL: bundleURL,
                databaseURL: opened.databaseURL,
                outputURL: outputURL,
                options: ["filter": filter, "limit": String(limit), "track": opened.track.id],
                startedAt: startedAt
            )
            if !globalOptions.quiet {
                print("Exported \(records.count) matching variants to \(output)")
            }
        }
    }

    struct CallSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "call",
            abstract: "Call viral variants from a bundle-owned alignment track"
        )

        @Option(name: .customLong("bundle"), help: "Path to the reference bundle directory")
        var bundlePath: String

        @Option(name: .customLong("alignment-track"), help: "Bundle alignment track identifier")
        var alignmentTrackID: String

        @Option(name: .customLong("caller"), help: "Variant caller: lofreq, ivar, medaka")
        var caller: String

        @Option(name: [.customLong("name"), .customLong("output-track-name")], help: "Display name for the created variant track")
        var outputTrackName: String?

        @Option(name: .customLong("min-af"), help: "Minimum allele frequency threshold")
        var minimumAlleleFrequency: Double?

        @Option(name: .customLong("min-depth"), help: "Minimum depth threshold")
        var minimumDepth: Int?

        @Flag(name: .customLong("ivar-primer-trimmed"), help: "Confirm the BAM was primer-trimmed before iVar calling")
        var ivarPrimerTrimConfirmed: Bool = false

        @Option(name: .customLong("medaka-model"), help: "Required ONT/basecaller model identifier for Medaka")
        var medakaModel: String?

        @Option(name: .customLong("ivar-consensus-af"), help: "Allele frequency threshold above which an iVar haplotype counts as consensus (default 0.75)")
        var ivarConsensusAF: Double = 0.75

        @Option(name: .customLong("ivar-merge-af-threshold"), help: "Maximum allele frequency distance for merging adjacent iVar SNPs (default 0.25)")
        var ivarMergeAFThreshold: Double = 0.25

        @Option(name: .customLong("ivar-bad-quality-threshold"), help: "iVar ALT_QUAL below this fails the bq filter (default 20)")
        var ivarBadQualityThreshold: Int = 20

        @Flag(name: .customLong("ivar-no-ignore-strand-bias"), help: "Apply iVar strand-bias filter (off by default for amplicon data)")
        var ivarApplyStrandBias: Bool = false

        @Option(
            name: .customLong("advanced-options"),
            parsing: .unconditional,
            help: "Additional caller options, written exactly as they should be passed to the underlying tool"
        )
        var advancedOptions: String = ""

        @OptionGroup var globalOptions: GlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse variants call arguments.")
            }
            return parsed
        }

        func run() async throws {
            let emitter: (VariantsCommand.VariantCallingEvent) -> Void
            if globalOptions.outputFormat == .json {
                emitter = { event in
                    if let line = encode(event: event) {
                        print(line)
                    }
                }
            } else {
                emitter = { event in
                    guard !globalOptions.quiet else { return }
                    print(event.message)
                }
            }

            _ = try await execute(runtime: .live(), emitEvent: emitter)
        }

        func executeForTesting(
            runtime: VariantsCommand.Runtime = .live(),
            emit: @escaping (String) -> Void
        ) async throws -> BundleVariantTrackAttachmentResult {
            try await execute(runtime: runtime) { event in
                if let line = encode(event: event) {
                    emit(line)
                }
            }
        }

        private func execute(
            runtime: VariantsCommand.Runtime,
            emitEvent: @escaping (VariantsCommand.VariantCallingEvent) -> Void
        ) async throws -> BundleVariantTrackAttachmentResult {
            let workflowStartedAt = Date()
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let resolvedCaller = try parseCaller()
            let advancedArguments = try parseAdvancedOptions()
            let initialTrackName = normalizedOutputTrackName(fallback: resolvedCaller.displayName)
            let initialRequest = BundleVariantCallingRequest(
                bundleURL: bundleURL,
                alignmentTrackID: alignmentTrackID,
                caller: resolvedCaller,
                outputTrackName: initialTrackName,
                threads: globalOptions.effectiveThreads,
                minimumAlleleFrequency: minimumAlleleFrequency,
                minimumDepth: minimumDepth,
                ivarPrimerTrimConfirmed: ivarPrimerTrimConfirmed,
                medakaModel: medakaModel,
                advancedArguments: advancedArguments,
                ivarConsensusAF: ivarConsensusAF,
                ivarMergeAFThreshold: ivarMergeAFThreshold,
                ivarBadQualityThreshold: ivarBadQualityThreshold,
                ivarIgnoreStrandBias: !ivarApplyStrandBias
            )

            emitSimpleEvent(event: "runStart", progress: 0.0, message: "Starting \(resolvedCaller.displayName) variant calling", caller: resolvedCaller.rawValue, emit: emitEvent)
            emitSimpleEvent(event: "preflightStart", progress: 0.02, message: "Checking bundle and alignment inputs", caller: resolvedCaller.rawValue, emit: emitEvent)

            do {
                let preflight = try await runtime.preflight(initialRequest)
                let finalTrackName = normalizedOutputTrackName(
                    fallback: "\(preflight.alignmentTrack.name) • \(resolvedCaller.displayName)"
                )
                let request = BundleVariantCallingRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: alignmentTrackID,
                    caller: resolvedCaller,
                    outputTrackName: finalTrackName,
                    threads: globalOptions.effectiveThreads,
                    minimumAlleleFrequency: minimumAlleleFrequency,
                    minimumDepth: minimumDepth,
                    ivarPrimerTrimConfirmed: ivarPrimerTrimConfirmed,
                    medakaModel: medakaModel,
                    advancedArguments: advancedArguments,
                    ivarConsensusAF: ivarConsensusAF,
                    ivarMergeAFThreshold: ivarMergeAFThreshold,
                    ivarBadQualityThreshold: ivarBadQualityThreshold,
                    ivarIgnoreStrandBias: !ivarApplyStrandBias
                )
                emitSimpleEvent(event: "preflightComplete", progress: 0.08, message: "Preflight checks passed", caller: resolvedCaller.rawValue, emit: emitEvent)

                let stagingRoot = try ProjectTempDirectory.create(
                    prefix: "variants-",
                    contextURL: bundleURL,
                    policy: .systemOnly
                )
                defer { try? FileManager.default.removeItem(at: stagingRoot) }
                let emitterBox = VariantCallingEventEmitter(emitEvent)

                let context = VariantsCommand.CallContext(
                    stagingRoot: stagingRoot,
                    emitStageProgress: { progress, message in
                        emitterBox.emit(
                            VariantsCommand.VariantCallingEvent(
                                event: "stageProgress",
                                progress: progress,
                                message: message,
                                bundlePath: bundleURL.path,
                                variantTrackID: nil,
                                variantTrackName: nil,
                                caller: resolvedCaller.rawValue,
                                vcfPath: nil,
                                tbiPath: nil,
                                databasePath: nil,
                                importedVariantCount: nil
                            )
                        )
                    },
                    shouldCancel: { Task.isCancelled }
                )

                emitSimpleEvent(event: "stageStart", progress: 0.10, message: "Running caller workflow", caller: resolvedCaller.rawValue, emit: emitEvent)
                let pipelineResult = try await runtime.runPipeline(request, preflight, context)
                emitSimpleEvent(event: "stageComplete", progress: 0.70, message: "Caller workflow completed", caller: resolvedCaller.rawValue, emit: emitEvent)

                emitSimpleEvent(event: "importStart", progress: 0.74, message: "Importing normalized variants into SQLite", caller: resolvedCaller.rawValue, emit: emitEvent)
                let importStartedAt = Date()
                let importRequest = VariantSQLiteImportRequest(
                    normalizedVCFURL: pipelineResult.normalizedVCFURL,
                    outputDatabaseURL: stagingRoot.appendingPathComponent("variants.sqlite.db"),
                    sourceFile: pipelineResult.stagedVCFGZURL.lastPathComponent,
                    importProfile: .ultraLowMemory,
                    importSemantics: .viralFrequency,
                    materializeVariantInfo: true
                )
                let importResult = try await runtime.importSQLite(importRequest, context)
                let importCompletedAt = Date()
                emitEvent(
                    VariantsCommand.VariantCallingEvent(
                        event: "importComplete",
                        progress: 0.88,
                        message: "Imported \(importResult.variantCount) variants into SQLite",
                        bundlePath: bundleURL.path,
                        variantTrackID: nil,
                        variantTrackName: finalTrackName,
                        caller: resolvedCaller.rawValue,
                        vcfPath: pipelineResult.stagedVCFGZURL.path,
                        tbiPath: pipelineResult.stagedTabixURL.path,
                        databasePath: nil,
                        importedVariantCount: importResult.variantCount
                    )
                )

                emitSimpleEvent(event: "attachStart", progress: 0.90, message: "Attaching variant track to bundle", caller: resolvedCaller.rawValue, emit: emitEvent)
                let workflowCompletedAt = Date()
                let workflowCommand = variantCallCommand(finalTrackName: finalTrackName)
                let workflowProvenance = VariantCallingWorkflowProvenance(
                    workflowName: "lungfish variants call",
                    workflowVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
                    command: workflowCommand,
                    startedAt: workflowStartedAt,
                    completedAt: workflowCompletedAt,
                    parameters: variantCallParameters(
                        caller: resolvedCaller,
                        finalTrackName: finalTrackName,
                        advancedArguments: advancedArguments
                    ),
                    steps: pipelineResult.provenanceSteps + [
                        VariantCallingProvenanceStep(
                            toolName: "lungfish variant-sqlite-import",
                            toolVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
                            command: [
                                "lungfish-internal",
                                "variant-sqlite-import",
                                "--normalized-vcf", importRequest.normalizedVCFURL.path,
                                "--output-database", importRequest.outputDatabaseURL.path,
                                "--source-file", importRequest.sourceFile ?? "",
                                "--import-profile", "ultraLowMemory",
                                "--import-semantics", "viralFrequency",
                                "--materialize-variant-info", String(importRequest.materializeVariantInfo),
                            ],
                            inputs: [ProvenanceRecorder.fileRecord(url: importRequest.normalizedVCFURL, format: .vcf, role: .input)],
                            outputs: [ProvenanceRecorder.fileRecord(url: importResult.databaseURL, role: .output)],
                            exitCode: 0,
                            wallTime: importCompletedAt.timeIntervalSince(importStartedAt),
                            stderr: nil,
                            startedAt: importStartedAt,
                            completedAt: importCompletedAt
                        )
                    ]
                )
                let attachmentRequest = BundleVariantTrackAttachmentRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: alignmentTrackID,
                    caller: resolvedCaller,
                    outputTrackID: Self.makeTrackID(),
                    outputTrackName: finalTrackName,
                    stagedVCFGZURL: pipelineResult.stagedVCFGZURL,
                    stagedTabixURL: pipelineResult.stagedTabixURL,
                    stagedDatabaseURL: importResult.databaseURL,
                    variantCount: importResult.variantCount,
                    variantCallerVersion: pipelineResult.callerVersion,
                    variantCallerParametersJSON: pipelineResult.callerParametersJSON,
                    variantCallerCommandLine: pipelineResult.commandLine,
                    referenceStagedFASTASHA256: pipelineResult.referenceFASTASHA256,
                    workflowProvenance: workflowProvenance
                )
                let attachmentResult = try await runtime.attachTrack(attachmentRequest)
                emitEvent(
                    VariantsCommand.VariantCallingEvent(
                        event: "attachComplete",
                        progress: 0.97,
                        message: "Attached variant track \(attachmentResult.trackInfo.name)",
                        bundlePath: bundleURL.path,
                        variantTrackID: attachmentResult.trackInfo.id,
                        variantTrackName: attachmentResult.trackInfo.name,
                        caller: resolvedCaller.rawValue,
                        vcfPath: attachmentResult.finalVCFGZURL.path,
                        tbiPath: attachmentResult.finalTabixURL.path,
                        databasePath: attachmentResult.finalDatabaseURL.path,
                        importedVariantCount: attachmentResult.trackInfo.variantCount
                    )
                )
                emitEvent(
                    VariantsCommand.VariantCallingEvent(
                        event: "runComplete",
                        progress: 1.0,
                        message: "Variant calling complete",
                        bundlePath: bundleURL.path,
                        variantTrackID: attachmentResult.trackInfo.id,
                        variantTrackName: attachmentResult.trackInfo.name,
                        caller: resolvedCaller.rawValue,
                        vcfPath: attachmentResult.finalVCFGZURL.path,
                        tbiPath: attachmentResult.finalTabixURL.path,
                        databasePath: attachmentResult.finalDatabaseURL.path,
                        importedVariantCount: attachmentResult.trackInfo.variantCount
                    )
                )
                return attachmentResult
            } catch {
                emitEvent(
                    VariantsCommand.VariantCallingEvent(
                        event: "runFailed",
                        progress: nil,
                        message: error.localizedDescription,
                        bundlePath: bundleURL.path,
                        variantTrackID: nil,
                        variantTrackName: nil,
                        caller: resolvedCaller.rawValue,
                        vcfPath: nil,
                        tbiPath: nil,
                        databasePath: nil,
                        importedVariantCount: nil
                    )
                )
                throw error
            }
        }

        private static func makeTrackID() -> String {
            "vc-\(UUID().uuidString.lowercased())"
        }

        private func parseCaller() throws -> ViralVariantCaller {
            guard let value = ViralVariantCaller(rawValue: caller.lowercased()) else {
                throw ValidationError("Unknown caller: \(caller)")
            }
            return value
        }

        private func parseAdvancedOptions() throws -> [String] {
            do {
                return try AdvancedCommandLineOptions.parse(advancedOptions)
            } catch {
                throw ValidationError(error.localizedDescription)
            }
        }

        private func normalizedOutputTrackName(fallback: String) -> String {
            let trimmed = outputTrackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? fallback : trimmed
        }

        private func variantCallCommand(finalTrackName: String) -> [String] {
            var command = [
                "lungfish",
                "variants",
                "call",
                "--bundle", bundlePath,
                "--alignment-track", alignmentTrackID,
                "--caller", caller,
                "--name", finalTrackName,
                "--threads", String(globalOptions.effectiveThreads),
                "--ivar-consensus-af", String(ivarConsensusAF),
                "--ivar-merge-af-threshold", String(ivarMergeAFThreshold),
                "--ivar-bad-quality-threshold", String(ivarBadQualityThreshold),
                "--format", globalOptions.outputFormat.rawValue
            ]
            if let minimumAlleleFrequency {
                command.append(contentsOf: ["--min-af", String(minimumAlleleFrequency)])
            }
            if let minimumDepth {
                command.append(contentsOf: ["--min-depth", String(minimumDepth)])
            }
            if ivarPrimerTrimConfirmed {
                command.append("--ivar-primer-trimmed")
            }
            if let medakaModel {
                command.append(contentsOf: ["--medaka-model", medakaModel])
            }
            if ivarApplyStrandBias {
                command.append("--ivar-no-ignore-strand-bias")
            }
            if !advancedOptions.isEmpty {
                command.append(contentsOf: ["--advanced-options", advancedOptions])
            }
            if globalOptions.quiet {
                command.append("--quiet")
            }
            return command
        }

        private func variantCallParameters(
            caller: ViralVariantCaller,
            finalTrackName: String,
            advancedArguments: [String]
        ) -> [String: String] {
            [
                "bundlePath": URL(fileURLWithPath: bundlePath).standardizedFileURL.path,
                "alignmentTrackID": alignmentTrackID,
                "caller": caller.rawValue,
                "outputTrackName": finalTrackName,
                "threads": String(globalOptions.effectiveThreads),
                "minimumAlleleFrequency": minimumAlleleFrequency.map { String($0) } ?? "caller-default",
                "minimumDepth": minimumDepth.map { String($0) } ?? "caller-default",
                "ivarPrimerTrimConfirmed": String(ivarPrimerTrimConfirmed),
                "medakaModel": medakaModel ?? "",
                "advancedArguments": advancedArguments.joined(separator: " "),
                "ivarConsensusAF": String(ivarConsensusAF),
                "ivarMergeAFThreshold": String(ivarMergeAFThreshold),
                "ivarBadQualityThreshold": String(ivarBadQualityThreshold),
                "ivarIgnoreStrandBias": String(!ivarApplyStrandBias),
                "outputFormat": globalOptions.outputFormat.rawValue,
                "quiet": String(globalOptions.quiet),
                "containerRuntime": "none"
            ]
        }

        private func emitSimpleEvent(
            event: String,
            progress: Double?,
            message: String,
            caller: String,
            emit: (VariantsCommand.VariantCallingEvent) -> Void
        ) {
            emit(
                VariantsCommand.VariantCallingEvent(
                    event: event,
                    progress: progress,
                    message: message,
                    bundlePath: bundlePath,
                    variantTrackID: nil,
                    variantTrackName: nil,
                    caller: caller,
                    vcfPath: nil,
                    tbiPath: nil,
                    databasePath: nil,
                    importedVariantCount: nil
                )
            )
        }

        private func encode(event: VariantsCommand.VariantCallingEvent) -> String? {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(event) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }
}

private final class VariantCallingEventEmitter: @unchecked Sendable {
    let emit: (VariantsCommand.VariantCallingEvent) -> Void

    init(_ emit: @escaping (VariantsCommand.VariantCallingEvent) -> Void) {
        self.emit = emit
    }
}
