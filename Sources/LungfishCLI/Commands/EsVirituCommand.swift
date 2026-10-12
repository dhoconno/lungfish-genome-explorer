// EsVirituCommand.swift - CLI command for EsViritu viral metagenomics
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Run EsViritu viral detection on FASTQ files.
///
/// This command configures and executes the EsViritu pipeline for viral
/// metagenomics analysis. It supports both single-end and paired-end input,
/// and includes a subcommand for database management.
///
/// ## Examples
///
/// ```
/// # Single-end viral detection
/// lungfish esviritu detect --input sample.fastq.gz --sample MySample --db /path/to/db
///
/// # Paired-end detection with custom threads
/// lungfish esviritu detect --input R1.fastq.gz R2.fastq.gz --paired --sample MySample --db /path/to/db --threads 8
///
/// # Interleaved pairs in one file (auto-detected by default)
/// lungfish esviritu detect --input interleaved.fastq.gz --read-format interleaved --sample MySample
///
/// # Every sample of a set of files into one batch of a project, as the app runs it
/// lungfish esviritu detect --input A_R1.fastq.gz A_R2.fastq.gz B.fastq.gz --batch --project My.lungfish
///
/// # Download the EsViritu database
/// lungfish esviritu download-db
///
/// # Check database status
/// lungfish esviritu db-status
/// ```
struct EsVirituCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "esviritu",
        abstract: "Run EsViritu viral metagenomics detection on FASTQ files",
        discussion: """
        Detect and characterize viruses from metagenomic sequencing data
        using EsViritu. Requires the EsViritu conda package and its curated
        viral reference database.

        Install the tool: lungfish-cli conda install esviritu
        Download the database: lungfish-cli esviritu download-db
        """,
        subcommands: [
            DetectSubcommand.self,
            DownloadDBSubcommand.self,
            DBStatusSubcommand.self,
        ],
        defaultSubcommand: DetectSubcommand.self
    )
}

// MARK: - Detect

extension EsVirituCommand {

