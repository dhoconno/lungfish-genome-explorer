// FastqCommand.swift - FASTQ processing CLI commands
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ONTImportStorageMode: ExpressibleByArgument {}
extension QualityBinningScheme: ExpressibleByArgument {}

/// FASTQ processing operations
struct FastqCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fastq",
        abstract: "FASTQ read processing and quality control",
        discussion: """
            Process FASTQ files using bundled bioinformatics tools (seqkit, fastp,
            bbtools). All tools are embedded — no external installations required.

            Operations include subsetting, quality/adapter trimming, contaminant
            filtering, error correction, primer removal, and paired-end utilities.

            Examples:
              lungfish fastq subsample --proportion 0.1 reads.fastq -o subset.fastq
              lungfish fastq quality-trim --threshold 20 reads.fastq -o trimmed.fastq
              lungfish fastq contaminant-filter --mode phix reads.fastq -o clean.fastq
              lungfish fastq error-correct reads.fastq -o corrected.fastq
            """,
        subcommands: [
            FastqSubsampleSubcommand.self,
            FastqLengthFilterSubcommand.self,
            FastqTrimSubcommand.self,
            FastqQualityTrimSubcommand.self,
            FastqAdapterTrimSubcommand.self,
            FastqFixedTrimSubcommand.self,
            FastqContaminantFilterSubcommand.self,
            FastqPrimerRemovalSubcommand.self,
            FastqErrorCorrectSubcommand.self,
            FastqMergeSubcommand.self,
            FastqRepairSubcommand.self,
            FastqDeinterleaveSubcommand.self,
            FastqInterleaveSubcommand.self,
            FastqDeduplicateSubcommand.self,
            FastqDemultiplexSubcommand.self,
            FastqONTFluidigmSamplesSubcommand.self,
            FastqONTPacBioBarcodeDemuxSubcommand.self,
            FastqScoutSubcommand.self,
            FastqImportONTSubcommand.self,
            FastqMaterializeSubcommand.self,
            FastqQCSummarySubcommand.self,
            FastqPBAAClusterSubcommand.self,
            FastqFullLengthONTMHCGenotypingSubcommand.self,
            FastqGenotypingSubcommand.self,
            FastqGenotypingCohortSubcommand.self,
            FastqUpdateCurrentWorkbookSubcommand.self,
            FastqONTGenotypingSubcommand.self,
            FastqONTBarcodeGenotypingSubcommand.self,
            FastqMHCReferenceBundleSubcommand.self,
            FastqTwelveSReferenceMetadataSubcommand.self,
            FastqTwelveSReferenceBundleSubcommand.self,
            FastqTwelveSMatchSubcommand.self,
            FastqTwelveSExportSubcommand.self,
            FastqTwelveSExportUnresolvedSubcommand.self,
            FastqSearchTextSubcommand.self,
            FastqSearchMotifSubcommand.self,
            FastqOrientSubcommand.self,
            FastqScrubHumanSubcommand.self,
            FastqSequenceFilterSubcommand.self,
            FastqDeaconRiboSubcommand.self,
            FastqReverseComplementSubcommand.self,
            FastqTranslateSubcommand.self,
        ]
    )
}

// MARK: - Combined fastp Trim

struct FastqTrimSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trim",
        abstract: "Trim adapters and low-quality bases in one fastp pass"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("threshold"), help: "Quality threshold (default: 20)")
    var threshold: Int = 20

    @Option(name: .customLong("window"), help: "Sliding window size (default: 4)")
    var windowSize: Int = 4

    @Option(name: .customLong("mode"), help: "Quality trim mode: cut-right, cut-front, cut-tail, cut-both (default: cut-right)")
    var mode: String = "cut-right"

    @Flag(
        name: .customLong("adapter-trimming"),
        inversion: .prefixedNo,
        help: "Run fastp adapter trimming in the same pass (default: enabled)"
    )
    var adapterTrimming: Bool = true

    @Option(name: .customLong("adapter"), help: "Adapter sequence (omit for auto-detect)")
    var adapterSequence: String?

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Additional fastp arguments passed verbatim"
    )
    var extraArgs: String = ""

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let started = Date()
        let args = try fastpArguments(inputURL: inputURL)
        let result = try await NativeToolRunner.shared.run(.fastp, arguments: args)
        try await writeProvenance(inputURL: inputURL, arguments: args, result: result, started: started)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "fastp combined trim failed: \(result.stderr)")
        }
        FileHandle.standardError.write(Data("Adapter and quality trimmed reads written to \(output.output)\n".utf8))
    }

    func fastpArgumentsForTesting(inputURL: URL) throws -> [String] {
        try fastpArguments(inputURL: inputURL)
    }

    private func fastpArguments(inputURL: URL) throws -> [String] {
        var args = [
            "-i", inputURL.path,
            "-o", output.output,
            "-W", String(windowSize),
            "-M", String(threshold),
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]

        if !adapterTrimming {
            args.append("--disable_adapter_trimming")
        } else if let adapterSequence {
            args += ["--adapter_sequence", adapterSequence]
        }

        switch mode {
        case "cut-right": args.append("--cut_right")
        case "cut-front": args.append("--cut_front")
        case "cut-tail": args.append("--cut_tail")
        case "cut-both":
            args.append("--cut_front")
            args.append("--cut_right")
        default:
            throw ValidationError("Invalid trim mode: \(mode). Use: cut-right, cut-front, cut-tail, cut-both")
        }
        args += try AdvancedCommandLineOptions.parse(extraArgs)
        return args
    }

    private func writeProvenance(
        inputURL: URL,
        arguments: [String],
        result: NativeToolResult,
        started: Date
    ) async throws {
        let outputURL = URL(fileURLWithPath: output.output)
        var cliArguments = ["trim", inputURL.path]
        if threshold != 20 {
            cliArguments += ["--threshold", String(threshold)]
        }
        if windowSize != 4 {
            cliArguments += ["--window", String(windowSize)]
        }
        if mode != "cut-right" {
            cliArguments += ["--mode", mode]
        }
        if !adapterTrimming {
            cliArguments.append("--no-adapter-trimming")
        }
        if let adapterSequence {
            cliArguments += ["--adapter", adapterSequence]
        }
        if !extraArgs.isEmpty {
            cliArguments += ["--extra-args", extraArgs]
        }
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq trim",
            nativeTool: .fastp,
            cliArguments: cliArguments,
            nativeArguments: arguments,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "threshold": .integer(threshold),
                "window": .integer(windowSize),
                "mode": .string(mode),
                "adapterTrimming": .boolean(adapterTrimming),
                "adapterSequence": adapterSequence.map(ParameterValue.string) ?? .null,
                "operation": .string("combined fastp adapter+quality trim"),
                "output": .file(outputURL),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "threshold": .integer(20),
                "window": .integer(4),
                "mode": .string("cut-right"),
                "adapterTrimming": .boolean(true),
                "adapterSequence": .null,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: started
        )
    }

    private var awaitlessFastpVersion: String {
        "managed fastp"
    }
}

// MARK: - Helpers

/// Builds the environment variables needed for BBTools shell scripts.
func bbToolsEnvironment(runner: NativeToolRunner) async -> [String: String] {
    var env: [String: String] = [:]
    if let toolsDir = await runner.getToolsDirectory() {
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let jreBinDir = toolsDir.appendingPathComponent("jre/bin")
        env["PATH"] = "\(toolsDir.path):\(jreBinDir.path):\(existingPath)"
        let javaURL = jreBinDir.appendingPathComponent("java")
        let javaHome = toolsDir.appendingPathComponent("jre")
        if FileManager.default.fileExists(atPath: javaURL.path) {
            env["JAVA_HOME"] = javaHome.path
            env["BBMAP_JAVA"] = javaURL.path
        }
    }
    return env
}

func validateInput(_ path: String) throws -> URL {
    guard FileManager.default.fileExists(atPath: path) else {
        throw CLIError.inputFileNotFound(path: path)
    }
    return URL(fileURLWithPath: path)
}

private let barcodeKitIDsHelpText = BarcodeKitRegistry.builtinKits()
    .map(\.id)
    .joined(separator: ", ")

private let barcodeDefinitionFormatHelpText = """
Custom definitions can be CSV, TSV, or whitespace text with columns id,sequence[,secondary_sequence][,sample_name]; header optional. Example: FLD0001<TAB>GTATCGTCGT.
"""

private let barcodeKitHelpText = """
Barcode kit: \(barcodeKitIDsHelpText), or path to custom CSV/TSV/text barcode definition. \(barcodeDefinitionFormatHelpText)
"""

func resolveBarcodeKitArgument(_ kit: String) throws -> (definition: BarcodeKitDefinition, customURL: URL?) {
    if let builtin = BarcodeKitRegistry.kit(byID: kit) {
        return (builtin, nil)
    }
    if FileManager.default.fileExists(atPath: kit) {
        let csvURL = URL(fileURLWithPath: kit)
        let name = csvURL.deletingPathExtension().lastPathComponent
        return (try BarcodeKitRegistry.loadCustomKit(from: csvURL, name: name), csvURL)
    }
    throw ValidationError(
        "Unknown barcode kit '\(kit)'. Use one of: \(barcodeKitIDsHelpText), "
        + "or a path to a custom CSV/TSV/text barcode definition. "
        + "Expected columns: id,sequence[,secondary_sequence][,sample_name]."
    )
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Subsample

struct FastqSubsampleSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subsample",
        abstract: "Subsample reads by proportion or count"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("proportion"), help: "Fraction of reads to keep (0-1)")
    var proportion: Double?

    @Option(name: .customLong("count"), help: "Number of reads to keep")
    var count: Int?

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let runner = NativeToolRunner.shared

        if proportion != nil && count != nil {
            throw ValidationError("Specify --proportion or --count, not both")
        }
        var args = ["sample"]
        if let proportion {
            guard proportion > 0, proportion <= 1 else {
                throw ValidationError("Proportion must be in (0, 1]")
            }
            args += ["-p", String(proportion)]
        } else if let count {
            guard count > 0 else {
                throw ValidationError("Count must be > 0")
            }
            args = ["sample2", "-n", String(count), "-2"]
        } else {
            throw ValidationError("Specify --proportion or --count")
        }
        args += [inputURL.path, "-o", output.output]

        let startedAt = Date()
        let result = try await runner.run(.seqkit, arguments: args)
        guard result.isSuccess else {
            let command = count == nil ? "seqkit sample" : "seqkit sample2"
            throw CLIError.conversionFailed(reason: "\(command) failed: \(result.stderr)")
        }
        var cliArguments = ["subsample"]
        if let proportion {
            cliArguments += ["--proportion", String(proportion)]
        }
        if let count {
            cliArguments += ["--count", String(count)]
        }
        cliArguments += [inputURL.path, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq subsample",
            nativeTool: .seqkit,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "proportion": proportion.map(ParameterValue.number) ?? .null,
                "count": count.map(ParameterValue.integer) ?? .null,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "proportion": .null,
                "count": .null,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Subsampled reads written to \(output.output)\n".utf8))
    }
}

// MARK: - Length Filter

struct FastqLengthFilterSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "length-filter",
        abstract: "Filter reads by length"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("min"), help: "Minimum read length")
    var minLength: Int?

    @Option(name: .customLong("max"), help: "Maximum read length")
    var maxLength: Int?

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        guard minLength != nil || maxLength != nil else {
            throw ValidationError("Specify --min, --max, or both")
        }
        if let minLength, minLength < 0 { throw ValidationError("--min must be >= 0") }
        if let maxLength, maxLength < 0 { throw ValidationError("--max must be >= 0") }
        if let minLength, let maxLength, minLength > maxLength {
            throw ValidationError("--min (\(minLength)) must be <= --max (\(maxLength))")
        }
        let runner = NativeToolRunner.shared

        var args = ["seq"]
        if let minLength { args += ["-m", String(minLength)] }
        if let maxLength { args += ["-M", String(maxLength)] }
        args += [inputURL.path, "-o", output.output]

        let startedAt = Date()
        let result = try await runner.run(.seqkit, arguments: args)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "seqkit seq failed: \(result.stderr)")
        }
        var cliArguments = ["length-filter"]
        if let minLength { cliArguments += ["--min", String(minLength)] }
        if let maxLength { cliArguments += ["--max", String(maxLength)] }
        cliArguments += [inputURL.path, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq length-filter",
            nativeTool: .seqkit,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "min": minLength.map(ParameterValue.integer) ?? .null,
                "max": maxLength.map(ParameterValue.integer) ?? .null,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "min": .null,
                "max": .null,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Filtered reads written to \(output.output)\n".utf8))
    }
}

// MARK: - Quality Trim

