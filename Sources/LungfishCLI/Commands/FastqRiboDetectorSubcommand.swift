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

struct FastqRiboDetectorSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ribodetector",
        abstract: "Detect and remove ribosomal RNA sequences with RiboDetector CPU mode"
    )

    @Argument(help: "Input FASTA/FASTQ file, or paired R1/R2 FASTQ files")
    var inputs: [String]

    @Option(name: .customLong("retain"), help: "Read classes to retain: norrna, rrna, or both")
    var retain: String = FASTQRiboDetectorRetention.nonRRNA.rawValue

    @Option(name: .customLong("ensure"), help: "RiboDetector assurance mode: rrna, norrna, both, or none")
    var ensure: String = FASTQRiboDetectorEnsure.rrna.rawValue

    @Option(name: .customLong("read-length"), help: "Mean sequencing read length. Inferred from input when omitted.")
    var readLength: Int?

    @OptionGroup var globalOptions: GlobalOptions

    var threads: Int? { globalOptions.threads }

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output directory")
    var outputDirectory: String

    func run() async throws {
        let inputURLs = try validateInputs(inputs)
        let outputDirectoryURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)

        let retention = try parsedRetention(retain)
        let ensureMode = try parsedEnsure(ensure)
        let effectiveReadLength = try await resolvedReadLength(for: inputURLs[0])
        let effectiveThreads = max(1, threads ?? ProcessInfo.processInfo.activeProcessorCount)
        let outputs = try Self.plannedOutputs(
            inputURLs: inputURLs,
            outputDirectory: outputDirectoryURL,
            retention: retention
        )

        var arguments = [
            "-t", "\(effectiveThreads)",
            "-l", "\(effectiveReadLength)",
            "-i",
        ]
        arguments += inputURLs.map(\.path)
        arguments += [
            "-e", ensureMode.rawValue,
            "-o",
        ]
        arguments += outputs.nonRRNAOutputURLs.map(\.path)
        if let rRNAOutputURLs = outputs.rRNAOutputURLs {
            arguments += ["-r"] + rRNAOutputURLs.map(\.path)
        }

        let provenanceCommand = CLIProvenanceSupport.condaCommand(
            toolName: "ribodetector_cpu",
            environment: "ribodetector",
            arguments: arguments
        )
        let toolVersion = await CLIProvenanceSupport.detectCondaToolVersion(
            toolName: "ribodetector_cpu",
            environment: "ribodetector",
            flags: ["--version", "-h", "--help"],
            fallback: "0.3.3"
        )
        let startedAt = Date()
        let result = try await CondaManager.shared.runTool(
            name: "ribodetector_cpu",
            arguments: arguments,
            environment: "ribodetector",
            workingDirectory: outputDirectoryURL,
            timeout: 7200
        )
        let wallTime = Date().timeIntervalSince(startedAt)
        guard result.exitCode == 0 else {
            try? await recordProvenance(
                inputURLs: inputURLs,
                outputDirectoryURL: outputDirectoryURL,
                retention: retention,
                ensureMode: ensureMode,
                effectiveReadLength: effectiveReadLength,
                effectiveThreads: effectiveThreads,
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

        if outputs.removeNonRRNAOutputsAfterRun {
            for outputURL in outputs.nonRRNAOutputURLs {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        try await recordProvenance(
            inputURLs: inputURLs,
            outputDirectoryURL: outputDirectoryURL,
            retention: retention,
            ensureMode: ensureMode,
            effectiveReadLength: effectiveReadLength,
            effectiveThreads: effectiveThreads,
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
        outputDirectoryURL: URL,
        retention: FASTQRiboDetectorRetention,
        ensureMode: FASTQRiboDetectorEnsure,
        effectiveReadLength: Int,
        effectiveThreads: Int,
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

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "RiboDetector FASTQ filter",
            parameters: [
                "input": .file(inputURLs[0]),
                "inputs": .array(inputURLs.map { .file($0) }),
                "outputDirectory": .file(outputDirectoryURL),
                "retain": .string(retention.rawValue),
                "ensure": .string(ensureMode.rawValue),
                "readLength": .integer(effectiveReadLength),
                "threads": .integer(effectiveThreads),
                "condaEnvironment": .string("ribodetector"),
            ],
            toolName: "RiboDetector",
            toolVersion: toolVersion,
            command: command,
            inputs: inputURLs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: fileFormat, role: .input)
            },
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

    static func plannedOutputs(
        inputURLs: [URL],
        outputDirectory: URL,
        retention: FASTQRiboDetectorRetention
    ) throws -> RiboDetectorOutputPlan {
        guard !inputURLs.isEmpty, inputURLs.count <= 2 else {
            throw ValidationError("RiboDetector requires one input file or one paired-end R1/R2 input pair.")
        }

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
        let normalNonRRNA = inputURLs.map { inputURL in
            outputDirectory.appendingPathComponent("\(sequenceStem(for: inputURL)).norrna.\(ext)")
        }
        let hiddenNonRRNA = inputURLs.map { inputURL in
            outputDirectory.appendingPathComponent(".\(sequenceStem(for: inputURL)).norrna.discarded.\(ext)")
        }
        let rRNAOutputs = inputURLs.map { inputURL in
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

    private func validateInputs(_ inputPaths: [String]) throws -> [URL] {
        guard !inputPaths.isEmpty, inputPaths.count <= 2 else {
            throw ValidationError("RiboDetector requires one input file or one paired-end R1/R2 input pair.")
        }

        let urls = try inputPaths.map { try validateInput($0) }
        _ = try Self.plannedOutputs(
            inputURLs: urls,
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