    /// Run EsViritu viral detection on FASTQ input files.
    ///
    /// The run goes through the analysis run executor with ``EsVirituAnalysisRunTool`` (2.7 A9), so
    /// this command and the app write one result tree. A plain `--output` keeps the one folder this
    /// command has always written (E2). `--project` makes `Analyses/esviritu-batch-<timestamp>/`
    /// with a folder per sample, as the app's EsViritu runs do (E1), and `--batch` groups the inputs
    /// into samples as the app's dialog does (E8). With `--format json` standard output holds the
    /// executor's version 2 events only, and in text mode the command prints what it always printed,
    /// with its errors and warnings on standard error. A SIGTERM cancels the run, which records
    /// `cancelled` and exits 125.
    struct DetectSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "detect",
            abstract: "Run EsViritu viral detection on FASTQ files"
        )

        // MARK: - Arguments

        @Option(
            name: [.customLong("input"), .customShort("i")],
            parsing: .upToNextOption,
            help: "Input FASTQ file(s) or .lungfishfastq bundle(s). Provide two files for paired-end."
        )
        var inputFiles: [String] = []

        @Option(
            name: [.customLong("sample"), .customShort("s")],
            help: "Sample name for output file prefixes (required without --batch)"
        )
        var sampleName: String?

        @Option(
            name: .customLong("db"),
            help: "Path to EsViritu database directory (default: auto-detect)"
        )
        var databasePath: String?

        /// The help names the folder ``resultDestination()`` computes, so change them together.
        @Option(
            name: [.customLong("output"), .customShort("o")],
            help: "Output directory (default: ./esviritu-<sample>)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("project"),
            help: ArgumentHelp(
                "The .lungfish project the run belongs to. The result lands in its Analyses/esviritu-batch-<timestamp>/ folder with one folder per sample, where the app's EsViritu runs put it",
                discussion: "Each sample folder is named after the sample, made safe for a folder name, and EsViritu names its tables after that folder. The result gets the batch summary, the batch manifest and esviritu.sqlite, and each source bundle records the run. Not with --output."
            )
        )
        var project: String?

        @Flag(
            name: .customLong("batch"),
            help: ArgumentHelp(
                "Group the inputs into samples by their file names, as the app's EsViritu dialog does, and run each sample into its own folder of one batch result",
                discussion: "Each sample's read layout is planned from its files, so --batch takes --read-format auto and no --sample. A batch completes while one sample completes, and each failed sample is a warning. Give --output or --project."
            )
        )
        var batch: Bool = false

        @Flag(
            name: .customLong("paired"),
            help: "Input files are paired-end reads"
        )
        var pairedEnd: Bool = false

        @Option(
            name: .customLong("read-format"),
            help: ArgumentHelp(
                "Read layout: auto, unpaired, paired, or interleaved.",
                discussion: """
                auto (default) plans a single input, a file or a .lungfishfastq \
                bundle. Separate R1 and R2 files run as a pair, strictly \
                alternating R1/R2 records run as interleaved, and single-end \
                reads run as unpaired. A sample that mixes pairs with merged or \
                orphan reads runs as unpaired on one file that holds every read, \
                and the output says why. Several files of single reads are joined \
                into one file. Two files run as unpaired unless --paired is given.
                """
            )
        )
        var readFormat: ReadFormatChoice = .auto

        @Flag(
            name: .customLong("recursive"),
            help: "When an input is a directory, include eligible FASTQ files in subfolders"
        )
        var recursive: Bool = false

        @Flag(
            name: .customLong("no-qc"),
            help: "Skip quality filtering (fastp)"
        )
        var noQC: Bool = false

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional EsViritu arguments passed verbatim"
        )
        var extraArgs: String = ""

        @OptionGroup var globalOptions: GlobalOptions

        /// `--read-format` values. `auto` resolves per input.
        enum ReadFormatChoice: String, ExpressibleByArgument, CaseIterable, Sendable {
            case auto
            case unpaired
            case paired
            case interleaved
        }

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw CLIError.validationFailed(errors: ["Failed to parse esviritu detect arguments."])
            }
            return parsed
        }

        // MARK: - Execution

        /// Runs the detection, with a SIGTERM turned into a cancel of the run, so the run records
        /// `cancelled`, settles its folder and exits 125 inside the grace the app's transport gives
        /// it. A cancel is taken from the SIGTERM count, never from how EsViritu ended (SWIFT X2).
        func run() async throws {
            let pendingCancel = PendingTaskCancel<Int32>()
            let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
            defer { termination.end() }
            let task = Task { () -> Int32 in
                await self.detect(
                    pipeline: .shared,
                    materializer: FASTQCLIMaterializer(runner: NativeToolRunner.shared),
                    cancelRequested: { pendingCancel.cancelRequested }
                )
            }
            pendingCancel.attach(task)
            try Self.exit(with: await task.value)
        }

        /// The body of ``run()`` with the pipeline and the materializer passed in, so a test can run
        /// a stand-in EsViritu. It throws the run's exit code when the run did not complete.
        func execute(
            pipeline: EsVirituPipeline,
            materializer: any CLISequenceInputMaterializing & Sendable,
            installedDatabase: @escaping @Sendable () async -> URL? = EsVirituAnalysisRunTool.installedDatabase
        ) async throws {
            try Self.exit(with: await detect(
                pipeline: pipeline,
                materializer: materializer,
                installedDatabase: installedDatabase,
                cancelRequested: { false }
            ))
        }

        /// Runs the request through the executor and returns the exit code of its report. Given
        /// `events`, the executor's events go there in place of the lines this command writes, so a
        /// test can read each one, such as the reason on a refusal's `failed` event.
        func detect(
            pipeline: EsVirituPipeline,
            materializer: any CLISequenceInputMaterializing & Sendable,
            installedDatabase: @escaping @Sendable () async -> URL? = EsVirituAnalysisRunTool.installedDatabase,
            cancelRequested: @escaping @Sendable () -> Bool,
            events eventsOverride: AnalysisRunEvents? = nil
        ) async -> Int32 {
            let eventsOn = globalOptions.outputFormat == .json
            let (destination, conflict) = resultDestination()
            let recursive = recursive
            let tool = EsVirituAnalysisRunTool(
                options: EsVirituAnalysisRunOptions(
                    sampleName: sampleName,
                    readFormat: EsVirituAnalysisRunOptions.ReadFormatChoice(rawValue: readFormat.rawValue) ?? .auto,
                    pairedEnd: pairedEnd,
                    databasePath: databasePath.map { URL(fileURLWithPath: $0) },
                    threads: globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount,
                    qualityFilter: !noQC,
                    extraArguments: extraArgs,
                    usageConflict: conflict
                ),
                groupsSamples: batch,
                pipeline: pipeline,
                materializer: materializer,
                installedDatabase: installedDatabase,
                expandInputs: { urls in
                    try CLIClassificationFolderResolver.expandInputArguments(urls.map(\.path), recursive: recursive)
                },
                reporter: eventsOn ? nil : EsVirituTextReporter(useColors: globalOptions.useColors, quiet: globalOptions.quiet)
            )
            let request = AnalysisRunRequest(
                inputs: inputFiles.map { URL(fileURLWithPath: $0) },
                destination: destination,
                groupsSamples: batch,
                commandLine: Self.recordedCommandLine(CommandLine.arguments, fallback: canonicalArguments())
            )
            let events = eventsOverride ?? (eventsOn
                ? AnalysisRunEvents.jsonLines { printEventLine($0) }
                : EsVirituTextReporter.events(
                    useColors: globalOptions.useColors,
                    quiet: globalOptions.quiet,
                    namesResultFolder: batch || project != nil
                ))
            let services = AnalysisRunServices(indexing: EsVirituResultIndexing(), cancelRequested: cancelRequested)
            return await AnalysisRunExecutor(services: services).execute(tool, request, events: events).exitCode
        }

        /// Where the result goes, and a conflict of the flags that name it, which the plan refuses.
        /// `--project` makes a new batch folder in the project, `--output` names the folder, and
        /// without either a run of one sample goes to `./esviritu-<sample>` as it always did.
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
                return (.directory(URL(fileURLWithPath: outputDir)), nil)
            }
            if batch {
                return (.directory(currentDirectory), "--batch needs --output or --project to name where the batch goes.")
            }
            return (.directory(currentDirectory.appendingPathComponent("esviritu-\(sampleName ?? "sample")")), nil)
        }

        /// The argv the root record names, the one this process was started with when it ran this
        /// leaf, else ``canonicalArguments()`` (a test runs the command inside another process).
        static func recordedCommandLine(_ arguments: [String], fallback: @autoclosure () -> [String]) -> [String] {
            if let index = arguments.firstIndex(of: "esviritu"),
               arguments.indices.contains(index + 1),
               arguments[index + 1] == "detect" {
                return arguments
            }
            return fallback()
        }

        /// The command that runs these options again, every option it was given spelled out.
        func canonicalArguments() -> [String] {
            var arguments = [CLICommandIdentity.executableName, "esviritu", "detect"]
            if !inputFiles.isEmpty { arguments += ["--input"] + inputFiles }
            if let sampleName { arguments += ["--sample", sampleName] }
            if batch { arguments.append("--batch") }
            arguments += ["--read-format", readFormat.rawValue]
            if pairedEnd { arguments.append("--paired") }
            if recursive { arguments.append("--recursive") }
            if let databasePath { arguments += ["--db", databasePath] }
            if let project { arguments += ["--project", project] }
            if let outputDir { arguments += ["--output", outputDir] }
            if let threads = globalOptions.threads { arguments += ["--threads", String(threads)] }
            if noQC { arguments.append("--no-qc") }
            if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
            if globalOptions.outputFormat == .json { arguments += ["--format", "json"] }
            return arguments
        }

        private static func exit(with code: Int32) throws {
            guard code != 0 else { return }
            throw ExitCode(code)
        }
    }
}