struct FastqQualityTrimSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quality-trim",
        abstract: "Trim low-quality bases using fastp"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("threshold"), help: "Quality threshold (default: 20)")
    var threshold: Int = 20

    @Option(name: .customLong("window"), help: "Sliding window size (default: 4)")
    var windowSize: Int = 4

    @Option(name: .customLong("mode"), help: "Trim mode: cut-right, cut-front, cut-tail, cut-both (default: cut-right)")
    var mode: String = "cut-right"

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Additional fastp arguments passed verbatim"
    )
    var extraArgs: String = ""

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let runner = NativeToolRunner.shared

        let args = try fastpArguments(inputURL: inputURL)

        let startedAt = Date()
        let result = try await runner.run(.fastp, arguments: args)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "fastp quality trim failed: \(result.stderr)")
        }
        var cliArguments = ["quality-trim"]
        if threshold != 20 {
            cliArguments += ["--threshold", String(threshold)]
        }
        if windowSize != 4 {
            cliArguments += ["--window", String(windowSize)]
        }
        if mode != "cut-right" {
            cliArguments += ["--mode", mode]
        }
        if !extraArgs.isEmpty {
            cliArguments += ["--extra-args", extraArgs]
        }
        cliArguments += [inputURL.path, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq quality-trim",
            nativeTool: .fastp,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "threshold": .integer(threshold),
                "windowSize": .integer(windowSize),
                "mode": .string(mode),
                "extraArgs": .string(extraArgs),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "threshold": .integer(20),
                "windowSize": .integer(4),
                "mode": .string("cut-right"),
                "extraArgs": .string(""),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Quality-trimmed reads written to \(output.output)\n".utf8))
    }

    var extraArguments: [String] {
        (try? AdvancedCommandLineOptions.parse(extraArgs)) ?? []
    }

    func fastpArgumentsForTesting(inputURL: URL) throws -> [String] {
        try fastpArguments(inputURL: inputURL)
    }

    private func fastpArguments(inputURL: URL) throws -> [String] {
        var args = [
            "-i", inputURL.path,
            "-o", output.output,
            "-W", String(windowSize),
            "-M", String(threshold),
            "--disable_adapter_trimming",
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]

        switch mode {
        case "cut-right": args.append("--cut_right")
        case "cut-front": args.append("--cut_front")
        case "cut-tail": args.append("--cut_tail")
        case "cut-both":
            args.append("--cut_front")
            args.append("--cut_right")
        default:
            throw ValidationError("Invalid trim mode: \(mode). Use: cut-right, cut-front, cut-tail, cut-both")
        }
        args += try AdvancedCommandLineOptions.parse(extraArgs)
        return args
    }

    func provenanceRunForTesting(
        inputURL: URL,
        outputURL: URL,
        argv: [String],
        fastpArguments: [String],
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) -> WorkflowRun {
        makeProvenanceRun(
            inputURL: inputURL,
            outputURL: outputURL,
            argv: argv,
            fastpArguments: fastpArguments,
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr
        )
    }

    private func makeProvenanceRun(
        inputURL: URL,
        outputURL: URL,
        argv: [String],
        fastpArguments: [String],
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) -> WorkflowRun {
        let parameters: [String: ParameterValue] = [
            "threshold": .integer(threshold),
            "windowSize": .integer(windowSize),
            "mode": .string(mode),
            "extraArgs": .string(extraArgs),
            "output": .file(outputURL),
        ]
        let step = StepExecution(
            toolName: "fastp",
            toolVersion: "bundled",
            command: fastpArguments,
            inputs: [ProvenanceRecorder.fileRecord(url: inputURL, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: outputURL, role: .output)],
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr,
            endTime: Date()
        )
        return WorkflowRun(
            name: "lungfish fastq quality-trim",
            endTime: Date(),
            status: exitCode == 0 ? .completed : .failed,
            steps: [step],
            parameters: parameters.merging([
                "argv": .array(argv.map { .string($0) }),
                "command": .string(argv.map(shellEscape).joined(separator: " ")),
            ]) { current, _ in current }
        )
    }
}

func recordFASTQNativeToolProvenance(
    workflowName: String,
    nativeTool: NativeTool,
    cliArguments: [String],
    nativeArguments: [String],
    result: NativeToolResult,
    inputURLs: [URL],
    outputURLs: [URL],
    parameters: [String: ParameterValue],
    defaults: [String: ParameterValue] = [:],
    inputRecords: [FileRecord]? = nil,
    outputRecords: [FileRecord]? = nil,
    startedAt: Date
) async throws {
    guard let firstOutputURL = outputURLs.first else { return }
    let completedAt = Date()
    let toolVersion = await NativeToolRunner.shared.getToolVersion(nativeTool) ?? "unknown"
    let stepCommand = result.arguments.isEmpty
        ? [nativeTool.executableName] + nativeArguments
        : result.arguments

    var resolved = parameters
    for (key, value) in defaults where resolved[key] == nil {
        resolved[key] = value
    }

    try await CLIProvenanceSupport.recordSingleStepRun(
        name: workflowName,
        parameters: parameters,
        defaults: defaults,
        resolved: resolved,
        toolName: nativeTool.rawValue,
        toolVersion: toolVersion,
        command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
        stepCommand: stepCommand,
        inputs: inputRecords ?? inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) },
        outputs: outputRecords ?? outputURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) },
        exitCode: result.exitCode,
        wallTime: completedAt.timeIntervalSince(startedAt),
        stderr: result.stderr,
        status: result.isSuccess ? .completed : .failed,
        outputDirectory: firstOutputURL.deletingLastPathComponent()
    )
}

struct FASTQGzipProvenanceResult {
    let command: [String]
    let inputURL: URL
    let outputURL: URL
    let exitCode: Int32
    let wallTime: TimeInterval
    let stderr: String?
}

func gzipCompressFASTQ(
    sourceURL: URL,
    outputURL: URL,
    failureDescription: String
) throws -> FASTQGzipProvenanceResult {
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    defer { try? outputHandle.close() }

    let process = Process()
    let command = ["/usr/bin/gzip", "-c", sourceURL.path]
    let stderrPipe = Pipe()
    let startedAt = Date()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = Array(command.dropFirst())
    process.standardOutput = outputHandle
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    let stderr = String(
        decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    let wallTime = Date().timeIntervalSince(startedAt)
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        throw CLIError.conversionFailed(reason: "gzip failed while compressing \(failureDescription) \(outputURL.path)\(suffix)")
    }
    return FASTQGzipProvenanceResult(
        command: command,
        inputURL: sourceURL,
        outputURL: outputURL,
        exitCode: process.terminationStatus,
        wallTime: wallTime,
        stderr: stderr
    )
}

@discardableResult
func recordFASTQMergeProvenance(
    cliArguments: [String],
    nativeArguments: [String],
    bbmergeResult: NativeToolResult,
    gzipResult: FASTQGzipProvenanceResult?,
    inputURL: URL,
    bbmergeOutputURLs: [URL],
    finalOutputURL: URL,
    parameters: [String: ParameterValue],
    defaults: [String: ParameterValue] = [:],
    concatenateWallTime: TimeInterval = 0,
    startedAt: Date
) async throws -> ProvenanceEnvelope {
    let completedAt = Date()
    let toolVersion = await NativeToolRunner.shared.getToolVersion(.bbmerge) ?? "unknown"
    let bbmergeCommand = bbmergeResult.arguments.isEmpty
        ? [NativeTool.bbmerge.executableName] + nativeArguments
        : bbmergeResult.arguments
    let inputRecord = ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input)
    let finalOutputRecord = ProvenanceRecorder.fileRecord(url: finalOutputURL, format: .fastq, role: .output)
    let bbmergeOutputRecords = bbmergeOutputURLs
        .filter { FileManager.default.fileExists(atPath: $0.path) }
        .map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) }

    let bbmergeStepID = UUID()
    let concatenateStepID = UUID()
    let concatenatedURL = gzipResult?.inputURL ?? finalOutputURL
    let concatenateInputs = bbmergeOutputRecords.map { ProvenanceFileDescriptor(fileRecord: $0).withRole(.input) }
    let concatenateOutput = try ProvenanceFileDescriptor.file(
        url: concatenatedURL,
        format: .fastq,
        role: .output
    )
    let concatenatedInputPaths = bbmergeOutputRecords.map(\.path)
    let concatenateShell = "cat "
        + concatenatedInputPaths.map(shellEscape).joined(separator: " ")
        + " > "
        + shellEscape(concatenatedURL.path)
    var extraSteps = [
        ProvenanceStep(
            id: concatenateStepID,
            toolName: "lungfish fastq merge concatenate",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: ["/bin/sh", "-lc", concatenateShell],
            inputs: concatenateInputs,
            outputs: [concatenateOutput],
            exitStatus: 0,
            wallTimeSeconds: concatenateWallTime,
            dependsOn: [bbmergeStepID],
            startedAt: completedAt.addingTimeInterval(-concatenateWallTime),
            completedAt: completedAt
        ),
    ]

    if let gzipResult {
        let gzipInput = try ProvenanceFileDescriptor.file(
            url: gzipResult.inputURL,
            format: .fastq,
            role: .input
        )
        let gzipOutput = try ProvenanceFileDescriptor.file(
            url: gzipResult.outputURL,
            format: .fastq,
            role: .output
        )
        extraSteps.append(
            ProvenanceStep(
                toolName: gzipResult.command.first ?? "/usr/bin/gzip",
                toolVersion: "system",
                argv: gzipResult.command,
                inputs: [gzipInput],
                outputs: [gzipOutput],
                exitStatus: Int(gzipResult.exitCode),
                wallTimeSeconds: gzipResult.wallTime,
                stderr: gzipResult.stderr,
                dependsOn: [concatenateStepID],
                startedAt: completedAt.addingTimeInterval(-gzipResult.wallTime),
                completedAt: completedAt
            )
        )
    }

    return try await CLIProvenanceSupport.recordSingleStepRun(
        name: "lungfish fastq merge",
        parameters: parameters,
        defaults: defaults,
        toolName: NativeTool.bbmerge.rawValue,
        toolVersion: toolVersion,
        command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
        stepID: bbmergeStepID,
        stepCommand: bbmergeCommand,
        stepInputs: [inputRecord],
        stepOutputs: bbmergeOutputRecords,
        extraSteps: extraSteps,
        inputs: [inputRecord],
        outputs: [finalOutputRecord],
        exitCode: bbmergeResult.exitCode,
        wallTime: completedAt.timeIntervalSince(startedAt),
        stderr: bbmergeResult.stderr,
        status: bbmergeResult.isSuccess && (gzipResult?.exitCode ?? 0) == 0 ? .completed : .failed,
        outputDirectory: finalOutputURL.deletingLastPathComponent()
    )
}

@discardableResult
func recordFASTQCountedMergeProvenance(
    cliArguments: [String],
    nativeArguments: [String],
    bbmergeResult: NativeToolResult,
    inputURL: URL,
    bbmergeOutputURLs: [URL],
    countedResult: CountedFASTQMaterializationResult,
    finalOutputURL: URL,
    parameters: [String: ParameterValue],
    defaults: [String: ParameterValue] = [:],
    startedAt: Date
) async throws -> ProvenanceEnvelope {
    let completedAt = Date()
    let toolVersion = await NativeToolRunner.shared.getToolVersion(.bbmerge) ?? "unknown"
    let bbmergeCommand = bbmergeResult.arguments.isEmpty
        ? [NativeTool.bbmerge.executableName] + nativeArguments
        : bbmergeResult.arguments
    let inputRecord = ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input)
    let finalOutputRecord = ProvenanceRecorder.fileRecord(url: finalOutputURL, format: .fastq, role: .output)
    let bbmergeOutputRecords = bbmergeOutputURLs
        .filter { FileManager.default.fileExists(atPath: $0.path) }
        .map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) }

    let bbmergeStepID = UUID()
    let countedStepID = UUID()
    let countedInputs = bbmergeOutputRecords
        .map { ProvenanceFileDescriptor(fileRecord: $0).withRole(.input) }
    let countedOutput = ProvenanceFileDescriptor(fileRecord: countedResult.materializedOutput)
    let countedCommand = [CLICommandIdentity.executableName, "fastq"] + cliArguments

    var extraSteps = [
        ProvenanceStep(
            id: countedStepID,
            toolName: "lungfish fastq merge count-duplicates",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: countedCommand,
            inputs: countedInputs,
            outputs: [countedOutput],
            exitStatus: 0,
            dependsOn: [bbmergeStepID],
            startedAt: completedAt,
            completedAt: completedAt
        ),
    ]

    if let compression = countedResult.compression {
        extraSteps.append(
            ProvenanceStep(
                toolName: compression.command.first ?? "/usr/bin/gzip",
                toolVersion: "system",
                argv: compression.command,
                inputs: [ProvenanceFileDescriptor(fileRecord: compression.input).withRole(.input)],
                outputs: [ProvenanceFileDescriptor(fileRecord: compression.output).withRole(.output)],
                exitStatus: Int(compression.exitCode),
                wallTimeSeconds: compression.wallTime,
                stderr: compression.stderr,
                dependsOn: [countedStepID],
                startedAt: completedAt.addingTimeInterval(-compression.wallTime),
                completedAt: completedAt
            )
        )
    }

    return try await CLIProvenanceSupport.recordSingleStepRun(
        name: "lungfish fastq merge",
        parameters: parameters,
        defaults: defaults,
        toolName: NativeTool.bbmerge.rawValue,
        toolVersion: toolVersion,
        command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
        stepID: bbmergeStepID,
        stepCommand: bbmergeCommand,
        stepInputs: [inputRecord],
        stepOutputs: bbmergeOutputRecords,
        extraSteps: extraSteps,
        inputs: [inputRecord],
        outputs: [finalOutputRecord],
        exitCode: bbmergeResult.exitCode,
        wallTime: completedAt.timeIntervalSince(startedAt),
        stderr: bbmergeResult.stderr,
        status: bbmergeResult.isSuccess && (countedResult.compression?.exitCode ?? 0) == 0 ? .completed : .failed,
        outputDirectory: finalOutputURL.deletingLastPathComponent()
    )
}

