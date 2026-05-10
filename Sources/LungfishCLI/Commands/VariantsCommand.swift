import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct VariantsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variants",
        abstract: "Call viral variants from a bundle-owned alignment track",
        subcommands: [CallSubcommand.self, PhaseSubcommand.self, ExtractSampleSubcommand.self, QuerySubcommand.self]
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
        case .bcftools:
            return .bcftools
        case .clair3:
            return .clair3
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
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BundleManifest.self, from: Data(contentsOf: manifestURL))
        guard let track = manifest.variants.first(where: { $0.databasePath != nil }),
              let databasePath = track.databasePath else {
            throw ValidationError("Bundle does not contain a variant track with a SQLite database.")
        }
        let databaseURL = bundleURL.appendingPathComponent(databasePath)
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
        parameters: [String: ParameterValue],
        startedAt: Date,
        completedAt: Date
    ) throws {
        let step = StepExecution(
            toolName: workflowName,
            toolVersion: LungfishCLI.configuration.version,
            command: command,
            inputs: [
                ProvenanceRecorder.fileRecord(url: bundleURL, role: .input),
                ProvenanceRecorder.fileRecord(url: databaseURL, role: .input),
            ],
            outputs: [
                ProvenanceRecorder.fileRecord(url: outputURL, format: .vcf, role: .output),
            ],
            exitCode: 0,
            wallTime: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startTime: startedAt,
            endTime: completedAt
        )
        let run = WorkflowRun(
            name: workflowName,
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            appVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
            hostOS: WorkflowRun.currentHostOS,
            steps: [step],
            parameters: parameters
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let provenanceURL = outputURL.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try encoder.encode(run).write(to: provenanceURL, options: .atomic)
    }

    static func writeCommandPlanProvenance(
        workflowName: String,
        workflowVersion: String,
        command: [String],
        inputs: [FileRecord],
        outputs: [FileRecord],
        parameters: [String: ParameterValue],
        outputDirectory: URL,
        startedAt: Date,
        completedAt: Date,
        exitCode: Int32 = 0,
        stderr: String? = nil
    ) throws {
        let step = StepExecution(
            toolName: workflowName,
            toolVersion: workflowVersion,
            command: command,
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: completedAt.timeIntervalSince(startedAt),
            stderr: stderr,
            startTime: startedAt,
            endTime: completedAt
        )
        let run = WorkflowRun(
            name: workflowName,
            startTime: startedAt,
            endTime: completedAt,
            status: exitCode == 0 ? .completed : .failed,
            appVersion: workflowVersion,
            hostOS: WorkflowRun.currentHostOS,
            steps: [step],
            parameters: parameters
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run)
            .write(to: outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename), options: .atomic)
    }

    struct PhaseSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "phase",
            abstract: "Construct a phase-aware GATK HaplotypeCaller plus WhatsHap command plan"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and WhatsHap through managed tool packs.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Write and print the command plan without running tools.")
        var dryRun: Bool = false

        @Option(name: .customLong("reference"), help: "Reference FASTA path")
        var reference: String

        @Option(name: .customLong("bam"), help: "Input BAM path")
        var bam: String

        @Option(name: .customLong("output-vcf"), help: "Final phased VCF path")
        var outputVCF: String

        @Option(name: .customLong("output-dir"), help: "Command-plan/provenance output directory")
        var outputDirectory: String?

        @Option(name: .customLong("sample"), help: "Optional sample name passed to WhatsHap")
        var sampleName: String?

        @Option(name: .customLong("threads"), help: "GATK PairHMM threads")
        var threads: Int = 1

        @Option(name: .customLong("extra-gatk-args"), parsing: .unconditional, help: "Additional GATK HaplotypeCaller arguments")
        var extraGATKArgs: String = ""

        @Option(name: .customLong("extra-whatshap-args"), parsing: .unconditional, help: "Additional WhatsHap phase arguments")
        var extraWhatsHapArgs: String = ""

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse variants phase arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            let startedAt = Date()
            let outputVCFURL = URL(fileURLWithPath: outputVCF)
            let outputDirURL = URL(fileURLWithPath: outputDirectory ?? outputVCFURL.deletingLastPathComponent().path)
            try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
            let plan = try buildPlan(outputDirURL: outputDirURL, outputVCFURL: outputVCFURL)
            let planURL = outputDirURL.appendingPathComponent("phased-variant-command-plan.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(plan).write(to: planURL, options: .atomic)

            for command in plan.commands {
                emit(command.shellCommand)
            }

            if execute && !dryRun {
                try await runPlan(plan)
                emit("Phased variant calling complete.")
            } else {
                emit("Command plan: \(planURL.path)")
            }

            let completedAt = Date()
            try VariantsCommand.writeCommandPlanProvenance(
                workflowName: plan.workflowName,
                workflowVersion: plan.workflowVersion,
                command: ["lungfish", "variants", "phase"] + originalArguments(outputDirURL: outputDirURL, outputVCFURL: outputVCFURL),
                inputs: plan.inputs,
                outputs: [ProvenanceRecorder.fileRecord(url: planURL, format: .json, role: .output)] + plan.outputs,
                parameters: [
                    "packIDs": .string(plan.packIDs.joined(separator: ",")),
                    "execute": .string(String(execute && !dryRun)),
                    "threads": .string(String(max(1, threads))),
                    "containerRuntime": .string("none"),
                    "gatkRuntime": .string(plan.runtimeIdentity.gatkCondaEnvironment),
                    "whatsHapRuntime": .string(plan.runtimeIdentity.whatsHapCondaEnvironment),
                    "options": .dictionary(plan.options.mapValues { .string($0) }),
                    "resolvedDefaults": .dictionary(plan.resolvedDefaults.mapValues { .string($0) }),
                ],
                outputDirectory: outputDirURL,
                startedAt: startedAt,
                completedAt: completedAt
            )
        }

        private func buildPlan(outputDirURL: URL, outputVCFURL: URL) throws -> PhasedVariantCallingPlan {
            PhasedVariantCallingPlan(
                configuration: PhasedVariantCallingConfiguration(
                    referenceFASTAURL: URL(fileURLWithPath: reference),
                    inputBAMURL: URL(fileURLWithPath: bam),
                    outputVCFURL: outputVCFURL,
                    outputDirectory: outputDirURL,
                    threads: threads,
                    sampleName: sampleName,
                    extraGATKArguments: try GATKCLICommand.parseExtraArgs(extraGATKArgs),
                    extraWhatsHapArguments: try GATKCLICommand.parseExtraArgs(extraWhatsHapArgs)
                ),
                gatkVersion: GATKCLICommand.defaultToolVersion(),
                whatsHapVersion: PluginPack.builtInPack(id: "phasing")?
                    .toolRequirements.first(where: { $0.id == "whatshap" })?.version ?? "unknown",
                runtimeIdentity: PhasedVariantRuntimeIdentity(
                    gatkCondaEnvironment: CondaManager.shared.rootPrefix
                        .appendingPathComponent("envs/gatk-core", isDirectory: true).path,
                    whatsHapCondaEnvironment: CondaManager.shared.rootPrefix
                        .appendingPathComponent("envs/phasing", isDirectory: true).path
                ),
                workflowVersion: "lungfish-cli \(LungfishCLI.configuration.version)"
            )
        }

        private func runPlan(_ plan: PhasedVariantCallingPlan) async throws {
            for command in plan.commands {
                let result = try await CondaManager.shared.runTool(
                    name: command.executable,
                    arguments: command.arguments,
                    environment: command.environment,
                    workingDirectory: nil,
                    timeout: 24 * 60 * 60
                )
                guard result.exitCode == 0 else {
                    throw CLIError.workflowFailed(reason: result.stderr.isEmpty ? result.stdout : result.stderr)
                }
            }
        }

        private func originalArguments(outputDirURL: URL, outputVCFURL: URL) -> [String] {
            var args = [
                "--reference", reference,
                "--bam", bam,
                "--output-vcf", outputVCFURL.path,
                "--output-dir", outputDirURL.path,
                "--threads", String(max(1, threads)),
            ]
            if let sampleName {
                args += ["--sample", sampleName]
            }
            if !extraGATKArgs.isEmpty {
                args += ["--extra-gatk-args", extraGATKArgs]
            }
            if !extraWhatsHapArgs.isEmpty {
                args += ["--extra-whatshap-args", extraWhatsHapArgs]
            }
            if execute {
                args.append("--execute")
            }
            if dryRun {
                args.append("--dry-run")
            }
            return args
        }
    }

    struct ExtractSampleSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "extract-sample",
            abstract: "Extract one sample's variant calls from a bundle variant database"
        )

        @Argument(help: "Path to a .lungfishref bundle with a variant database")
        var bundlePath: String

        @Option(name: .customLong("sample"), help: "Sample name to extract")
        var sampleName: String

        @Option(name: [.short, .customLong("output")], help: "Output VCF path")
        var outputPath: String

        @OptionGroup var globalOptions: GlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse variants extract-sample arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting()
            if !globalOptions.quiet {
                print("Wrote sample VCF: \(outputPath)")
            }
        }

        func executeForTesting() async throws {
            let startedAt = Date()
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let opened = try VariantsCommand.openDefaultVariantDatabase(bundleURL: bundleURL)
            guard opened.db.sampleNames().contains(sampleName) else {
                throw ValidationError("Sample '\(sampleName)' was not found in \(bundleURL.path).")
            }
            let records = opened.db.queryForTable(sampleNames: [sampleName], limit: Int.max)
            try opened.db.writeVCF(records: records, sampleNames: [sampleName], to: outputURL)
            let completedAt = Date()
            try VariantsCommand.writeProvenance(
                workflowName: "lungfish variants extract-sample",
                command: commandArgv(bundlePath: bundlePath, sampleName: sampleName, outputPath: outputPath),
                bundleURL: bundleURL,
                databaseURL: opened.databaseURL,
                outputURL: outputURL,
                parameters: [
                    "bundlePath": .string(bundleURL.path),
                    "variantTrackID": .string(opened.track.id),
                    "databasePath": .string(opened.databaseURL.path),
                    "sample": .string(sampleName),
                    "outputPath": .string(outputURL.path),
                    "quiet": .boolean(globalOptions.quiet),
                    "outputFormat": .string(globalOptions.outputFormat.rawValue),
                    "containerRuntime": .string("none"),
                    "condaEnvironment": .string("none"),
                ],
                startedAt: startedAt,
                completedAt: completedAt
            )
        }

        private func commandArgv(bundlePath: String, sampleName: String, outputPath: String) -> [String] {
            var argv = [
                "lungfish", "variants", "extract-sample",
                bundlePath,
                "--sample", sampleName,
                "--output", outputPath,
                "--format", globalOptions.outputFormat.rawValue,
            ]
            if globalOptions.quiet { argv.append("--quiet") }
            return argv
        }
    }

    struct QuerySubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "query",
            abstract: "Query bundle variants with a per-sample smart filter"
        )

        @Argument(help: "Path to a .lungfishref bundle with a variant database")
        var bundlePath: String

        @Option(name: .customLong("filter"), help: "Smart filter, e.g. Sample[NA12878].GT=1/1")
        var filterText: String

        @Option(name: [.short, .customLong("output")], help: "Output VCF path")
        var outputPath: String

        @Option(name: .customLong("limit"), help: "Maximum variants to export")
        var limit: Int = 5000

        @OptionGroup var globalOptions: GlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse variants query arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting()
            if !globalOptions.quiet {
                print("Wrote filtered VCF: \(outputPath)")
            }
        }

        func executeForTesting() async throws {
            let startedAt = Date()
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let opened = try VariantsCommand.openDefaultVariantDatabase(bundleURL: bundleURL)
            let records = try opened.db.query(smartFilter: filterText, limit: limit)
            try opened.db.writeVCF(records: records, sampleNames: [], to: outputURL)
            let completedAt = Date()
            try VariantsCommand.writeProvenance(
                workflowName: "lungfish variants query",
                command: commandArgv(bundlePath: bundlePath, filterText: filterText, outputPath: outputPath),
                bundleURL: bundleURL,
                databaseURL: opened.databaseURL,
                outputURL: outputURL,
                parameters: [
                    "bundlePath": .string(bundleURL.path),
                    "variantTrackID": .string(opened.track.id),
                    "databasePath": .string(opened.databaseURL.path),
                    "filter": .string(filterText),
                    "limit": .integer(limit),
                    "outputPath": .string(outputURL.path),
                    "quiet": .boolean(globalOptions.quiet),
                    "outputFormat": .string(globalOptions.outputFormat.rawValue),
                    "containerRuntime": .string("none"),
                    "condaEnvironment": .string("none"),
                ],
                startedAt: startedAt,
                completedAt: completedAt
            )
        }

        private func commandArgv(bundlePath: String, filterText: String, outputPath: String) -> [String] {
            var argv = [
                "lungfish", "variants", "query",
                bundlePath,
                "--filter", filterText,
                "--output", outputPath,
                "--limit", String(limit),
                "--format", globalOptions.outputFormat.rawValue,
            ]
            if globalOptions.quiet { argv.append("--quiet") }
            return argv
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

        @Option(name: .customLong("caller"), help: "Variant caller: lofreq, ivar, medaka, bcftools, clair3")
        var caller: String

        @Option(name: [.customLong("name"), .customLong("output-track-name")], help: "Display name for the created variant track")
        var outputTrackName: String?

        @Option(name: .customLong("min-af"), help: "Minimum allele frequency threshold")
        var minimumAlleleFrequency: Double?

        @Option(name: .customLong("min-depth"), help: "Minimum depth threshold")
        var minimumDepth: Int?

        @Flag(name: .customLong("ivar-primer-trimmed"), help: "Confirm the BAM was primer-trimmed before iVar calling")
        var ivarPrimerTrimConfirmed: Bool = false

        @Option(name: .customLong("medaka-model"), help: "Required ONT/basecaller model identifier or Clair3 model path")
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
            name: [.customLong("extra-args"), .customLong("advanced-options")],
            parsing: .unconditional,
            help: "Additional caller arguments, written exactly as they should be passed to the underlying tool"
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
                command.append(contentsOf: ["--extra-args", advancedOptions])
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
                "extraArgs": AdvancedCommandLineOptions.join(advancedArguments),
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
