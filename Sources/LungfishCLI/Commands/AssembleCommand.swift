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

protocol AssemblyInputMaterializing {
    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL
}

extension FASTQCLIMaterializer: AssemblyInputMaterializing {}

struct AssemblyResolvedExecutionInputs {
    let inputURLs: [URL]
    let materializationStartedAt: Date?
    let materializationEndedAt: Date?
}

struct AssembleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assemble",
        abstract: "Run de novo genome assembly with the managed assembly pack",
        discussion: """
            Assemble sequence reads with a managed assembler from the Genome Assembly pack.
            The CLI uses the same tool/read-type compatibility model as the app.
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

    @Option(name: [.customLong("memory-gb"), .customLong("memory")], help: "Memory budget in GB when the selected assembler supports it")
    var memoryGB: Int?

    @Option(name: .customLong("min-contig-length"), help: "Minimum contig length when the selected assembler supports it")
    var minContigLength: Int?

    @Option(name: .customLong("profile"), help: "Curated assembler profile, such as meta-sensitive or nano-hq")
    var profile: String?

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

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let startedAt = Date()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        warnIfDeprecatedAdvancedOptionsUsed()

        guard let tool = AssemblyTool(rawValue: assembler.lowercased()) else {
            print(formatter.error("Unknown assembler: \(assembler)"))
            throw ExitCode.failure
        }

        let inputURLs = fastqFiles.map { URL(fileURLWithPath: $0) }
        for inputURL in inputURLs where !FileManager.default.fileExists(atPath: inputURL.path) {
            print(formatter.error("Input file not found: \(inputURL.path)"))
            throw ExitCode.failure
        }

        let projectName = resolvedProjectName(from: inputURLs)
        let outputDirectory = resolvedOutputDirectory(projectName: projectName)

        if pairedEnd && inputURLs.count != 2 {
            print(formatter.error("Paired-end assembly requires exactly two sequence inputs."))
            throw ExitCode.failure
        }

        let advancedArguments: [String]
        do {
            advancedArguments = try Self.parseExtraArgs(extraArgs, deprecatedAdvancedOptions: advancedOptions) + extraArg
        } catch {
            print(formatter.error(error.localizedDescription))
            throw ExitCode.failure
        }

        let explicitReadType: AssemblyReadType?
        do {
            explicitReadType = try Self.parseExplicitReadType(readType)
        } catch {
            print(formatter.error(error.localizedDescription))
            throw ExitCode.failure
        }

        if let explicitReadType,
           !AssemblyCompatibility.isSupported(tool: tool, for: explicitReadType) {
            print(formatter.error("\(tool.displayName) is not available for \(explicitReadType.displayName) in v1."))
            throw ExitCode.failure
        }

        do {
            try Self.validatePreMaterializationTopology(
                tool: tool,
                inputURLs: inputURLs,
                pairedEnd: pairedEnd
            )
        } catch {
            print(formatter.error(error.localizedDescription))
            throw ExitCode.failure
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
            throw ExitCode.failure
        }

        if let preMaterializationReadType,
           !AssemblyCompatibility.isSupported(tool: tool, for: preMaterializationReadType) {
            print(formatter.error("\(tool.displayName) is not available for \(preMaterializationReadType.displayName) in v1."))
            throw ExitCode.failure
        }

        let executionInputURLs: [URL]
        let materializationStartedAt: Date?
        let materializationEndedAt: Date?
        let resolvedReadType: AssemblyReadType
        let materializationDirectory = outputDirectory.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true)
        do {
            let resolvedInputs = try await Self.resolveExecutionInputs(
                for: inputURLs,
                tempDirectory: materializationDirectory,
                materializer: FASTQCLIMaterializer(runner: NativeToolRunner.shared),
                progress: { message in
                    if !globalOptions.quiet {
                        print(formatter.info(message))
                    }
                }
            )
            executionInputURLs = resolvedInputs.inputURLs
            materializationStartedAt = resolvedInputs.materializationStartedAt
            materializationEndedAt = resolvedInputs.materializationEndedAt
            resolvedReadType = try preMaterializationReadType ?? Self.resolveReadType(
                    for: tool,
                    explicitReadType: readType,
                    originalInputURLs: inputURLs,
                    executionInputURLs: executionInputURLs
                )
            guard AssemblyCompatibility.isSupported(tool: tool, for: resolvedReadType) else {
                print(formatter.error("\(tool.displayName) is not available for \(resolvedReadType.displayName) in v1."))
                try? FileManager.default.removeItem(at: materializationDirectory)
                throw ExitCode.failure
            }
        } catch is ExitCode {
            throw ExitCode.failure
        } catch {
            try? FileManager.default.removeItem(at: materializationDirectory)
            print(formatter.error(error.localizedDescription))
            throw ExitCode.failure
        }

        let request = AssemblyRunRequest(
            tool: tool,
            readType: resolvedReadType,
            inputURLs: executionInputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: globalOptions.effectiveThreads,
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: profile,
            extraArguments: advancedArguments
        )
        let executionRequest = request.normalizedForExecution()

        print(formatter.header("Managed Assembly"))
        print("")
        print(formatter.keyValueTable([
            ("Assembler", tool.displayName),
            ("Read type", resolvedReadType.displayName),
            ("Inputs", inputURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Paired-end", pairedEnd ? "yes" : "no"),
            ("Threads", "\(executionRequest.threads)"),
            ("Memory", memoryGB.map { "\($0) GB" } ?? "default"),
            ("Profile", profile ?? "default"),
            ("Extra arguments", advancedArguments.isEmpty ? "none" : AdvancedCommandLineOptions.join(advancedArguments)),
            ("Output", outputDirectory.path),
        ]))
        print("")

        let result = try await ManagedAssemblyPipeline().run(request: executionRequest) { _, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }
        _ = try Self.writeProvenance(
            request: executionRequest,
            result: result,
            originalInputURLs: inputURLs,
            executionInputURLs: executionInputURLs,
            argv: CommandLine.arguments,
            startedAt: startedAt,
            endedAt: Date(),
            materializationStartedAt: materializationStartedAt,
            materializationEndedAt: materializationEndedAt
        )

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

        let inputDetections = zipOriginalAndExecutionInputs(
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
            guard !pairedEnd, inputURLs.count == 1 else {
                throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                    "Flye expects a single ONT sequence input in v1."
                )
            }
        case .hifiasm:
            guard !pairedEnd, inputURLs.count == 1 else {
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
        ).inputURLs
    }

    static func resolveExecutionInputs(
        for inputURLs: [URL],
        tempDirectory: URL,
        materializer: AssemblyInputMaterializing,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> AssemblyResolvedExecutionInputs {
        var resolvedURLs: [URL] = []
        var materializationStartedAt: Date?
        var materializationEndedAt: Date?
        for inputURL in inputURLs {
            if let bundleURL = AssemblyInputMaterialization.bundleRequiringMaterialization(for: inputURL) {
                if materializationStartedAt == nil {
                    materializationStartedAt = Date()
                }
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                let materializedURL = try await materializer.materialize(
                    bundleURL: bundleURL,
                    tempDirectory: tempDirectory,
                    progress: progress
                )
                materializationEndedAt = Date()
                resolvedURLs.append(materializedURL.standardizedFileURL)
                continue
            }

            guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) else {
                throw AssembleInputResolutionError.unreadableBundlePayload(inputURL.standardizedFileURL.path)
            }
            resolvedURLs.append(resolvedURL.standardizedFileURL)
        }
        return AssemblyResolvedExecutionInputs(
            inputURLs: resolvedURLs,
            materializationStartedAt: materializationStartedAt,
            materializationEndedAt: materializationEndedAt
        )
    }

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
            explicit: assemblyExplicitOptions(for: request, originalInputURLs: originalInputURLs, executionInputURLs: executionInputURLs),
            defaults: assemblyDefaultOptions(),
            resolved: assemblyResolvedOptions(for: request, originalInputURLs: originalInputURLs, executionInputURLs: executionInputURLs)
        )
        .runtime(
            ProvenanceRuntimeIdentity(
                appVersion: LungfishCLI.configuration.version,
                condaEnvironment: request.tool.environmentName
            )
        )

        let inputPairs = zipOriginalAndExecutionInputs(
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
            builder = builder.step(
                ProvenanceStep(
                    toolName: "lungfish.assemble.input-materialization",
                    toolVersion: LungfishCLI.configuration.version,
                    argv: argv,
                    reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
                    inputs: materializationInputDescriptors,
                    outputs: materializedExecutionDescriptors,
                    exitStatus: 0,
                    wallTimeSeconds: stepCompletedAt.timeIntervalSince(stepStartedAt),
                    startedAt: stepStartedAt,
                    completedAt: stepCompletedAt
                )
            )
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

    private static func zipOriginalAndExecutionInputs(
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) -> [(originalURL: URL, executionURL: URL)] {
        executionInputURLs.enumerated().map { index, executionURL in
            let originalURL = originalInputURLs.indices.contains(index) ? originalInputURLs[index] : executionURL
            return (originalURL, executionURL)
        }
    }

    private static func assemblyDefaultOptions() -> [String: ParameterValue] {
        [
            "assembler": .string("spades"),
            "readType": .null,
            "projectName": .null,
            "pairedEnd": .boolean(false),
            "threads": .null,
            "memoryGB": .null,
            "minContigLength": .null,
            "profile": .string("default"),
            "extraArguments": .array([]),
        ]
    }

    private static func assemblyExplicitOptions(
        for request: AssemblyRunRequest,
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) -> [String: ParameterValue] {
        assemblyResolvedOptions(
            for: request,
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        )
    }

    private static func assemblyResolvedOptions(
        for request: AssemblyRunRequest,
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) -> [String: ParameterValue] {
        [
            "assembler": .string(request.tool.rawValue),
            "readType": .string(request.readType.cliArgument),
            "projectName": .string(request.projectName),
            "outputDirectory": .file(request.outputDirectory),
            "pairedEnd": .boolean(request.pairedEnd),
            "threads": .integer(request.threads),
            "memoryGB": request.memoryGB.map(ParameterValue.integer) ?? .null,
            "minContigLength": request.effectiveMinContigLength.map(ParameterValue.integer) ?? .null,
            "profile": request.selectedProfileID.map(ParameterValue.string) ?? .string("default"),
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