func recordFASTQSwiftToolProvenance(
    workflowName: String,
    cliArguments: [String],
    inputURLs: [URL],
    outputURLs: [URL],
    parameters: [String: ParameterValue],
    defaults: [String: ParameterValue] = [:],
    inputRecords: [FileRecord]? = nil,
    outputFormat: FileFormat = .fastq,
    startedAt: Date
) async throws {
    guard let firstOutputURL = outputURLs.first else { return }
    let completedAt = Date()
    let command = [CLICommandIdentity.executableName, "fastq"] + cliArguments
    var resolved = parameters
    for (key, value) in defaults where resolved[key] == nil {
        resolved[key] = value
    }

    try await CLIProvenanceSupport.recordSingleStepRun(
        name: workflowName,
        parameters: parameters,
        defaults: defaults,
        resolved: resolved,
        toolName: workflowName,
        toolVersion: WorkflowRun.currentAppVersion,
        command: command,
        stepCommand: command,
        inputs: inputRecords ?? inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) },
        outputs: outputURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ProvenanceRecorder.fileRecord(url: $0, format: outputFormat, role: .output) },
        exitCode: 0,
        wallTime: completedAt.timeIntervalSince(startedAt),
        stderr: nil,
        status: .completed,
        outputDirectory: firstOutputURL.deletingLastPathComponent()
    )
}

func provenanceRecords(
    for url: URL,
    format: FileFormat? = nil,
    role: FileRole
) -> [FileRecord] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return [ProvenanceRecorder.fileRecord(url: url, format: format, role: role)]
    }
    guard isDirectory.boolValue else {
        return [ProvenanceRecorder.fileRecord(url: url, format: format, role: role)]
    }
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return [ProvenanceRecorder.fileRecord(url: url, format: format, role: role)]
    }
    return enumerator
        .compactMap { item -> URL? in
            guard let fileURL = item as? URL,
                  (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return fileURL
        }
        .sorted { $0.path < $1.path }
        .map { ProvenanceRecorder.fileRecord(url: $0, format: format, role: role) }
}

// MARK: - Reverse Complement

struct FastqReverseComplementSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reverse-complement",
        abstract: "Reverse-complement FASTQ reads and reverse their quality scores"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let outputURL = URL(fileURLWithPath: output.output)
        let startedAt = Date()

        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputURL)
        do {
            try writer.open()
            for try await record in reader.records(from: inputURL) {
                try writer.write(record.reverseComplement())
            }
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }

        var cliArguments = ["reverse-complement", inputURL.path, "-o", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        try await recordFASTQSwiftToolProvenance(
            workflowName: "lungfish fastq reverse-complement",
            cliArguments: cliArguments,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Reverse-complemented reads written to \(output.output)\n".utf8))
    }
}

// MARK: - FASTQ Translate

struct FastqTranslateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "translate",
        abstract: "Translate FASTQ reads to protein FASTA"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("frame"), help: "Reading frame: 1-3 forward, 4-6 reverse (default: 1)")
    var frame: Int = 1

    @Option(name: .customLong("table"), help: "Genetic code table ID (default: 1)")
    var table: Int = 1

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        guard (1...6).contains(frame) else {
            throw CLIError.conversionFailed(reason: "Frame must be 1-6.")
        }
        guard let codonTable = CodonTable.table(id: table) else {
            throw CLIError.conversionFailed(reason: "Unknown genetic code table ID \(table).")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        let readingFrame = Self.readingFrame(for: frame)
        let startedAt = Date()

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        do {
            let reader = FASTQReader(validateSequence: false)
            for try await record in reader.records(from: inputURL) {
                let translated = TranslationEngine.translateFrames(
                    [readingFrame],
                    sequence: record.sequence,
                    table: codonTable
                )
                guard let protein = translated.first?.1, !protein.isEmpty else { continue }
                try Self.writeFASTARecord(
                    identifier: "\(record.identifier)_frame\(readingFrame.rawValue)",
                    description: "[\(codonTable.name)] [\(protein.count) aa]",
                    sequence: protein,
                    to: handle
                )
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        var cliArguments = ["translate", inputURL.path, "--frame", "\(frame)", "-o", output.output]
        if table != 1 {
            cliArguments += ["--table", "\(table)"]
        }
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        try await recordFASTQSwiftToolProvenance(
            workflowName: "lungfish fastq translate",
            cliArguments: cliArguments,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "frame": .integer(frame),
                "table": .integer(table),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "frame": .integer(1),
                "table": .integer(1),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            outputFormat: .fasta,
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Translated reads written to \(output.output)\n".utf8))
    }

    private static func readingFrame(for number: Int) -> ReadingFrame {
        switch number {
        case 1: return .plus1
        case 2: return .plus2
        case 3: return .plus3
        case 4: return .minus1
        case 5: return .minus2
        case 6: return .minus3
        default: return .plus1
        }
    }

    private static func writeFASTARecord(
        identifier: String,
        description: String,
        sequence: String,
        to handle: FileHandle
    ) throws {
        try handle.write(contentsOf: Data(">\(identifier) \(description)\n".utf8))
        var offset = 0
        while offset < sequence.count {
            let start = sequence.index(sequence.startIndex, offsetBy: offset)
            let end = sequence.index(start, offsetBy: min(70, sequence.count - offset))
            try handle.write(contentsOf: Data("\(sequence[start..<end])\n".utf8))
            offset += 70
        }
    }
}

// MARK: - Adapter Trim

struct FastqAdapterTrimSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adapter-trim",
        abstract: "Remove adapter sequences using fastp"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("adapter"), help: "Adapter sequence (omit for auto-detect)")
    var adapterSequence: String?

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let runner = NativeToolRunner.shared

        var args = [
            "-i", inputURL.path,
            "-o", output.output,
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]

        if let adapterSequence {
            args += ["--adapter_sequence", adapterSequence]
        }

        let startedAt = Date()
        let result = try await runner.run(.fastp, arguments: args)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "fastp adapter trim failed: \(result.stderr)")
        }
        var cliArguments = ["adapter-trim"]
        if let adapterSequence {
            cliArguments += ["--adapter", adapterSequence]
        }
        cliArguments += [inputURL.path, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq adapter-trim",
            nativeTool: .fastp,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "adapter": adapterSequence.map(ParameterValue.string) ?? .null,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "adapter": .null,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Adapter-trimmed reads written to \(output.output)\n".utf8))
    }
}

// MARK: - Fixed Trim

struct FastqFixedTrimSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fixed-trim",
        abstract: "Trim fixed number of bases from read ends"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("front"), help: "Bases to trim from 5' end (default: 0)")
    var front: Int = 0

    @Option(name: .customLong("tail"), help: "Bases to trim from 3' end (default: 0)")
    var tail: Int = 0

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        guard front >= 0 else { throw ValidationError("--front must be >= 0") }
        guard tail >= 0 else { throw ValidationError("--tail must be >= 0") }
        guard front > 0 || tail > 0 else {
            throw ValidationError("At least one of --front or --tail must be > 0")
        }
        let runner = NativeToolRunner.shared

        var args = [
            "-i", inputURL.path,
            "-o", output.output,
            "--disable_adapter_trimming",
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]
        if front > 0 { args += ["--trim_front1", String(front)] }
        if tail > 0 { args += ["--trim_tail1", String(tail)] }

        let startedAt = Date()
        let result = try await runner.run(.fastp, arguments: args)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "fastp fixed trim failed: \(result.stderr)")
        }
        var cliArguments = ["fixed-trim"]
        if front != 0 {
            cliArguments += ["--front", String(front)]
        }
        if tail != 0 {
            cliArguments += ["--tail", String(tail)]
        }
        cliArguments += [inputURL.path, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq fixed-trim",
            nativeTool: .fastp,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "front": .integer(front),
                "tail": .integer(tail),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "front": .integer(0),
                "tail": .integer(0),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Fixed-trimmed reads written to \(output.output)\n".utf8))
    }
}

// MARK: - Contaminant Filter

struct FastqContaminantFilterSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contaminant-filter",
        abstract: "Remove contaminant reads using bbduk"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("mode"), help: "Filter mode: phix, custom (default: phix)")
    var mode: String = "phix"

    @Option(name: .customLong("ref"), help: "Reference FASTA for custom mode")
    var reference: String?

    @Option(name: .customLong("kmer"), help: "K-mer size (default: 31)")
    var kmerSize: Int = 31

    @Option(name: .customLong("hdist"), help: "Hamming distance tolerance (default: 1)")
    var hammingDistance: Int = 1

    @OptionGroup var output: OutputOptions

    static func bbdukReferenceURL(
        mode: String,
        reference: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        switch mode {
        case "phix":
            guard let phixReference = CoreToolLocator.bbToolsPhiXReferenceURL(homeDirectory: homeDirectory) else {
                throw ValidationError(
                    "PhiX reference not found in managed BBTools resources: \(CoreToolLocator.bbToolsPhiXReferenceFileName)"
                )
            }
            return phixReference
        case "custom":
            guard let reference else {
                throw ValidationError("Custom mode requires --ref")
            }
            guard FileManager.default.fileExists(atPath: reference) else {
                throw CLIError.inputFileNotFound(path: reference)
            }
            return URL(fileURLWithPath: reference)
        default:
            throw ValidationError("Invalid mode: \(mode). Use: phix, custom")
        }
    }

    static func bbdukArguments(
        inputURL: URL,
        outputPath: String,
        mode: String,
        reference: String?,
        kmerSize: Int,
        hammingDistance: Int,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [String] {
        var args = [
            "in=\(inputURL.path)",
            "out=\(outputPath)",
            "k=\(kmerSize)",
            "hdist=\(hammingDistance)",
        ]

        let referenceURL = try bbdukReferenceURL(mode: mode, reference: reference, homeDirectory: homeDirectory)
        args.append("ref=\(referenceURL.path)")
        return args
    }

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        guard kmerSize > 0 else { throw ValidationError("--kmer must be > 0") }
        guard hammingDistance >= 0 else { throw ValidationError("--hdist must be >= 0") }
        let runner = NativeToolRunner.shared

        let args = try Self.bbdukArguments(
            inputURL: inputURL,
            outputPath: output.output,
            mode: mode,
            reference: reference,
            kmerSize: kmerSize,
            hammingDistance: hammingDistance
        )

        let env = await bbToolsEnvironment(runner: runner)
        let resolvedReferenceURL = try Self.bbdukReferenceURL(mode: mode, reference: reference)
        let startedAt = Date()
        let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "bbduk contaminant filter failed: \(result.stderr)")
        }
        var cliArguments = ["contaminant-filter", inputURL.path, "--mode", mode]
        if let reference {
            cliArguments += ["--ref", reference]
        }
        if kmerSize != 31 {
            cliArguments += ["--kmer", String(kmerSize)]
        }
        if hammingDistance != 1 {
            cliArguments += ["--hdist", String(hammingDistance)]
        }
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq contaminant-filter",
            nativeTool: .bbduk,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "mode": .string(mode),
                "reference": .file(resolvedReferenceURL),
                "kmer": .integer(kmerSize),
                "hdist": .integer(hammingDistance),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "mode": .string("phix"),
                "reference": .null,
                "kmer": .integer(31),
                "hdist": .integer(1),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: [
                ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input)
            ] + provenanceRecords(for: resolvedReferenceURL, format: .fasta, role: .reference),
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Filtered reads written to \(output.output)\n".utf8))
    }
}

// MARK: - Primer Removal

enum FastqPrimerRemovalEngine: String, ExpressibleByArgument {
    case bbduk
    case cutadaptLinked = "cutadapt-linked"
}