/// What `esviritu detect` prints in text mode, the lines it has always printed at the points it
/// printed them, with its errors and warnings on standard error.
struct EsVirituTextReporter: EsVirituRunReporting {
    let useColors: Bool
    let quiet: Bool

    private var formatter: TerminalFormatter { TerminalFormatter(useColors: useColors) }

    func resolving(_ message: String) {
        if !quiet { print(formatter.info(message)) }
    }

    func willRun(_ config: EsVirituConfig, inputs: [URL], advisory: String?) {
        let formatter = formatter
        print(formatter.header("EsViritu Viral Detection"))
        print("")
        print(formatter.keyValueTable([
            ("Input files", inputs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Read format", "\(config.readFormat.rawValue) (\(EsVirituReadFormat.inputLabel(format: config.readFormat, layout: config.inputLayout?.layout)))"),
            ("Sample name", config.sampleName),
            ("Database", config.databasePath.path),
            ("Quality filter", config.qualityFilter ? "yes" : "no"),
            ("Threads", String(config.threads)),
            ("Output", config.outputDirectory.path),
        ]))
        print("")
        if let reason = config.readSetPlan?.singleReadReason {
            print(formatter.info(reason))
            print("")
        }
        // Same read-length gate as the EsViritu dialog: warn, never block.
        if let advisory, !quiet {
            printStatusLine(formatter.warning(advisory))
        }
    }

    func progress(_ fraction: Double, _ message: String) {
        if !quiet { print("\r\(formatter.info(message))", terminator: "") }
    }

    func didRun(_ result: LungfishWorkflow.EsVirituResult) {
        let formatter = formatter
        // Clear the progress line.
        print("")
        print("")
        print(formatter.header("Results"))
        print("")
        print(result.summary)
        print("")
        print(formatter.header("Output Files"))
        print("  Detection: \(formatter.path(result.detectionURL.path))")
        if let assembly = result.assemblyURL {
            print("  Assembly:  \(formatter.path(assembly.path))")
        }
        if let taxProfile = result.taxProfileURL {
            print("  Profile:   \(formatter.path(taxProfile.path))")
        }
        if let coverage = result.coverageURL {
            print("  Coverage:  \(formatter.path(coverage.path))")
        }
        print("")
        print(formatter.success("Detection completed in \(String(format: "%.1f", result.runtime))s"))
        print("\(result.virusCount) virus(es) detected")
    }

    /// The executor's events in text mode. The human text comes from the reporter, so the events
    /// print only what went wrong, on standard error, and a batch names its result folder.
    static func events(useColors: Bool, quiet: Bool, namesResultFolder: Bool) -> AnalysisRunEvents {
        let formatter = TerminalFormatter(useColors: useColors)
        return AnalysisRunEvents { line in
            switch line.event {
            case .log(.warning, let message)?:
                if !quiet { printStatusLine(formatter.warning(message)) }
            case .log(.error, let message)?:
                printStatusLine(formatter.error(message))
            case .failed(let message, let detail)?:
                printStatusLine(formatter.error(message))
                if let detail { printStatusLine(detail) }
            case .complete(let outputs, let message)? where namesResultFolder:
                print("")
                print(formatter.success(message ?? "EsViritu finished."))
                if let folder = outputs.first {
                    print("  Result folder: \(formatter.path(folder))")
                }
            default:
                break
            }
        }
    }
}

// MARK: - Download Database

extension EsVirituCommand {

