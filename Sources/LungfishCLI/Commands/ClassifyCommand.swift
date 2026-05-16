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
/// This subcommand resolves the database from the metagenomics registry,
/// configures the classification pipeline, and runs Kraken2. Optionally
/// chains Bracken for abundance profiling.
///
/// ## Examples
///
/// ```
/// # Classify with balanced preset
/// lungfish conda classify sample.fastq --db Viral --preset balanced
///
/// # Paired-end classification with profiling
/// lungfish conda classify R1.fastq R2.fastq --db Standard-8 --paired --profile
///
/// # Precise classification with 8 threads
/// lungfish conda classify reads.fastq --db PlusPF --preset precise --threads 8
/// ```
struct ClassifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "classify",
        abstract: "Run Kraken2 taxonomic classification on FASTQ or FASTA inputs",
        discussion: """
        Classify metagenomic reads or assembled sequences using Kraken2 with an installed database.
        Databases are managed via `lungfish conda db` or downloaded from the
        built-in catalog. Results include a kreport file, per-read output,
        and an optional Bracken abundance profile.
        """
    )

    // MARK: - Arguments

    @Argument(help: "Input sequence file(s). Provide two files for paired-end FASTQ.")
    var fastqFiles: [String]

    @Option(name: .customLong("db"), help: "Database name (e.g., 'Viral', 'Standard-8')")
    var databaseName: String

    @Option(name: .customLong("preset"), help: "Sensitivity preset: sensitive, balanced, precise (default: balanced)")
    var preset: ClassificationPresetArgument = .balanced

    @Option(name: [.customLong("output-dir"), .customShort("o")], help: "Output directory (default: current directory)")
    var outputDir: String?

    @Flag(name: .customLong("paired"), help: "Input files are paired-end reads")
    var pairedEnd: Bool = false

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

    @Option(name: .customLong("bracken-read-length"), help: "Read length for Bracken -r flag (default: 150)")
    var brackenReadLength: Int = 150

    @Option(name: .customLong("bracken-level"), help: "Bracken taxonomic level: D,P,C,O,F,G,S (default: S)")
    var brackenLevel: String = "S"

    @Option(name: .customLong("bracken-threshold"), help: "Bracken minimum read threshold (default: 10)")
    var brackenThreshold: Int = 10

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Additional kraken2 arguments passed verbatim"
    )
    var extraArgs: String = ""

    @OptionGroup var globalOptions: GlobalOptions

    // MARK: - Execution

    static func inferInputFormat(from inputURLs: [URL]) throws -> SequenceFormat {
        let formats = try inputURLs.map { url -> SequenceFormat in
            guard let format = SequenceInputResolver.inputSequenceFormat(for: url) else {
                throw CLIError.formatDetectionFailed(path: url.path)
            }
            return format
        }

        guard let firstFormat = formats.first else {
            return .fastq
        }
        guard formats.dropFirst().allSatisfy({ $0 == firstFormat }) else {
            throw CLIError.validationFailed(
                errors: ["All input sequence files must use the same format (FASTA or FASTQ)."]
            )
        }
        return firstFormat
    }

    func run() async throws {
        let startedAt = Date()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Resolve input files.
        let inputURLs = fastqFiles.map { URL(fileURLWithPath: $0) }
        for url in inputURLs {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIError.inputFileNotFound(path: url.path)
            }
        }

        if pairedEnd && inputURLs.count != 2 {
            throw CLIError.validationFailed(errors: ["Paired-end mode requires exactly 2 input files, got \(inputURLs.count)."])
        }

        // Resolve output directory before materialization so virtual FASTQ
        // payloads are durable and captured in final-location provenance.
        let outputDirectory: URL
        if let dir = outputDir {
            outputDirectory = URL(fileURLWithPath: dir)
        } else {
            outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("classification-\(databaseName.lowercased())")
        }

        let inputFormat: SequenceFormat
        do {
            inputFormat = try Self.inferInputFormat(from: inputURLs)
        } catch {
            print(formatter.error(error.localizedDescription))
            throw ExitCode.failure
        }
        if let confidence, confidence < 0.0 || confidence > 1.0 {
            print(formatter.error("Confidence must be between 0.0 and 1.0, got \(confidence)"))
            throw ExitCode.failure
        }

        // Resolve database and parse user options before materializing virtual
        // inputs so validation errors do not create scientific payloads.
        let registry = MetagenomicsDatabaseRegistry.shared
        guard let dbInfo = try await registry.database(named: databaseName) else {
            print(formatter.error("Database '\(databaseName)' not found in registry"))
            print(formatter.info("Available databases:"))
            let available = try await registry.availableDatabases()
            for db in available where db.isDownloaded {
                print("  \(db.name) [\(db.status.rawValue)]")
            }
            throw ExitCode.failure
        }

        guard let dbPath = dbInfo.path, dbInfo.status == .ready else {
            print(formatter.error("Database '\(databaseName)' is not ready (status: \(dbInfo.status.rawValue))"))
            if !dbInfo.isDownloaded {
                print(formatter.info("Download it first: the database has not been installed"))
            }
            throw ExitCode.failure
        }

        let parsedExtraArguments: [String]
        do {
            parsedExtraArguments = try AdvancedCommandLineOptions.parse(extraArgs)
        } catch {
            print(formatter.error(error.localizedDescription))
            throw ExitCode.failure
        }

        let resolvedInputs: CLISequenceInputMaterializationResult
        let materializationDirectory = outputDirectory.appendingPathComponent(".lungfish-classify-inputs", isDirectory: true)
        do {
            resolvedInputs = try await Self.resolveExecutionInputs(
                for: inputURLs,
                tempDirectory: materializationDirectory,
                materializer: FASTQCLIMaterializer(runner: NativeToolRunner.shared),
                progress: { message in
                    if !globalOptions.quiet {
                        print(formatter.info(message))
                    }
                }
            )
        } catch {
            throw CLIError.workflowFailed(reason: error.localizedDescription)
        }
        let executionInputURLs = resolvedInputs.inputURLs
        let durableReplayArguments = CLISequenceInputMaterialization.durableReplayArgv(
            argv: CommandLine.arguments,
            originalInputArguments: fastqFiles,
            originalInputURLs: inputURLs,
            executionInputURLs: executionInputURLs
        )
        if resolvedInputs.didMaterialize {
            let materializationStartedAt = resolvedInputs.materializationStartedAt ?? startedAt
            let materializationEndedAt = resolvedInputs.materializationEndedAt ?? materializationStartedAt
            do {
                _ = try CLISequenceInputMaterialization.writeMaterializationProvenanceOrCleanup(
                    workflowName: "lungfish.classify.input-materialization",
                    workflowVersion: LungfishCLI.configuration.version,
                    parentArgv: CommandLine.arguments,
                    parentDurableReplayArgv: durableReplayArguments,
                    originalInputURLs: inputURLs,
                    executionInputURLs: executionInputURLs,
                    outputDirectory: outputDirectory,
                    operationName: "classification",
                    startedAt: materializationStartedAt,
                    endedAt: materializationEndedAt
                )
            } catch {
                throw CLIError.outputWriteFailed(
                    path: outputDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename).path,
                    reason: error.localizedDescription
                )
            }
        }

        // Build config from preset, then apply overrides.
        let effectiveThreads = globalOptions.threads ?? 4
        var config = ClassificationConfig.fromPreset(
            preset.toPreset(),
            inputFiles: executionInputURLs,
            isPairedEnd: pairedEnd,
            databaseName: databaseName,
            inputFormat: inputFormat,
            databasePath: dbPath,
            threads: effectiveThreads,
            memoryMapping: memoryMapping,
            quickMode: quickMode,
            outputDirectory: outputDirectory,
            extraArguments: parsedExtraArguments
        )

        // Apply explicit overrides if provided.
        if let conf = confidence {
            config.confidence = conf
        }
        if let mhg = minHitGroups {
            config.minimumHitGroups = mhg
        }
        config.originalInputFiles = inputURLs.map(\.standardizedFileURL)
        config.sampleDisplayName = inputURLs.first?.deletingPathExtension().lastPathComponent

        // Print configuration.
        print(formatter.header("Kraken2 Classification"))
        print("")
        print(formatter.keyValueTable([
            ("Input files", inputURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Input format", inputFormat == .fasta ? "FASTA" : "FASTQ"),
            ("Paired-end", pairedEnd ? "yes" : "no"),
            ("Database", databaseName),
            ("Preset", preset.rawValue),
            ("Confidence", String(format: "%.2f", config.confidence)),
            ("Min hit groups", String(config.minimumHitGroups)),
            ("Threads", String(config.threads)),
            ("Memory mapping", config.memoryMapping ? "yes" : "no"),
            ("Bracken profiling", profile ? "yes" : "no"),
            ("Output", outputDirectory.path),
        ]))
        print("")

        // Run pipeline.
        let pipeline = ClassificationPipeline.shared

        let result: ClassificationResult
        if profile {
            let rank = TaxonomicRank(code: brackenLevel)
            result = try await pipeline.profile(
                config: config,
                brackenReadLength: brackenReadLength,
                brackenLevel: rank,
                brackenThreshold: brackenThreshold
            ) { fraction, message in
                if !globalOptions.quiet {
                    print("\r\(formatter.info(message))", terminator: "")
                }
            }
        } else {
            result = try await pipeline.classify(config: config) { fraction, message in
                if !globalOptions.quiet {
                    print("\r\(formatter.info(message))", terminator: "")
                }
            }
        }

        do {
            _ = try Self.writeProvenance(
                result: result,
                originalInputURLs: inputURLs,
                executionInputURLs: executionInputURLs,
                argv: CommandLine.arguments,
                durableReplayArgv: durableReplayArguments,
                profile: profile,
                brackenReadLength: brackenReadLength,
                brackenLevel: brackenLevel,
                brackenThreshold: brackenThreshold,
                startedAt: startedAt,
                endedAt: Date(),
                materializationStartedAt: resolvedInputs.materializationStartedAt,
                materializationEndedAt: resolvedInputs.materializationEndedAt
            )
        } catch {
            throw CLIError.outputWriteFailed(
                path: outputDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename).path,
                reason: error.localizedDescription
            )
        }

        // Clear progress line.
        print("")
        print("")

        // Print summary.
        print(formatter.header("Results"))
        print("")
        print(result.summary)
        print("")

        // Print top species.
        let topSpecies = result.tree.nodes(at: .species)
            .sorted { $0.readsClade > $1.readsClade }
            .prefix(10)

        if !topSpecies.isEmpty {
            print(formatter.header("Top Species"))
            print("")
            let rows = topSpecies.map { node -> [String] in
                let pct = String(format: "%.2f%%", node.fractionClade * 100)
                let reads = String(node.readsClade)
                let bracken = node.brackenReads.map { String($0) } ?? "-"
                return [node.name, reads, bracken, pct]
            }
            print(formatter.table(
                headers: ["Species", "Reads", "Bracken", "Fraction"],
                rows: Array(rows)
            ))
            print("")
        }

        // Print output file paths.
        print(formatter.header("Output Files"))
        print("  Report:  \(formatter.path(result.reportURL.path))")
        print("  Output:  \(formatter.path(result.outputURL.path))")
        if let bracken = result.brackenURL {
            print("  Bracken: \(formatter.path(bracken.path))")
        }
        print("")
        print(formatter.success("Classification completed in \(String(format: "%.1f", result.runtime))s"))
    }

    static func resolveExecutionInputURLs(for inputURLs: [URL]) throws -> [URL] {
        try inputURLs.map { inputURL in
            guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) else {
                throw CLIError.formatDetectionFailed(path: inputURL.path)
            }
            return resolvedURL.standardizedFileURL
        }
    }

    static func resolveExecutionInputs(
        for inputURLs: [URL],
        tempDirectory: URL,
        materializer: CLISequenceInputMaterializing,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> CLISequenceInputMaterializationResult {
        try await CLISequenceInputMaterialization.resolveExecutionInputs(
            for: inputURLs,
            tempDirectory: tempDirectory,
            materializer: materializer,
            operationName: "classification",
            progress: progress
        )
    }

    @discardableResult
    static func writeProvenance(
        result: ClassificationResult,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        argv: [String],
        durableReplayArgv: [String]? = nil,
        profile: Bool = false,
        brackenReadLength: Int = 150,
        brackenLevel: String = "S",
        brackenThreshold: Int = 10,
        startedAt: Date,
        endedAt: Date,
        materializationStartedAt: Date? = nil,
        materializationEndedAt: Date? = nil,
        stderr: String? = nil,
        writer: ProvenanceWriter = ProvenanceWriter()
    ) throws -> URL {
        let config = result.config
        let inputPairs = zipOriginalAndExecutionInputs(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        )
        let executionDescriptors = try inputPairs.map { originalURL, executionURL in
            try CLISequenceInputMaterialization.executionInputDescriptor(
                originalURL: originalURL,
                executionURL: executionURL
            )
        }
        let materializationSteps = try CLISequenceInputMaterialization.materializationProvenanceSteps(
            workflowVersion: LungfishCLI.configuration.version,
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs,
            startedAt: materializationStartedAt ?? startedAt,
            endedAt: materializationEndedAt ?? (materializationStartedAt ?? startedAt)
        )
        let outputDescriptors = try classificationOutputDescriptors(for: result)

        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish.classify",
            workflowVersion: LungfishCLI.configuration.version,
            toolName: "kraken2",
            toolVersion: result.toolVersion
        )
        .argv(argv)
        .durableReplayArgv(durableReplayArgv)
        .options(
            explicit: classificationResolvedOptions(
                for: config,
                originalInputURLs: originalInputURLs,
                executionInputURLs: executionInputURLs,
                profile: profile,
                brackenReadLength: brackenReadLength,
                brackenLevel: brackenLevel,
                brackenThreshold: brackenThreshold
            ),
            defaults: classificationDefaultOptions(),
            resolved: classificationResolvedOptions(
                for: config,
                originalInputURLs: originalInputURLs,
                executionInputURLs: executionInputURLs,
                profile: profile,
                brackenReadLength: brackenReadLength,
                brackenLevel: brackenLevel,
                brackenThreshold: brackenThreshold
            )
        )
        .runtime(
            ProvenanceRuntimeIdentity(
                appVersion: LungfishCLI.configuration.version,
                condaEnvironment: ClassificationPipeline.kraken2Environment
            )
        )

        for materializationStep in materializationSteps {
            builder = builder.step(materializationStep)
        }

        let krakenArgv = ["kraken2"] + config.kraken2Arguments()
        builder = builder.step(
            ProvenanceStep(
                toolName: "kraken2",
                toolVersion: result.toolVersion,
                argv: krakenArgv,
                reproducibleCommand: krakenArgv.map(shellEscape).joined(separator: " "),
                inputs: executionDescriptors,
                outputs: outputDescriptors,
                exitStatus: 0,
                wallTimeSeconds: result.runtime,
                stderr: stderr,
                startedAt: startedAt,
                completedAt: endedAt
            )
        )

        if let brackenStep = try brackenProvenanceStep(
            result: result,
            brackenReadLength: brackenReadLength,
            brackenLevel: brackenLevel,
            brackenThreshold: brackenThreshold,
            fallbackStartedAt: endedAt
        ) {
            builder = builder.step(brackenStep)
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            stderr: stderr,
            startedAt: startedAt,
            endedAt: endedAt
        )
        return try writer.write(envelope, to: config.outputDirectory)
    }

    private static func zipOriginalAndExecutionInputs(
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) -> [(originalURL: URL, executionURL: URL)] {
        executionInputURLs.enumerated().map { index, executionURL in
            let originalURL = originalInputURLs.indices.contains(index) ? originalInputURLs[index] : executionURL
            return (originalURL, executionURL)
        }
    }

    private static func classificationDefaultOptions() -> [String: ParameterValue] {
        [
            "preset": .string("balanced"),
            "pairedEnd": .boolean(false),
            "profile": .boolean(false),
            "threads": .integer(4),
            "memoryMapping": .boolean(false),
            "quickMode": .boolean(false),
            "brackenReadLength": .integer(150),
            "brackenLevel": .string("S"),
            "brackenThreshold": .integer(10),
            "extraArguments": .array([]),
        ]
    }

    private static func classificationResolvedOptions(
        for config: ClassificationConfig,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        profile: Bool,
        brackenReadLength: Int,
        brackenLevel: String,
        brackenThreshold: Int
    ) -> [String: ParameterValue] {
        [
            "databaseName": .string(config.databaseName),
            "databasePath": .file(config.databasePath),
            "inputFormat": .string(config.inputFormat.rawValue),
            "pairedEnd": .boolean(config.isPairedEnd),
            "profile": .boolean(profile),
            "confidence": .number(config.confidence),
            "minimumHitGroups": .integer(config.minimumHitGroups),
            "threads": .integer(config.threads),
            "memoryMapping": .boolean(config.memoryMapping),
            "quickMode": .boolean(config.quickMode),
            "brackenReadLength": .integer(brackenReadLength),
            "brackenLevel": .string(brackenLevel),
            "brackenThreshold": .integer(brackenThreshold),
            "outputDirectory": .file(config.outputDirectory),
            "extraArguments": .array(config.extraArguments.map(ParameterValue.string)),
            "originalInputs": .array(originalInputURLs.map { .file($0.standardizedFileURL) }),
            "executionInputs": .array(executionInputURLs.map { .file($0.standardizedFileURL) }),
        ]
    }

    private static func brackenProvenanceStep(
        result: ClassificationResult,
        brackenReadLength: Int,
        brackenLevel: String,
        brackenThreshold: Int,
        fallbackStartedAt: Date
    ) throws -> ProvenanceStep? {
        guard let brackenURL = result.brackenURL,
              FileManager.default.fileExists(atPath: brackenURL.path) else {
            return nil
        }

        let legacyStep = ProvenanceRecorder.load(from: result.config.outputDirectory)?
            .steps
            .first { $0.toolName == "bracken" }
        let fallbackArgv = [
            "bracken",
            "-d", result.config.databasePath.path,
            "-i", result.reportURL.path,
            "-o", brackenURL.path,
            "-r", String(brackenReadLength),
            "-l", brackenLevel,
            "-t", String(brackenThreshold),
        ]
        let brackenArgv = legacyStep?.command ?? fallbackArgv
        return ProvenanceStep(
            toolName: "bracken",
            toolVersion: legacyStep?.toolVersion ?? "unknown",
            argv: brackenArgv,
            reproducibleCommand: brackenArgv.map(shellEscape).joined(separator: " "),
            inputs: [
                try ProvenanceFileDescriptor.file(url: result.reportURL, format: .text, role: .input),
            ],
            outputs: [
                try ProvenanceFileDescriptor.file(url: brackenURL, format: .text, role: .output),
            ],
            exitStatus: Int(legacyStep?.exitCode ?? 0),
            wallTimeSeconds: legacyStep?.wallTime ?? 0,
            stderr: legacyStep?.stderr,
            startedAt: legacyStep?.startTime ?? fallbackStartedAt,
            completedAt: legacyStep?.endTime ?? fallbackStartedAt
        )
    }

    private static func classificationOutputDescriptors(
        for result: ClassificationResult
    ) throws -> [ProvenanceFileDescriptor] {
        var outputs: [(url: URL, format: FileFormat?, role: FileRole)] = [
            (result.reportURL, .text, .report),
            (result.outputURL, .text, .output),
        ]
        if let brackenURL = result.brackenURL {
            outputs.append((brackenURL, .text, .output))
        }
        let resultSidecarURL = result.config.outputDirectory.appendingPathComponent("classification-result.json")
        if FileManager.default.fileExists(atPath: resultSidecarURL.path) {
            outputs.append((resultSidecarURL, .json, .report))
        }
        return try outputs
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .map { output in
                try ProvenanceFileDescriptor.file(
                    url: output.url,
                    format: output.format,
                    role: output.role
                )
            }
    }

    func makeConfigForTesting(
        inputURLs: [URL],
        databasePath: URL,
        inputFormat: SequenceFormat,
        outputDirectory: URL
    ) throws -> ClassificationConfig {
        ClassificationConfig.fromPreset(
            preset.toPreset(),
            inputFiles: inputURLs,
            isPairedEnd: pairedEnd,
            databaseName: databaseName,
            inputFormat: inputFormat,
            databasePath: databasePath,
            threads: globalOptions.threads ?? 4,
            memoryMapping: memoryMapping,
            quickMode: quickMode,
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