struct FastqPrimerRemovalSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "primer-remove",
        abstract: "Remove primer sequences from FASTQ reads"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("literal"), help: "Primer sequence (IUPAC nucleotides)")
    var literalSequence: String?

    @Option(name: .customLong("ref"), help: "Primer reference FASTA file")
    var reference: String?

    @Option(name: .customLong("kmer"), help: "K-mer size (default: 23)")
    var kmerSize: Int = 23

    @Option(name: .customLong("mink"), help: "Minimum k-mer size (default: 11)")
    var minKmer: Int = 11

    @Option(name: .customLong("hdist"), help: "Hamming distance tolerance (default: 1)")
    var hammingDistance: Int = 1

    @Option(name: .customLong("engine"), help: "Primer trimming engine: bbduk or cutadapt-linked")
    var engine: FastqPrimerRemovalEngine = .bbduk

    @Option(name: .customLong("minimum-overlap"), help: "Minimum overlap for cutadapt-linked primer matching")
    var minimumOverlap: Int = 12

    @Option(name: .customLong("error-rate"), help: "Maximum error rate for cutadapt-linked primer matching")
    var errorRate: Double = 0.12

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        guard kmerSize > 0 else { throw ValidationError("--kmer must be > 0") }
        guard minKmer > 0 else { throw ValidationError("--mink must be > 0") }
        guard minKmer <= kmerSize else {
            throw ValidationError("--mink (\(minKmer)) must be <= --kmer (\(kmerSize))")
        }
        guard hammingDistance >= 0 else { throw ValidationError("--hdist must be >= 0") }
        guard minimumOverlap > 0 else { throw ValidationError("--minimum-overlap must be > 0") }
        guard errorRate >= 0.0, errorRate <= 1.0 else {
            throw ValidationError("--error-rate must be between 0 and 1")
        }
        let runner = NativeToolRunner.shared

        let startedAt = Date()
        let referenceURL = reference.map { URL(fileURLWithPath: $0) }
        let execution = try await nativePrimerRemovalExecution(
            inputURL: inputURL,
            outputPath: output.output,
            runner: runner
        )
        let result = execution.result
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "\(execution.tool.rawValue) primer removal failed: \(result.stderr)")
        }
        var cliArguments = ["primer-remove", inputURL.path]
        if let literalSequence {
            cliArguments += ["--literal", literalSequence]
        }
        if let reference {
            cliArguments += ["--ref", reference]
        }
        if engine != .bbduk {
            cliArguments += ["--engine", engine.rawValue]
        }
        if kmerSize != 23 {
            cliArguments += ["--kmer", String(kmerSize)]
        }
        if minKmer != 11 {
            cliArguments += ["--mink", String(minKmer)]
        }
        if hammingDistance != 1 {
            cliArguments += ["--hdist", String(hammingDistance)]
        }
        if engine == .cutadaptLinked || minimumOverlap != 12 {
            cliArguments += ["--minimum-overlap", String(minimumOverlap)]
        }
        if engine == .cutadaptLinked || errorRate != 0.12 {
            cliArguments += ["--error-rate", String(errorRate)]
        }
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq primer-remove",
            nativeTool: execution.tool,
            cliArguments: cliArguments,
            nativeArguments: execution.arguments,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "literal": literalSequence.map(ParameterValue.string) ?? .null,
                "reference": reference.map { .file(URL(fileURLWithPath: $0)) } ?? .null,
                "kmer": .integer(kmerSize),
                "mink": .integer(minKmer),
                "hdist": .integer(hammingDistance),
                "engine": .string(engine.rawValue),
                "minimumOverlap": .integer(minimumOverlap),
                "errorRate": .number(errorRate),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "literal": .null,
                "reference": .null,
                "kmer": .integer(23),
                "mink": .integer(11),
                "hdist": .integer(1),
                "engine": .string(FastqPrimerRemovalEngine.bbduk.rawValue),
                "minimumOverlap": .integer(12),
                "errorRate": .number(0.12),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: [
                ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input)
            ] + (referenceURL.map { provenanceRecords(for: $0, format: .fasta, role: .reference) } ?? []),
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Primer-trimmed reads written to \(output.output)\n".utf8))
    }

    private func nativePrimerRemovalExecution(
        inputURL: URL,
        outputPath: String,
        runner: NativeToolRunner
    ) async throws -> (tool: NativeTool, arguments: [String], result: NativeToolResult) {
        switch engine {
        case .bbduk:
            var args = [
                "in=\(inputURL.path)",
                "out=\(outputPath)",
                "ktrim=r",
                "k=\(kmerSize)",
                "mink=\(minKmer)",
                "hdist=\(hammingDistance)",
            ]

            if let literalSequence {
                args.append("literal=\(literalSequence)")
            } else if let reference {
                guard FileManager.default.fileExists(atPath: reference) else {
                    throw CLIError.inputFileNotFound(path: reference)
                }
                args.append("ref=\(reference)")
            } else {
                throw ValidationError("Specify --literal or --ref for primer sequence")
            }

            let env = await bbToolsEnvironment(runner: runner)
            let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
            return (.bbduk, args, result)

        case .cutadaptLinked:
            guard literalSequence == nil else {
                throw ValidationError("--engine cutadapt-linked requires --ref, not --literal")
            }
            guard let reference else {
                throw ValidationError("--engine cutadapt-linked requires --ref")
            }
            guard FileManager.default.fileExists(atPath: reference) else {
                throw CLIError.inputFileNotFound(path: reference)
            }
            let stagingDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-cutadapt-linked-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }

            let linkedPrimerURL = try await writeLinkedPrimerAdapters(
                from: URL(fileURLWithPath: reference),
                to: stagingDirectory.appendingPathComponent("linked-primers.fasta")
            )
            let args = [
                "-e", String(errorRate),
                "-O", String(minimumOverlap),
                "--discard-untrimmed",
                "-g", "file:\(linkedPrimerURL.path)",
                "-o", outputPath,
                inputURL.path,
            ]
            let result = try await runner.run(.cutadapt, arguments: args, timeout: 1800)
            return (.cutadapt, args, result)
        }
    }

    private func writeLinkedPrimerAdapters(from referenceURL: URL, to destinationURL: URL) async throws -> URL {
        let records = try await FASTAReader(url: referenceURL).readAll()
        var forwardByBase: [String: String] = [:]
        var reverseByBase: [String: String] = [:]

        for record in records {
            guard let parsed = parsePrimerPairName(record.name) else { continue }
            let sequence = record.asString().uppercased()
            switch parsed.role {
            case .forward:
                forwardByBase[parsed.base] = sequence
            case .reverse:
                reverseByBase[parsed.base] = sequence
            }
        }

        var contents = ""
        for base in forwardByBase.keys.sorted() {
            guard let forward = forwardByBase[base], let reverse = reverseByBase[base] else { continue }
            contents += ">\(base)_R_to_rcF\n\(reverse)...\(reverseComplement(forward))\n"
            contents += ">\(base)_F_to_rcR\n\(forward)...\(reverseComplement(reverse))\n"
        }

        guard !contents.isEmpty else {
            throw ValidationError(
                "No paired primers found in \(referenceURL.path). Expected FASTA headers ending in -F/-R or _F/_R."
            )
        }
        try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
        return destinationURL
    }

    private enum PrimerRole {
        case forward
        case reverse
    }

    private func parsePrimerPairName(_ name: String) -> (base: String, role: PrimerRole)? {
        let suffixes: [(String, PrimerRole)] = [
            ("-F", .forward), ("_F", .forward),
            ("-R", .reverse), ("_R", .reverse),
            ("-FORWARD", .forward), ("_FORWARD", .forward),
            ("-REVERSE", .reverse), ("_REVERSE", .reverse),
        ]
        let uppercasedName = name.uppercased()
        for (suffix, role) in suffixes {
            guard uppercasedName.hasSuffix(suffix) else { continue }
            let index = name.index(name.endIndex, offsetBy: -suffix.count)
            return (String(name[..<index]), role)
        }
        return nil
    }

    private func reverseComplement(_ sequence: String) -> String {
        let map: [Character: Character] = [
            "A": "T", "C": "G", "G": "C", "T": "A", "U": "A",
            "R": "Y", "Y": "R", "S": "S", "W": "W", "K": "M", "M": "K",
            "B": "V", "D": "H", "H": "D", "V": "B", "N": "N",
        ]
        return String(sequence.uppercased().reversed().map { map[$0] ?? "N" })
    }
}

// MARK: - Error Correction

struct FastqErrorCorrectSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "error-correct",
        abstract: "Correct sequencing errors using tadpole"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("kmer"), help: "K-mer size for correction (default: 50, max: 62)")
    var kmerSize: Int = 50

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        guard kmerSize > 0, kmerSize <= 62 else {
            throw ValidationError("K-mer size must be between 1 and 62")
        }
        let runner = NativeToolRunner.shared

        let args = [
            "in=\(inputURL.path)",
            "out=\(output.output)",
            "mode=correct",
            "ecc=t",
            "k=\(kmerSize)",
        ]

        let env = await bbToolsEnvironment(runner: runner)
        let startedAt = Date()
        let result = try await runner.run(.tadpole, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "tadpole error correction failed: \(result.stderr)")
        }
        var cliArguments = ["error-correct", inputURL.path]
        if kmerSize != 50 {
            cliArguments += ["--kmer", String(kmerSize)]
        }
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq error-correct",
            nativeTool: .tadpole,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "kmer": .integer(kmerSize),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "kmer": .integer(50),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Error-corrected reads written to \(output.output)\n".utf8))
    }
}

// MARK: - PE Merge

struct FastqMergeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge overlapping paired-end reads using bbmerge"
    )

    @Argument(help: "Input interleaved FASTQ file")
    var input: String

    @Option(name: .customLong("min-overlap"), help: "Minimum overlap (default: 12)")
    var minOverlap: Int = 12

    @Flag(name: .customLong("strict"), help: "Use strict merge mode")
    var strict: Bool = false

    @Flag(name: .customLong("count-duplicates"), help: "Collapse identical output sequences after merge and encode support as size=N")
    var countDuplicates: Bool = false

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        guard minOverlap > 0 else { throw ValidationError("--min-overlap must be > 0") }
        let runner = NativeToolRunner.shared

        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "bbmerge-",
            contextURL: URL(fileURLWithPath: output.output)
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mergedURL = tempDir.appendingPathComponent("merged.fastq")
        let unmergedURL = tempDir.appendingPathComponent("unmerged.fastq")

        var args = [
            "in=\(inputURL.path)",
            "out=\(mergedURL.path)",
            "outu=\(unmergedURL.path)",
            "minoverlap=\(minOverlap)",
        ]
        if strict { args.append("strict=t") }

        let env = await bbToolsEnvironment(runner: runner)
        let startedAt = Date()
        let result = try await runner.run(.bbmerge, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "bbmerge failed: \(result.stderr)")
        }

        let outputURL = URL(fileURLWithPath: output.output)
        var countedResult: CountedFASTQMaterializationResult?
        var gzipResult: FASTQGzipProvenanceResult?
        var concatenateWallTime: TimeInterval = 0
        if countDuplicates {
            let countedInputs = [mergedURL, unmergedURL].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            if countedInputs.isEmpty {
                countedResult = try CountedFASTQMaterializer().write(
                    counts: [:],
                    outputURL: outputURL,
                    compress: output.compress,
                    inputRecordCount: 0,
                    totalReadCount: 0
                )
            } else {
                countedResult = try await CountedFASTQMaterializer().materialize(
                    inputs: countedInputs,
                    outputURL: outputURL,
                    compress: output.compress,
                    normalization: .uppercase
                )
            }
        } else {
            // Concatenate merged + unmerged.
            let concatenateStartedAt = Date()
            let concatenatedURL = output.compress
                ? tempDir.appendingPathComponent("merged-and-unmerged.fastq")
                : outputURL
            FileManager.default.createFile(atPath: concatenatedURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: concatenatedURL)
            for url in [mergedURL, unmergedURL] {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let inputHandle = try FileHandle(forReadingFrom: url)
                defer { try? inputHandle.close() }
                while true {
                    let chunk = inputHandle.readData(ofLength: 1_048_576)
                    if chunk.isEmpty { break }
                    outputHandle.write(chunk)
                }
            }
            try outputHandle.close()
            concatenateWallTime = Date().timeIntervalSince(concatenateStartedAt)
            if output.compress {
                gzipResult = try gzipCompress(
                    sourceURL: concatenatedURL,
                    outputURL: outputURL
                )
            }
        }
        var cliArguments = ["merge", inputURL.path]
        if minOverlap != 12 {
            cliArguments += ["--min-overlap", String(minOverlap)]
        }
        if strict {
            cliArguments.append("--strict")
        }
        if countDuplicates {
            cliArguments.append("--count-duplicates")
        }
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let countedOutputRecords: ParameterValue = countedResult
            .map { ParameterValue.integer($0.uniqueSequenceCount) } ?? .string("not counted")
        let countedOutputReadCount: ParameterValue = countedResult
            .map { ParameterValue.integer($0.totalReadCount) } ?? .string("not counted")
        let provenanceParameters: [String: ParameterValue] = [
            "input": .file(inputURL),
            "output": .file(outputURL),
            "minOverlap": .integer(minOverlap),
            "strict": .boolean(strict),
            "countDuplicatesAfterMerge": .boolean(countDuplicates),
            "duplicateCountEncoding": .string(countDuplicates ? "size=N" : "none"),
            "countedOutputRecords": countedOutputRecords,
            "countedOutputReadCount": countedOutputReadCount,
            "force": .boolean(output.force),
            "compress": .boolean(output.compress)
        ]
        let provenanceDefaults: [String: ParameterValue] = [
            "minOverlap": .integer(12),
            "strict": .boolean(false),
            "countDuplicatesAfterMerge": .boolean(false),
            "duplicateCountEncoding": .string("none"),
            "force": .boolean(false),
            "compress": .boolean(false)
        ]
        if countDuplicates {
            guard let countedResult else {
                throw CLIError.conversionFailed(reason: "Counted merge did not produce an output for provenance recording")
            }
            try await recordFASTQCountedMergeProvenance(
                cliArguments: cliArguments,
                nativeArguments: args,
                bbmergeResult: result,
                inputURL: inputURL,
                bbmergeOutputURLs: [mergedURL, unmergedURL],
                countedResult: countedResult,
                finalOutputURL: outputURL,
                parameters: provenanceParameters,
                defaults: provenanceDefaults,
                startedAt: startedAt
            )
        } else {
            try await recordFASTQMergeProvenance(
                cliArguments: cliArguments,
                nativeArguments: args,
                bbmergeResult: result,
                gzipResult: gzipResult,
                inputURL: inputURL,
                bbmergeOutputURLs: [mergedURL, unmergedURL],
                finalOutputURL: outputURL,
                parameters: provenanceParameters,
                defaults: provenanceDefaults,
                concatenateWallTime: concatenateWallTime,
                startedAt: startedAt
            )
        }

        FileHandle.standardError.write(Data("Merged reads written to \(output.output)\n".utf8))
    }

    private func gzipCompress(sourceURL: URL, outputURL: URL) throws -> FASTQGzipProvenanceResult {
        try gzipCompressFASTQ(
            sourceURL: sourceURL,
            outputURL: outputURL,
            failureDescription: "merged FASTQ"
        )
    }
}

