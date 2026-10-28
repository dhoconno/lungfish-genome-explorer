// ClassifyCommand.swift - CLI command for Kraken2 classification
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishIO
import LungfishCore

/// Run Kraken2 taxonomic classification on FASTQ or FASTA inputs.
///
/// The command runs ``Kraken2AnalysisRunTool`` through ``AnalysisRunExecutor`` (Phase 2.7 lane
/// A8), the path the app's route runs too. The executor makes or claims the folder, writes the root
/// record whose argv is this command, and ends with exit 0 for a completed run, with or without
/// warnings, 64 for a failed run and 125 for a cancel. A degraded Bracken profile completes with a
/// warning (decision E4). SIGTERM cancels the run, so a cancel from the app records `cancelled`.
///
/// ## Examples
///
/// ```
/// # Classify with balanced preset
/// lungfish-cli kraken2 classify sample.fastq --db Viral --preset balanced
///
/// # Paired-end classification with profiling
/// lungfish-cli kraken2 classify R1.fastq R2.fastq --db Standard-8 --paired --profile
///
/// # Every sample of a folder in its own result folder, in a project
/// lungfish-cli kraken2 classify reads/ --db Viral --batch --project My.lungfish
/// ```
struct ClassifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "classify",
        abstract: "Run Kraken2 taxonomic classification on FASTQ or FASTA inputs",
        discussion: """
        Classify metagenomic reads or assembled sequences using Kraken2 with an installed database.
        Databases are managed via `lungfish-cli conda db` or downloaded from the
        built-in catalog. Results include a kreport file, per-read output,
        and an optional Bracken abundance profile. A Bracken profile that cannot
        be made leaves the classification complete with a warning and exit 0.
        """
    )

    // MARK: - Arguments

    @Argument(help: "Input sequence file(s). Provide two files for paired-end FASTQ.")
    var fastqFiles: [String]

    @Option(name: .customLong("db"), help: "Database name (e.g., 'Viral', 'Standard-8')")
    var databaseName: String

    @Option(
        name: .customLong("db-digest"),
        help: "SHA-256 the database's install receipt must hold, checked before anything is written"
    )
    var databaseDigest: String?

    @Option(name: .customLong("preset"), help: "Sensitivity preset")
    var preset: ClassificationPresetArgument = .balanced

    /// The help names the folder ``outputDirectoryURL`` computes, so change them together.
    @Option(
        name: [.customLong("output-dir"), .customShort("o")],
        help: "Output directory (default: ./classification-<db>, with <db> in lower case)"
    )
    var outputDir: String?

    @Option(
        name: .customLong("project"),
        help: "Project to write a new Analyses/kraken2-<timestamp> folder in, as the app does"
    )
    var project: String?

    @Flag(
        name: .customLong("batch"),
        help: "Group the inputs into samples by their R1 and R2 names and classify each in its own folder"
    )
    var batch: Bool = false

    @Flag(name: .customLong("paired"), help: "Input files are paired-end reads")
    var pairedEnd: Bool = false

    @Option(
        name: .customLong("read-format"),
        help: ArgumentHelp(
            "Read layout.",
            discussion: """
            auto plans a single input, a file or a .lungfishfastq bundle. Its read \
            pairs run as pairs with kraken2 --paired, and its merged or single reads run beside \
            them in the same kraken2 run. A strictly interleaved file is split into two mate \
            files. unpaired classifies every read on its own. Two separate files need --paired.
            """
        )
    )
    var readFormat: ReadFormatChoice = .auto

    @Option(name: .customLong("unpaired"), help: "A file of merged or single reads classified beside the --paired R1 and R2 files (repeatable)")
    var unpaired: [String] = []

    @Flag(name: .customLong("recursive"), help: "When an input is a directory, include eligible FASTQ/FASTA files in subfolders")
    var recursive: Bool = false

    @Flag(name: .customLong("profile"), help: "Run Bracken abundance profiling after classification")
    var profile: Bool = false

    @Option(name: .customLong("confidence"), help: "Override confidence threshold (0.0-1.0)")
    var confidence: Double?

    @Option(name: .customLong("min-hit-groups"), help: "Override minimum hit groups")
    var minHitGroups: Int?

    @Flag(name: .customLong("memory-mapping"), help: "Use memory-mapped I/O (slower, less RAM)")
    var memoryMapping: Bool = false

    @Flag(name: .customLong("quick"), help: "Use Kraken2 quick mode")
    var quickMode: Bool = false

    @OptionGroup var timeLimit: TimeLimitOptions

    @Option(name: .customLong("bracken-read-length"), help: "Read length for Bracken -r flag")
    var brackenReadLength: Int = 150

    @Option(
        name: .customLong("bracken-level"),
        help: "Bracken taxonomic level: D,P,C,O,F,G,S (default: automatic for the selected database)"
    )
    var brackenLevel: String?

    @Option(name: .customLong("bracken-threshold"), help: "Bracken minimum read threshold")
    var brackenThreshold: Int = 10

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Additional kraken2 arguments passed verbatim"
    )
    var extraArgs: String = ""

    @OptionGroup var globalOptions: GlobalOptions

    func validate() throws {
        if project != nil, outputDir != nil {
            throw ValidationError("--project and --output-dir name two places for one result. Give one of them.")
        }
    }

    // MARK: - Execution

    /// The one sequence format of every input, as ``Kraken2RunRequest/inferInputFormat(from:)``
    /// finds it, with the command's errors.
    static func inferInputFormat(from inputURLs: [URL]) throws -> SequenceFormat {
        do {
            return try Kraken2RunRequest.inferInputFormat(from: inputURLs)
        } catch Kraken2InputFormatError.undetected(let path) {
            throw CLIError.formatDetectionFailed(path: path)
        } catch let error as Kraken2InputFormatError {
            throw CLIError.validationFailed(errors: [error.errorDescription ?? "Mixed input formats."])
        }
    }

    func run() async throws {
        try await execute()
    }

    /// The body of ``run()``. A test passes `adjustServices` to replace the services the run
    /// reaches for, such as the database registry and the Kraken2 pipeline, so the whole command
    /// runs in the test's process with a stand-in kraken2, as `esviritu detect` does through
    /// `execute(pipeline:materializer:installedDatabase:)`.
    func execute(adjustServices: (inout Kraken2RunServices) -> Void = { _ in }) async throws {
        try await timeLimit.scope { try await executeRun(adjustServices: adjustServices) }
    }

    private func executeRun(adjustServices: (inout Kraken2RunServices) -> Void) async throws {
        let eventsOn = globalOptions.outputFormat == .json
        let useColors = globalOptions.useColors
        let quiet = globalOptions.quiet
        let destination: AnalysisRunDestination = project.map { .project(URL(fileURLWithPath: $0).standardizedFileURL) }
            ?? .directory(outputDirectoryURL)
        // SIGTERM (the app's Cancel) cancels the run, so the executor records it as cancelled with
        // exit 125, from the cancel request and never from how a child ended (SWIFT X2). A kraken2
        // child in the same process group can end first, before this process has run its handler.
        // `signalCaught` reads the kernel's note of the post beside the handler's count, so it says a
        // cancel was asked then too, and so does the cancel request (Phase 2.10 lane FXS).
        let pendingCancel = PendingTaskCancel<AnalysisRunReport>()
        let cancelRequested: @Sendable () -> Bool = {
            SIGTERMCancellation.signalCaught || pendingCancel.cancelRequested
        }
        var services = Kraken2RunServices(
            expandInputs: { arguments, recursive in
                try CLIClassificationFolderResolver.expandInputArguments(arguments, recursive: recursive)
            },
            presentation: eventsOn ? .none : textPresentation(useColors: useColors, quiet: quiet),
            cancelRequested: cancelRequested
        )
        adjustServices(&services)
        let tool = Kraken2AnalysisRunTool(request: runRequest, services: services)
        let request = AnalysisRunRequest(
            inputs: fastqFiles.map { URL(fileURLWithPath: $0).standardizedFileURL },
            destination: destination,
            groupsSamples: batch,
            commandLine: Self.recordedCommandLine(CommandLine.arguments, fallback: canonicalArguments())
        )
        let events = eventsOn
            ? AnalysisRunEvents.jsonLines { printEventLine($0) }
            : Self.textEvents(useColors: useColors, quiet: quiet)

        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        let executor = AnalysisRunExecutor(services: AnalysisRunServices(
            indexing: Self.resultIndexer(cancelRequested: cancelRequested),
            cancelRequested: cancelRequested
        ))
        let task = Task { await executor.execute(tool, request, events: events) }
        pendingCancel.attach(task)
        let report = await task.value
        termination.end()

        if !eventsOn, report.status == .completed {
            printTextSummary(report, formatter: TerminalFormatter(useColors: useColors))
        }
        guard report.exitCode == 0 else {
            throw ExitCode(report.exitCode)
        }
    }

    /// The folder a run without `--project` claims, `--output-dir` or `./classification-<db>`.
    var outputDirectoryURL: URL {
        if let outputDir {
            return URL(fileURLWithPath: outputDir).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("classification-\(databaseName.lowercased())")
            .standardizedFileURL
    }

    /// The path below the executable this run was given as, `kraken2 classify` or `conda classify`.
    static func commandPath(in argv: [String]) -> [String] {
        for (index, word) in argv.enumerated() where word == "classify" && index > 0 {
            if ["conda", "kraken2"].contains(argv[index - 1]) {
                return [argv[index - 1], "classify"]
            }
        }
        return ["kraken2", "classify"]
    }

    // MARK: - Text

    /// Text mode prints the log lines a person reads, with warnings and the failure on standard
    /// error (UX D11), and a failure's detail on the lines after it, as `esviritu detect` prints
    /// it. The progress of the pipeline and the configuration come from the tool's presentation,
    /// so they print as they always have.
    static func textEvents(useColors: Bool, quiet: Bool) -> AnalysisRunEvents {
        AnalysisRunEvents { line in
            let formatter = TerminalFormatter(useColors: useColors)
            switch line.event {
            case .log(.info, let message)?:
                if !quiet { print(formatter.info(message)) }
            case .log(.warning, let message)?:
                if !quiet { printStatusLine(formatter.warning(message)) }
            case .log(.error, let message)?:
                printStatusLine(formatter.error(message))
            case .failed(let message, let detail)?:
                printStatusLine(formatter.error(message))
                if let detail { printStatusLine(detail) }
            default:
                break
            }
        }
    }

    private func textPresentation(useColors: Bool, quiet: Bool) -> Kraken2RunPresentation {
        let presetName = preset.rawValue
        let profile = profile
        return Kraken2RunPresentation(
            configured: { config in
                let formatter = TerminalFormatter(useColors: useColors)
                let inputs = config.originalInputFiles ?? config.inputFiles
                print(formatter.header("Kraken2 Classification"))
                print("")
                print(formatter.keyValueTable([
                    ("Input files", inputs.map(\.lastPathComponent).joined(separator: ", ")),
                    ("Input format", config.inputFormat == .fasta ? "FASTA" : "FASTQ"),
                    ("Read format", "\(config.readFormat.rawValue) (\(config.inputLabel))"),
                    ("Database", config.databaseName),
                    ("Preset", presetName),
                    ("Confidence", String(format: "%.2f", config.confidence)),
                    ("Min hit groups", String(config.minimumHitGroups)),
                    ("Threads", String(config.threads)),
                    ("Memory mapping", config.memoryMapping ? "yes" : "no"),
                    ("Bracken profiling", profile ? "yes" : "no"),
                    ("Bracken rank", Self.resolvedBrackenRankDescription(for: config)),
                    ("Output", config.outputDirectory.path),
                ]))
                print("")
            },
            pipelineProgress: { message in
                if !quiet { print("\r\(TerminalFormatter(useColors: useColors).info(message))", terminator: "") }
            },
            resolving: { message in
                if !quiet { print(TerminalFormatter(useColors: useColors).info(message)) }
            }
        )
    }

    /// The results of a completed run, as the command has always printed them for one sample, and
    /// the batch's detail and folder for a batch.
    private func printTextSummary(_ report: AnalysisRunReport, formatter: TerminalFormatter) {
        guard let folder = report.analysisDirectory else { return }
        print("")
        print("")
        guard !batch, let result = try? ClassificationResult.load(from: folder) else {
            print(formatter.header("Results"))
            print("")
            print("  Output:  \(formatter.path(folder.path))")
            print("")
            print(formatter.success(report.message))
            return
        }
        print(formatter.header("Results"))
        print("")
        print(result.summary)
        print("")
        let topSpecies = result.tree.nodes(at: .species).sorted { $0.readsClade > $1.readsClade }.prefix(10)
        if !topSpecies.isEmpty {
            print(formatter.header("Top Species"))
            print("")
            print(formatter.table(
                headers: ["Species", "Reads", "Bracken", "Fraction"],
                rows: topSpecies.map { node in
                    [node.name, String(node.readsClade), node.brackenReads.map { String($0) } ?? "-",
                     String(format: "%.2f%%", node.fractionClade * 100)]
                }
            ))
            print("")
        }
        print(formatter.header("Output Files"))
        print("  Report:  \(formatter.path(result.reportURL.path))")
        print("  Output:  \(formatter.path(result.outputURL.path))")
        if let bracken = result.brackenURL {
            print("  Bracken: \(formatter.path(bracken.path))")
        }
        print("")
        if let message = Self.terminalMessage(for: result) {
            print(formatter.success("\(message) in \(String(format: "%.1f", result.runtime))s"))
        }
    }

    /// The last line of a completed run, or nil for a degraded profile, whose warning went to
    /// standard error.
    static func terminalMessage(for result: ClassificationResult) -> String? {
        switch result.profileOutcome.state {
        case .notRequested: return "Classification completed"
        case .completed: return "Kraken classification and Bracken profiling completed"
        case .degraded: return nil
        }
    }

    static func resolvedBrackenRankDescription(for config: ClassificationConfig) -> String {
        guard let request = config.brackenProfileRequest else {
            return "not requested"
        }
        let resolution = BrackenDatabaseCapabilities.resolve(
            catalogID: config.databaseCatalogID,
            installationRecipe: config.databaseInstallationRecipe,
            request: request
        )
        let requestedMode = request.rank.provenanceValue.replacingOccurrences(of: ":", with: " ")
        return "\(requestedMode) → \(resolution.rank.displayName) (\(resolution.rank.code); \(resolution.source.rawValue))"
    }

    func makeConfigForTesting(
        inputURLs: [URL],
        databaseInfo: MetagenomicsDatabaseInfo,
        inputFormat: SequenceFormat,
        outputDirectory: URL
    ) throws -> ClassificationConfig {
        guard let databasePath = databaseInfo.path else {
            throw CLIError.validationFailed(errors: ["Database '\(databaseInfo.name)' has no installed path."])
        }
        return runRequest.makeConfig(
            inputURLs: inputURLs,
            readFormat: try resolveReadFormat(inputURLs: inputURLs),
            databaseInfo: databaseInfo,
            databasePath: databasePath,
            inputFormat: inputFormat,
            outputDirectory: outputDirectory,
            extraArguments: try AdvancedCommandLineOptions.parse(extraArgs)
        )
    }

    func makeConfigForTesting(
        inputURLs: [URL],
        databasePath: URL,
        inputFormat: SequenceFormat,
        outputDirectory: URL
    ) throws -> ClassificationConfig {
        runRequest.makeConfig(
            inputURLs: inputURLs,
            readFormat: try resolveReadFormat(inputURLs: inputURLs),
            databaseInfo: nil,
            databasePath: databasePath,
            inputFormat: inputFormat,
            outputDirectory: outputDirectory,
            extraArguments: try AdvancedCommandLineOptions.parse(extraArgs)
        )
    }
}

// MARK: - ClassificationPresetArgument

/// ArgumentParser-compatible wrapper for ``ClassificationConfig/Preset``.
enum ClassificationPresetArgument: String, ExpressibleByArgument, CaseIterable {
    case sensitive
    case balanced
    case precise

    /// Converts to the workflow module's preset type.
    func toPreset() -> ClassificationConfig.Preset {
        switch self {
        case .sensitive: return .sensitive
        case .balanced: return .balanced
        case .precise: return .precise
        }
    }
}
