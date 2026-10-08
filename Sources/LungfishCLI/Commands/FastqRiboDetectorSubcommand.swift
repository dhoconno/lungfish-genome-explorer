import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct RiboDetectorOutputPlan: Sendable, Equatable {
    let nonRRNAOutputURLs: [URL]
    let rRNAOutputURLs: [URL]?
    let retainedOutputURLs: [URL]
    let removeNonRRNAOutputsAfterRun: Bool
}

/// One retained output that RiboDetector wrote as R1/R2 and that is joined
/// back into a single interleaved file at the planned path.
struct RiboDetectorPairJoin: Sendable, Equatable {
    let r1: URL
    let r2: URL
    let output: URL
}

/// How RiboDetector is invoked for a strictly interleaved input: the tool
/// sees split R1/R2 files and writes R1/R2 outputs under `scratch`; each
/// retained class is interleaved again at its planned path.
struct RiboDetectorPairedInvocationPlan: Sendable, Equatable {
    let toolPlan: RiboDetectorOutputPlan
    let joins: [RiboDetectorPairJoin]
}

/// Runs `ribodetector_cpu`; replaced by tests that fake the tool.
protocol RiboDetectorToolRunning: Sendable {
    func run(arguments: [String], workingDirectory: URL) async throws -> (stdout: String, stderr: String, exitCode: Int32)
    func detectVersion() async -> String
}

struct CondaRiboDetectorToolRunner: RiboDetectorToolRunning {
    func run(arguments: [String], workingDirectory: URL) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await CondaManager.shared.runTool(
            name: "ribodetector_cpu",
            arguments: arguments,
            environment: "ribodetector",
            workingDirectory: workingDirectory,
            timeout: 7200
        )
    }

    func detectVersion() async -> String {
        await CLIProvenanceSupport.detectCondaToolVersion(
            toolName: "ribodetector_cpu",
            environment: "ribodetector",
            flags: ["--version", "-h", "--help"],
            fallback: "0.3.3"
        )
    }
}