// MARK: - PE Repair

struct FastqRepairSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Repair desynchronized paired-end reads using repair.sh"
    )

    @Argument(help: "Input interleaved FASTQ file")
    var input: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let runner = NativeToolRunner.shared

        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "bbrepair-",
            contextURL: URL(fileURLWithPath: output.output)
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repairedURL = tempDir.appendingPathComponent("repaired.fastq")
        let singletonsURL = tempDir.appendingPathComponent("singletons.fastq")

        let args = [
            "in=\(inputURL.path)",
            "out=\(repairedURL.path)",
            "outs=\(singletonsURL.path)",
        ]

        let env = await bbToolsEnvironment(runner: runner)
        let startedAt = Date()
        let result = try await runner.run(.repair, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "repair.sh failed: \(result.stderr)")
        }

        // Concatenate repaired + singletons
        let outputURL = URL(fileURLWithPath: output.output)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        for url in [repairedURL, singletonsURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let inputHandle = try FileHandle(forReadingFrom: url)
            defer { try? inputHandle.close() }
            while true {
                let chunk = inputHandle.readData(ofLength: 1_048_576)
                if chunk.isEmpty { break }
                outputHandle.write(chunk)
            }
        }
        var cliArguments = ["repair", inputURL.path, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq repair",
            nativeTool: .repair,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )

        FileHandle.standardError.write(Data("Repaired reads written to \(output.output)\n".utf8))
    }
}

// MARK: - Deinterleave

struct FastqDeinterleaveSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deinterleave",
        abstract: "Split interleaved FASTQ into separate R1/R2 files"
    )

    @Argument(help: "Input interleaved FASTQ file")
    var input: String

    @Option(name: .customLong("out1"), help: "Output R1 file (required)")
    var out1: String

    @Option(name: .customLong("out2"), help: "Output R2 file (required)")
    var out2: String

    func run() async throws {
        let inputURL = try validateInput(input)
        let runner = NativeToolRunner.shared

        let args = [
            "in=\(inputURL.path)",
            "out1=\(out1)",
            "out2=\(out2)",
            "interleaved=t",
        ]

        let env = await bbToolsEnvironment(runner: runner)
        let startedAt = Date()
        let result = try await runner.run(.reformat, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "reformat.sh deinterleave failed: \(result.stderr)")
        }
        let out1URL = URL(fileURLWithPath: out1)
        let out2URL = URL(fileURLWithPath: out2)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq deinterleave",
            nativeTool: .reformat,
            cliArguments: ["deinterleave", inputURL.path, "--out1", out1, "--out2", out2],
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [out1URL, out2URL],
            parameters: [
                "input": .file(inputURL),
                "out1": .file(out1URL),
                "out2": .file(out2URL)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Deinterleaved: R1 → \(out1), R2 → \(out2)\n".utf8))
    }
}

// MARK: - Interleave

struct FastqInterleaveSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interleave",
        abstract: "Interleave separate R1/R2 files into one FASTQ"
    )

    @Option(name: .customLong("in1"), help: "Input R1 file (required)")
    var in1: String

    @Option(name: .customLong("in2"), help: "Input R2 file (required)")
    var in2: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        guard FileManager.default.fileExists(atPath: in1) else {
            throw CLIError.inputFileNotFound(path: in1)
        }
        guard FileManager.default.fileExists(atPath: in2) else {
            throw CLIError.inputFileNotFound(path: in2)
        }
        try output.validateOutput()
        let runner = NativeToolRunner.shared

        let args = [
            "in1=\(in1)",
            "in2=\(in2)",
            "out=\(output.output)",
        ]

        let env = await bbToolsEnvironment(runner: runner)
        let startedAt = Date()
        let result = try await runner.run(.reformat, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "reformat.sh interleave failed: \(result.stderr)")
        }
        let in1URL = URL(fileURLWithPath: in1)
        let in2URL = URL(fileURLWithPath: in2)
        let outputURL = URL(fileURLWithPath: output.output)
        var cliArguments = ["interleave", "--in1", in1, "--in2", in2, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq interleave",
            nativeTool: .reformat,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [in1URL, in2URL],
            outputURLs: [outputURL],
            parameters: [
                "in1": .file(in1URL),
                "in2": .file(in2URL),
                "output": .file(outputURL),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Interleaved reads written to \(output.output)\n".utf8))
    }
}

// MARK: - Deduplicate

struct FastqDeduplicateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deduplicate",
        abstract: "Remove duplicate reads using clumpify.sh (BBTools)"
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("subs"), help: "Substitution tolerance (0=exact, 2=default)")
    var substitutions: Int = 0

    @Flag(name: .customLong("optical"), help: "Optical duplicate mode (patterned flowcells)")
    var optical: Bool = false

    @Option(name: .customLong("dupedist"), help: "Pixel distance for optical duplicates (default: 40)")
    var opticalDistance: Int = 40

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let runner = NativeToolRunner.shared

        let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let heapGB = max(1, min(31, physicalMemoryGB * 80 / 100))
        var args = [
            "in=\(inputURL.path)",
            "out=\(output.output)",
            "-Xmx\(heapGB)g",
            "dedupe=t",
            "subs=\(substitutions)",
            "ow=t"
        ]
        if optical {
            args.append("optical=t")
            args.append("dupedist=\(opticalDistance)")
        }

        let startedAt = Date()
        let result = try await runner.run(.clumpify, arguments: args)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "clumpify deduplication failed: \(result.stderr)")
        }
        var cliArguments = ["deduplicate", inputURL.path]
        if substitutions != 0 {
            cliArguments += ["--subs", String(substitutions)]
        }
        if optical {
            cliArguments.append("--optical")
        }
        if opticalDistance != 40 {
            cliArguments += ["--dupedist", String(opticalDistance)]
        }
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq deduplicate",
            nativeTool: .clumpify,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "subs": .integer(substitutions),
                "optical": .boolean(optical),
                "dupedist": .integer(opticalDistance),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "subs": .integer(0),
                "optical": .boolean(false),
                "dupedist": .integer(40),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Deduplicated reads written to \(output.output)\n".utf8))
    }
}

// MARK: - Demultiplex

