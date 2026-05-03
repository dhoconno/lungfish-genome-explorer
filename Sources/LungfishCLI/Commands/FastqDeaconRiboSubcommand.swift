import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct DeaconRiboOutputPlan: Sendable, Equatable {
    let nonRRNAOutputURLs: [URL]
    let rRNAOutputURLs: [URL]?
    let retainedOutputURLs: [URL]
}

private struct DeaconRiboInvocationRecord: Sendable {
    let arguments: [String]
    let outputs: [URL]
    let exitCode: Int32
    let wallTime: TimeInterval
    let stderr: String
}

struct FastqDeaconRiboSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deacon-ribo",
        abstract: "Detect and remove ribosomal RNA sequences with Deacon and BBMap ribokmers"
    )

    @Argument(help: "Input FASTA/FASTQ file, or paired R1/R2 FASTQ files")
    var inputs: [String]

    @Option(name: .customLong("retain"), help: "Read classes to retain: norrna, rrna, or both")
    var retain: String = FASTQRiboDetectorRetention.nonRRNA.rawValue

    @Option(name: .customLong("database-id"), help: "Managed Deacon database ID")
    var databaseID: String = DeaconRibokmersDatabaseInstaller.databaseID

    @Option(name: .customLong("absolute-threshold"), help: "Minimum absolute minimizer hits for an rRNA match")
    var absoluteThreshold: Int = 1

    @Option(name: .customLong("relative-threshold"), help: "Minimum relative minimizer-hit proportion for an rRNA match")
    var relativeThreshold: Double = 0

    @OptionGroup var globalOptions: GlobalOptions

    var threads: Int? { globalOptions.threads }

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output directory")
    var outputDirectory: String

    func run() async throws {
        let inputURLs = try validateInputs(inputs)
        let outputDirectoryURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)

        let retention = try parsedRetention(retain)
        guard absoluteThreshold > 0 else {
            throw ValidationError("--absolute-threshold must be positive")
        }
        guard relativeThreshold >= 0, relativeThreshold <= 1 else {
            throw ValidationError("--relative-threshold must be between 0 and 1")
        }

        let effectiveThreads = max(1, threads ?? ProcessInfo.processInfo.activeProcessorCount)
        let resolvedDatabaseID = DatabaseRegistry.canonicalDatabaseID(for: databaseID)
        let databaseURL = try await DatabaseRegistry.shared.requiredDatabasePath(for: resolvedDatabaseID)
        let outputs = try Self.plannedOutputs(
            inputURLs: inputURLs,
            outputDirectory: outputDirectoryURL,
            retention: retention
        )
        let toolVersion = await CLIProvenanceSupport.detectCondaToolVersion(
            toolName: "deacon",
            environment: "deacon",
            flags: ["--version"],
            fallback: "0.15.0"
        )

        var invocations: [DeaconRiboInvocationRecord] = []
        do {
            if retention == .nonRRNA || retention == .both {
                let record = try await runDeacon(
                    inputURLs: inputURLs,
                    databaseURL: databaseURL,
                    outputURLs: outputs.nonRRNAOutputURLs,
                    deplete: true,
                    effectiveThreads: effectiveThreads
                )
                invocations.append(record)
                guard record.exitCode == 0 else {
                    throw CLIError.conversionFailed(reason: "Deacon rRNA filter failed: \(record.stderr)")
                }
            }

            if retention == .rRNA || retention == .both {
                let rRNAOutputURLs = outputs.rRNAOutputURLs ?? []
                let record = try await runDeacon(
                    inputURLs: inputURLs,
                    databaseURL: databaseURL,
                    outputURLs: rRNAOutputURLs,
                    deplete: false,
                    effectiveThreads: effectiveThreads
                )
                invocations.append(record)
                guard record.exitCode == 0 else {
                    throw CLIError.conversionFailed(reason: "Deacon rRNA filter failed: \(record.stderr)")
                }
            }
        } catch {
            try? await recordProvenance(
                inputURLs: inputURLs,
                databaseURL: databaseURL,
                outputDirectoryURL: outputDirectoryURL,
                retention: retention,
                effectiveThreads: effectiveThreads,
                resolvedDatabaseID: resolvedDatabaseID,
                toolVersion: toolVersion,
                invocations: invocations,
                status: .failed
            )
            throw error
        }

        try await recordProvenance(
            inputURLs: inputURLs,
            databaseURL: databaseURL,
            outputDirectoryURL: outputDirectoryURL,
            retention: retention,
            effectiveThreads: effectiveThreads,
            resolvedDatabaseID: resolvedDatabaseID,
            toolVersion: toolVersion,
            invocations: invocations,
            status: .completed
        )

        let retained = outputs.retainedOutputURLs.map(\.path).joined(separator: ", ")
        FileHandle.standardError.write(Data("Deacon rRNA outputs written to \(retained)\n".utf8))
    }

    static func plannedOutputs(
        inputURLs: [URL],
        outputDirectory: URL,
        retention: FASTQRiboDetectorRetention
    ) throws -> DeaconRiboOutputPlan {
        guard !inputURLs.isEmpty, inputURLs.count <= 2 else {
            throw ValidationError("Deacon rRNA filtering requires one input file or one paired-end R1/R2 input pair.")
        }

        let formats = try inputURLs.map { inputURL -> SequenceFormat in
            guard let format = SequenceFormat.from(url: inputURL) else {
                throw ValidationError("Deacon rRNA input must be FASTA or FASTQ: \(inputURL.path)")
            }
            return format
        }
        guard Set(formats.map(\.rawValue)).count == 1 else {
            throw ValidationError("Deacon rRNA paired inputs must use the same sequence format.")
        }

        let ext = formats[0].fileExtension
        let nonRRNA = inputURLs.map { inputURL in
            outputDirectory.appendingPathComponent("\(sequenceStem(for: inputURL)).norrna.\(ext)")
        }
        let rRNA = inputURLs.map { inputURL in
            outputDirectory.appendingPathComponent("\(sequenceStem(for: inputURL)).rrna.\(ext)")
        }

        switch retention {
        case .nonRRNA:
            return DeaconRiboOutputPlan(
                nonRRNAOutputURLs: nonRRNA,
                rRNAOutputURLs: nil,
                retainedOutputURLs: nonRRNA
            )
        case .rRNA:
            return DeaconRiboOutputPlan(
                nonRRNAOutputURLs: [],
                rRNAOutputURLs: rRNA,
                retainedOutputURLs: rRNA
            )
        case .both:
            return DeaconRiboOutputPlan(
                nonRRNAOutputURLs: nonRRNA,
                rRNAOutputURLs: rRNA,
                retainedOutputURLs: nonRRNA + rRNA
            )
        }
    }

    private func runDeacon(
        inputURLs: [URL],
        databaseURL: URL,
        outputURLs: [URL],
        deplete: Bool,
        effectiveThreads: Int
    ) async throws -> DeaconRiboInvocationRecord {
        let arguments = deaconArguments(
            inputURLs: inputURLs,
            databaseURL: databaseURL,
            outputURLs: outputURLs,
            deplete: deplete,
            effectiveThreads: effectiveThreads
        )
        let startedAt = Date()
        let result = try await CondaManager.shared.runTool(
            name: "deacon",
            arguments: arguments,
            environment: "deacon",
            workingDirectory: URL(fileURLWithPath: outputDirectory, isDirectory: true),
            timeout: 7200
        )
        let wallTime = Date().timeIntervalSince(startedAt)
        return DeaconRiboInvocationRecord(
            arguments: arguments,
            outputs: outputURLs,
            exitCode: result.exitCode,
            wallTime: wallTime,
            stderr: result.stderr
        )
    }

    private func deaconArguments(
        inputURLs: [URL],
        databaseURL: URL,
        outputURLs: [URL],
        deplete: Bool,
        effectiveThreads: Int
    ) -> [String] {
        var arguments = [
            "filter",
        ]
        if deplete {
            arguments.append("--deplete")
        }
        arguments += [
            "-a", "\(absoluteThreshold)",
            "-r", "\(relativeThreshold)",
            databaseURL.path,
        ]
        arguments += inputURLs.map(\.path)
        if let outputURL = outputURLs.first {
            arguments += ["-o", outputURL.path]
        }
        if outputURLs.count > 1 {
            arguments += ["-O", outputURLs[1].path]
        }
        arguments += ["-t", "\(effectiveThreads)"]
        return arguments
    }

    private func recordProvenance(
        inputURLs: [URL],
        databaseURL: URL,
        outputDirectoryURL: URL,
        retention: FASTQRiboDetectorRetention,
        effectiveThreads: Int,
        resolvedDatabaseID: String,
        toolVersion: String,
        invocations: [DeaconRiboInvocationRecord],
        status: RunStatus
    ) async throws {
        let runID = await ProvenanceRecorder.shared.beginRun(
            name: "Deacon rRNA FASTQ filter",
            parameters: [
                "input": .file(inputURLs[0]),
                "inputs": .array(inputURLs.map { .file($0) }),
                "outputDirectory": .file(outputDirectoryURL),
                "retain": .string(retention.rawValue),
                "databaseID": .string(resolvedDatabaseID),
                "databasePath": .file(databaseURL),
                "absoluteThreshold": .integer(absoluteThreshold),
                "relativeThreshold": .number(relativeThreshold),
                "threads": .integer(effectiveThreads),
                "condaEnvironment": .string("deacon"),
            ]
        )

        let sequenceFormat = SequenceFormat.from(url: inputURLs[0])
        let fileFormat: FileFormat = {
            switch sequenceFormat {
            case .fastq:
                return .fastq
            case .fasta:
                return .fasta
            case .none:
                return .unknown
            }
        }()
        let inputRecords = inputURLs.map {
            ProvenanceRecorder.fileRecord(url: $0, format: fileFormat, role: .input)
        } + [
            ProvenanceRecorder.fileRecord(url: databaseURL, format: .unknown, role: .index),
        ]

        for invocation in invocations {
            await ProvenanceRecorder.shared.recordStep(
                runID: runID,
                toolName: "deacon",
                toolVersion: toolVersion,
                command: CLIProvenanceSupport.condaCommand(
                    toolName: "deacon",
                    environment: "deacon",
                    arguments: invocation.arguments
                ),
                inputs: inputRecords,
                outputs: invocation.outputs
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                    .map { ProvenanceRecorder.fileRecord(url: $0, format: fileFormat, role: .output) },
                exitCode: invocation.exitCode,
                wallTime: invocation.wallTime,
                stderr: invocation.stderr
            )
        }

        await ProvenanceRecorder.shared.completeRun(runID, status: status)
        try await ProvenanceRecorder.shared.save(runID: runID, to: outputDirectoryURL)
    }

    private func validateInputs(_ inputPaths: [String]) throws -> [URL] {
        guard !inputPaths.isEmpty, inputPaths.count <= 2 else {
            throw ValidationError("Deacon rRNA filtering requires one input file or one paired-end R1/R2 input pair.")
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

    private static func sequenceStem(for inputURL: URL) -> String {
        let baseURL = inputURL.pathExtension.lowercased() == "gz"
            ? inputURL.deletingPathExtension()
            : inputURL
        let stem = baseURL.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "deacon-ribo-output" : stem
    }
}
