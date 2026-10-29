// AssembleCommand.swift - CLI command for managed de novo assembly
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum AssembleInputResolutionError: LocalizedError {
    case unreadableBundlePayload(String)
    case derivedBundleRequiresMaterialization(String)

    var errorDescription: String? {
        switch self {
        case .unreadableBundlePayload(let path):
            return "Sequence bundle does not contain a readable FASTQ or FASTA payload: \(path)"
        case .derivedBundleRequiresMaterialization(let path):
            return "Derived FASTQ bundle must be materialized before assembly execution: \(path)"
        }
    }
}

enum AssembleReadTypeResolutionError: LocalizedError {
    case unknownReadType(String)

    var errorDescription: String? {
        switch self {
        case .unknownReadType(let value):
            return "Unknown read type: \(value)"
        }
    }
}

struct AssembleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assemble",
        abstract: "Run de novo genome assembly with the managed assembly pack",
        discussion: """
            Assemble sequence reads with a managed assembler from the Genome Assembly pack.
            The CLI uses the same tool/read-type compatibility model as the app.

            Multiple inputs are treated as one sample's reads (--paired binds exactly
            two files as paired-end mates of that sample); invoke once per sample for per-sample results.
            """
    )

    @Argument(help: "Input sequence file(s). Provide two files with --paired for paired-end Illumina reads.")
    var fastqFiles: [String]

    @Option(name: .customLong("assembler"), help: "Assembler to run: spades, megahit, skesa, flye, hifiasm (default: follows the read type, so spades for short reads or no evidence, flye for ONT or other long reads, hifiasm for PacBio HiFi)")
    var assembler: String?

    @Option(name: .customLong("read-type"), help: "Read class: illumina-short-reads, ont-reads, pacbio-hifi")
    var readType: String?

    @Option(name: [.customLong("output"), .customLong("output-dir"), .customShort("o")], help: "Output directory")
    var outputDir: String?

    @Option(name: [.customLong("project-name"), .customLong("name")], help: "Project name for the assembly")
    var projectName: String?

    @Flag(name: .customLong("paired"), help: "Treat the two input sequence files as paired-end mates")
    var pairedEnd: Bool = false

    @Option(
        name: .customLong("read-layout"),
        help: ArgumentHelp(
            "How the records of a single Illumina input file relate: auto, single-end, interleaved (every record is followed by its mate), or mixed (merged reads and interleaved pairs in one file)",
            discussion: "auto reads the enclosing .lungfishfastq bundle's metadata, then scans read names (identical names, /1 /2, and Casava descriptions all count as mates). SPAdes and MEGAHIT assemble a strictly interleaved file with --12 and SKESA with --use_paired_ends. Under auto or mixed, a file that mixes merged reads with pairs is split by fragment name, its pairs are assembled as pairs, and its merged and single reads go in beside them in the same run. A bundle that keeps its mates in separate R1 and R2 files refuses --read-layout."
        )
    )
    var readLayout: AssembleReadLayoutArgument = .auto

    @Option(name: [.customLong("memory-gb"), .customLong("memory")], help: "Memory budget in GB when the selected assembler supports it")
    var memoryGB: Int?

    @Option(name: .customLong("min-contig-length"), help: "Minimum contig length when the selected assembler supports it")
    var minContigLength: Int?

    @Option(name: .customLong("profile"), help: "Curated assembler profile, such as meta-sensitive or nano-hq")
    var profile: String?

    @Option(
        name: .customLong("profile-basis"),
        help: "Why --profile was chosen, recorded in provenance (the app passes its read-quality preselection)"
    )
    var profileBasis: String?

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Additional assembler options, written exactly as they should be passed to the underlying tool"
    )
    var extraArgs: String = ""

    @Option(
        name: .customLong("advanced-options"),
        parsing: .unconditional,
        help: .hidden
    )
    var advancedOptions: String = ""

    @Option(name: .customLong("extra-arg"), parsing: .unconditionalSingleValue, help: "Additional assembler argument (repeatable)")
    var extraArg: [String] = []

    @Flag(name: .customLong("json-events"), help: .hidden)
    var jsonEvents = false

    @Flag(name: .customLong("reference-bundle"), help: "Also publish a .lungfishref bundle of the contigs beside --output, named after the project")
    var referenceBundle = false

    @OptionGroup var timeLimit: TimeLimitOptions
    @OptionGroup var globalOptions: GlobalOptions

    /// Assembles so that SIGTERM cancels the run (decision P2, ``runCancellingOnSIGTERM(pipeline:)``).
    func run() async throws {
        try await timeLimit.scope { try await runCancellingOnSIGTERM(pipeline: ManagedAssemblyPipeline()) }
    }

    /// The body of ``run()`` with the pipeline passed in, so a test can run a stand-in assembler.
    func execute(pipeline: ManagedAssemblyPipeline) async throws {
        let runClock = ProvenanceRunClock()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let reporter = AssembleRunReporter(eventsOn: eventsOn, useColors: globalOptions.useColors)
        warnIfDeprecatedAdvancedOptionsUsed()

        let inputURLs = fastqFiles.map { URL(fileURLWithPath: $0) }
        for inputURL in inputURLs where !FileManager.default.fileExists(atPath: inputURL.path) {
            throw reporter.refusal("Input file not found: \(inputURL.path)", exit: .inputError)
        }
        guard let tool = Self.resolveTool(assembler, readType: readType, inputURLs: inputURLs, quiet: globalOptions.quiet) else {
            throw reporter.refusal("Unknown assembler: \(assembler ?? "")", exit: .inputError)
        }

        reporter.start("Launching \(tool.displayName)")
        let projectName = resolvedProjectName(from: inputURLs)
        let outputDirectory = resolvedOutputDirectory(projectName: projectName)
        let referenceBundleURL = try refusingAnExistingReferenceBundle(outputDirectory: outputDirectory, projectName: projectName, reporter: reporter)

        if pairedEnd && inputURLs.count != 2 {
            throw reporter.refusal("Paired-end assembly requires exactly two sequence inputs.", exit: .inputError)
        }
        if let readLayoutError = Self.validateReadLayoutOption(
            readLayout,
            tool: tool,
            pairedEnd: pairedEnd,
            inputCount: inputURLs.count
        ) {
            throw reporter.refusal(readLayoutError, exit: .inputError)
        }

        let advancedArguments: [String]
        do {
            advancedArguments = try Self.parseExtraArgs(extraArgs, deprecatedAdvancedOptions: advancedOptions) + extraArg
        } catch {
            throw reporter.refusal(error.localizedDescription, exit: .inputError)
        }

        if tool == .spades,
           let rejection = SPAdesCarefulModeCompatibility.rejectionMessage(
                profileID: profile,
                extraArguments: advancedArguments
           ) {
            throw reporter.refusal(rejection, exit: .inputError)
        }

        let explicitReadType: AssemblyReadType?
        do {
            explicitReadType = try Self.parseExplicitReadType(readType)
        } catch {
            throw reporter.refusal(error.localizedDescription, exit: .inputError)
        }

        do {
            try Self.validatePreMaterializationTopology(
                tool: tool,
                inputURLs: inputURLs,
                pairedEnd: pairedEnd
            )
        } catch {
            throw reporter.refusal(error.localizedDescription, exit: .inputError)
        }

        let preMaterialization = Self.preMaterializationReadTypeDecision(
            for: tool,
            explicitReadType: explicitReadType,
            inputURLs: inputURLs
        )

        let readSets: AssemblyResolvedInputs
        let resolvedReadType: AssemblyReadType
        let materializationDirectory = outputDirectory.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true)
        do {
            readSets = try await AssemblyReadSetResolution.resolve(
                inputURLs: inputURLs,
                tool: tool,
                pairedEnd: pairedEnd,
                explicitLayout: readLayout.explicitLayout,
                materializationDirectory: materializationDirectory,
                materializer: FASTQCLIMaterializer(runner: NativeToolRunner.shared),
                progress: { message in
                    if !globalOptions.quiet {
                        reporter.text(formatter.info(message))
                    }
                }
            )
            let decision = try preMaterialization ?? Self.readTypeDecision(
                    for: tool,
                    explicitReadType: readType,
                    originalInputURLs: readSets.inputs.originalInputURLs,
                    executionInputURLs: readSets.inputs.executionInputURLs
                )
            resolvedReadType = decision.readType ?? AssemblyCompatibility.defaultReadType(for: tool)
            for warning in decision.warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
        } catch let exit as ExitCode {
            throw exit
        } catch CLISequenceInputMaterializationError.unreadableSequenceInput(let path) {
            try? FileManager.default.removeItem(at: materializationDirectory)
            throw reporter.refusal(AssembleInputResolutionError.unreadableBundlePayload(path).localizedDescription, exit: .formatError)
        } catch let error as AssemblyReadSetResolutionError {
            try? FileManager.default.removeItem(at: materializationDirectory)
            throw reporter.refusal(error.localizedDescription, exit: .inputError)
        } catch {
            try? FileManager.default.removeItem(at: materializationDirectory)
            if Task.isCancelled { throw CancellationError() }
            throw reporter.refusal(error.localizedDescription, exit: .workflowError)
        }
        // Every read a bundle holds, as `map` hands the mapper: one original
        // per execution file. A bundle that holds the R1 and R2 of a mate pair
        // is assembled as pairs, as `map` and the app's per-bundle launch do,
        // and so is a sample of pairs and single reads (`readSets`, decision 1
        // of 2026-10-03).
        let resolvedInputs = readSets.inputs
        let executionInputURLs = resolvedInputs.executionInputURLs
        let executionOriginalInputURLs = resolvedInputs.originalInputURLs
        if readLayout != .auto, resolvedInputs.resolvedAsMatePair {
            throw reporter.refusal("--read-layout describes one input file; \(inputURLs[0].lastPathComponent) holds R1 and R2 files.", exit: .inputError)
        }

        let resolvedProfile = await Self.resolveProfile(
            tool: tool,
            explicitProfile: profile,
            explicitProfileBasis: profileBasis,
            inputURL: inputURLs.first,
            readType: resolvedReadType
        )

        // The layout of one file is resolved on the materialized input with
        // the ORIGINAL bundle's metadata as hints, the same way `map` does it,
        // so a paired import stored as one interleaved file is assembled as pairs.
        let (request, layoutResolution) = readSets.request(
            tool: tool,
            readType: resolvedReadType,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            explicitLayout: readLayout.explicitLayout,
            threads: globalOptions.effectiveThreads,
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: resolvedProfile.profileID,
            extraArguments: advancedArguments,
            profileSelectionBasis: resolvedProfile.basis
        )
        let executionRequest = request.normalizedForExecution()

        if let warning = Self.readLayoutWarning(for: executionRequest, resolution: layoutResolution) {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }

        reporter.text(formatter.header("Managed Assembly"))
        reporter.text("")
        reporter.text(formatter.keyValueTable([
            ("Assembler", tool.displayName),
            ("Read type", resolvedReadType.displayName),
            ("Inputs", inputURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Paired-end", executionRequest.readPairing.displayName),
            ("Read layout", Self.readLayoutDescription(for: executionRequest, resolution: layoutResolution)),
            ("Layout handling", executionRequest.readLayoutHandling.displayName),
            ("Threads", "\(executionRequest.threads)"),
            ("Memory", memoryGB.map { "\($0) GB" } ?? "default"),
            ("Profile", resolvedProfile.profileID ?? "default"),
            ("Profile basis", resolvedProfile.basis ?? (profile == nil ? "tool default" : "explicit --profile")),
            ("Extra arguments", advancedArguments.isEmpty ? "none" : AdvancedCommandLineOptions.join(advancedArguments)),
            ("Output", outputDirectory.path),
        ]))
        reporter.text("")

        let showHumanOutput = !eventsOn && !globalOptions.quiet
        let result: AssemblyResult
        do {
            result = try await pipeline.run(
                request: executionRequest,
                onOutput: { line in
                    reporter.log(.info, line)
                    if showHumanOutput { FileHandle.standardError.write(Data((line + "\n").utf8)) }
                },
                progress: { _, message in
                    reporter.progress(0, message)
                    if showHumanOutput { FileHandle.standardError.write(Data((message + "\n").utf8)) }
                }
            )
        } catch {
            // An assembler stopped by the cancel can fail on its own, so the cancel decides.
            if Task.isCancelled { throw CancellationError() }
            throw reporter.refusal(error.localizedDescription, exit: .workflowError)
        }
        let bundle = try await publishReferenceBundle(
            at: referenceBundleURL, result: result, request: executionRequest, requestedInputURLs: inputURLs,
            readSets: readSets, projectName: projectName, reporter: reporter, showHumanOutput: showHumanOutput
        )
        do {
            _ = try Self.writeProvenance(
                request: executionRequest,
                result: result,
                originalInputURLs: executionOriginalInputURLs,
                executionInputURLs: executionInputURLs,
                argv: Self.recordedCommandLine(CommandLine.arguments, fallback: canonicalArguments()),
                startedAt: runClock.startedAt,
                endedAt: runClock.now,
                materializationStartedAt: resolvedInputs.materializationStartedAt,
                materializationEndedAt: resolvedInputs.materializationEndedAt,
                layoutResolution: layoutResolution,
                readSets: readSets,
                referenceBundle: bundle
            )
        } catch {
            if let bundle { try? FileManager.default.removeItem(at: bundle.url) }
            reporter.failed(error.localizedDescription)
            throw error
        }
        if result.outcome == .completedWithNoContigs {
            reporter.log(.warning, "Assembly completed, but no contigs were generated.")
        }
        reporter.complete(outputs: [result.outputDirectory.path] + [bundle?.url.path].compactMap { $0 }, message: "Assembly completed")

        if !globalOptions.quiet {
            reporter.text("")
            reporter.text("")
        }

        reporter.text(formatter.header("Assembly Results"))
        reporter.text("")
        if result.outcome == .completed {
            let stats = result.statistics
            reporter.text(formatter.keyValueTable([
                ("Contigs", "\(stats.contigCount)"),
                ("Total length", "\(stats.totalLengthBP) bp"),
                ("N50", "\(stats.n50) bp"),
                ("Largest contig", "\(stats.largestContigBP) bp"),
                ("GC content", String(format: "%.1f%%", stats.gcPercent)),
            ]))
            reporter.text("")
        }
        reporter.text("Contigs: \(formatter.path(result.contigsPath.path))")
        if let graphPath = result.graphPath {
            reporter.text("Graph:   \(formatter.path(graphPath.path))")
        }
        if let logPath = result.logPath {
            reporter.text("Log:     \(formatter.path(logPath.path))")
        }
        reporter.text("")
        if result.outcome == .completedWithNoContigs {
            reporter.text(formatter.success("Assembly completed, but no contigs were generated."))
        } else {
            reporter.text(formatter.success("Assembly completed in \(String(format: "%.1f", result.wallTimeSeconds))s"))
        }
    }

    /// The profile the run uses and, when the CLI chose it, why.
    ///
    /// An explicit `--profile` always wins; it carries the basis only when
    /// `--profile-basis` gives one (the app passes the read-quality
    /// preselection its sheet made, so a window run records it too). Without one,
    /// Flye takes the same read-quality preselection the app's sheet makes
    /// (Nano Raw under Q10, Nano HQ otherwise), measured on the ORIGINAL
    /// input so an imported bundle's persisted statistics are used before
    /// any reads are sampled. Other assemblers keep their pipeline defaults.
    static func resolveProfile(
        tool: AssemblyTool,
        explicitProfile: String?,
        explicitProfileBasis: String? = nil,
        inputURL: URL?,
        readType: AssemblyReadType? = nil
    ) async -> (profileID: String?, basis: String?) {
        if let explicitProfile {
            let basis = explicitProfileBasis?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (explicitProfile, basis?.isEmpty == false ? basis : nil)
        }
        guard tool == .flye, let inputURL else {
            return (nil, nil)
        }
        let selection = await FlyeProfileSelector.select(forInputURL: inputURL, readType: readType)
        return (selection.profileID, selection.provenanceBasis(appliedProfileID: nil))
    }

    static func parseExtraArgs(_ extraArgs: String, deprecatedAdvancedOptions: String) throws -> [String] {
        try AdvancedCommandLineOptions.parse(extraArgs) + AdvancedCommandLineOptions.parse(deprecatedAdvancedOptions)
    }

    private func warnIfDeprecatedAdvancedOptionsUsed() {
        guard !advancedOptions.isEmpty else { return }
        FileHandle.standardError.write(Data("warning: --advanced-options is deprecated, use --extra-args\n".utf8))
    }

    static func parseExplicitReadType(_ readType: String?) throws -> AssemblyReadType? {
        guard let readType else { return nil }
        guard let parsedReadType = AssemblyReadType(cliArgument: readType) else {
            throw AssembleReadTypeResolutionError.unknownReadType(readType)
        }
        return parsedReadType
    }

    static func detectPreMaterializationReadType(from inputURL: URL) -> AssemblyReadType? {
        let standardizedURL = inputURL.standardizedFileURL
        if let bundleURL = AssemblyInputMaterialization.bundleRequiringMaterialization(for: standardizedURL),
           let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            let rootBundleURL = FASTQBundle.resolveBundle(
                relativePath: manifest.rootBundleRelativePath,
                from: bundleURL
            )
            let rootPayloadURL = rootBundleURL
                .appendingPathComponent(manifest.rootFASTQFilename)
                .standardizedFileURL
            return AssemblyReadType.detect(fromInputURL: rootPayloadURL)
        }

        return AssemblyReadType.detect(fromInputURL: standardizedURL)
    }

    static func validatePreMaterializationTopology(
        tool: AssemblyTool,
        inputURLs: [URL],
        pairedEnd: Bool
    ) throws {
        for inputURL in inputURLs {
            if let unsupportedMessage = AssemblyInputMaterialization.unsupportedAssemblyInputMessage(for: inputURL) {
                throw ManagedAssemblyPipelineError.unsupportedInputTopology(unsupportedMessage)
            }
        }

        if pairedEnd && inputURLs.count != 2 {
            throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                "Paired-end assembly requests must include exactly two sequence inputs."
            )
        }

        switch tool {
        case .flye:
            guard !pairedEnd, AssemblyInputSamples.sampleURLs(inputURLs).count == 1 else {
                throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                    "Flye expects a single ONT sequence input in v1."
                )
            }
        case .hifiasm:
            guard !pairedEnd, AssemblyInputSamples.sampleURLs(inputURLs).count == 1 else {
                throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                    "Hifiasm expects a single ONT or PacBio HiFi/CCS sequence input in v1."
                )
            }
        case .spades, .megahit, .skesa:
            break
        }
    }

    private func resolvedProjectName(from inputURLs: [URL]) -> String {
        if let projectName, !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return projectName
        }

        guard let firstURL = inputURLs.first else {
            return "assembly"
        }

        var detectURL = firstURL
        if detectURL.pathExtension.lowercased() == "gz" {
            detectURL = detectURL.deletingPathExtension()
        }

        return detectURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_R1", with: "")
            .replacingOccurrences(of: "_R2", with: "")
            .replacingOccurrences(of: "_1", with: "")
            .replacingOccurrences(of: "_2", with: "")
    }

    private func resolvedOutputDirectory(projectName: String) -> URL {
        if let outputDir {
            return URL(fileURLWithPath: outputDir)
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("assembly-\(projectName)")
    }

    /// One primary file per input, for inputs that need no materialization (a
    /// test seam). `run` reads every file (`AssemblyReadSetResolution.resolve`).
    static func resolveExecutionInputURLs(for inputURLs: [URL]) throws -> [URL] {
        try inputURLs.map { inputURL in
            if AssemblyInputMaterialization.requiresMaterialization(inputURL) {
                throw AssembleInputResolutionError.derivedBundleRequiresMaterialization(inputURL.standardizedFileURL.path)
            }
            guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) else {
                throw AssembleInputResolutionError.unreadableBundlePayload(inputURL.standardizedFileURL.path)
            }
            return resolvedURL.standardizedFileURL
        }
    }

    /// `originalInputURLs[i]` is the input `executionInputURLs[i]` came from
    /// (one per execution file). The explicit `originalInputs` lists each once.
    @discardableResult
    static func writeProvenance(
        request: AssemblyRunRequest,
        result: AssemblyResult,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        argv: [String],
        startedAt: Date,
        endedAt: Date,
        materializationStartedAt: Date? = nil,
        materializationEndedAt: Date? = nil,
        stderr: String? = nil,
        layoutResolution: FASTQInputLayoutResolution? = nil,
        readSets: AssemblyResolvedInputs? = nil,
        referenceBundle: PublishedReferenceBundle? = nil,
        writer: ProvenanceWriter = ProvenanceWriter()
    ) throws -> URL {
        let toolVersion = result.assemblerVersion ?? "unknown"
        // A sample of pairs and single reads records the plan, once, in the
        // resolved options (E13), and the split steps that wrote its files
        // (decision 1 of 2026-10-03).
        let readSetOptions = readSets?.provenanceParameters ?? [:]
        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish.assemble",
            workflowVersion: LungfishCLI.configuration.version,
            toolName: request.tool.rawValue,
            toolVersion: toolVersion
        )
        .argv(argv)
        .options(
            explicit: assemblyExplicitOptions(
                for: request,
                originalInputURLs: originalInputURLs,
                executionInputURLs: executionInputURLs,
                layoutResolution: layoutResolution
            ),
            defaults: assemblyDefaultOptions(),
            resolved: assemblyResolvedOptions(
                for: request,
                originalInputURLs: originalInputURLs,
                executionInputURLs: executionInputURLs,
                layoutResolution: layoutResolution
            ).merging(readSetOptions) { _, plan in plan }
        )
        .runtime(
            ProvenanceRuntimeIdentity(
                appVersion: LungfishCLI.configuration.version,
                condaEnvironment: request.tool.environmentName
            )
        )

        let inputPairs = CLISequenceInputMaterialization.originalAndExecutionInputs(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        )
        let executionDescriptors = try inputPairs.map { originalURL, executionURL in
            try AssemblyInputMaterialization.executionInputDescriptor(
                originalURL: originalURL,
                executionURL: executionURL
            )
        }
        // The read-set steps record how a virtual bundle was materialized and split.
        let materializedPairs = (readSets?.inputRoles == nil ? inputPairs : []).filter { originalURL, executionURL in
            AssemblyInputMaterialization.requiresMaterialization(originalURL)
                && originalURL.standardizedFileURL != executionURL.standardizedFileURL
        }
        let materializedExecutionDescriptors = try materializedPairs.map { originalURL, executionURL in
            try AssemblyInputMaterialization.executionInputDescriptor(
                originalURL: originalURL,
                executionURL: executionURL
            )
        }
        let materializationInputDescriptors = try materializedPairs.flatMap { originalURL, _ in
            try AssemblyInputMaterialization.originalInputDescriptors(for: originalURL)
        }
        let outputDescriptors = try provenanceOutputDescriptors(for: result)

        if !materializedExecutionDescriptors.isEmpty {
            let stepStartedAt = materializationStartedAt ?? startedAt
            let stepCompletedAt = materializationEndedAt ?? stepStartedAt
            let materializationCommands = materializedPairs.map { originalURL, executionURL in
                CLISequenceInputMaterialization.materializationCommand(
                    originalURL: originalURL,
                    executionURL: executionURL
                )
            }
            let materializationArgv = materializationCommands.count == 1
                ? materializationCommands[0]
                : [
                    "/bin/sh",
                    "-lc",
                    materializationCommands
                        .map { $0.map(shellEscape).joined(separator: " ") }
                        .joined(separator: " && "),
                ]
            builder = builder.step(
                ProvenanceStep(
                    toolName: CLISequenceInputMaterialization.materializationToolName,
                    toolVersion: LungfishCLI.configuration.version,
                    argv: materializationArgv,
                    durableReplayArgv: materializationArgv,
                    reproducibleCommand: materializationArgv.map(shellEscape).joined(separator: " "),
                    inputs: materializationInputDescriptors,
                    outputs: materializedExecutionDescriptors,
                    exitStatus: 0,
                    wallTimeSeconds: stepCompletedAt.timeIntervalSince(stepStartedAt),
                    startedAt: stepStartedAt,
                    completedAt: stepCompletedAt
                )
            )
        }
        // Each concatenation of a bundle's files is a `cat` step, as `map` records it.
        let concatenatedPairs = inputPairs.filter {
            CLISequenceInputMaterialization.concatenation(forExecutionURL: $0.executionURL) != nil
        }
        for step in try CLISequenceInputMaterialization.materializationProvenanceSteps(
            workflowVersion: LungfishCLI.configuration.version,
            originalInputURLs: concatenatedPairs.map(\.originalURL),
            executionInputURLs: concatenatedPairs.map(\.executionURL),
            startedAt: materializationStartedAt ?? startedAt,
            endedAt: materializationEndedAt ?? materializationStartedAt ?? startedAt
        ) {
            builder = builder.step(step)
        }
        for step in try readSets?.provenanceSteps(workflowVersion: LungfishCLI.configuration.version) ?? [] {
            builder = builder.step(step)
        }

        builder = builder.step(
            ProvenanceStep(
                toolName: request.tool.rawValue,
                toolVersion: toolVersion,
                reproducibleCommand: result.commandLine,
                inputs: executionDescriptors,
                outputs: outputDescriptors,
                exitStatus: 0,
                wallTimeSeconds: result.wallTimeSeconds,
                stderr: stderr,
                startedAt: startedAt,
                completedAt: endedAt
            )
        )
        if let referenceBundle {
            builder = builder.step(try referenceBundle.wrappingStep(inputs: outputDescriptors))
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            stderr: stderr,
            startedAt: startedAt,
            endedAt: endedAt
        )
        return try writer.write(envelope, to: request.outputDirectory)
    }

    private static func assemblyDefaultOptions() -> [String: ParameterValue] {
        [
            "assembler": .string("spades"),
            "readType": .null,
            "projectName": .null,
            "pairedEnd": .boolean(false),
            "readPairing": .string(AssemblyReadPairing.single.rawValue),
            "readLayout": .string("auto"),
            "threads": .null,
            "memoryGB": .null,
            "minContigLength": .null,
            "profile": .string("default"),
            "profileBasis": .null,
            "extraArguments": .array([]),
        ]
    }

    private static func assemblyExplicitOptions(
        for request: AssemblyRunRequest,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        layoutResolution: FASTQInputLayoutResolution?
    ) -> [String: ParameterValue] {
        var options = assemblyResolvedOptions(
            for: request,
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs,
            layoutResolution: layoutResolution
        )
        let givenInputURLs = originalInputURLs.reduce(into: [URL]()) { if !$0.contains($1) { $0.append($1) } }
        options["originalInputs"] = .array(givenInputURLs.map { .file($0.standardizedFileURL) })
        return options
    }

    /// `pairedEnd` says whether MATES REACHED THE ASSEMBLER AS PAIRS, for
    /// R1/R2 files and for one interleaved file alike; `readPairing` says
    /// which form they took and `readLayout*` how the layout was decided.
    private static func assemblyResolvedOptions(
        for request: AssemblyRunRequest,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        layoutResolution: FASTQInputLayoutResolution?
    ) -> [String: ParameterValue] {
        AnalysisTimeLimit.recording([
            "assembler": .string(request.tool.rawValue),
            "readType": .string(request.readType.cliArgument),
            "projectName": .string(request.projectName),
            "outputDirectory": .file(request.outputDirectory),
            "pairedEnd": .boolean(request.readPairing.assemblesPairs),
            "readPairing": .string(request.readPairing.rawValue),
            "readLayout": .string(request.effectiveInputLayout.rawValue),
            "readLayoutSource": layoutResolution.map { .string($0.source.rawValue) } ?? .null,
            "readLayoutReason": layoutResolution.map { .string($0.reason) } ?? .null,
            "readLayoutHandling": .string(request.readLayoutHandling.rawValue),
            "threads": .integer(request.threads),
            "memoryGB": request.memoryGB.map(ParameterValue.integer) ?? .null,
            "minContigLength": request.effectiveMinContigLength.map(ParameterValue.integer) ?? .null,
            "profile": request.selectedProfileID.map(ParameterValue.string) ?? .string("default"),
            "profileBasis": request.profileSelectionBasis.map(ParameterValue.string) ?? .null,
            "extraArguments": .array(request.extraArguments.map(ParameterValue.string)),
            "originalInputs": .array(originalInputURLs.map { .file($0.standardizedFileURL) }),
            "executionInputs": .array(executionInputURLs.map { .file($0.standardizedFileURL) }),
        ])
    }

    private static func provenanceOutputDescriptors(
        for result: AssemblyResult
    ) throws -> [ProvenanceFileDescriptor] {
        var outputs: [(url: URL, format: FileFormat?, role: FileRole)] = [
            (result.contigsPath, .fasta, .output),
            (result.outputDirectory.appendingPathComponent("assembly-result.json"), .json, .report),
        ]
        if let logPath = result.logPath {
            outputs.append((logPath, .text, .log))
        }
        if let graphPath = result.graphPath {
            outputs.append((graphPath, provenanceFormat(for: graphPath), .output))
        }
        if let scaffoldsPath = result.scaffoldsPath {
            outputs.append((scaffoldsPath, .fasta, .output))
        }
        if let paramsPath = result.paramsPath {
            outputs.append((paramsPath, .text, .report))
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

    private static func provenanceFormat(for url: URL) -> FileFormat? {
        if let sequenceFormat = SequenceFormat.from(url: url) {
            switch sequenceFormat {
            case .fasta:
                return .fasta
            case .fastq:
                return .fastq
            }
        }

        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "json":
            return .json
        case "log", "txt", "tsv":
            return .text
        case "fa", "fasta", "fna":
            return .fasta
        case "fq", "fastq":
            return .fastq
        default:
            return .unknown
        }
    }
}