struct FastqDemultiplexSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "demultiplex",
        abstract: "Demultiplex reads by internal barcodes",
        discussion: """
            Splits multiplexed FASTQ reads into per-barcode output files using
            embedded cutadapt. Supports single- and dual-indexed Illumina kits,
            Fluidigm Access Array indexes, custom barcode definition files, and
            terminally anchored barcode location (5', 3', or both ends) for
            cutadapt demultiplexing.

            Useful for internal Illumina barcodes within ONT reads, re-demultiplexing,
            or demultiplexing with custom barcode sets.

            Built-in kits: \(barcodeKitIDsHelpText).

            Custom definitions can be CSV, TSV, or whitespace-delimited text:
              id,sequence[,secondary_sequence][,sample_name]
              FLD0001<TAB>GTATCGTCGT

            Engines:
              cutadapt    Established fuzzy adapter matcher; supports error rate and indels.
              exact-bare  Swift-native exact matching for bare A/C/G/T barcodes; scans whole reads,
                          searches reverse complements, and preserves reads.

            Examples:
              lungfish fastq demultiplex reads.fastq.gz --kit truseq-single-a -o demux-out/
              lungfish fastq demultiplex reads.fastq.gz --kit fluidigm-access-array -o demux-out/ --engine exact-bare
              lungfish fastq demultiplex reads.fastq.gz --kit custom.csv -o demux-out/ --location bothends
            """
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("kit"),
            help: .init(barcodeKitHelpText))
    var kit: String

    @Option(name: [.customLong("output"), .customShort("o")],
            help: "Output directory for per-barcode bundles")
    var output: String

    @Option(name: .customLong("location"),
            help: "Cutadapt barcode location: 5prime, 3prime, bothends (default: bothends)")
    var location: String = "bothends"

    @Option(name: .customLong("max-distance-5prime"),
            help: "Cutadapt max bases from 5' terminus where barcodes may start (default: 0)")
    var maxDistanceFrom5Prime: Int = 0

    @Option(name: .customLong("max-distance-3prime"),
            help: "Cutadapt max bases from 3' terminus where barcodes may end (default: 0)")
    var maxDistanceFrom3Prime: Int = 0

    @Option(name: .customLong("error-rate"),
            help: "Cutadapt maximum error rate for barcode matching (default: 0.15)")
    var errorRate: Double = 0.15

    @Option(name: .customLong("overlap"),
            help: "Cutadapt minimum overlap length (default: 3)")
    var overlap: Int = 3

    @Option(name: .customLong("engine"),
            help: "Demultiplexing engine: cutadapt or exact-bare (default: cutadapt)")
    var engine: String = DemultiplexEngine.cutadapt.rawValue

    @Flag(name: .customLong("no-trim"),
          help: "Cutadapt only: keep barcode sequences in output reads (exact-bare always preserves reads)")
    var noTrim: Bool = false

    @Flag(name: .customLong("discard-unassigned"),
          help: "Discard reads that do not match any barcode")
    var discardUnassigned: Bool = false

    @Option(name: .customLong("threads"),
            help: "Cutadapt thread count (default: 4)")
    var threads: Int = 4

    func run() async throws {
        guard errorRate >= 0 && errorRate <= 1 else {
            throw ValidationError("Error rate must be between 0 and 1 (got \(errorRate))")
        }
        guard maxDistanceFrom5Prime >= 0, maxDistanceFrom3Prime >= 0 else {
            throw ValidationError("Max barcode distances must be non-negative")
        }

        let inputURL = try validateInput(input)
        let outputURL = URL(fileURLWithPath: output)

        // Resolve barcode kit
        let resolvedKit = try resolveBarcodeKitArgument(kit)
        let barcodeKit = resolvedKit.definition
        let customKitURL = resolvedKit.customURL

        let sourceBundleURL = FASTQBundle.isBundleURL(inputURL) ? inputURL : nil
        let sourceManifest = sourceBundleURL.flatMap { FASTQBundle.loadDerivedManifest(in: $0) }
        let rootBundleURL = sourceBundleURL.flatMap { bundleURL -> URL? in
            guard let sourceManifest else { return nil }
            return FASTQBundle.resolveBundle(
                relativePath: sourceManifest.rootBundleRelativePath,
                from: bundleURL
            )
        }
        let rootFASTQFilename = sourceManifest?.rootFASTQFilename
        let inputPairingMode = sourceManifest?.pairingMode
            ?? sourceBundleURL
                .flatMap { FASTQBundle.resolvePrimaryFASTQURL(for: $0) }
                .flatMap { FASTQMetadataStore.load(for: $0)?.ingestion?.pairingMode }
        let inputSequenceFormat = sourceManifest?.sequenceFormat

        // Parse barcode location
        let barcodeLocation: BarcodeLocation
        switch location.lowercased() {
        case "5prime", "five-prime", "fiveprime": barcodeLocation = .fivePrime
        case "3prime", "three-prime", "threeprime": barcodeLocation = .threePrime
        case "bothends", "both", "both-ends", "both_ends": barcodeLocation = .bothEnds
        default:
            throw ValidationError("Invalid barcode location '\(location)'. Use: 5prime, 3prime, bothends")
        }

        let demultiplexEngine: DemultiplexEngine
        switch engine.lowercased() {
        case "cutadapt":
            demultiplexEngine = .cutadapt
        case "exact-bare", "exact-bare-barcode", "exactbare", "bare":
            demultiplexEngine = .exactBareBarcode
        default:
            throw ValidationError("Invalid demultiplexing engine '\(engine)'. Use: cutadapt or exact-bare")
        }
        let effectiveTrimBarcodes = demultiplexEngine == .exactBareBarcode ? false : !noTrim

        let config = DemultiplexConfig(
            inputURL: inputURL,
            sourceBundleURL: sourceBundleURL,
            barcodeKit: barcodeKit,
            outputDirectory: outputURL,
            barcodeLocation: barcodeLocation,
            errorRate: errorRate,
            minimumOverlap: overlap,
            maxDistanceFrom5Prime: maxDistanceFrom5Prime,
            maxDistanceFrom3Prime: maxDistanceFrom3Prime,
            trimBarcodes: effectiveTrimBarcodes,
            unassignedDisposition: discardUnassigned ? .discard : .keep,
            threads: threads,
            engine: demultiplexEngine,
            rootBundleURL: rootBundleURL,
            rootFASTQFilename: rootFASTQFilename,
            inputPairingMode: inputPairingMode,
            inputSequenceFormat: inputSequenceFormat
        )

        let pipeline = DemultiplexingPipeline()
        let startedAt = Date()
        let result = try await pipeline.run(config: config) { fraction, message in
            FileHandle.standardError.write(Data("[\(String(format: "%3.0f%%", fraction * 100))] \(message)\n".utf8))
        }
        var cliArguments = ["demultiplex", inputURL.path, "--kit", kit, "--output", output]
        if demultiplexEngine == .exactBareBarcode {
            cliArguments += ["--engine", demultiplexEngine.rawValue]
            if threads != 4 {
                cliArguments += ["--threads", String(threads)]
            }
        } else {
            if location != "bothends" {
                cliArguments += ["--location", location]
            }
            if maxDistanceFrom5Prime != 0 {
                cliArguments += ["--max-distance-5prime", String(maxDistanceFrom5Prime)]
            }
            if maxDistanceFrom3Prime != 0 {
                cliArguments += ["--max-distance-3prime", String(maxDistanceFrom3Prime)]
            }
            if errorRate != 0.15 {
                cliArguments += ["--error-rate", String(errorRate)]
            }
            if overlap != 3 {
                cliArguments += ["--overlap", String(overlap)]
            }
            if noTrim {
                cliArguments.append("--no-trim")
            }
            if threads != 4 {
                cliArguments += ["--threads", String(threads)]
            }
        }
        if discardUnassigned {
            cliArguments.append("--discard-unassigned")
        }
        let outputBundleURLs = result.outputBundleURLs
            + (result.unassignedBundleURL.map { [$0] } ?? [])
        let outputPayloads = outputBundleURLs
        .compactMap { FASTQBundle.resolvePrimaryFASTQURL(for: $0) }
        let manifestURL = outputURL.appendingPathComponent(DemultiplexManifest.filename)
        let outputRecords = [ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .output)]
            + outputPayloads.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) }
        let demultiplexToolName = result.manifest.parameters.tool
        let demultiplexToolVersion: String
        if demultiplexToolName == NativeTool.cutadapt.rawValue {
            demultiplexToolVersion = await NativeToolRunner.shared.getToolVersion(.cutadapt) ?? "unknown"
        } else {
            demultiplexToolVersion = LungfishCLI.configuration.version
        }
        let stepCommand = result.nativeCommand
            ?? result.manifest.parameters.commandLine?.split(separator: " ").map(String.init)
        let inputRecords = [ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input)]
            + (customKitURL.map { provenanceRecords(for: $0, format: .text, role: .reference) } ?? [])
        var provenanceParameters: [String: ParameterValue] = [
            "input": .file(inputURL),
            "kit": .string(kit),
            "resolvedKit": .string(barcodeKit.id),
            "customBarcodeKit": customKitURL.map(ParameterValue.file) ?? .null,
            "output": .file(outputURL),
            "engine": .string(demultiplexEngine.rawValue),
            "discardUnassigned": .boolean(discardUnassigned),
        ]
        var provenanceDefaults: [String: ParameterValue] = [
            "engine": .string(DemultiplexEngine.cutadapt.rawValue),
            "discardUnassigned": .boolean(false),
            "customBarcodeKit": .null,
        ]
        if demultiplexEngine == .exactBareBarcode {
            provenanceParameters["searchMode"] = .string("whole-read")
            provenanceParameters["searchReverseComplement"] = .boolean(true)
            provenanceParameters["trimBarcodes"] = .boolean(false)
            provenanceParameters["threads"] = .integer(threads)
            provenanceDefaults["searchMode"] = .string("whole-read")
            provenanceDefaults["searchReverseComplement"] = .boolean(true)
            provenanceDefaults["trimBarcodes"] = .boolean(false)
            provenanceDefaults["threads"] = .integer(4)
        } else {
            provenanceParameters["location"] = .string(location)
            provenanceParameters["resolvedLocation"] = .string(barcodeLocation.rawValue)
            provenanceParameters["maxDistanceFrom5Prime"] = .integer(maxDistanceFrom5Prime)
            provenanceParameters["maxDistanceFrom3Prime"] = .integer(maxDistanceFrom3Prime)
            provenanceParameters["errorRate"] = .number(errorRate)
            provenanceParameters["overlap"] = .integer(overlap)
            provenanceParameters["trimBarcodes"] = .boolean(effectiveTrimBarcodes)
            provenanceParameters["threads"] = .integer(threads)
            provenanceDefaults["location"] = .string("bothends")
            provenanceDefaults["maxDistanceFrom5Prime"] = .integer(0)
            provenanceDefaults["maxDistanceFrom3Prime"] = .integer(0)
            provenanceDefaults["errorRate"] = .number(0.15)
            provenanceDefaults["overlap"] = .integer(3)
            provenanceDefaults["trimBarcodes"] = .boolean(true)
            provenanceDefaults["threads"] = .integer(4)
        }

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq demultiplex",
            parameters: provenanceParameters,
            defaults: provenanceDefaults,
            toolName: demultiplexToolName,
            toolVersion: demultiplexToolVersion,
            command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            stepCommand: stepCommand,
            inputs: inputRecords,
            outputs: outputRecords,
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: outputURL
        )

        // Summary output
        FileHandle.standardError.write(Data("\n--- Demultiplexing Summary ---\n".utf8))
        FileHandle.standardError.write(Data("Kit: \(barcodeKit.displayName)\n".utf8))
        FileHandle.standardError.write(Data("Input reads: \(result.manifest.inputReadCount)\n".utf8))
        FileHandle.standardError.write(Data("Assigned: \(result.manifest.assignedReadCount) (\(String(format: "%.1f%%", result.manifest.assignmentRate * 100)))\n".utf8))
        FileHandle.standardError.write(Data("Unassigned: \(result.manifest.unassigned.readCount)\n".utf8))
        FileHandle.standardError.write(Data("Barcodes with reads: \(result.manifest.barcodes.filter { $0.readCount > 0 }.count)\n".utf8))
        FileHandle.standardError.write(Data("Output: \(output)\n".utf8))
        FileHandle.standardError.write(Data("Time: \(String(format: "%.1f", result.wallClockSeconds))s\n".utf8))

        for barcode in result.manifest.barcodes where barcode.readCount > 0 {
            FileHandle.standardError.write(Data("  \(barcode.displayName): \(barcode.readCount) reads\n".utf8))
        }
    }
}

// MARK: - ONT Fluidigm Sample Materialization

struct FastqONTFluidigmSamplesSubcommand: AsyncParsableCommand {
    private static let progressEmitLock = NSLock()

    static let configuration = CommandConfiguration(
        commandName: "ont-fluidigm-samples",
        abstract: "Materialize counted per-sample ONT Fluidigm amplicon FASTQs",
        discussion: """
            Assigns ONT reads to samples with the same exact Fluidigm barcode matching
            used by amplicon genotyping, extracts the CS1-CS2 amplicon insert, then
            writes one physical .lungfishfastq bundle per sample containing unique
            insert exemplars. Payloads are gzip-compressed and duplicate support is
            encoded in FASTQ headers as size=N.
            """
    )

