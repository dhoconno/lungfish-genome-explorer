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
    case mixedDetectedAndUnknown
    case unsupportedDetectedCombination(String)

    var errorDescription: String? {
        switch self {
        case .unknownReadType(let value):
            return "Unknown read type: \(value)"
        case .mixedDetectedAndUnknown:
            return "Selected FASTQ inputs mix detected and unclassified read classes. Select one read class per run."
        case .unsupportedDetectedCombination(let message):
            return message
        }
    }
}

/// The materializer `assemble` hands the shared resolver, which runs it from a `@Sendable` closure.
protocol AssemblyInputMaterializing: CLISequenceInputMaterializing, Sendable {}

extension FASTQCLIMaterializer: AssemblyInputMaterializing {}

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

    @Option(name: .customLong("assembler"), help: "Assembler to run: spades, megahit, skesa, flye, hifiasm")
    var assembler: String = "spades"

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
            "How the records of a single Illumina input file relate: auto, single-end, interleaved (every record is followed by its mate), or mixed (merged reads and interleaved pairs in one file) (default: auto)",
            discussion: "auto reads the enclosing .lungfishfastq bundle's metadata, then scans read names (identical names, /1 /2, and Casava descriptions all count as mates). SPAdes and MEGAHIT assemble a strictly interleaved file with --12 and SKESA with --use_paired_ends; a mixed file is assembled as single reads because those flags pair records by position."
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

    @Flag(name: .customLong("json-events"), help: "Stream newline-delimited status and log events to stderr")
    var jsonEvents = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let startedAt = Date()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        warnIfDeprecatedAdvancedOptionsUsed()

        guard let tool = AssemblyTool(rawValue: assembler.lowercased()) else {
            print(formatter.error("Unknown assembler: \(assembler)"))
            throw CLIExitCode.inputError.exitCode
        }

        let inputURLs = fastqFiles.map { URL(fileURLWithPath: $0) }
        for inputURL in inputURLs where !FileManager.default.fileExists(atPath: inputURL.path) {
            print(formatter.error("Input file not found: \(inputURL.path)"))
            throw CLIExitCode.inputError.exitCode
        }

        let projectName = resolvedProjectName(from: inputURLs)
        let outputDirectory = resolvedOutputDirectory(projectName: projectName)

        if pairedEnd && inputURLs.count != 2 {
            print(formatter.error("Paired-end assembly requires exactly two sequence inputs."))
            throw CLIExitCode.inputError.exitCode
        }
        if let readLayoutError = Self.validateReadLayoutOption(
            readLayout,
            tool: tool,
            pairedEnd: pairedEnd,
            inputCount: inputURLs.count
        ) {
            print(formatter.error(readLayoutError))
            throw CLIExitCode.inputError.exitCode
        }

        let advancedArguments: [String]
        do {
            advancedArguments = try Self.parseExtraArgs(extraArgs, deprecatedAdvancedOptions: advancedOptions) + extraArg
        } catch {
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.inputError.exitCode
        }

        if tool == .spades,
           let rejection = SPAdesCarefulModeCompatibility.rejectionMessage(
                profileID: profile,
                extraArguments: advancedArguments
           ) {
            print(formatter.error(rejection))
            throw CLIExitCode.inputError.exitCode
        }

        let explicitReadType: AssemblyReadType?
        do {
            explicitReadType = try Self.parseExplicitReadType(readType)
        } catch {
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.inputError.exitCode
        }

        if let explicitReadType,
           !AssemblyCompatibility.isSupported(tool: tool, for: explicitReadType) {
            print(formatter.error("\(tool.displayName) is not available for \(explicitReadType.displayName) in v1."))
            throw CLIExitCode.inputError.exitCode
        }

        do {
            try Self.validatePreMaterializationTopology(
                tool: tool,
                inputURLs: inputURLs,
                pairedEnd: pairedEnd
            )
        } catch {
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.inputError.exitCode
        }

        let preMaterializationReadType: AssemblyReadType?
        do {
            preMaterializationReadType = try Self.resolvePreMaterializationReadType(
                for: tool,
                explicitReadType: explicitReadType,
                inputURLs: inputURLs
            )
        } catch {
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.inputError.exitCode
        }

        if let preMaterializationReadType,
           !AssemblyCompatibility.isSupported(tool: tool, for: preMaterializationReadType) {
            print(formatter.error("\(tool.displayName) is not available for \(preMaterializationReadType.displayName) in v1."))
            throw CLIExitCode.inputError.exitCode
        }

        let resolvedInputs: ResolvedSequenceInputs
        let resolvedReadType: AssemblyReadType
        let materializationDirectory = outputDirectory.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true)
        do {
            resolvedInputs = try await ResolvedSequenceInputs.resolveForAssembly(
                inputURLs: inputURLs,
                materializationDirectory: materializationDirectory,
                materializer: FASTQCLIMaterializer(runner: NativeToolRunner.shared),
                progress: { message in
                    if !globalOptions.quiet {
                        print(formatter.info(message))
                    }
                }
            )
            resolvedReadType = try preMaterializationReadType ?? Self.resolveReadType(
                    for: tool,
                    explicitReadType: readType,
                    originalInputURLs: resolvedInputs.originalInputURLs,
                    executionInputURLs: resolvedInputs.executionInputURLs
                )
            guard AssemblyCompatibility.isSupported(tool: tool, for: resolvedReadType) else {
                print(formatter.error("\(tool.displayName) is not available for \(resolvedReadType.displayName) in v1."))
                try? FileManager.default.removeItem(at: materializationDirectory)
                throw CLIExitCode.inputError.exitCode
            }
        } catch let exit as ExitCode {
            throw exit
        } catch CLISequenceInputMaterializationError.unreadableSequenceInput(let path) {
            try? FileManager.default.removeItem(at: materializationDirectory)
            print(formatter.error(AssembleInputResolutionError.unreadableBundlePayload(path).localizedDescription))
            throw CLIExitCode.formatError.exitCode
        } catch {
            try? FileManager.default.removeItem(at: materializationDirectory)
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.workflowError.exitCode
        }
        // Every read a bundle holds, as `map` hands the mapper: one original
        // per execution file, and a bundle that holds the R1 and R2 of a mate
        // pair is assembled as pairs, as `map` and the app's per-bundle launch do.
        let executionInputURLs = resolvedInputs.executionInputURLs
        let executionOriginalInputURLs = resolvedInputs.originalInputURLs
        let effectivePairedEnd = pairedEnd || resolvedInputs.resolvedAsMatePair
        if readLayout != .auto, resolvedInputs.resolvedAsMatePair {
            print(formatter.error("--read-layout describes one input file; \(inputURLs[0].lastPathComponent) holds R1 and R2 files."))
            throw CLIExitCode.inputError.exitCode
        }

        let resolvedProfile = await Self.resolveProfile(
            tool: tool,
            explicitProfile: profile,
            explicitProfileBasis: profileBasis,
            inputURL: inputURLs.first
        )

        // Resolved on the materialized input with the ORIGINAL bundle's
        // metadata as hints, the same way `map` does it, so a paired import
        // stored as one interleaved file is assembled as pairs.
        let layoutResolution = AssemblyRunRequest.resolveInputLayout(
            tool: tool,
            readType: resolvedReadType,
            pairedEnd: effectivePairedEnd,
            explicit: readLayout.explicitLayout,
            originalInputURLs: executionOriginalInputURLs,
            executionInputURLs: executionInputURLs,
            pooled: resolvedInputs.pooledLayoutResolution
        )

        let request = AssemblyRunRequest(
            tool: tool,
            readType: resolvedReadType,
            inputURLs: executionInputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: effectivePairedEnd,
            threads: globalOptions.effectiveThreads,
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: resolvedProfile.profileID,
            extraArguments: advancedArguments,
            profileSelectionBasis: resolvedProfile.basis,
            inputLayout: layoutResolution?.layout
        )
        let executionRequest = request.normalizedForExecution()

        if let warning = Self.readLayoutWarning(for: executionRequest, resolution: layoutResolution) {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }

        print(formatter.header("Managed Assembly"))
        print("")
        print(formatter.keyValueTable([
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
        print("")

        // Use the same newline-delimited event contract as the other workflows.
        // stderr remains live even when stdout is block-buffered by a GUI pipe.
        let events = CLIEventEmitter(enabled: jsonEvents) { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        events.emitStart("Launching \(tool.displayName)")
        let showHumanOutput = !jsonEvents && !globalOptions.quiet
        let result: AssemblyResult
        do {
            result = try await ManagedAssemblyPipeline().run(
                request: executionRequest,
                onOutput: { line in
                    events.emitLog(.info, line)
                    if showHumanOutput { FileHandle.standardError.write(Data((line + "\n").utf8)) }
                },
                progress: { _, message in
                    events.emitProgress(0, message: message)
                    if showHumanOutput { FileHandle.standardError.write(Data((message + "\n").utf8)) }
                }
            )
        } catch {
            events.emitFailed(error.localizedDescription)
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.workflowError.exitCode
        }
        do {
            _ = try Self.writeProvenance(
                request: executionRequest,
                result: result,
                originalInputURLs: executionOriginalInputURLs,
                executionInputURLs: executionInputURLs,
                argv: CommandLine.arguments,
                startedAt: startedAt,
                endedAt: Date(),
                materializationStartedAt: resolvedInputs.materializationStartedAt,
                materializationEndedAt: resolvedInputs.materializationEndedAt,
                layoutResolution: layoutResolution
            )
        } catch {
            events.emitFailed(error.localizedDescription)
            throw error
        }
        if result.outcome == .completedWithNoContigs {
            events.emitLog(.warning, "Assembly completed, but no contigs were generated.")
        }
        events.emitComplete(outputs: [result.outputDirectory.path], message: "Assembly completed")

        if !globalOptions.quiet {
            print("")
            print("")
        }

        print(formatter.header("Assembly Results"))
        print("")
        if result.outcome == .completed {
            let stats = result.statistics
            print(formatter.keyValueTable([
                ("Contigs", "\(stats.contigCount)"),
                ("Total length", "\(stats.totalLengthBP) bp"),
                ("N50", "\(stats.n50) bp"),
                ("Largest contig", "\(stats.largestContigBP) bp"),
                ("GC content", String(format: "%.1f%%", stats.gcPercent)),
            ]))
            print("")
        }
        print("Contigs: \(formatter.path(result.contigsPath.path))")
        if let graphPath = result.graphPath {
            print("Graph:   \(formatter.path(graphPath.path))")
        }
        if let logPath = result.logPath {
            print("Log:     \(formatter.path(logPath.path))")
        }
        print("")
        if result.outcome == .completedWithNoContigs {
            print(formatter.success("Assembly completed, but no contigs were generated."))
        } else {
            print(formatter.success("Assembly completed in \(String(format: "%.1f", result.wallTimeSeconds))s"))
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
        inputURL: URL?
    ) async -> (profileID: String?, basis: String?) {
        if let explicitProfile {
            let basis = explicitProfileBasis?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (explicitProfile, basis?.isEmpty == false ? basis : nil)
        }
        guard tool == .flye, let inputURL else {
            return (nil, nil)
        }
        let selection = await FlyeProfileSelector.select(forInputURL: inputURL)
        return (selection.profileID, selection.provenanceBasis(appliedProfileID: nil))
    }

    static func parseExtraArgs(_ extraArgs: String, deprecatedAdvancedOptions: String) throws -> [String] {
        try AdvancedCommandLineOptions.parse(extraArgs) + AdvancedCommandLineOptions.parse(deprecatedAdvancedOptions)
    }

    /// The `--read-layout` values, mirroring `FASTQInputLayout` for one file
    /// (the same spellings `map --read-layout` accepts).
    enum AssembleReadLayoutArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
        case auto
        case singleEnd = "single-end"
        case interleaved
        case mixed

        /// The layout the caller stated, or `nil` for auto detection.
        var explicitLayout: FASTQInputLayout? {
            switch self {
            case .auto: return nil
            case .singleEnd: return .singleEnd
            case .interleaved: return .strictlyInterleaved
            case .mixed: return .mixedMergedAndPairs
            }
        }
    }

    /// Why an explicit `--read-layout` cannot apply, or `nil` when it can.
    static func validateReadLayoutOption(
        _ readLayout: AssembleReadLayoutArgument,
        tool: AssemblyTool,
        pairedEnd: Bool,
        inputCount: Int
    ) -> String? {
        guard readLayout != .auto else { return nil }
        if pairedEnd || inputCount != 1 {
            return "--read-layout describes one input file; use --paired for two R1/R2 files."
        }
        if !Self.shortReadTools.contains(tool), readLayout != .singleEnd {
            return "--read-layout \(readLayout.rawValue) applies to the short-read assemblers (spades, megahit, skesa); \(tool.displayName) assembles every record as a single read."
        }
        return nil
    }

    private static let shortReadTools: Set<AssemblyTool> = [.spades, .megahit, .skesa]

    /// Resolves the layout of a single short-read input, or `nil` when the
    /// run has nothing to resolve (two `--paired` files, a long-read
    /// assembler, or pooled inputs, whose records are single by contract).
    ///
    /// A materialized scratch copy of a derived bundle carries no sidecar,
    /// so the ORIGINAL input supplies the bundle metadata as hints (a VSP2
    /// merge recipe in the lineage demotes strict to mixed). A concatenation
    /// of a bundle's files keeps their `pooled` single-read layout, as `map`.
    static func resolveInputLayout(
        tool: AssemblyTool,
        readType: AssemblyReadType,
        pairedEnd: Bool,
        explicit: FASTQInputLayout?,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        pooled: FASTQInputLayoutResolution? = nil
    ) -> FASTQInputLayoutResolution? {
        guard Self.shortReadTools.contains(tool),
              readType == .illuminaShortReads,
              !pairedEnd,
              executionInputURLs.count == 1,
              let executionURL = executionInputURLs.first else {
            return nil
        }
        if let explicit {
            return FASTQInputLayoutResolver.resolve(inputURLs: [executionURL], explicit: explicit)
        }
        if let pooled { return pooled }
        let originalURL = originalInputURLs.first?.standardizedFileURL
        let hintURL = originalURL == executionURL.standardizedFileURL ? nil : originalURL
        return FASTQInputLayoutResolver.resolve(fastqURL: executionURL, metadataFrom: hintURL)
    }

    /// The `Read layout` table row: the layout and where the answer came from.
    static func readLayoutDescription(
        for request: AssemblyRunRequest,
        resolution: FASTQInputLayoutResolution?
    ) -> String {
        guard let resolution else {
            return request.effectiveInputLayout.displayName
        }
        return "\(resolution.layout.displayName) (\(resolution.source.rawValue))"
    }

    /// A warning when the records hold mates the assembler will not pair.
    static func readLayoutWarning(
        for request: AssemblyRunRequest,
        resolution: FASTQInputLayoutResolution?
    ) -> String? {
        guard let resolution, resolution.layout == .mixedMergedAndPairs,
              request.readLayoutHandling == .asSingle,
              let inputURL = request.inputURLs.first else {
            return nil
        }
        return "\(inputURL.lastPathComponent) holds merged reads and pairs (\(resolution.reason)) "
            + "Every record is assembled as a single read so that mates are not paired by position."
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

    static func resolvePreMaterializationReadType(
        for tool: AssemblyTool,
        explicitReadType: AssemblyReadType?,
        inputURLs: [URL]
    ) throws -> AssemblyReadType? {
        if let explicitReadType {
            return explicitReadType
        }
        let inputDetections = inputURLs.map(detectPreMaterializationReadType)
        return try evaluateReadTypeDetections(inputDetections, defaultTool: nil)
    }

    static func resolveReadType(
        for tool: AssemblyTool,
        explicitReadType: String?,
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) throws -> AssemblyReadType {
        if let parsedReadType = try parseExplicitReadType(explicitReadType) {
            return parsedReadType
        }

        let inputDetections = CLISequenceInputMaterialization.originalAndExecutionInputs(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        ).map { originalURL, executionURL in
            AssemblyReadType.detect(fromFASTQ: executionURL)
                ?? AssemblyReadType.detect(fromInputURL: originalURL)
        }
        guard let resolvedReadType = try evaluateReadTypeDetections(inputDetections, defaultTool: tool) else {
            preconditionFailure("Read type resolution with a default tool must return a read type")
        }
        return resolvedReadType
    }

    private static func evaluateReadTypeDetections(
        _ inputDetections: [AssemblyReadType?],
        defaultTool tool: AssemblyTool?
    ) throws -> AssemblyReadType? {
        let detectedReadTypes = orderedUniqueReadTypes(inputDetections)
        let evaluation = AssemblyCompatibility.evaluate(detectedReadTypes: detectedReadTypes)
        let knownInputCount = inputDetections.compactMap { $0 }.count
        let hasKnownAndUnknownMix = knownInputCount > 0 && knownInputCount < inputDetections.count

        if let blockingMessage = evaluation.blockingMessage {
            throw AssembleReadTypeResolutionError.unsupportedDetectedCombination(blockingMessage)
        }

        if hasKnownAndUnknownMix {
            throw AssembleReadTypeResolutionError.mixedDetectedAndUnknown
        }

        if let resolvedReadType = evaluation.resolvedReadType {
            return resolvedReadType
        }

        guard let tool else {
            return nil
        }

        switch tool {
        case .spades, .megahit, .skesa:
            return .illuminaShortReads
        case .flye:
            return .ontReads
        case .hifiasm:
            return .pacBioHiFi
        }
    }

    private static func detectPreMaterializationReadType(from inputURL: URL) -> AssemblyReadType? {
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

    private static func orderedUniqueReadTypes(_ readTypes: [AssemblyReadType?]) -> [AssemblyReadType] {
        let detected = Set(readTypes.compactMap { $0 })
        return AssemblyReadType.allCases.filter { detected.contains($0) }
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
    /// test seam). `run` reads every file (`ResolvedSequenceInputs.resolveForAssembly`).
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

    static func resolveExecutionInputURLs(
        for inputURLs: [URL],
        tempDirectory: URL,
        materializer: AssemblyInputMaterializing,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [URL] {
        try await resolveExecutionInputs(
            for: inputURLs,
            tempDirectory: tempDirectory,
            materializer: materializer,
            progress: progress
        ).executionInputURLs
    }

    /// Resolves the inputs as `lungfish-cli map` does (``ResolvedSequenceInputs``):
    /// every read a bundle holds, a virtual bundle materialized and the unpaired
    /// files of one bundle (a multi-file import, a `fullMixed` derivative)
    /// concatenated into `tempDirectory`, the R1 and R2 of a mate pair kept
    /// apart. An input with no readable payload is refused before anything is written.
    static func resolveExecutionInputs(
        for inputURLs: [URL],
        tempDirectory: URL,
        materializer: any AssemblyInputMaterializing,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ResolvedSequenceInputs {
        // Files of one bundle given separately (the app's per-bundle batch names a pair's R1 and R2) are that bundle, once.
        var seen = Set<String>()
        let inputURLs = inputURLs.map { SequenceInputResolver.enclosingFASTQBundleURL(for: $0) ?? $0.standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
        for inputURL in inputURLs where !AssemblyInputMaterialization.requiresMaterialization(inputURL) {
            guard SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) != nil else {
                throw AssembleInputResolutionError.unreadableBundlePayload(inputURL.standardizedFileURL.path)
            }
        }
        return try await ResolvedSequenceInputs.resolve(
            inputURLs: inputURLs,
            materializationDirectory: tempDirectory,
            materializer: materializer,
            concatenateUnpairedFiles: true,
            progress: progress
        )
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
        writer: ProvenanceWriter = ProvenanceWriter()
    ) throws -> URL {
        let toolVersion = result.assemblerVersion ?? "unknown"
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
            )
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
        let materializedPairs = inputPairs.filter { originalURL, executionURL in
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
        [
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
        ]
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