    /// Download the EsViritu viral reference database from Zenodo.
    struct DownloadDBSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download-db",
            abstract: "Download the EsViritu viral reference database"
        )

        @Flag(
            name: .customLong("force"),
            help: "Re-download even if the database is already installed"
        )
        var force: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let dbManager = EsVirituDatabaseManager.shared

            // Check if already installed.
            let isInstalled = await dbManager.isInstalled()
            if isInstalled && !force {
                let dbURL = await dbManager.databaseURL
                print(formatter.success(
                    "EsViritu database \(EsVirituDatabaseManager.currentVersion) is already installed at:"
                ))
                print("  \(formatter.path(dbURL.path))")
                print("")
                print("Use --force to re-download.")
                return
            }

            print(formatter.header("Downloading EsViritu Database"))
            print("  Version: \(EsVirituDatabaseManager.currentVersion)")
            print("  DOI: \(EsVirituDatabaseManager.zenodoDOI)")
            print("  Size: ~2 GB (compressed)")
            print("")

            let dbPath = try await dbManager.download { fraction, message in
                if !globalOptions.quiet {
                    print("\r\(formatter.info(message))", terminator: "")
                }
            }

            print("")
            print("")
            print(formatter.success("Database installed at: \(dbPath.path)"))
        }
    }
}

// MARK: - Database Status

extension EsVirituCommand {

    /// Check the status of the installed EsViritu database.
    struct DBStatusSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "db-status",
            abstract: "Check EsViritu database installation status"
        )

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let dbManager = EsVirituDatabaseManager.shared

            print(formatter.header("EsViritu Database Status"))
            print("")

            let isInstalled = await dbManager.isInstalled()
            if isInstalled {
                if let info = await dbManager.installedDatabaseInfo() {
                    let sizeStr = ByteCountFormatter.string(
                        fromByteCount: info.sizeBytes,
                        countStyle: .file
                    )
                    print(formatter.keyValueTable([
                        ("Status", "Installed"),
                        ("Version", info.version),
                        ("Path", info.path.path),
                        ("Size", sizeStr),
                    ]))
                } else {
                    print("  Status: Installed")
                }
            } else {
                print("  Status: Not installed")
                print("")
                print(formatter.info("Download with: lungfish-cli esviritu download-db"))
            }
        }
    }
}