    @Argument(help: "Input FASTQ file, directory, or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("barcodes"), help: "CSV/TSV file with sample and Fluidigm barcode sequence columns")
    var barcodes: String

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output directory for per-sample .lungfishfastq bundles")
    var output: String

    @Option(name: .customLong("threads"), help: "Worker count reserved for future parallel materialization; currently recorded for provenance")
    var threads: Int = 1

    @Option(name: .customLong("primer-mismatches"), help: "Maximum mismatches allowed when detecting CS1/CS2 primer boundaries (default: 2)")
    var primerMismatches: Int = 2

    @Option(name: .customLong("minimum-insert-length"), help: "Minimum CS1-CS2 insert length to retain (default: 20)")
    var minimumInsertLength: Int = 20

    @Flag(
        name: .customLong("canonicalize-reverse-complements"),
        inversion: .prefixedNo,
        help: "Canonicalize exact reverse-complement insert duplicates after orienting CS1-CS2 reads (default: disabled)"
    )
    var canonicalizeReverseComplements: Bool = false

    @Flag(name: .customLong("force"), help: "Replace an existing output directory")
    var force: Bool = false

    func run() async throws {
        guard threads > 0 else {
            throw ValidationError("--threads must be positive.")
        }
        guard primerMismatches >= 0 else {
            throw ValidationError("--primer-mismatches must be non-negative.")
        }
        guard minimumInsertLength > 0 else {
            throw ValidationError("--minimum-insert-length must be positive.")
        }

        let inputURL = URL(fileURLWithPath: input)
        let barcodeURL = URL(fileURLWithPath: barcodes)
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        let startedAt = Date()
        let request = ONTFluidigmAmpliconMaterializationRequest(
            inputURL: inputURL,
            barcodeDefinitionsURL: barcodeURL,
            outputDirectory: outputURL,
            primerMismatches: primerMismatches,
            minimumInsertLength: minimumInsertLength,
            canonicalizeReverseComplements: canonicalizeReverseComplements,
            force: force
        )
        let result = try await ONTFluidigmAmpliconMaterializer().run(request) { fraction, message in
            emitProgress(fraction, message)
        }

        var cliArguments = [
            "ont-fluidigm-samples",
            inputURL.path,
            "--barcodes", barcodeURL.path,
            "--output", outputURL.path,
            "--primer-mismatches", String(primerMismatches),
            "--minimum-insert-length", String(minimumInsertLength),
        ]
        if threads != 1 {
            cliArguments += ["--threads", String(threads)]
        }
        if !canonicalizeReverseComplements {
            cliArguments.append("--no-canonicalize-reverse-complements")
        }
        if force {
            cliArguments.append("--force")
        }

        let outputPayloads = result.outputBundleURLs
            .compactMap { FASTQBundle.resolvePrimaryFASTQURL(for: $0) }
        let outputs = [
            directoryOutputRecord(result.outputDirectory),
            ProvenanceRecorder.fileRecord(url: result.manifestURL, format: .json, role: .output),
        ] + result.outputBundleURLs.map {
            directoryOutputRecord($0)
        } + outputPayloads.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output)
        }
        let inputRecords = [
            ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input),
            ProvenanceRecorder.fileRecord(url: barcodeURL, format: .text, role: .input),
        ]
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq ont-fluidigm-samples",
            parameters: [
                "input": .file(inputURL),
                "barcodes": .file(barcodeURL),
                "output": .file(outputURL),
                "threads": .integer(threads),
                "force": .boolean(force),
                "forwardPrimer": .string(request.forwardPrimer),
                "reversePrimer": .string(request.reversePrimer),
                "primerMismatches": .integer(primerMismatches),
                "minimumInsertLength": .integer(minimumInsertLength),
                "canonicalizeReverseComplements": .boolean(canonicalizeReverseComplements),
                "payloadRepresentation": .string("deduplicated gzip-compressed CS1-CS2 insert FASTQ"),
                "duplicateCountEncoding": .string("size=N"),
                "inputReadCount": .integer(result.inputReadCount),
                "assignedReadCount": .integer(result.assignedReadCount),
                "extractedReadCount": .integer(result.extractedReadCount),
                "uniqueSequenceCount": .integer(result.uniqueSequenceCount),
                "unassignedReadCount": .integer(result.unassignedReadCount),
                "unextractedReadCount": .integer(result.unextractedReadCount),
            ],
            defaults: [
                "threads": .integer(1),
                "force": .boolean(false),
                "forwardPrimer": .string(ONTFluidigmAmpliconMaterializer.defaultForwardPrimer),
                "reversePrimer": .string(ONTFluidigmAmpliconMaterializer.defaultReversePrimer),
                "primerMismatches": .integer(2),
                "minimumInsertLength": .integer(20),
                "canonicalizeReverseComplements": .boolean(false),
                "payloadRepresentation": .string("deduplicated gzip-compressed CS1-CS2 insert FASTQ"),
                "duplicateCountEncoding": .string("size=N"),
            ],
            toolName: "lungfish fastq ont-fluidigm-samples",
            toolVersion: WorkflowRun.currentAppVersion,
            command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            stepCommand: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            inputs: inputRecords,
            outputs: outputs,
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: result.outputDirectory
        )

        let payload: [String: Any] = [
            "outputDirectory": result.outputDirectory.path,
            "manifest": result.manifestURL.path,
            "outputBundles": result.outputBundleURLs.map(\.path),
            "inputReadCount": result.inputReadCount,
            "assignedReadCount": result.assignedReadCount,
            "extractedReadCount": result.extractedReadCount,
            "uniqueSequenceCount": result.uniqueSequenceCount,
            "unassignedReadCount": result.unassignedReadCount,
            "unextractedReadCount": result.unextractedReadCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func directoryOutputRecord(_ url: URL) -> FileRecord {
        FileRecord(
            path: url.standardizedFileURL.path,
            sha256: nil,
            sizeBytes: nil,
            format: .unknown,
            role: .output
        )
    }

    private func emitProgress(_ fraction: Double, _ message: String) {
        let payload: [String: Any] = [
            "event": "progress",
            "operation": "ontFluidigmSamples",
            "progress": max(0, min(1, fraction)),
            "message": message,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(Data("\n".utf8))
        Self.progressEmitLock.lock()
        FileHandle.standardError.write(line)
        Self.progressEmitLock.unlock()
    }
}

// MARK: - ONT PacBio Barcode Pair Demultiplexing

struct FastqONTPacBioBarcodeDemuxSubcommand: AsyncParsableCommand {
    private static let progressEmitLock = NSLock()

    static let configuration = CommandConfiguration(
        commandName: "ont-pacbio-barcode-demux",
        abstract: "Demultiplex full-length MHC ONT amplicons with PacBio barcode pairs",
        discussion: """
            Validates a PacBio barcode-pair sample sheet, resolves built-in bc*
            barcode IDs, and writes one materialized .lungfishfastq bundle per
            sample. Barcode definitions must contain sample_id, barcode_1, and
            barcode_2 columns, or headerless rows in that order.
            """
    )

    @Argument(help: "Input ONT FASTQ file, barcode directory, run directory, or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("barcodes"), help: "CSV/TSV file with sample_id, barcode_1, and barcode_2 columns, or headerless rows in that order")
    var barcodes: String

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output directory for per-sample .lungfishfastq bundles")
    var output: String

    @Option(name: .customLong("threads"), help: "Compatibility option for legacy chunked demux paths (default: 1)")
    var threads: Int = 1

    @Option(name: .customLong("chunk-jobs"), help: "Compatibility option for legacy chunked demux paths (default: active cores)")
    var chunkJobs: Int = ONTPacBioBarcodeDemuxMaterializationRequest.defaultChunkJobs

    @Option(name: .customLong("max-reads-per-slice"), help: "Compatibility option for legacy chunked demux paths; 0 disables sub-slicing (default: 100000)")
    var maxReadsPerSlice: Int = 100_000

    @Option(name: .customLong("max-bytes-per-cutadapt"), help: "Compatibility option for legacy chunked demux paths (default: 536870912)")
    var maxBytesPerCutadapt: Int64 = 512 * 1024 * 1024

    @Flag(name: .customLong("force"), help: "Replace an existing output directory")
    var force: Bool = false

    func run() async throws {
        guard threads > 0 else {
            throw ValidationError("--threads must be positive.")
        }
        guard chunkJobs > 0 else {
            throw ValidationError("--chunk-jobs must be positive.")
        }
        guard maxReadsPerSlice >= 0 else {
            throw ValidationError("--max-reads-per-slice must be non-negative.")
        }
        guard maxBytesPerCutadapt > 0 else {
            throw ValidationError("--max-bytes-per-cutadapt must be positive.")
        }

        let inputURL = URL(fileURLWithPath: input)
        let barcodeURL = URL(fileURLWithPath: barcodes)
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        let startedAt = Date()
        let request = ONTPacBioBarcodeDemuxMaterializationRequest(
            inputURL: inputURL,
            barcodeDefinitionsURL: barcodeURL,
            outputDirectory: outputURL,
            force: force,
            threads: threads,
            chunkJobs: chunkJobs,
            maxReadsPerSlice: maxReadsPerSlice,
            maxInputBytesPerCutadapt: maxBytesPerCutadapt
        )
        let result = try await ONTPacBioBarcodeDemuxMaterializer().run(request) { fraction, message in
            emitProgress(fraction, message)
        }

        var cliArguments = [
            "ont-pacbio-barcode-demux",
            inputURL.path,
            "--barcodes", barcodeURL.path,
            "--output", outputURL.path,
            "--threads", String(threads),
            "--chunk-jobs", String(chunkJobs),
            "--max-reads-per-slice", String(maxReadsPerSlice),
            "--max-bytes-per-cutadapt", String(maxBytesPerCutadapt),
        ]
        if force {
            cliArguments.append("--force")
        }

        let resolvedInputFASTQs = (try? ONTBarcodeDemuxGenotypingPipeline.resolveInputFASTQURLs(for: inputURL)) ?? [inputURL]
        let outputPayloads = result.outputBundleURLs
            .compactMap { FASTQBundle.resolvePrimaryFASTQURL(for: $0) }
        let inputs = resolvedInputFASTQs.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
        } + [
            ProvenanceRecorder.fileRecord(url: barcodeURL, format: .text, role: .input),
        ]
        let outputs = Self.provenanceOutputRecords(
            outputDirectory: result.outputDirectory,
            manifestURL: result.manifestURL,
            outputBundleURLs: result.outputBundleURLs,
            outputPayloads: outputPayloads
        )

        let cutadaptArgv = result.cutadaptRuns
            .map { $0.argv.joined(separator: " ") }
            .joined(separator: "\n")
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq ont-pacbio-barcode-demux",
            parameters: [
                "input": .file(inputURL),
                "barcodes": .file(barcodeURL),
                "output": .file(outputURL),
                "threads": .integer(threads),
                "chunkJobs": .integer(chunkJobs),
                "effectiveChunkJobs": .integer(result.chunkJobs),
                "force": .boolean(force),
                "maxReadsPerSlice": .integer(maxReadsPerSlice),
                "maxBytesPerCutadapt": .integer(Int(maxBytesPerCutadapt)),
                "inputChunkCount": .integer(result.inputChunkCount),
                "executedCutadaptChunkCount": .integer(result.executedCutadaptChunkCount),
                "inputReadCount": .integer(result.inputReadCount),
                "assignedReadCount": .integer(result.assignedReadCount),
                "unassignedReadCount": .integer(result.unassignedReadCount),
                "payloadRepresentation": .string("gzip-compressed full demultiplexed FASTQ"),
                "cutadaptCommands": .string(cutadaptArgv),
            ],
            defaults: [
                "threads": .integer(1),
                "chunkJobs": .integer(ONTPacBioBarcodeDemuxMaterializationRequest.defaultChunkJobs),
                "force": .boolean(false),
                "maxReadsPerSlice": .integer(100_000),
                "maxBytesPerCutadapt": .integer(512 * 1024 * 1024),
                "payloadRepresentation": .string("gzip-compressed full demultiplexed FASTQ"),
            ],
            toolName: "lungfish fastq ont-pacbio-barcode-demux",
            toolVersion: WorkflowRun.currentAppVersion,
            command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            stepCommand: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            inputs: inputs,
            outputs: outputs,
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: result.outputDirectory
        )

        let payload: [String: Any] = [
            "outputDirectory": result.outputDirectory.path,
            "manifest": result.manifestURL.path,
            "outputBundles": result.outputBundleURLs.map(\.path),
            "inputChunkCount": result.inputChunkCount,
            "executedCutadaptChunkCount": result.executedCutadaptChunkCount,
            "chunkJobs": result.chunkJobs,
            "inputReadCount": result.inputReadCount,
            "assignedReadCount": result.assignedReadCount,
            "unassignedReadCount": result.unassignedReadCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func emitProgress(_ fraction: Double, _ message: String) {
        let payload: [String: Any] = [
            "event": "progress",
            "operation": "ontPacBioBarcodeDemux",
            "progress": max(0, min(1, fraction)),
            "message": message,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(Data("\n".utf8))
        Self.progressEmitLock.lock()
        FileHandle.standardError.write(line)
        Self.progressEmitLock.unlock()
    }

    static func provenanceOutputRecords(
        outputDirectory: URL,
        manifestURL: URL,
        outputBundleURLs: [URL],
        outputPayloads: [URL]
    ) -> [FileRecord] {
        [
            ProvenanceRecorder.fileOrDirectoryRecord(url: outputDirectory, format: .unknown, role: .output),
            ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .output),
        ] + outputBundleURLs.map {
            ProvenanceRecorder.fileOrDirectoryRecord(url: $0, format: .unknown, role: .output)
        } + outputPayloads.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output)
        }
    }
}

struct FastqScoutSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scout",
        abstract: "Scout barcode assignments before FASTQ demultiplexing",
        discussion: """
            Scans a subset of reads against a barcode kit and writes a
            scout-result.json file with per-barcode hit counts and suggested
            accept/reject dispositions.
            """
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("kit"), help: .init(barcodeKitHelpText))
    var kit: String

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output scout-result.json path")
    var output: String

    @Option(name: .customLong("read-limit"), help: "Maximum reads to scan (default: 10000)")
    var readLimit: Int = 10_000

    @Option(name: .customLong("accept-threshold"), help: "Minimum hits to auto-accept a barcode (default: 10)")
    var acceptThreshold: Int = 10

    @Option(name: .customLong("reject-threshold"), help: "Maximum hits to auto-reject a barcode (default: 3)")
    var rejectThreshold: Int = 3

    @Option(name: .customLong("error-rate"), help: "Override barcode matching error rate")
    var errorRate: Double?

    @Option(name: .customLong("overlap"), help: "Override minimum barcode overlap")
    var overlap: Int?

    @Option(name: .customLong("source-platform"), help: "Source platform: illumina, ont, pacbio, element, ultima, mgi")
    var sourcePlatform: String?

    @Flag(name: .customLong("no-indels"), help: "Disallow indels in barcode matching")
    var useNoIndels: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        guard readLimit > 0 else {
            throw ValidationError("--read-limit must be greater than zero")
        }
        guard acceptThreshold >= 0, rejectThreshold >= 0 else {
            throw ValidationError("Scout thresholds must be non-negative")
        }
        if let errorRate {
            guard errorRate >= 0 && errorRate <= 1 else {
                throw ValidationError("--error-rate must be between 0 and 1")
            }
        }
        if let overlap {
            guard overlap > 0 else {
                throw ValidationError("--overlap must be greater than zero")
            }
        }

        let inputURL = try validateInput(input)
        let outputURL = URL(fileURLWithPath: output)
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let resolvedKit = try resolveBarcodeKitArgument(kit)
        let resolvedSourcePlatform: LungfishIO.SequencingPlatform?
        if let sourcePlatform {
            let parsed = LungfishIO.SequencingPlatform(vendor: sourcePlatform)
            guard parsed != .unknown else {
                throw ValidationError("Unknown source platform '\(sourcePlatform)'")
            }
            resolvedSourcePlatform = parsed
        } else {
            resolvedSourcePlatform = nil
        }

        let pipeline = DemultiplexingPipeline()
        let startedAt = Date()
        let result = try await pipeline.scout(
            inputURL: inputURL,
            kit: resolvedKit.definition,
            sourcePlatform: resolvedSourcePlatform,
            errorRate: errorRate,
            minimumOverlap: overlap,
            useNoIndels: useNoIndels,
            readLimit: readLimit,
            acceptThreshold: acceptThreshold,
            rejectThreshold: rejectThreshold
        ) { fraction, message in
            guard !globalOptions.quiet else { return }
            FileHandle.standardError.write(Data("[\(String(format: "%3.0f%%", fraction * 100))] \(message)\n".utf8))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outputURL, options: .atomic)

        var command = [
            CLICommandIdentity.executableName, "fastq", "scout",
            inputURL.path,
            "--kit", kit,
            "--output", outputURL.path,
        ]
        if readLimit != 10_000 {
            command += ["--read-limit", String(readLimit)]
        }
        if acceptThreshold != 10 {
            command += ["--accept-threshold", String(acceptThreshold)]
        }
        if rejectThreshold != 3 {
            command += ["--reject-threshold", String(rejectThreshold)]
        }
        if let errorRate {
            command += ["--error-rate", String(errorRate)]
        }
        if let overlap {
            command += ["--overlap", String(overlap)]
        }
        if let sourcePlatform {
            command += ["--source-platform", sourcePlatform]
        }
        if useNoIndels {
            command.append("--no-indels")
        }

        var inputRecords = [ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input)]
        if let customURL = resolvedKit.customURL {
            inputRecords += provenanceRecords(for: customURL, format: .text, role: .reference)
        }
        let customBarcodeKitParameter: ParameterValue = resolvedKit.customURL.map { .file($0) } ?? .null
        let errorRateParameter: ParameterValue = errorRate.map { .number($0) } ?? .null
        let overlapParameter: ParameterValue = overlap.map { .integer($0) } ?? .null
        let sourcePlatformParameter: ParameterValue = sourcePlatform.map { .string($0) } ?? .null
        let resolvedSourcePlatformParameter: ParameterValue = resolvedSourcePlatform.map { .string($0.rawValue) } ?? .null
        let parameters: [String: ParameterValue] = [
            "input": .file(inputURL),
            "kit": .string(kit),
            "resolvedKit": .string(resolvedKit.definition.id),
            "customBarcodeKit": customBarcodeKitParameter,
            "output": .file(outputURL),
            "readLimit": .integer(readLimit),
            "acceptThreshold": .integer(acceptThreshold),
            "rejectThreshold": .integer(rejectThreshold),
            "errorRate": errorRateParameter,
            "overlap": overlapParameter,
            "sourcePlatform": sourcePlatformParameter,
            "resolvedSourcePlatform": resolvedSourcePlatformParameter,
            "noIndels": .boolean(useNoIndels),
        ]
        let defaults: [String: ParameterValue] = [
            "readLimit": .integer(10_000),
            "acceptThreshold": .integer(10),
            "rejectThreshold": .integer(3),
            "errorRate": .null,
            "overlap": .null,
            "sourcePlatform": .null,
            "noIndels": .boolean(false),
        ]
        let outputRecords = [
            ProvenanceRecorder.fileRecord(url: outputURL, format: .json, role: .output),
        ]
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq scout",
            parameters: parameters,
            defaults: defaults,
            toolName: "lungfish fastq scout",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: inputRecords,
            outputs: outputRecords,
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: outputDirectory
        )

        if !globalOptions.quiet {
            FileHandle.standardError.write(Data("\n--- Barcode Scout Summary ---\n".utf8))
            FileHandle.standardError.write(Data("Kit: \(resolvedKit.definition.displayName)\n".utf8))
            FileHandle.standardError.write(Data("Reads scanned: \(result.readsScanned)\n".utf8))
            FileHandle.standardError.write(Data("Assigned: \(result.readsScanned - result.unassignedCount) (\(String(format: "%.1f%%", result.assignmentRate * 100)))\n".utf8))
            FileHandle.standardError.write(Data("Accepted barcodes: \(result.acceptedCount)\n".utf8))
            FileHandle.standardError.write(Data("Output: \(outputURL.path)\n".utf8))
        }
    }
}

