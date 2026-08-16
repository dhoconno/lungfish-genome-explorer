// ClassifyCommand.swift - CLI command for Kraken2 classification
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
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
struct ClassifyTerminalPolicy: Equatable {
    let isSuccess: Bool
    let exitCode: Int32
    let message: String
}

enum ClassifyFailureStage: String {
    case inputValidation
    case databaseResolution
    case materialization
    case pipeline
    case provenancePublication
}

struct ClassifyFailureProvenanceContext {
    let outputDirectory: URL
    var originalInputURLs: [URL]
    var executionInputURLs: [URL] = []
    var durableReplayArgv: [String]?
    var inputFormat: SequenceFormat?
    var databaseInfo: MetagenomicsDatabaseInfo?
    var databasePath: URL?
    var parsedExtraArguments: [String]?
    var config: ClassificationConfig?
    var materializationStartedAt: Date?
    var materializationEndedAt: Date?
    var pipelineStarted = false
    var wrapperProvenanceWritten = false
    var stage: ClassifyFailureStage = .inputValidation
    var failureMessage: String?
}

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

    @Option(name: .customLong("bracken-read-length"), help: "Read length for Bracken -r flag (default: 150)")
    var brackenReadLength: Int = 150

    @Option(
        name: .customLong("bracken-level"),
        help: "Bracken taxonomic level: D,P,C,O,F,G,S (default: automatic for the selected database)"
    )
    var brackenLevel: String?

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

        // Resolve the final provenance location before any validation so even
        // pre-tool failures have a durable command record.
        let outputDirectory: URL
        if let dir = outputDir {
            outputDirectory = URL(fileURLWithPath: dir)
        } else {
            outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("classification-\(databaseName.lowercased())")
        }
        var failureContext = ClassifyFailureProvenanceContext(
            outputDirectory: outputDirectory,
            originalInputURLs: fastqFiles.map { URL(fileURLWithPath: $0).standardizedFileURL }
        )

        do {

        // Resolve input files.
        let inputURLs = try CLIClassificationFolderResolver.expandInputArguments(
            fastqFiles,
            recursive: recursive
        )
        failureContext.originalInputURLs = inputURLs.map(\.standardizedFileURL)
        if inputURLs.isEmpty {
            failureContext.failureMessage = "No eligible FASTQ or FASTA inputs found."
            throw CLIError.validationFailed(errors: ["No eligible FASTQ or FASTA inputs found."])
        }

        if pairedEnd && inputURLs.count != 2 {
            failureContext.failureMessage = "Paired-end mode requires exactly 2 input files, got \(inputURLs.count)."
            throw CLIError.validationFailed(errors: ["Paired-end mode requires exactly 2 input files, got \(inputURLs.count)."])
        }

        let inputFormat: SequenceFormat
        do {
            inputFormat = try Self.inferInputFormat(from: inputURLs)
            failureContext.inputFormat = inputFormat
        } catch {
            failureContext.failureMessage = error.localizedDescription
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.inputError.exitCode
        }
        if let confidence, confidence < 0.0 || confidence > 1.0 {
            let message = "Confidence must be between 0.0 and 1.0, got \(confidence)"
            failureContext.failureMessage = message
            print(formatter.error(message))
            throw CLIExitCode.inputError.exitCode
        }

        // Resolve database and parse user options before materializing virtual
        // inputs so validation errors do not create scientific payloads.
        failureContext.stage = .databaseResolution
        let registry = MetagenomicsDatabaseRegistry.shared
        guard let dbInfo = try await registry.database(named: databaseName) else {
            failureContext.failureMessage = "Database '\(databaseName)' not found in registry."
            print(formatter.error("Database '\(databaseName)' not found in registry"))
            print(formatter.info("Available databases:"))
            let available = try await registry.availableDatabases()
            for db in available where db.isDownloaded {
                print("  \(db.name) [\(db.status.rawValue)]")
            }
            throw CLIExitCode.inputError.exitCode
        }
        failureContext.databaseInfo = dbInfo

        guard let dbPath = dbInfo.path, dbInfo.status == .ready else {
            failureContext.failureMessage = "Database '\(databaseName)' is not ready (status: \(dbInfo.status.rawValue))."
            print(formatter.error("Database '\(databaseName)' is not ready (status: \(dbInfo.status.rawValue))"))
            if !dbInfo.isDownloaded {
                print(formatter.info("Download it first: the database has not been installed"))
            }
            throw CLIExitCode.dependency.exitCode
        }
        failureContext.databasePath = dbPath

        let parsedExtraArguments: [String]
        do {
            parsedExtraArguments = try AdvancedCommandLineOptions.parse(extraArgs)
            failureContext.parsedExtraArguments = parsedExtraArguments
        } catch {
            failureContext.failureMessage = error.localizedDescription
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.inputError.exitCode
        }

        let resolvedInputs: CLISequenceInputMaterializationResult
        failureContext.stage = .materialization
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
            failureContext.failureMessage = error.localizedDescription
            throw CLIError.workflowFailed(reason: error.localizedDescription)
        }
        let executionInputURLs = resolvedInputs.inputURLs
        let durableReplayArguments = CLISequenceInputMaterialization.durableReplayArgv(
            argv: CommandLine.arguments,
            originalInputArguments: fastqFiles,
            originalInputURLs: inputURLs,
            executionInputURLs: executionInputURLs
        )
        failureContext.executionInputURLs = executionInputURLs.map(\.standardizedFileURL)
        failureContext.durableReplayArgv = durableReplayArguments
        failureContext.materializationStartedAt = resolvedInputs.materializationStartedAt
        failureContext.materializationEndedAt = resolvedInputs.materializationEndedAt
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
                failureContext.stage = .provenancePublication
                failureContext.failureMessage = error.localizedDescription
                throw CLIError.outputWriteFailed(
                    path: outputDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename).path,
                    reason: error.localizedDescription
                )
            }
        }

        // Build config from the registry identity and preset, then apply overrides.
        let effectiveThreads = globalOptions.threads ?? 4
        var config = makeConfig(
            inputURLs: executionInputURLs,
            databaseInfo: dbInfo,
            databasePath: dbPath,
            inputFormat: inputFormat,
            outputDirectory: outputDirectory,
            threads: effectiveThreads,
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
        failureContext.config = config

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
            ("Bracken rank", resolvedBrackenRankDescription(for: config)),
            ("Output", outputDirectory.path),
        ]))
        print("")

        // Run pipeline.
        let pipeline = ClassificationPipeline.shared
        failureContext.stage = .pipeline
        failureContext.pipelineStarted = true

        let result: ClassificationResult
        if profile {
            result = try await pipeline.profile(config: config) { fraction, message in
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
                preset: preset.rawValue,
                startedAt: startedAt,
                endedAt: Date(),
                materializationStartedAt: resolvedInputs.materializationStartedAt,
                materializationEndedAt: resolvedInputs.materializationEndedAt,
                recursive: recursive
            )
            failureContext.wrapperProvenanceWritten = true
        } catch {
            failureContext.stage = .provenancePublication
            failureContext.failureMessage = error.localizedDescription
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

        let terminalPolicy = Self.terminalPolicy(for: result)
        if terminalPolicy.isSuccess {
            print(formatter.success("\(terminalPolicy.message) in \(String(format: "%.1f", result.runtime))s"))
        } else {
            print(formatter.warning(terminalPolicy.message))
            throw ExitCode(rawValue: terminalPolicy.exitCode)
        }
        } catch {
            guard !failureContext.wrapperProvenanceWritten else {
                throw error
            }

            let endedAt = Date()
            let failureMessage: String
            if let recordedMessage = failureContext.failureMessage {
                failureMessage = recordedMessage
            } else if error is CancellationError {
                failureMessage = "Classification cancelled."
            } else {
                failureMessage = error.localizedDescription
            }

            do {
                _ = try Self.writeFailureProvenance(
                    command: self,
                    context: failureContext,
                    argv: CommandLine.arguments,
                    exitStatus: Self.failureExitStatus(for: error),
                    profileState: Self.failureProfileState(for: error),
                    stderr: failureMessage,
                    startedAt: startedAt,
                    endedAt: endedAt
                )
            } catch let provenanceError {
                throw CLIError.outputWriteFailed(
                    path: outputDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename).path,
                    reason: provenanceError.localizedDescription
                )
            }

            if error is CancellationError {
                throw CLIError.cancelled
            }
            if error is CLIError || error is ExitCode {
                throw error
            }
            throw CLIError.workflowFailed(reason: error.localizedDescription)
        }
    }

    static func resolveExecutionInputURLs(for inputURLs: [URL]) throws -> [URL] {
        try inputURLs.map { inputURL in
            guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) else {
                throw CLIError.formatDetectionFailed(path: inputURL.path)
            }
            return resolvedURL.standardizedFileURL
        }
    }

    static func terminalPolicy(for result: ClassificationResult) -> ClassifyTerminalPolicy {
        switch result.profileOutcome.state {
        case .notRequested where result.config.goal == .profile:
            return ClassifyTerminalPolicy(
                isSuccess: false,
                exitCode: CLIExitCode.workflowError.rawValue,
                message: "Kraken classification completed, but Bracken profiling has no recorded outcome."
            )
        case .notRequested:
            return ClassifyTerminalPolicy(
                isSuccess: true,
                exitCode: CLIExitCode.success.rawValue,
                message: "Classification completed"
            )
        case .completed:
            return ClassifyTerminalPolicy(
                isSuccess: true,
                exitCode: CLIExitCode.success.rawValue,
                message: "Kraken classification and Bracken profiling completed"
            )
        case .degraded:
            let detail = result.profileOutcome.message
                ?? result.profileOutcome.reason?.rawValue
                ?? "unknown profiling failure"
            return ClassifyTerminalPolicy(
                isSuccess: false,
                exitCode: CLIExitCode.workflowError.rawValue,
                message: "Kraken classification completed, but Bracken profiling did not complete: \(detail)"
            )
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
    static func writeFailureProvenance(
        command: ClassifyCommand,
        context: ClassifyFailureProvenanceContext,
        argv: [String],
        exitStatus: Int,
        profileState: String,
        stderr: String,
        startedAt: Date,
        endedAt: Date,
        writer: ProvenanceWriter = ProvenanceWriter()
    ) throws -> URL {
        let executionInputsRemainAvailable = !context.executionInputURLs.isEmpty
            && context.executionInputURLs.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            }
        let effectiveExecutionInputURLs = executionInputsRemainAvailable
            ? context.executionInputURLs
            : []
        let durableReplayArgv = executionInputsRemainAvailable
            ? (context.durableReplayArgv ?? argv)
            : classificationFailureOriginalReplayArgv(
                command: command,
                context: context,
                argv: argv
            )
        let databaseReference = classificationFailureDatabaseReferenceDescriptor(
            context: context
        )
        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish.classify",
            workflowVersion: LungfishCLI.configuration.version,
            toolName: CLICommandIdentity.executableName,
            toolVersion: LungfishCLI.configuration.version
        )
        .argv(argv)
        .durableReplayArgv(durableReplayArgv)
        .reproducibleCommand(durableReplayArgv.map(shellEscape).joined(separator: " "))
        .options(
            explicit: classificationFailureExplicitOptions(
                command: command,
                context: context,
                argv: argv
            ),
            defaults: classificationDefaultOptions(preset: command.preset.rawValue),
            resolved: classificationFailureResolvedOptions(
                command: command,
                context: context,
                profileState: profileState,
                effectiveExecutionInputURLs: effectiveExecutionInputURLs,
                databaseReference: databaseReference
            )
        )
        .runtime(
            ProvenanceRuntimeIdentity(appVersion: LungfishCLI.configuration.version)
        )

        if effectiveExecutionInputURLs.isEmpty {
            for inputURL in context.originalInputURLs {
                let descriptors = try CLISequenceInputMaterialization.originalInputDescriptors(
                    for: inputURL
                )
                for descriptor in descriptors {
                    builder = try builder.consumedInputSnapshot(descriptor)
                }
            }
        } else {
            for pair in zipOriginalAndExecutionInputs(
                originalInputURLs: context.originalInputURLs,
                executionInputURLs: effectiveExecutionInputURLs
            ) {
                let descriptor = try CLISequenceInputMaterialization.executionInputDescriptor(
                    originalURL: pair.originalURL,
                    executionURL: pair.executionURL
                )
                builder = try builder.consumedInputSnapshot(descriptor)
            }

            let materializationSteps = try CLISequenceInputMaterialization.materializationProvenanceSteps(
                workflowVersion: LungfishCLI.configuration.version,
                originalInputURLs: context.originalInputURLs,
                executionInputURLs: effectiveExecutionInputURLs,
                startedAt: context.materializationStartedAt ?? startedAt,
                endedAt: context.materializationEndedAt
                    ?? context.materializationStartedAt
                    ?? startedAt
            )
            for step in materializationSteps {
                builder = builder.step(step)
            }
        }

        if let databaseReference {
            builder = try builder.input(databaseReference)
        }

        if context.pipelineStarted,
           let pipelineEnvelope = ProvenanceRecorder.loadEnvelope(from: context.outputDirectory),
           ["Metagenomics Classification", "Metagenomics Profiling"].contains(pipelineEnvelope.workflowName),
           pipelineEnvelope.createdAt >= startedAt.addingTimeInterval(-1),
           pipelineEnvelope.createdAt <= endedAt.addingTimeInterval(1) {
            for step in pipelineEnvelope.steps {
                builder = builder.step(step)
            }
        }

        let envelope = try builder.complete(
            exitStatus: exitStatus,
            stderr: stderr,
            startedAt: startedAt,
            endedAt: endedAt
        )
        return try writer.write(envelope, to: context.outputDirectory)
    }

    private static func classificationFailureExplicitOptions(
        command: ClassifyCommand,
        context: ClassifyFailureProvenanceContext,
        argv: [String]
    ) -> [String: ParameterValue] {
        if let config = context.config {
            return classificationExplicitOptions(
                for: config,
                originalInputURLs: context.originalInputURLs,
                argv: argv,
                preset: command.preset.rawValue
            )
        }

        var options: [String: ParameterValue] = [
            "databaseName": .string(command.databaseName),
            "originalInputs": .array(context.originalInputURLs.map { .file($0) }),
        ]
        if argvContainsOption(argv, names: ["--output-dir", "-o"]) {
            options["outputDirectory"] = .file(context.outputDirectory)
        }
        if argvContainsOption(argv, names: ["--preset"]) {
            options["preset"] = .string(command.preset.rawValue)
        }
        if argvContainsOption(argv, names: ["--paired"]) {
            options["pairedEnd"] = .boolean(command.pairedEnd)
        }
        if argvContainsOption(argv, names: ["--recursive"]) {
            options["recursive"] = .boolean(command.recursive)
        }
        if argvContainsOption(argv, names: ["--profile"]) {
            options["profile"] = .boolean(command.profile)
        }
        if let confidence = command.confidence {
            options["confidence"] = .number(confidence)
        }
        if let minimumHitGroups = command.minHitGroups {
            options["minimumHitGroups"] = .integer(minimumHitGroups)
        }
        if argvContainsOption(argv, names: ["--threads"]),
           let threads = command.globalOptions.threads {
            options["threads"] = .integer(threads)
        }
        if argvContainsOption(argv, names: ["--memory-mapping"]) {
            options["memoryMapping"] = .boolean(command.memoryMapping)
        }
        if argvContainsOption(argv, names: ["--quick"]) {
            options["quickMode"] = .boolean(command.quickMode)
        }
        if argvContainsOption(argv, names: ["--bracken-read-length"]) {
            options["brackenReadLength"] = .integer(command.brackenReadLength)
        }
        if let level = command.brackenLevel {
            options["brackenLevel"] = .string(level)
            options["brackenRankRequest"] = .string(
                BrackenRankRequest.explicit(TaxonomicRank(code: level)).provenanceValue
            )
        }
        if argvContainsOption(argv, names: ["--bracken-threshold"]) {
            options["brackenThreshold"] = .integer(command.brackenThreshold)
        }
        if argvContainsOption(argv, names: ["--extra-args"]) {
            options["extraArguments"] = .string(command.extraArgs)
        }
        return options
    }

    private static func classificationFailureResolvedOptions(
        command: ClassifyCommand,
        context: ClassifyFailureProvenanceContext,
        profileState: String,
        effectiveExecutionInputURLs: [URL],
        databaseReference: ProvenanceFileDescriptor?
    ) -> [String: ParameterValue] {
        if let config = context.config {
            var options = classificationResolvedOptions(
                for: config,
                outcome: .notRequested,
                originalInputURLs: context.originalInputURLs,
                executionInputURLs: effectiveExecutionInputURLs.isEmpty
                    ? context.originalInputURLs
                    : effectiveExecutionInputURLs,
                preset: command.preset.rawValue,
                recursive: command.recursive
            )
            options["profileState"] = .string(profileState)
            options["failureStage"] = .string(context.stage.rawValue)
            options["databaseReferenceMetadataStatus"] = .string(
                classificationFailureDatabaseReferenceMetadataStatus(
                    context: context,
                    databaseReference: databaseReference
                )
            )
            options["databaseReferenceSizeBytes"] = databaseReference?.fileSize
                .map { .integer(Int(min($0, UInt64(Int.max)))) } ?? .null
            return options
        }

        let presetParameters = command.preset.toPreset().parameters
        let request = command.requestedBrackenProfile()
        let resolution = context.databaseInfo.flatMap { databaseInfo in
            request.map {
                BrackenDatabaseCapabilities.resolve(
                    catalogID: databaseInfo.catalogID,
                    installationRecipe: databaseInfo.installationRecipe,
                    request: $0
                )
            }
        }
        let databaseInfo = context.databaseInfo
        return [
            "databaseName": .string(command.databaseName),
            "databaseVersion": databaseInfo?.version.map(ParameterValue.string) ?? .null,
            "databaseDigest": databaseInfo?.payloadDigest.map(ParameterValue.string) ?? .null,
            "databaseCatalogID": databaseInfo?.catalogID.map(ParameterValue.string) ?? .null,
            "databaseInstallationRecipe": databaseInfo?.installationRecipe
                .map { .string($0.provenanceValue) } ?? .null,
            "databasePath": context.databasePath.map(ParameterValue.file) ?? .null,
            "inputFormat": context.inputFormat.map { .string($0.rawValue) } ?? .null,
            "goal": .string(command.profile ? "profile" : "classify"),
            "preset": .string(command.preset.rawValue),
            "pairedEnd": .boolean(command.pairedEnd),
            "recursive": .boolean(command.recursive),
            "profile": .boolean(command.profile),
            "confidence": .number(command.confidence ?? presetParameters.confidence),
            "minimumHitGroups": .integer(command.minHitGroups ?? presetParameters.minimumHitGroups),
            "threads": .integer(command.globalOptions.threads ?? 4),
            "memoryMapping": .boolean(command.memoryMapping),
            "quickMode": .boolean(command.quickMode),
            "brackenRankRequest": request.map { .string($0.rank.provenanceValue) } ?? .string("notRequested"),
            "brackenRequestedReadLength": request.map { .integer($0.readLength) } ?? .null,
            "brackenRequestedThreshold": request.map { .integer($0.threshold) } ?? .null,
            "brackenResolvedRank": resolution.map { .string($0.rank.code) } ?? .null,
            "brackenResolutionSource": resolution.map { .string($0.source.rawValue) } ?? .null,
            "brackenReadLength": resolution.map { .integer($0.readLength) } ?? .null,
            "brackenThreshold": resolution.map { .integer($0.threshold) } ?? .null,
            "profileState": .string(profileState),
            "outputDirectory": .file(context.outputDirectory),
            "extraArguments": context.parsedExtraArguments
                .map { .array($0.map(ParameterValue.string)) } ?? .null,
            "originalInputs": .array(context.originalInputURLs.map { .file($0) }),
            "executionInputs": .array(effectiveExecutionInputURLs.map { .file($0) }),
            "failureStage": .string(context.stage.rawValue),
            "databaseReferenceMetadataStatus": .string(
                classificationFailureDatabaseReferenceMetadataStatus(
                    context: context,
                    databaseReference: databaseReference
                )
            ),
            "databaseReferenceSizeBytes": databaseReference?.fileSize
                .map { .integer(Int(min($0, UInt64(Int.max)))) } ?? .null,
        ]
    }

    private static func classificationFailureOriginalReplayArgv(
        command: ClassifyCommand,
        context: ClassifyFailureProvenanceContext,
        argv: [String]
    ) -> [String] {
        var replacements: [String: String] = [:]
        let hasOneToOneResolution = command.fastqFiles.count == context.originalInputURLs.count
        for (index, rawArgument) in command.fastqFiles.enumerated() {
            let durablePath: String
            if hasOneToOneResolution,
               context.originalInputURLs.indices.contains(index) {
                durablePath = context.originalInputURLs[index].standardizedFileURL.path
            } else {
                durablePath = URL(fileURLWithPath: rawArgument).standardizedFileURL.path
            }
            replacements[rawArgument] = durablePath
        }
        return argv.map { replacements[$0] ?? $0 }
    }

    private static func classificationFailureDatabaseReferenceMetadataStatus(
        context: ClassifyFailureProvenanceContext,
        databaseReference: ProvenanceFileDescriptor?
    ) -> String {
        if databaseReference != nil {
            return "verifiedInstallReceipt"
        }
        if context.databaseInfo != nil || context.databasePath != nil {
            return "registryIdentityWithoutVerifiedReceipt"
        }
        return "unresolved"
    }

    private static func classificationFailureDatabaseReferenceDescriptor(
        context: ClassifyFailureProvenanceContext
    ) -> ProvenanceFileDescriptor? {
        guard let databasePath = (context.databasePath ?? context.databaseInfo?.path)?
            .standardizedFileURL else {
            return nil
        }

        guard let receipt = ProvenanceRecorder.loadEnvelope(from: databasePath),
              receipt.workflowName == "metagenomics.database.install",
              receipt.exitStatus == 0,
              receipt.options.resolvedDefaults["intendedFinalPath"]?.stringValue
                == databasePath.path,
              let receiptDigest = normalizedSHA256(
                receipt.options.resolvedDefaults["payloadAggregateSHA256"]?.stringValue
              ),
              let verifiedReceiptSize = verifiedDatabaseReceiptSize(
                receipt,
                databasePath: databasePath,
                aggregateDigest: receiptDigest
              ) else {
            return nil
        }

        if let registryDigest = context.databaseInfo?.payloadDigest {
            guard normalizedSHA256(registryDigest) == receiptDigest else {
                return nil
            }
        }
        return ProvenanceFileDescriptor(
            path: databasePath.path,
            checksumSHA256: receiptDigest,
            fileSize: verifiedReceiptSize,
            format: .unknown,
            role: .reference,
            sourceProvenancePath: databasePath
                .appendingPathComponent(ProvenanceWriter.provenanceFilename).path
        )
    }

    private static func normalizedSHA256(_ value: String?) -> String? {
        guard var value else { return nil }
        if value.lowercased().hasPrefix("sha256:") {
            value = String(value.dropFirst("sha256:".count))
        }
        let normalized = value.lowercased()
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            return nil
        }
        return normalized
    }

    private static func verifiedDatabaseReceiptSize(
        _ receipt: ProvenanceEnvelope,
        databasePath: URL,
        aggregateDigest: String
    ) -> UInt64? {
        guard !receipt.outputs.isEmpty else { return nil }
        let rootPath = databasePath.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var seenPaths = Set<String>()
        var aggregateRows: [(relativePath: String, checksum: String, size: UInt64)] = []
        var totalSizeBytes: UInt64 = 0

        for descriptor in receipt.outputs {
            let outputPath = URL(fileURLWithPath: descriptor.path).standardizedFileURL.path
            guard descriptor.role == .output,
                  outputPath.hasPrefix(rootPrefix),
                  seenPaths.insert(outputPath).inserted,
                  let checksum = normalizedSHA256(descriptor.checksumSHA256),
                  let size = descriptor.fileSize else {
                return nil
            }
            let (newTotal, overflow) = totalSizeBytes.addingReportingOverflow(size)
            guard !overflow else { return nil }
            totalSizeBytes = newTotal
            aggregateRows.append((
                relativePath: String(outputPath.dropFirst(rootPrefix.count)),
                checksum: checksum,
                size: size
            ))
        }

        let aggregateLines = aggregateRows
            .sorted { $0.relativePath < $1.relativePath }
            .map { "\($0.relativePath)\t\($0.checksum)\t\($0.size)\n" }
            .joined()
        let computedDigest = SHA256.hash(data: Data(aggregateLines.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard computedDigest == aggregateDigest else { return nil }
        guard let claimedSize = receipt.options.resolvedDefaults["payloadTotalSizeBytes"]?.integerValue,
              claimedSize >= 0,
              UInt64(claimedSize) == totalSizeBytes else { return nil }
        return totalSizeBytes
    }

    private static func failureProfileState(for error: Error) -> String {
        error is CancellationError ? "cancelled" : "failed"
    }

    private static func failureExitStatus(for error: Error) -> Int {
        if let exitCode = error as? ExitCode {
            return Int(exitCode.rawValue)
        }
        if let cliError = error as? CLIError {
            return Int(cliError.exitCode.rawValue)
        }
        if error is CancellationError {
            return Int(CLIExitCode.cancelled.rawValue)
        }
        return Int(CLIExitCode.workflowError.rawValue)
    }

    @discardableResult
    static func writeProvenance(
        result: ClassificationResult,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        argv: [String],
        durableReplayArgv: [String]? = nil,
        preset: String = "balanced",
        startedAt: Date,
        endedAt: Date,
        materializationStartedAt: Date? = nil,
        materializationEndedAt: Date? = nil,
        recursive: Bool = false,
        stderr: String? = nil,
        writer: ProvenanceWriter = ProvenanceWriter()
    ) throws -> URL {
        let config = result.config
        let pipelineEnvelope = ProvenanceRecorder.loadEnvelope(from: config.outputDirectory)
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
            explicit: classificationExplicitOptions(
                for: config,
                originalInputURLs: originalInputURLs,
                argv: argv,
                preset: preset
            ),
            defaults: classificationDefaultOptions(preset: preset),
            resolved: classificationResolvedOptions(
                for: config,
                outcome: result.profileOutcome,
                originalInputURLs: originalInputURLs,
                executionInputURLs: executionInputURLs,
                preset: preset,
                recursive: recursive
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
        for outputDescriptor in outputDescriptors {
            builder = try builder.output(
                URL(fileURLWithPath: outputDescriptor.path),
                format: outputDescriptor.format,
                role: outputDescriptor.role
            )
        }

        let krakenArgv = ["kraken2"] + config.kraken2Arguments()
        let krakenOutputDescriptors = outputDescriptors.filter { descriptor in
            descriptor.path == result.reportURL.path
                || descriptor.path == config.outputURL.path
        }
        let recordedKrakenStep = pipelineEnvelope.flatMap { envelope -> ProvenanceStep? in
            guard isCurrentClassificationPipelineEnvelope(envelope, result: result) else {
                return nil
            }
            return envelope.steps.first {
                $0.toolName == "kraken2" && $0.exitStatus == 0
            }
        }
        let krakenStep = recordedKrakenStep
            ?? ProvenanceStep(
                toolName: "kraken2",
                toolVersion: result.toolVersion,
                argv: krakenArgv,
                reproducibleCommand: krakenArgv.map(shellEscape).joined(separator: " "),
                inputs: executionDescriptors,
                outputs: krakenOutputDescriptors,
                exitStatus: 0,
                wallTimeSeconds: result.runtime,
                stderr: stderr,
                startedAt: startedAt,
                completedAt: endedAt
            )
        builder = builder.step(krakenStep)

        if let brackenStep = try brackenProvenanceStep(
            result: result,
            pipelineEnvelope: pipelineEnvelope,
            fallbackStartedAt: endedAt
        ) {
            builder = builder.step(brackenStep)
        }

        let terminalPolicy = terminalPolicy(for: result)
        let terminalStderr = terminalPolicy.isSuccess
            ? stderr
            : [stderr, terminalPolicy.message]
                .compactMap { $0 }
                .joined(separator: "\n")
        let synthesizedEnvelope = try builder.complete(
            exitStatus: Int(terminalPolicy.exitCode),
            stderr: terminalStderr,
            startedAt: startedAt,
            endedAt: endedAt
        )
        let envelope = preservingPipelineOnlySteps(
            in: synthesizedEnvelope,
            from: pipelineEnvelope,
            result: result
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

    private static func classificationDefaultOptions(
        preset: String
    ) -> [String: ParameterValue] {
        let presetParameters = ClassificationConfig.Preset(rawValue: preset)?.parameters
            ?? ClassificationConfig.Preset.balanced.parameters
        return [
            "preset": .string("balanced"),
            "pairedEnd": .boolean(false),
            "recursive": .boolean(false),
            "profile": .boolean(false),
            "confidence": .number(presetParameters.confidence),
            "minimumHitGroups": .integer(presetParameters.minimumHitGroups),
            "threads": .integer(4),
            "memoryMapping": .boolean(false),
            "quickMode": .boolean(false),
            "brackenRankRequest": .string("automatic"),
            "brackenReadLength": .integer(150),
            "brackenThreshold": .integer(10),
            "extraArguments": .array([]),
        ]
    }

    private static func classificationResolvedOptions(
        for config: ClassificationConfig,
        outcome: BrackenProfileOutcome,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        preset: String,
        recursive: Bool
    ) -> [String: ParameterValue] {
        let request = config.brackenProfileRequest
        let resolution = outcome.resolution ?? request.map {
            BrackenDatabaseCapabilities.resolve(
                catalogID: config.databaseCatalogID,
                installationRecipe: config.databaseInstallationRecipe,
                request: $0
            )
        }
        let profileRequested = config.goal == .profile
            || request != nil
            || outcome.state != .notRequested

        var options: [String: ParameterValue] = [
            "databaseName": .string(config.databaseName),
            "databaseVersion": .string(config.databaseVersion.isEmpty ? "unknown" : config.databaseVersion),
            "databaseDigest": config.databaseDigest.map(ParameterValue.string) ?? .null,
            "databaseCatalogID": config.databaseCatalogID.map(ParameterValue.string) ?? .null,
            "databaseInstallationRecipe": config.databaseInstallationRecipe
                .map { .string($0.provenanceValue) } ?? .null,
            "databasePath": .file(config.databasePath),
            "inputFormat": .string(config.inputFormat.rawValue),
            "goal": .string(config.goal.rawValue),
            "preset": .string(preset),
            "pairedEnd": .boolean(config.isPairedEnd),
            "recursive": .boolean(recursive),
            "profile": .boolean(profileRequested),
            "confidence": .number(config.confidence),
            "minimumHitGroups": .integer(config.minimumHitGroups),
            "threads": .integer(config.threads),
            "memoryMapping": .boolean(config.memoryMapping),
            "quickMode": .boolean(config.quickMode),
            "brackenRankRequest": request.map { .string($0.rank.provenanceValue) } ?? .string("notRequested"),
            "brackenRequestedReadLength": request.map { .integer($0.readLength) } ?? .null,
            "brackenRequestedThreshold": request.map { .integer($0.threshold) } ?? .null,
            "brackenResolvedRank": resolution.map { .string($0.rank.code) } ?? .null,
            "brackenResolutionSource": resolution.map { .string($0.source.rawValue) } ?? .null,
            "brackenReadLength": resolution.map { .integer($0.readLength) } ?? .null,
            "brackenThreshold": resolution.map { .integer($0.threshold) } ?? .null,
            "profileState": .string(outcome.state.rawValue),
            "profileReason": outcome.reason.map { .string($0.rawValue) } ?? .null,
            "profileMessage": outcome.message.map(ParameterValue.string) ?? .null,
            "brackenToolVersion": outcome.toolVersion.map(ParameterValue.string) ?? .null,
            "outputDirectory": .file(config.outputDirectory),
            "extraArguments": .array(config.extraArguments.map(ParameterValue.string)),
            "originalInputs": .array(originalInputURLs.map { .file($0.standardizedFileURL) }),
            "executionInputs": .array(executionInputURLs.map { .file($0.standardizedFileURL) }),
        ]
        if let request,
           case .explicit(let rank) = request.rank {
            options["brackenExplicitRank"] = .string(rank.code)
        }
        return options
    }

    private static func classificationExplicitOptions(
        for config: ClassificationConfig,
        originalInputURLs: [URL],
        argv: [String],
        preset: String
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "databaseName": .string(config.databaseName),
            "originalInputs": .array(originalInputURLs.map { .file($0.standardizedFileURL) }),
        ]

        if argvContainsOption(argv, names: ["--output-dir", "-o"]) {
            options["outputDirectory"] = .file(config.outputDirectory)
        }
        if argvContainsOption(argv, names: ["--preset"]) {
            options["preset"] = .string(preset)
        }
        if argvContainsOption(argv, names: ["--paired"]) {
            options["pairedEnd"] = .boolean(config.isPairedEnd)
        }
        if argvContainsOption(argv, names: ["--recursive"]) {
            options["recursive"] = .boolean(true)
        }
        if argvContainsOption(argv, names: ["--profile"]) {
            options["profile"] = .boolean(true)
        }
        if argvContainsOption(argv, names: ["--confidence"]) {
            options["confidence"] = .number(config.confidence)
        }
        if argvContainsOption(argv, names: ["--min-hit-groups"]) {
            options["minimumHitGroups"] = .integer(config.minimumHitGroups)
        }
        if argvContainsOption(argv, names: ["--threads"]) {
            options["threads"] = .integer(config.threads)
        }
        if argvContainsOption(argv, names: ["--memory-mapping"]) {
            options["memoryMapping"] = .boolean(config.memoryMapping)
        }
        if argvContainsOption(argv, names: ["--quick"]) {
            options["quickMode"] = .boolean(config.quickMode)
        }
        if let rawReadLength = argvOptionValue(argv, names: ["--bracken-read-length"]),
           let readLength = Int(rawReadLength) {
            options["brackenReadLength"] = .integer(readLength)
        }
        if let brackenLevel = argvOptionValue(argv, names: ["--bracken-level"]) {
            options["brackenLevel"] = .string(brackenLevel)
            options["brackenRankRequest"] = .string(
                BrackenRankRequest.explicit(TaxonomicRank(code: brackenLevel)).provenanceValue
            )
        }
        if let rawThreshold = argvOptionValue(argv, names: ["--bracken-threshold"]),
           let threshold = Int(rawThreshold) {
            options["brackenThreshold"] = .integer(threshold)
        }
        if argvContainsOption(argv, names: ["--extra-args"]) {
            options["extraArguments"] = .array(config.extraArguments.map(ParameterValue.string))
        }

        return options
    }

    private static func argvContainsOption(_ argv: [String], names: Set<String>) -> Bool {
        argv.contains { argument in
            let name = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? argument
            return names.contains(name)
        }
    }

    private static func argvOptionValue(_ argv: [String], names: Set<String>) -> String? {
        for (index, argument) in argv.enumerated() {
            let components = argument.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let name = String(components[0])
            guard names.contains(name) else {
                continue
            }
            if components.count == 2 {
                return String(components[1])
            }
            guard argv.indices.contains(index + 1) else {
                return nil
            }
            return argv[index + 1]
        }
        return nil
    }

    private static func brackenProvenanceStep(
        result: ClassificationResult,
        pipelineEnvelope: ProvenanceEnvelope?,
        fallbackStartedAt: Date
    ) throws -> ProvenanceStep? {
        guard let brackenURL = result.brackenURL,
              FileManager.default.fileExists(atPath: brackenURL.path) else {
            return nil
        }

        if let pipelineEnvelope,
           isCurrentClassificationPipelineEnvelope(pipelineEnvelope, result: result),
           pipelineEnvelope.steps.contains(where: { step in
               step.toolName == "bracken"
                   && step.exitStatus == 0
                   && step.outputs.contains { $0.path == brackenURL.path }
           }) {
            // `preservingPipelineOnlySteps` will retain and dependency-remap the
            // exact pipeline invocation, including its distribution input,
            // resolved options, runtime identity, resource use, and lineage.
            return nil
        }

        let legacyStep = ProvenanceRecorder.load(from: result.config.outputDirectory)?
            .steps
            .first { $0.toolName == "bracken" }
        let resolution = result.profileOutcome.resolution
            ?? result.config.brackenProfileRequest.map {
                BrackenDatabaseCapabilities.resolve(
                    catalogID: result.config.databaseCatalogID,
                    installationRecipe: result.config.databaseInstallationRecipe,
                    request: $0
                )
            }
        let resolvedReadLength = resolution?.readLength
            ?? BrackenDatabaseCapabilities.supportedReadLength
        let resolvedLevel = resolution
            .flatMap { BrackenDatabaseCapabilities.levelCode(for: $0.rank) }
            ?? "S"
        let resolvedThreshold = resolution?.threshold
            ?? result.config.brackenProfileRequest?.threshold
            ?? 10
        let fallbackArgv = [
            "bracken",
            "-d", result.config.databasePath.path,
            "-i", result.reportURL.path,
            "-o", brackenURL.path,
            "-r", String(resolvedReadLength),
            "-l", resolvedLevel,
            "-t", String(resolvedThreshold),
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

    private static func preservingPipelineOnlySteps(
        in envelope: ProvenanceEnvelope,
        from pipelineEnvelope: ProvenanceEnvelope?,
        result: ClassificationResult
    ) -> ProvenanceEnvelope {
        guard let pipelineEnvelope,
              isCurrentClassificationPipelineEnvelope(pipelineEnvelope, result: result) else {
            return envelope
        }

        let synthesizedToolNames = Set(envelope.steps.map(\.toolName))
        let synthesizedStepByToolName = Dictionary(
            envelope.steps.map { ($0.toolName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let dependencyIDRemap = Dictionary(
            pipelineEnvelope.steps.compactMap { pipelineStep -> (UUID, UUID)? in
                guard let synthesizedStep = synthesizedStepByToolName[pipelineStep.toolName] else {
                    return nil
                }
                return (pipelineStep.id, synthesizedStep.id)
            },
            uniquingKeysWith: { _, final in final }
        )
        let preservedSteps = pipelineEnvelope.steps.compactMap { step -> ProvenanceStep? in
            guard !synthesizedToolNames.contains(step.toolName) else {
                return nil
            }
            let remappedDependencies = step.dependsOn.map { dependencyIDRemap[$0] ?? $0 }
            return replacingDependencies(in: step, with: remappedDependencies)
        }
        guard !preservedSteps.isEmpty else {
            return envelope
        }

        let preservedStepFiles = preservedSteps.flatMap { $0.inputs + $0.outputs }
        let mergedFiles = deduplicatedDescriptors(envelope.files + preservedStepFiles)
        let mergedOutputs = deduplicatedDescriptors(envelope.outputs + preservedSteps.flatMap(\.outputs))

        return ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            durableReplayArgv: envelope.durableReplayArgv,
            reproducibleCommand: envelope.reproducibleCommand,
            options: envelope.options,
            runtimeIdentity: envelope.runtimeIdentity,
            files: mergedFiles,
            output: envelope.output ?? mergedOutputs.first,
            outputs: mergedOutputs,
            steps: envelope.steps + preservedSteps,
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: envelope.signatures,
            legacyWorkflowRun: envelope.legacyRun
        )
    }

    private static func isCurrentClassificationPipelineEnvelope(
        _ envelope: ProvenanceEnvelope,
        result: ClassificationResult
    ) -> Bool {
        let pipelineNames: Set<String> = ["Metagenomics Classification", "Metagenomics Profiling"]
        guard pipelineNames.contains(envelope.workflowName) else {
            return false
        }
        let currentPaths = Set([
            result.reportURL.standardizedFileURL.path,
            result.outputURL.standardizedFileURL.path,
        ])
        let envelopePaths = Set((envelope.files + envelope.outputs).map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        return !currentPaths.isDisjoint(with: envelopePaths)
    }

    private static func deduplicatedDescriptors(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            guard seen.insert(descriptor.path).inserted else {
                continue
            }
            result.append(descriptor)
        }
        return result
    }

    private static func replacingDependencies(
        in step: ProvenanceStep,
        with dependsOn: [UUID]
    ) -> ProvenanceStep {
        ProvenanceStep(
            id: step.id,
            toolName: step.toolName,
            toolVersion: step.toolVersion,
            githubReleaseVersion: step.githubReleaseVersion,
            argv: step.argv,
            durableReplayArgv: step.durableReplayArgv,
            reproducibleCommand: step.reproducibleCommand,
            resolvedOptions: step.resolvedOptions,
            runtimeIdentity: step.runtimeIdentity,
            inputs: step.inputs,
            outputs: step.outputs,
            exitStatus: step.exitStatus,
            wallTimeSeconds: step.wallTimeSeconds,
            peakMemoryBytes: step.peakMemoryBytes,
            stderr: step.stderr,
            dependsOn: dependsOn,
            startedAt: step.startedAt,
            completedAt: step.completedAt
        )
    }

    private static func classificationOutputDescriptors(
        for result: ClassificationResult
    ) throws -> [ProvenanceFileDescriptor] {
        var outputs: [(url: URL, format: FileFormat?, role: FileRole)] = [
            (result.reportURL, .text, .report),
            (result.outputURL, .text, .output),
        ]
        let krakenIndexURL = KrakenIndexDatabase.indexURL(for: result.outputURL)
        if FileManager.default.fileExists(atPath: krakenIndexURL.path) {
            outputs.append((krakenIndexURL, .unknown, .index))
        }
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

    private func requestedBrackenProfile() -> BrackenProfileRequest? {
        guard profile else {
            return nil
        }
        let rankRequest: BrackenRankRequest = brackenLevel
            .map { .explicit(TaxonomicRank(code: $0)) }
            ?? .automatic
        return BrackenProfileRequest(
            rank: rankRequest,
            readLength: brackenReadLength,
            threshold: brackenThreshold
        )
    }

    private func makeConfig(
        inputURLs: [URL],
        databaseInfo: MetagenomicsDatabaseInfo,
        databasePath: URL,
        inputFormat: SequenceFormat,
        outputDirectory: URL,
        threads: Int,
        extraArguments: [String]
    ) -> ClassificationConfig {
        ClassificationConfig.fromPreset(
            preset.toPreset(),
            goal: profile ? .profile : .classify,
            inputFiles: inputURLs,
            isPairedEnd: pairedEnd,
            databaseName: databaseName,
            inputFormat: inputFormat,
            databaseVersion: databaseInfo.version ?? "unknown",
            databasePath: databasePath,
            databaseDigest: databaseInfo.payloadDigest,
            databaseCatalogID: databaseInfo.catalogID,
            databaseInstallationRecipe: databaseInfo.installationRecipe,
            brackenProfileRequest: requestedBrackenProfile(),
            threads: threads,
            memoryMapping: memoryMapping,
            quickMode: quickMode,
            outputDirectory: outputDirectory,
            extraArguments: extraArguments
        )
    }

    private func resolvedBrackenRankDescription(for config: ClassificationConfig) -> String {
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
            throw CLIError.validationFailed(
                errors: ["Database '\(databaseInfo.name)' has no installed path."]
            )
        }
        return makeConfig(
            inputURLs: inputURLs,
            databaseInfo: databaseInfo,
            databasePath: databasePath,
            inputFormat: inputFormat,
            outputDirectory: outputDirectory,
            threads: globalOptions.threads ?? 4,
            extraArguments: try AdvancedCommandLineOptions.parse(extraArgs)
        )
    }

    func makeConfigForTesting(
        inputURLs: [URL],
        databasePath: URL,
        inputFormat: SequenceFormat,
        outputDirectory: URL
    ) throws -> ClassificationConfig {
        ClassificationConfig.fromPreset(
            preset.toPreset(),
            goal: profile ? .profile : .classify,
            inputFiles: inputURLs,
            isPairedEnd: pairedEnd,
            databaseName: databaseName,
            inputFormat: inputFormat,
            databaseVersion: "unknown",
            databasePath: databasePath,
            brackenProfileRequest: requestedBrackenProfile(),
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