struct FastqRiboDetectorSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ribodetector",
        abstract: "Detect and remove ribosomal RNA sequences with RiboDetector CPU mode"
    )

    nonisolated(unsafe) static var toolRunner: RiboDetectorToolRunning = CondaRiboDetectorToolRunner()

    @Argument(help: "Input FASTA/FASTQ file or .lungfishfastq bundle, or paired R1/R2 FASTQ files")
    var inputs: [String]

    @Option(name: .customLong("retain"), help: "Read classes to retain: norrna, rrna, or both")
    var retain: String = FASTQRiboDetectorRetention.nonRRNA.rawValue

    @Option(name: .customLong("ensure"), help: "RiboDetector assurance mode: rrna, norrna, both, or none")
    var ensure: String = FASTQRiboDetectorEnsure.rrna.rawValue

    @Option(name: .customLong("read-length"), help: "Mean sequencing read length. Inferred from input when omitted.")
    var readLength: Int?

    @OptionGroup var globalOptions: GlobalOptions

    var threads: Int? { globalOptions.threads }

    @OptionGroup var pairing: FASTQPairingOptions

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output directory")
    var outputDirectory: String

    func run() async throws {
        guard !inputs.isEmpty, inputs.count <= 2 else {
            throw ValidationError("RiboDetector requires one input file or one paired-end R1/R2 input pair.")
        }
        let outputDirectoryURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        // A bundle is read as its reads, resolved the way the dialog resolves
        // it, and the outputs are named after the bundle (R3, lane 1x).
        let resolvedInputs = try await FASTQSubcommandInput.resolve(inputs, operationName: "ribodetector", contextURL: outputDirectoryURL)
        defer { resolvedInputs.cleanup() }
        let inputURLs = try validateInputs(resolvedInputs)
        let originalInputURLs = resolvedInputs.map(\.originalURL)

        let retention = try parsedRetention(retain)
        let ensureMode = try parsedEnsure(ensure)

        // One interleaved file is split into R1/R2 for RiboDetector, which
        // then classifies each fragment from both mates and keeps or drops
        // them together (`-e` settles a discordant pair), and every retained
        // class is joined back into one interleaved file at its planned
        // path. Handed the interleaved file directly, RiboDetector judges
        // each record alone and orphans the surviving mate. A file that
        // mixes merged reads with pairs runs as single reads: the split
        // pairs by position and would mis-pair it.
        let pairingDecision: FASTQPairingDecision?
        if inputURLs.count == 1 {
            pairingDecision = pairing.resolvePairing(inputURL: inputURLs[0], metadataFrom: resolvedInputs[0].pairingMetadataURL)
        } else {
            guard pairing.pairing != .interleaved else {
                throw ValidationError("--pairing interleaved applies to one interleaved input; R1/R2 inputs are already paired.")
            }
            pairingDecision = nil
        }
        let isInterleaved = pairingDecision?.pairAware ?? false

        let effectiveReadLength = try await resolvedReadLength(for: inputURLs[0])
        let effectiveThreads = max(1, threads ?? ProcessInfo.processInfo.activeProcessorCount)
        let outputs = try Self.plannedOutputs(
            inputURLs: inputURLs,
            namedAfter: originalInputURLs,
            outputDirectory: outputDirectoryURL,
            retention: retention
        )

        let scratchDirectory = outputDirectoryURL.appendingPathComponent(
            ".ribodetector-pairs-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        var toolInputURLs = inputURLs
        var toolPlan = outputs
        var joins: [RiboDetectorPairJoin] = []
        var splitPairs: Int?
        if isInterleaved {
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
            let stem = Self.sequenceStem(for: inputURLs[0])
            let inputR1 = scratchDirectory.appendingPathComponent("\(stem).input.R1.fastq")
            let inputR2 = scratchDirectory.appendingPathComponent("\(stem).input.R2.fastq")
            let counts = try await Self.deinterleave(inputURLs[0], r1: inputR1, r2: inputR2)
            splitPairs = counts.r1Records
            toolInputURLs = [inputR1, inputR2]
            let paired = Self.pairedInvocationPlan(for: outputs, scratchDirectory: scratchDirectory)
            toolPlan = paired.toolPlan
            joins = paired.joins
        }

        var arguments = [
            "-t", "\(effectiveThreads)",
            "-l", "\(effectiveReadLength)",
            "-i",
        ]
        arguments += toolInputURLs.map(\.path)
        arguments += [
            "-e", ensureMode.rawValue,
            "-o",
        ]
        arguments += toolPlan.nonRRNAOutputURLs.map(\.path)
        if let rRNAOutputURLs = toolPlan.rRNAOutputURLs {
            arguments += ["-r"] + rRNAOutputURLs.map(\.path)
        }

        let provenanceCommand = CLIProvenanceSupport.condaCommand(
            toolName: "ribodetector_cpu",
            environment: "ribodetector",
            arguments: arguments
        )
        let toolVersion = await Self.toolRunner.detectVersion()
        let runClock = ProvenanceRunClock()
        let result = try await Self.toolRunner.run(arguments: arguments, workingDirectory: outputDirectoryURL)
        var wallTime = runClock.elapsed
        guard result.exitCode == 0 else {
            try? await recordProvenance(
                inputURLs: inputURLs,
                originalInputURLs: originalInputURLs,
                inputRecords: try resolvedInputs.inputRecords(),
                materializationSteps: try resolvedInputs.materializationSteps(),
                outputDirectoryURL: outputDirectoryURL,
                retention: retention,
                ensureMode: ensureMode,
                effectiveReadLength: effectiveReadLength,
                effectiveThreads: effectiveThreads,
                pairingDecision: pairingDecision,
                isInterleaved: isInterleaved,
                splitPairs: splitPairs,
                command: provenanceCommand,
                toolVersion: toolVersion,
                outputs: outputs.retainedOutputURLs.filter { FileManager.default.fileExists(atPath: $0.path) },
                exitCode: result.exitCode,
                wallTime: wallTime,
                stderr: result.stderr,
                status: .failed
            )
            throw CLIError.conversionFailed(reason: "RiboDetector failed: \(result.stderr)")
        }

        // Join each retained class back into one interleaved file; the
        // count check refuses an output whose mates fell out of step.
        do {
            for join in joins {
                let counts = try await Self.interleave(r1: join.r1, r2: join.r2, to: join.output)
                guard counts.r1Records == counts.r2Records else {
                    throw CLIError.conversionFailed(
                        reason: "RiboDetector wrote \(counts.r1Records) R1 reads but \(counts.r2Records) R2 reads for \(join.output.lastPathComponent); the mates are out of step."
                    )
                }
            }
            wallTime = runClock.elapsed
        } catch {
            for join in joins { try? FileManager.default.removeItem(at: join.output) }
            try? await recordProvenance(
                inputURLs: inputURLs,
                originalInputURLs: originalInputURLs,
                inputRecords: try resolvedInputs.inputRecords(),
                materializationSteps: try resolvedInputs.materializationSteps(),
                outputDirectoryURL: outputDirectoryURL,
                retention: retention,
                ensureMode: ensureMode,
                effectiveReadLength: effectiveReadLength,
                effectiveThreads: effectiveThreads,
                pairingDecision: pairingDecision,
                isInterleaved: isInterleaved,
                splitPairs: splitPairs,
                command: provenanceCommand,
                toolVersion: toolVersion,
                outputs: [],
                exitCode: result.exitCode,
                wallTime: runClock.elapsed,
                stderr: error.localizedDescription,
                status: .failed
            )
            throw error
        }

        if outputs.removeNonRRNAOutputsAfterRun {
            for outputURL in outputs.nonRRNAOutputURLs + toolPlan.nonRRNAOutputURLs {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        try await recordProvenance(
            inputURLs: inputURLs,
            originalInputURLs: originalInputURLs,
            inputRecords: try resolvedInputs.inputRecords(),
            materializationSteps: try resolvedInputs.materializationSteps(),
            outputDirectoryURL: outputDirectoryURL,
            retention: retention,
            ensureMode: ensureMode,
            effectiveReadLength: effectiveReadLength,
            effectiveThreads: effectiveThreads,
            pairingDecision: pairingDecision,
            isInterleaved: isInterleaved,
            splitPairs: splitPairs,
            command: provenanceCommand,
            toolVersion: toolVersion,
            outputs: outputs.retainedOutputURLs,
            exitCode: result.exitCode,
            wallTime: wallTime,
            stderr: result.stderr,
            status: .completed
        )

        let retained = outputs.retainedOutputURLs.map(\.path).joined(separator: ", ")
        FileHandle.standardError.write(Data("RiboDetector outputs written to \(retained)\n".utf8))
    }

    private func recordProvenance(
        inputURLs: [URL],
        originalInputURLs: [URL],
        inputRecords: [FileRecord],
        materializationSteps: [ProvenanceStep],
        outputDirectoryURL: URL,
        retention: FASTQRiboDetectorRetention,
        ensureMode: FASTQRiboDetectorEnsure,
        effectiveReadLength: Int,
        effectiveThreads: Int,
        pairingDecision: FASTQPairingDecision?,
        isInterleaved: Bool,
        splitPairs: Int?,
        command: [String],
        toolVersion: String,
        outputs: [URL],
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String,
        status: RunStatus
    ) async throws {
        let format = SequenceFormat.from(url: inputURLs[0])
        let fileFormat: FileFormat = {
            switch format {
            case .fastq:
                return .fastq
            case .fasta:
                return .fasta
            case .none:
                return .unknown
            }
        }()

        var parameters: [String: ParameterValue] = [
            "input": .file(originalInputURLs[0]),
            "inputs": .array(originalInputURLs.map { .file($0) }),
            "outputDirectory": .file(outputDirectoryURL),
            "retain": .string(retention.rawValue),
            "ensure": .string(ensureMode.rawValue),
            "readLength": .integer(effectiveReadLength),
            "threads": .integer(effectiveThreads),
            "pairing": pairing.provenanceValue,
            "interleaved": .boolean(isInterleaved),
            "readLayout": .string((pairingDecision?.layout ?? .pairedFiles).rawValue),
            "readLayoutReason": pairingDecision.map { .string($0.resolution.reason) } ?? .null,
            "condaEnvironment": .string("ribodetector"),
        ]
        if let splitPairs {
            parameters["splitPairs"] = .integer(splitPairs)
        }

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "RiboDetector FASTQ filter",
            parameters: parameters,
            toolName: "RiboDetector",
            toolVersion: toolVersion,
            command: command,
            extraSteps: materializationSteps,
            inputs: inputRecords,
            outputs: outputs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: fileFormat, role: .output)
            },
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr,
            status: status,
            outputDirectory: outputDirectoryURL
        )
    }

    /// - Parameter namedAfter: the paths the user gave, which name the
    ///   outputs, when `inputURLs` are files resolved for the run (a bundle's
    ///   joined or materialized reads). Formats come from `inputURLs`.
    static func plannedOutputs(
        inputURLs: [URL],
        namedAfter originalURLs: [URL]? = nil,
        outputDirectory: URL,
        retention: FASTQRiboDetectorRetention
    ) throws -> RiboDetectorOutputPlan {
        guard !inputURLs.isEmpty, inputURLs.count <= 2 else {
            throw ValidationError("RiboDetector requires one input file or one paired-end R1/R2 input pair.")
        }
        let namingURLs = originalURLs ?? inputURLs

        let formats = try inputURLs.map { inputURL -> SequenceFormat in
            guard let format = SequenceFormat.from(url: inputURL) else {
                throw ValidationError("RiboDetector input must be FASTA or FASTQ: \(inputURL.path)")
            }
            return format
        }
        guard Set(formats.map(\.rawValue)).count == 1 else {
            throw ValidationError("RiboDetector paired inputs must use the same sequence format.")
        }

        let ext = formats[0].fileExtension
        let normalNonRRNA = namingURLs.map { inputURL in
            outputDirectory.appendingPathComponent("\(sequenceStem(for: inputURL)).norrna.\(ext)")
        }
        let hiddenNonRRNA = namingURLs.map { inputURL in
            outputDirectory.appendingPathComponent(".\(sequenceStem(for: inputURL)).norrna.discarded.\(ext)")
        }
        let rRNAOutputs = namingURLs.map { inputURL in
            outputDirectory.appendingPathComponent("\(sequenceStem(for: inputURL)).rrna.\(ext)")
        }

        switch retention {
        case .nonRRNA:
            return RiboDetectorOutputPlan(
                nonRRNAOutputURLs: normalNonRRNA,
                rRNAOutputURLs: nil,
                retainedOutputURLs: normalNonRRNA,
                removeNonRRNAOutputsAfterRun: false
            )
        case .rRNA:
            return RiboDetectorOutputPlan(
                nonRRNAOutputURLs: hiddenNonRRNA,
                rRNAOutputURLs: rRNAOutputs,
                retainedOutputURLs: rRNAOutputs,
                removeNonRRNAOutputsAfterRun: true
            )
        case .both:
            return RiboDetectorOutputPlan(
                nonRRNAOutputURLs: normalNonRRNA,
                rRNAOutputURLs: rRNAOutputs,
                retainedOutputURLs: normalNonRRNA + rRNAOutputs,
                removeNonRRNAOutputsAfterRun: false
            )
        }
    }

    /// The tool's view of a single-input plan when the input was split into
    /// R1/R2: every planned output becomes an R1/R2 pair under `scratch`,
    /// and every retained output is joined back at its planned path.
    static func pairedInvocationPlan(
        for plan: RiboDetectorOutputPlan,
        scratchDirectory: URL
    ) -> RiboDetectorPairedInvocationPlan {
        func mates(for output: URL) -> (r1: URL, r2: URL) {
            let name = output.lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            return (
                scratchDirectory.appendingPathComponent("\(stem).R1.\(ext)"),
                scratchDirectory.appendingPathComponent("\(stem).R2.\(ext)")
            )
        }
        let nonRRNA = plan.nonRRNAOutputURLs.flatMap { output -> [URL] in
            let pair = mates(for: output)
            return [pair.r1, pair.r2]
        }
        let rRNA = plan.rRNAOutputURLs.map { outputs in
            outputs.flatMap { output -> [URL] in
                let pair = mates(for: output)
                return [pair.r1, pair.r2]
            }
        }
        let joins = plan.retainedOutputURLs.map { output in
            let pair = mates(for: output)
            return RiboDetectorPairJoin(r1: pair.r1, r2: pair.r2, output: output)
        }
        return RiboDetectorPairedInvocationPlan(
            toolPlan: RiboDetectorOutputPlan(
                nonRRNAOutputURLs: nonRRNA,
                rRNAOutputURLs: rRNA,
                retainedOutputURLs: joins.flatMap { [$0.r1, $0.r2] },
                removeNonRRNAOutputsAfterRun: plan.removeNonRRNAOutputsAfterRun
            ),
            joins: joins
        )
    }

    /// Splits a strictly interleaved file into plain R1/R2 files in process.
    private static func deinterleave(_ source: URL, r1: URL, r2: URL) async throws -> FASTQPairInterleaver.Counts {
        let worker = Task.detached(priority: .utility) { () throws -> FASTQPairInterleaver.Counts in
            let fm = FileManager.default
            fm.createFile(atPath: r1.path, contents: nil)
            fm.createFile(atPath: r2.path, contents: nil)
            guard let handle1 = FileHandle(forWritingAtPath: r1.path),
                  let handle2 = FileHandle(forWritingAtPath: r2.path) else {
                throw CLIError.conversionFailed(reason: "cannot open mate files for writing in \(r1.deletingLastPathComponent().path)")
            }
            defer {
                try? handle1.close()
                try? handle2.close()
            }
            return try FASTQPairInterleaver.deinterleave(interleaved: source, r1: handle1, r2: handle2)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Joins R1/R2 back into one interleaved file at `output`.
    private static func interleave(r1: URL, r2: URL, to output: URL) async throws -> FASTQPairInterleaver.Counts {
        let worker = Task.detached(priority: .utility) { () throws -> FASTQPairInterleaver.Counts in
            let fm = FileManager.default
            try? fm.removeItem(at: output)
            fm.createFile(atPath: output.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: output.path) else {
                throw CLIError.conversionFailed(reason: "cannot open \(output.path) for writing")
            }
            defer { try? handle.close() }
            return try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: handle)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// The files the tool reads, once the resolved inputs plan valid outputs.
    private func validateInputs(_ resolvedInputs: [FASTQSubcommandInput]) throws -> [URL] {
        guard !resolvedInputs.isEmpty, resolvedInputs.count <= 2 else {
            throw ValidationError("RiboDetector requires one input file or one paired-end R1/R2 input pair.")
        }

        let urls = resolvedInputs.map(\.executionURL)
        _ = try Self.plannedOutputs(
            inputURLs: urls,
            namedAfter: resolvedInputs.map(\.originalURL),
            outputDirectory: FileManager.default.temporaryDirectory,
            retention: .nonRRNA
        )
        return urls
    }

    private func parsedRetention(_ value: String) throws -> FASTQRiboDetectorRetention {
        guard let retention = FASTQRiboDetectorRetention(rawValue: value.lowercased()) else {
            throw ValidationError("Unsupported --retain value: \(value). Use norrna, rrna, or both.")
        }
        return retention
    }

    private func parsedEnsure(_ value: String) throws -> FASTQRiboDetectorEnsure {
        guard let ensure = FASTQRiboDetectorEnsure(rawValue: value.lowercased()) else {
            throw ValidationError("Unsupported --ensure value: \(value). Use rrna, norrna, both, or none.")
        }
        return ensure
    }

    private func resolvedReadLength(for inputURL: URL) async throws -> Int {
        if let readLength {
            guard readLength > 0 else {
                throw ValidationError("--read-length must be positive")
            }
            return readLength
        }
        return try await Self.inferMeanReadLength(from: inputURL)
    }

    private static func inferMeanReadLength(from inputURL: URL, sampleLimit: Int = 1000) async throws -> Int {
        guard let format = SequenceFormat.from(url: inputURL) else {
            throw ValidationError("RiboDetector input must be FASTA or FASTQ: \(inputURL.path)")
        }

        var totalLength = 0
        var sampledCount = 0
        switch format {
        case .fastq:
            let reader = FASTQReader(validateSequence: false)
            for try await record in reader.records(from: inputURL) {
                totalLength += record.sequence.count
                sampledCount += 1
                if sampledCount >= sampleLimit { break }
            }
        case .fasta:
            let reader = try FASTAReader(url: inputURL)
            for try await sequence in reader.sequences() {
                totalLength += sequence.length
                sampledCount += 1
                if sampledCount >= sampleLimit { break }
            }
        }

        guard sampledCount > 0 else {
            throw CLIError.conversionFailed(reason: "Cannot infer read length from an empty input file")
        }
        return max(1, Int((Double(totalLength) / Double(sampledCount)).rounded()))
    }

    private static func sequenceStem(for inputURL: URL) -> String {
        let baseURL = inputURL.pathExtension.lowercased() == "gz"
            ? inputURL.deletingPathExtension()
            : inputURL
        let stem = baseURL.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "ribodetector-output" : stem
    }
}