// MARK: - Import ONT

struct FastqImportONTSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-ont",
        abstract: "Import ONT output directory into per-barcode bundles",
        discussion: """
            Imports Oxford Nanopore sequencing output directories into per-barcode
            .lungfishfastq bundles. Concatenates chunked FASTQ files within each
            barcode directory and generates a demultiplex manifest.

            Accepts either a fastq_pass/ parent directory or a single barcode
            directory (e.g., fastq_pass/barcode01/).

            Examples:
              lungfish fastq import-ont fastq_pass/ -o imported/
              lungfish fastq import-ont fastq_pass/barcode13/ -o imported/
              lungfish fastq import-ont fastq_pass/ -o imported/ --include-unclassified
            """
    )

    @Argument(help: "ONT output directory (fastq_pass/ or single barcode directory)")
    var input: String

    @Option(name: [.customLong("output"), .customShort("o")],
            help: "Output directory for .lungfishfastq bundles")
    var output: String

    @Flag(name: .customLong("include-unclassified"),
          help: "Include unclassified reads (default: skip)")
    var includeUnclassified: Bool = false

    @Option(name: .customLong("concurrency"),
            help: "Max concurrent barcode imports (default: 4)")
    var concurrency: Int = 4

    @Option(name: .customLong("storage-mode"),
            help: "How to store ONT chunks inside each bundle: chunked or flattened (default: chunked)")
    var storageMode: ONTImportStorageMode = .chunked

    @Flag(name: .customLong("optimize-storage"),
          help: "Run clumpify on flattened per-barcode FASTQ payloads to improve compression")
    var optimizeStorage: Bool = false

    @Option(name: .customLong("quality-binning"),
            help: "Quality binning for --optimize-storage: none, illumina4, or eightLevel (default: none)")
    var qualityBinning: QualityBinningScheme = .none

    func run() async throws {
        guard concurrency >= 1 else {
            throw ValidationError("Concurrency must be at least 1 (got \(concurrency))")
        }
        if optimizeStorage && storageMode != .flattened {
            throw ValidationError("--optimize-storage requires --storage-mode flattened")
        }

        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw CLIError.inputFileNotFound(path: input)
        }

        let cliArguments = cliArguments(inputURL: inputURL, outputURL: outputURL)
        let argv = [CLICommandIdentity.executableName, "fastq"] + cliArguments
        if FASTQBundle.isBundleURL(inputURL) {
            let destinationBundleURL = FASTQBundleCopyImportWorkflow.resolvedDestinationBundleURL(
                outputURL: outputURL,
                sourceBundleURL: inputURL
            )
            FileHandle.standardError.write(Data("Detected existing FASTQ bundle; copying atomically\n".utf8))
            let workflow = FASTQBundleCopyImportWorkflow()
            let result = try workflow.importBundle(
                sourceBundleURL: inputURL,
                outputURL: outputURL,
                context: FASTQBundleCopyImportWorkflow.CommandContext(
                    workflowName: "lungfish fastq import-ont",
                    workflowVersion: WorkflowRun.currentAppVersion,
                    toolName: "lungfish fastq import-ont",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: argv,
                    durableReplayArgv: argv,
                    reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
                    explicitOptions: [
                        "input": .file(inputURL),
                        "output": .file(outputURL),
                        "includeUnclassified": .boolean(includeUnclassified),
                        "concurrency": .integer(concurrency),
                        "storageMode": .string(storageMode.rawValue),
                        "optimizeStorage": .boolean(optimizeStorage),
                        "qualityBinning": .string(qualityBinning.rawValue)
                    ],
                    defaultOptions: [
                        "includeUnclassified": .boolean(false),
                        "concurrency": .integer(4),
                        "storageMode": .string(ONTImportStorageMode.chunked.rawValue),
                        "optimizeStorage": .boolean(false),
                        "qualityBinning": .string(QualityBinningScheme.none.rawValue),
                        "sourceKind": .string("raw-ont-directory")
                    ],
                    resolvedOptions: [
                        "input": .file(inputURL),
                        "output": .file(outputURL),
                        "destinationBundle": .file(destinationBundleURL),
                        "includeUnclassified": .boolean(includeUnclassified),
                        "concurrency": .integer(concurrency),
                        "storageMode": .string(storageMode.rawValue),
                        "optimizeStorage": .boolean(optimizeStorage),
                        "qualityBinning": .string(qualityBinning.rawValue),
                        "sourceKind": .string("existing-fastq-bundle"),
                        "copyMode": .string("atomic-bundle-copy"),
                        "caller": .string("cli")
                    ],
                    runtimeIdentity: ProvenanceRuntimeIdentity()
                )
            )

            FileHandle.standardError.write(Data("\n--- ONT Import Summary ---\n".utf8))
            FileHandle.standardError.write(Data("Source: existing FASTQ bundle\n".utf8))
            FileHandle.standardError.write(Data("Bundle: \(result.bundleURL.lastPathComponent)\n".utf8))
            FileHandle.standardError.write(Data("Files copied: \(result.copiedFileCount)\n".utf8))
            FileHandle.standardError.write(Data("Bytes copied: \(result.totalCopiedBytes)\n".utf8))
            FileHandle.standardError.write(Data("Output: \(result.bundleURL.path)\n".utf8))
            FileHandle.standardError.write(Data("Time: \(String(format: "%.1f", result.wallClockSeconds))s\n".utf8))
            return
        }

        let importer = ONTDirectoryImporter()

        // Detect layout first
        let layout = try importer.detectLayout(at: inputURL)
        FileHandle.standardError.write(Data("Detected \(layout.barcodeDirectories.count) barcode directories, \(layout.totalChunkCount) chunks\n".utf8))

        let config = ONTImportConfig(
            sourceDirectory: inputURL,
            outputDirectory: outputURL,
            maxConcurrentBarcodes: concurrency,
            includeUnclassified: includeUnclassified,
            storageMode: storageMode
        )

        let workflow = ONTImportWorkflow()
        let workflowResult = try await workflow.importDirectory(
            config: config,
            context: ONTImportWorkflow.CommandContext(
                caller: .cli,
                workflowName: "lungfish fastq import-ont",
                workflowVersion: WorkflowRun.currentAppVersion,
                toolName: "lungfish fastq import-ont",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: argv,
                durableReplayArgv: argv,
                reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
                explicitOptions: [
                    "input": .file(inputURL),
                    "output": .file(outputURL),
                    "includeUnclassified": .boolean(includeUnclassified),
                    "concurrency": .integer(concurrency),
                    "storageMode": .string(storageMode.rawValue),
                    "optimizeStorage": .boolean(optimizeStorage),
                    "qualityBinning": .string(qualityBinning.rawValue)
                ],
                defaultOptions: [
                    "includeUnclassified": .boolean(false),
                    "concurrency": .integer(4),
                    "storageMode": .string(ONTImportStorageMode.chunked.rawValue),
                    "optimizeStorage": .boolean(false),
                    "qualityBinning": .string(QualityBinningScheme.none.rawValue),
                    "useVirtualConcatenation": .boolean(true)
                ],
                resolvedOptions: [
                    "input": .file(inputURL),
                    "output": .file(outputURL),
                    "includeUnclassified": .boolean(includeUnclassified),
                    "concurrency": .integer(concurrency),
                    "storageMode": .string(storageMode.rawValue),
                    "optimizeStorage": .boolean(optimizeStorage),
                    "qualityBinning": .string(qualityBinning.rawValue),
                    "useVirtualConcatenation": .boolean(storageMode.usesVirtualConcatenation),
                    "caller": .string("cli"),
                    "barcodeDirectoryCount": .integer(layout.barcodeDirectories.count),
                    "chunkCount": .integer(layout.totalChunkCount)
                ],
                runtimeIdentity: ProvenanceRuntimeIdentity()
            ),
            optimization: ONTImportWorkflow.OptimizationConfig(
                optimizeStorage: optimizeStorage,
                qualityBinning: qualityBinning,
                threads: concurrency
            )
        ) { fraction, message in
            FileHandle.standardError.write(Data("[\(String(format: "%3.0f%%", fraction * 100))] \(message)\n".utf8))
        }
        let result = workflowResult.importResult

        // Summary output
        FileHandle.standardError.write(Data("\n--- ONT Import Summary ---\n".utf8))
        if let flowCell = result.flowCellID {
            FileHandle.standardError.write(Data("Flow Cell: \(flowCell)\n".utf8))
        }
        if let sample = result.sampleID {
            FileHandle.standardError.write(Data("Sample: \(sample)\n".utf8))
        }
        if let model = result.basecallModel {
            FileHandle.standardError.write(Data("Basecall Model: \(model)\n".utf8))
        }
        FileHandle.standardError.write(Data("Barcodes: \(result.bundleURLs.count)\n".utf8))
        FileHandle.standardError.write(Data("Total reads: \(result.totalReadCount)\n".utf8))
        FileHandle.standardError.write(Data("Output: \(output)\n".utf8))
        FileHandle.standardError.write(Data("Time: \(String(format: "%.1f", result.wallClockSeconds))s\n".utf8))

        for barcode in result.manifest.barcodes {
            FileHandle.standardError.write(Data("  \(barcode.barcodeID): \(barcode.readCount) reads\n".utf8))
        }
    }

    private func cliArguments(inputURL: URL, outputURL: URL) -> [String] {
        var cliArguments = ["import-ont", inputURL.path, "--output", outputURL.path]
        if includeUnclassified {
            cliArguments.append("--include-unclassified")
        }
        if concurrency != 4 {
            cliArguments += ["--concurrency", String(concurrency)]
        }
        if storageMode != .chunked {
            cliArguments += ["--storage-mode", storageMode.rawValue]
        }
        if optimizeStorage {
            cliArguments.append("--optimize-storage")
        }
        if qualityBinning != .none {
            cliArguments += ["--quality-binning", qualityBinning.rawValue]
        }
        return cliArguments
    }
}
