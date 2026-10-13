// TaxTriageCommand+Run.swift - lungfish-cli taxtriage run
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishIO

// MARK: - Run Subcommand

extension TaxTriageCommand {

    /// Execute the TaxTriage pipeline.
    ///
    /// The run goes through the analysis run executor with ``TaxTriageAnalysisRunTool`` (Phase 2.9
    /// lane A2), so every refusal comes before any folder exists and a cancel records `cancelled`
    /// with exit 125 in the executor's root record (S2). A plain `--output` runs every sample in one
    /// Nextflow run into that folder, as the command always has (2.8 T2). `--project` makes
    /// `Analyses/taxtriage-batch-<timestamp>/` in the project, where the app's TaxTriage runs put
    /// it, and runs each sample of several in its own Nextflow run and folder there (2.9 T5, 2.8
    /// T4). `--batch` gives each sample its own run and folder under `--output` too. With `--format
    /// json` standard output holds the executor's version 2 events only. In text mode the command
    /// prints its header, progress and results as it always has, with failures and warnings on
    /// standard error. A SIGTERM cancels the run.
    struct RunSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Execute TaxTriage classification on FASTQ files"
        )

        // MARK: - Input Options

        /// The help says what each bundle gives its sample, which ``TaxTriageAnalysisRunTool/inputSample(_:named:read2:)``
        /// reads (2.10 T4 and T6), so change them together.
        @Option(
            name: .customLong("input"),
            help: ArgumentHelp(
                "Input FASTQ file (R1 or single-end) or .lungfishfastq bundle. Repeat it to run several",
                discussion: "A bundle is planned whole. A bundle of pairs runs as pairs, and a bundle that mixes pairs with merged or single reads, or holds several files of single reads, gives one single-end file of every read. A file inside a bundle is read as named, except the preview of a virtual bundle, which reads its bundle. --input and --input2 that name every file of one bundle are read as that bundle. A folder gives one sample of each FASTQ file or bundle in it. A folder that holds paired reads is refused, since the folder route pairs no R1 and R2 files. Use --samplesheet to pair them. Several --input run their samples in the order given. A sample whose reads lie in a bundle runs on the platform the bundle records, and it is a negative control when the bundle's sample role is negative control or extraction blank.",
                valueName: "input"
            )
        )
        var inputs: [String] = []

        /// The one `--input` of a run that names one, nil with none or several.
        var input: String? {
            inputs.count == 1 ? inputs[0] : nil
        }

        @Option(
            name: .customLong("input2"),
            help: "Second FASTQ file (R2 for paired-end)"
        )
        var input2: String?

        @Flag(
            name: .customLong("recursive"),
            help: "When --input is a directory, include eligible FASTQ files in subfolders"
        )
        var recursive: Bool = false

        @Option(
            name: .customLong("sample"),
            help: "Sample name, required with one --input file or bundle and with --input2. With an --input folder or several --input, each sample is named after its file or bundle, behind this name when given"
        )
        var sampleId: String?

        @Option(
            name: .customLong("samplesheet"),
            help: "Path to a TaxTriage samplesheet CSV (alternative to --input)"
        )
        var samplesheet: String?

        /// The marks stay in each sample's configuration, where the viewer reads them (2.10 T4), and the
        /// samplesheet the launch writes takes no column for them.
        @Option(
            name: .customLong("negative-control"),
            help: ArgumentHelp(
                "Mark the sample of this name as a negative control. Repeat it for several",
                discussion: "The result keeps the mark, so the batch overview flags organisms found in a control as possible contamination. TaxTriage never sees it. A bundle whose sample role is negative control or extraction blank marks its sample without this option. A name that no sample of the run has is refused.",
                valueName: "sample"
            )
        )
        var negativeControls: [String] = []

        /// The help names what a bundle's platform does, which the plan reads (2.10 T6), so change them together.
        @Option(
            name: .customLong("platform"),
            help: ArgumentHelp(
                "Sequencing platform: illumina, oxford, pacbio (default: illumina)",
                discussion: "The platform of each sample whose reads record none. A bundle of Illumina, Oxford Nanopore or PacBio reads runs on the platform it records, and a --samplesheet row on its platform column. A plain --output runs every sample in one Nextflow run of one platform, so samples that record different platforms are refused there. Add --batch to run each alone."
            )
        )
        var platform: PlatformArgument = .illumina

        // MARK: - Output Options

        /// The discussion names what ``run()`` does with several samples (decision T2), so
        /// change them together.
        @Option(
            name: [.customLong("output"), .customShort("o")],
            help: ArgumentHelp(
                "Output directory for results",
                discussion: "Without --project or --batch, one Nextflow run processes every sample and writes their results to this folder, and the folder keeps every file TaxTriage wrote. With --batch, each sample runs alone in its own folder inside it. Not with --project."
            )
        )
        var outputDir: String?

        /// The help names the folder the executor makes for a project, so change them together.
        @Option(
            name: .customLong("project"),
            help: ArgumentHelp(
                "The .lungfish project the run belongs to. The result lands in its Analyses/taxtriage-batch-<timestamp>/ folder, where the app's TaxTriage runs put it",
                discussion: "One sample runs in that folder itself. Several samples each run alone, in a folder named after the sample and made safe for a folder name. The run then builds taxtriage.sqlite for the viewer and removes the intermediate files the viewer does not read, keeping top/. Not with --output."
            )
        )
        var project: String?

        @Flag(
            name: .customLong("batch"),
            help: ArgumentHelp(
                "Run each sample alone, in its own Nextflow run and folder of one batch result",
                discussion: "Without --batch, a plain --output runs every sample in one Nextflow run. --batch pairs no R1 and R2 files by name, so give pairs in a --samplesheet. The batch result gets taxtriage.sqlite and loses its intermediate files as a --project result does. Give --output or --project."
            )
        )
        var batch: Bool = false

        // MARK: - Database Options

        @Option(
            name: .customLong("db"),
            help: "Path to existing Kraken2 database"
        )
        var databasePath: String?

        // MARK: - Pipeline Parameters

        @Option(
            name: .customLong("confidence"),
            help: "Kraken2 confidence threshold (default: 0.2)"
        )
        var confidence: Double = 0.2

        @Option(
            name: .customLong("top-hits"),
            help: "Number of top hits to report (default: 10)"
        )
        var topHits: Int = 10

        @Option(
            name: .customLong("rank"),
            help: "Taxonomic rank: D,P,C,O,F,G,S (default: S)"
        )
        var rank: String = "S"

        @Flag(
            name: .customLong("skip-assembly"),
            help: "Skip genome assembly steps (default: true)"
        )
        var skipAssembly: Bool = false

        @Flag(
            name: .customLong("no-skip-assembly"),
            help: "Enable genome assembly steps"
        )
        var noSkipAssembly: Bool = false

        @Flag(
            name: .customLong("skip-krona"),
            help: "Skip Krona visualization generation"
        )
        var skipKrona: Bool = false

        @Option(
            name: .customLong("remove-taxids"),
            help: ArgumentHelp(
                "NCBI taxids to exclude as host before TaxTriage picks references, separated by spaces or commas (e.g. 9606 for human). Passed as --remove_taxids. Default: none.",
                valueName: "ids"
            )
        )
        var removeTaxids: String?

        @Option(
            name: .customLong("max-memory"),
            help: "Maximum memory (Nextflow format, default: 16.GB)"
        )
        var maxMemory: String = "16.GB"

        @Option(
            name: .customLong("max-cpus"),
            help: "Maximum CPUs (default: auto)"
        )
        var maxCpus: Int?

        // MARK: - Nextflow Options

        @Option(
            name: .customLong("nf-profile"),
            help: "Nextflow execution profile (default: docker)"
        )
        var nfProfile: String = "docker"

        @Option(
            name: .customLong("revision"),
            help: "The TaxTriage commit or tag to run. Without it, LGE runs the commit its tool lock pins"
        )
        var revision: String?

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional TaxTriage/Nextflow pipeline arguments passed verbatim"
        )
        var extraArgs: String = ""

        @OptionGroup var globalOptions: GlobalOptions

        /// Makes the pipeline each unit runs (Phase 2.8 decision T14). The default is today's
        /// `TaxTriagePipeline.shared`. Only a test binds another, to run a stand-in Nextflow.
        /// Input materialization still goes through `NativeToolRunner.shared`. The factory is
        /// task-local, so nothing can assign it, and ``execute(events:)`` reads it once.
        @TaskLocal static var makePipeline: @Sendable () -> TaxTriagePipeline = { TaxTriagePipeline.shared }

        // MARK: - Validation

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw CLIError.validationFailed(errors: ["Failed to parse taxtriage run arguments."])
            }
            return parsed
        }

        func validate() throws {
            // Must provide either --input or --samplesheet
            if inputs.isEmpty && samplesheet == nil {
                throw CLIError.validationFailed(errors: ["Provide either --input (with --sample) or --samplesheet"])
            }
            if !inputs.isEmpty && samplesheet != nil {
                throw CLIError.validationFailed(errors: ["Cannot use both --input and --samplesheet"])
            }
            // One --input file or bundle needs its name. A folder or several --input name each sample after its input.
            if let input, sampleId == nil {
                let inputURL = URL(fileURLWithPath: input)
                var isDirectory: ObjCBool = false
                let isFolderInput = FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                    && !FASTQBundle.isBundleURL(inputURL)
                if !isFolderInput {
                    throw CLIError.validationFailed(errors: ["--sample is required when using --input"])
                }
            }
            if input2 != nil && inputs.count > 1 {
                throw CLIError.validationFailed(errors: [TaxTriageRunRefusal.input2WithSeveralInputs.message])
            }
            if input2 != nil && sampleId == nil {
                throw CLIError.validationFailed(errors: ["--sample is required when using --input2"])
            }
            if skipAssembly && noSkipAssembly {
                throw CLIError.validationFailed(errors: ["Cannot use both --skip-assembly and --no-skip-assembly"])
            }
            if let removeTaxids {
                let invalid = TaxTriageConfig.invalidTaxIDTokens(in: removeTaxids)
                if !invalid.isEmpty {
                    throw CLIError.validationFailed(errors: [
                        "--remove-taxids must list NCBI taxids (whole numbers such as 9606), got: \(invalid.joined(separator: ", "))",
                    ])
                }
            }
        }

        /// The normalized `--remove-taxids` list, or `nil` when the flag is
        /// absent or blank.
        var normalizedRemoveTaxids: String? {
            removeTaxids.flatMap(TaxTriageConfig.normalizedTaxIDList)
        }

        // MARK: - Execution

        func run() async throws {
            try await execute()
        }

        /// The body of ``run()``. It runs the request through the executor, with a SIGTERM turned
        /// into a cancel of the run, so the run records `cancelled`, settles its folder and exits 125
        /// inside the grace the app's transport gives it. A cancel is taken from the SIGTERM count
        /// and the cancel request, never from how Nextflow ended (SWIFT X2). Given `events`, the
        /// executor's events go there in place of the lines this command writes, so a test can read
        /// each one. It throws the run's exit code when the run did not complete.
        func execute(events eventsOverride: AnalysisRunEvents? = nil) async throws {
            let eventsOn = globalOptions.outputFormat == .json
            let useColors = globalOptions.useColors
            let quiet = globalOptions.quiet
            let pendingCancel = PendingTaskCancel<AnalysisRunReport>()
            let cancelRequested: @Sendable () -> Bool = {
                SIGTERMCancellation.signalCaught || pendingCancel.cancelRequested
            }
            let (destination, conflict) = resultDestination()
            let services = TaxTriageRunServices(
                makePipeline: Self.makePipeline,
                expandInputs: { arguments, recursive in
                    try CLIClassificationFolderResolver.expandInputArguments(arguments, recursive: recursive)
                },
                materializer: FASTQCLIMaterializer(runner: NativeToolRunner.shared),
                lock: .bundled,
                cancelRequested: cancelRequested,
                presentation: eventsOn || eventsOverride != nil ? .none : textPresentation(useColors: useColors)
            )
            let tool = TaxTriageAnalysisRunTool(request: runRequest(usageConflict: conflict), services: services)
            let request = AnalysisRunRequest(
                inputs: (inputs + [samplesheet].compactMap { $0 }).map { URL(fileURLWithPath: $0).standardizedFileURL },
                destination: destination,
                groupsSamples: batch,
                commandLine: Self.recordedCommandLine(CommandLine.arguments, fallback: canonicalArguments())
            )
            let events = eventsOverride ?? (eventsOn
                ? AnalysisRunEvents.jsonLines { printEventLine($0) }
                : Self.textEvents(useColors: useColors, quiet: quiet))

            // The listener starts before the task, so a SIGTERM caught before then cancels the task
            // as soon as it exists, and a second SIGTERM ends the command at once.
            let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
            let executor = AnalysisRunExecutor(services: AnalysisRunServices(
                indexing: TaxTriageResultIndexer(),
                cancelRequested: cancelRequested
            ))
            let task = Task { await executor.execute(tool, request, events: events) }
            pendingCancel.attach(task)
            let report = await task.value
            termination.end()

            if !eventsOn, eventsOverride == nil, report.status == .completed {
                printTextSummary(report, formatter: TerminalFormatter(useColors: useColors))
            }
            guard report.exitCode == 0 else {
                throw ExitCode(report.exitCode)
            }
        }

        /// The request the tool plans, the options as given with a configuration of every other
        /// setting. The plan sets each launch's samples, output folder, revision and extra
        /// arguments, so the configuration's values for those four are never read.
        func runRequest(usageConflict: String? = nil) -> TaxTriageRunRequest {
            let destinationURL: URL
            switch resultDestination().0 {
            case .project(let url), .directory(let url):
                destinationURL = url
            }
            return TaxTriageRunRequest(
                inputs: inputs,
                input2: input2,
                recursive: recursive,
                sampleID: sampleId,
                samplesheet: samplesheet,
                negativeControls: negativeControls,
                revision: revision,
                extraArguments: extraArgs,
                settings: settingsConfig(samples: [], outputDirectory: destinationURL, extraArguments: []),
                usageConflict: usageConflict
            )
        }

        /// Where the result goes, and a conflict of the flags that name it, which the plan refuses
        /// before any folder exists. `--project` makes a new batch folder in the project and
        /// `--output` names the folder.
        func resultDestination() -> (AnalysisRunDestination, conflict: String?) {
            let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            if let project {
                let projectURL = URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL
                if outputDir != nil {
                    return (.project(projectURL), "--project makes the result folder in the project, so it takes no --output.")
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return (.project(projectURL), "Project not found: \(projectURL.path)")
                }
                return (.project(projectURL), nil)
            }
            if let outputDir {
                return (.directory(URL(fileURLWithPath: outputDir).standardizedFileURL), nil)
            }
            return (.directory(currentDirectory), "Give --output or --project to name where the result goes.")
        }

        /// Every setting of the command as a configuration, with the samples, output folder and
        /// extra arguments given.
        func settingsConfig(samples: [TaxTriageSample], outputDirectory: URL, extraArguments: [String]) -> TaxTriageConfig {
            TaxTriageConfig(
                samples: samples,
                platform: platform.toPlatform(),
                outputDirectory: outputDirectory,
                kraken2DatabasePath: databasePath.map { URL(fileURLWithPath: $0) },
                classifiers: ["kraken2"],
                topHitsCount: topHits,
                k2Confidence: confidence,
                rank: rank,
                // Assembly is skipped unless --no-skip-assembly asks for it.
                skipAssembly: !noSkipAssembly,
                skipKrona: skipKrona,
                maxMemory: maxMemory,
                maxCpus: maxCpus ?? ProcessInfo.processInfo.activeProcessorCount,
                profile: nfProfile,
                containerRuntime: nil,
                revision: revision,
                extraArguments: extraArguments,
                removeTaxids: normalizedRemoveTaxids
            )
        }

        func makeConfigForTesting() throws -> TaxTriageConfig {
            let samples: [TaxTriageSample]
            if let inputPath = input, let sid = sampleId {
                samples = [
                    TaxTriageSample(
                        sampleId: sid,
                        fastq1: URL(fileURLWithPath: inputPath),
                        fastq2: input2.map { URL(fileURLWithPath: $0) },
                        platform: platform.toPlatform()
                    ),
                ]
            } else {
                samples = []
            }
            return settingsConfig(
                samples: samples,
                outputDirectory: URL(fileURLWithPath: outputDir ?? project ?? FileManager.default.currentDirectoryPath),
                extraArguments: try AdvancedCommandLineOptions.parse(extraArgs)
            )
        }

        /// The argv the root record names, the one this process was started with when it ran this
        /// leaf, as `taxtriage run` or as `taxtriage` and an option, which runs `run` as the default
        /// subcommand the way the app's row spells it, else ``canonicalArguments()`` (a test runs
        /// the command inside another process).
        static func recordedCommandLine(_ arguments: [String], fallback: @autoclosure () -> [String]) -> [String] {
            if let index = arguments.firstIndex(of: "taxtriage"),
               arguments.indices.contains(index + 1),
               arguments[index + 1] == "run" || arguments[index + 1].hasPrefix("-") {
                return arguments
            }
            return fallback()
        }

        /// The command that runs these options again, every option it was given spelled out.
        func canonicalArguments() -> [String] {
            var arguments = [CLICommandIdentity.executableName, "taxtriage", "run"]
            for input in inputs { arguments += ["--input", input] }
            if let input2 { arguments += ["--input2", input2] }
            if recursive { arguments.append("--recursive") }
            if let sampleId { arguments += ["--sample", sampleId] }
            if let samplesheet { arguments += ["--samplesheet", samplesheet] }
            for control in negativeControls { arguments += ["--negative-control", control] }
            arguments += ["--platform", platform.rawValue]
            if let project { arguments += ["--project", project] }
            if let outputDir { arguments += ["--output", outputDir] }
            if batch { arguments.append("--batch") }
            if let databasePath { arguments += ["--db", databasePath] }
            arguments += ["--confidence", String(confidence), "--top-hits", String(topHits), "--rank", rank]
            if skipAssembly { arguments.append("--skip-assembly") }
            if noSkipAssembly { arguments.append("--no-skip-assembly") }
            if skipKrona { arguments.append("--skip-krona") }
            if let removeTaxids { arguments += ["--remove-taxids", removeTaxids] }
            arguments += ["--max-memory", maxMemory]
            if let maxCpus { arguments += ["--max-cpus", String(maxCpus)] }
            arguments += ["--nf-profile", nfProfile]
            if let revision { arguments += ["--revision", revision] }
            if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
            if let threads = globalOptions.threads { arguments += ["--threads", String(threads)] }
            if globalOptions.outputFormat == .json { arguments += ["--format", "json"] }
            return arguments
        }

        // MARK: - Text

        /// Text mode prints the progress line a person reads as it always has, with warnings and the
        /// failure on standard error (UX D11), and the two hints of a missing `--db` after its words.
        static func textEvents(useColors: Bool, quiet: Bool) -> AnalysisRunEvents {
            AnalysisRunEvents { line in
                let formatter = TerminalFormatter(useColors: useColors)
                switch line.event {
                case .progress(let fraction, let message)?:
                    guard !quiet else { return }
                    print("\r\(formatter.info("[\(Int(fraction * 100))%] \(message)"))  ", terminator: "")
                    fflush(stdout)
                case .log(.info, let message)?:
                    if !quiet { print(formatter.info(message)) }
                case .log(.warning, let message)?:
                    if !quiet { printStatusLine(formatter.warning(message)) }
                case .log(.error, let message)?:
                    printStatusLine(formatter.error(message))
                case .failed(let message, let detail)?:
                    // The progress line has no line break yet.
                    if !quiet { print("") }
                    printStatusLine(formatter.error(message))
                    if let detail { printStatusLine(detail) }
                    if message == TaxTriageRunRefusal.missingDatabaseMessage {
                        printStatusLine(formatter.info("  List installed databases: lungfish-cli conda db list"))
                        printStatusLine(formatter.info("  Install one:              lungfish-cli conda db download Viral"))
                    }
                default:
                    break
                }
            }
        }

        /// The header and settings table each launch prints before Nextflow starts, with the platform the
        /// launch runs on, which a bundle's platform can set (2.10 T6).
        private func textPresentation(useColors: Bool) -> TaxTriageRunPresentation {
            let databaseName = databasePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "default"
            return TaxTriageRunPresentation(configured: { config in
                let formatter = TerminalFormatter(useColors: useColors)
                print(formatter.header("TaxTriage Pipeline"))
                print("")
                print(formatter.keyValueTable([
                    ("Samples", String(config.samples.count)),
                    ("Platform", config.platform.rawValue.lowercased()),
                    ("Database", databaseName),
                    ("Confidence", String(format: "%.2f", config.k2Confidence)),
                    ("Top hits", String(config.topHitsCount)),
                    ("Rank", config.rank),
                    ("Skip assembly", config.skipAssembly ? "yes" : "no"),
                    ("Skip Krona", config.skipKrona ? "yes" : "no"),
                    ("Exclude host taxa", config.effectiveRemoveTaxids
                        ?? (TaxTriageConfig.extraArgumentsSetRemoveTaxids(config.extraArguments) ? "set in --extra-args" : "none")),
                    ("Max memory", config.maxMemory),
                    ("Max CPUs", String(config.maxCpus)),
                    ("Profile", config.profile),
                    ("Revision", config.revision ?? "none pinned"),
                    ("Output", config.outputDirectory.path),
                ]))
                print("")
            })
        }

        /// The results of a completed run as the command has always printed them for one result
        /// folder, and the folder and the run's detail for a batch of sample folders.
        private func printTextSummary(_ report: AnalysisRunReport, formatter: TerminalFormatter) {
            guard let folder = report.analysisDirectory else { return }
            print("")
            print("")
            print(formatter.header("Results"))
            print("")
            guard let result = try? TaxTriageResult.load(from: folder) else {
                print("  Output:  \(formatter.path(folder.path))")
                print("")
                print(formatter.success(report.message))
                return
            }
            print(result.summary)
            print("")
            print(formatter.header("Output Files"))
            for report in result.reportFiles {
                print("  Report:  \(formatter.path(report.path))")
            }
            for metrics in result.metricsFiles {
                print("  Metrics: \(formatter.path(metrics.path))")
            }
            for krona in result.kronaFiles {
                print("  Krona:   \(formatter.path(krona.path))")
            }
            if let log = result.logFile {
                print("  Log:     \(formatter.path(log.path))")
            }
            print("")
            let runtime = String(format: "%.1f", result.runtime)
            if result.erroredProcessesMessage != nil {
                // The paragraph of errored tasks went to standard error as the run's warning.
                print(formatter.warning("TaxTriage completed with warnings in \(runtime)s"))
            } else {
                print(formatter.success("TaxTriage completed in \(runtime)s"))
            }
        }
    }
}
