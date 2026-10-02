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
    /// `deacon` for the classifier, `reformat` for the pair split/join steps.
    let toolName: String
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

    @Argument(help: "Input FASTA/FASTQ file or .lungfishfastq bundle, or paired R1/R2 FASTQ files")
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

    @OptionGroup var pairing: FASTQPairingOptions

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output directory")
    var outputDirectory: String

    func run() async throws {
        guard !inputs.isEmpty, inputs.count <= 2 else {
            throw ValidationError("Deacon rRNA filtering requires one input file or one paired-end R1/R2 input pair.")
        }
        let outputDirectoryURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        // A bundle is read as its reads, resolved the way the dialog resolves
        // it, and the outputs are named after the bundle (R3, lane 1x).
        let resolvedInputs = try await FASTQSubcommandInput.resolve(inputs, operationName: "deacon-ribo", contextURL: outputDirectoryURL)
        defer { resolvedInputs.cleanup() }
        let inputURLs = try validateInputs(resolvedInputs)
        let originalInputURLs = resolvedInputs.map(\.originalURL)

        let retention = try parsedRetention(retain)
        guard absoluteThreshold > 0 else {
            throw ValidationError("--absolute-threshold must be positive")
        }
        guard relativeThreshold >= 0, relativeThreshold <= 1 else {
            throw ValidationError("--relative-threshold must be between 0 and 1")
        }

        // One interleaved file is split into R1/R2 for Deacon, which then
        // keeps or drops both mates of a fragment together, and the result
        // is joined back into one interleaved file at the planned output
        // path. Handed the interleaved file directly, Deacon would judge
        // each mate alone and orphan the other. A file that mixes merged
        // reads with pairs runs as single reads: the reformat split pairs by
        // position and would mis-pair it.
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

        let effectiveThreads = max(1, threads ?? ProcessInfo.processInfo.activeProcessorCount)
        let resolvedDatabaseID = DatabaseRegistry.canonicalDatabaseID(for: databaseID)
        let databaseURL = try await DatabaseRegistry.shared.requiredDatabasePath(for: resolvedDatabaseID)
        let outputs = try Self.plannedOutputs(
            inputURLs: inputURLs,
            namedAfter: originalInputURLs,
            outputDirectory: outputDirectoryURL,
            retention: retention
        )
        let toolVersion = await CLIProvenanceSupport.detectCondaToolVersion(
            toolName: "deacon",
            environment: "deacon",
            flags: ["--version"],
            fallback: "0.15.0"
        )

        let scratchDirectory = outputDirectoryURL.appendingPathComponent(
            "deacon-ribo-pairs-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        var invocations: [DeaconRiboInvocationRecord] = []
        do {
            var deaconInputURLs = inputURLs
            if isInterleaved {
                try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
                let stem = Self.sequenceStem(for: inputURLs[0])
                let inputR1 = scratchDirectory.appendingPathComponent("\(stem).input.R1.fastq")
                let inputR2 = scratchDirectory.appendingPathComponent("\(stem).input.R2.fastq")
                let record = try await Self.reformatPairs(
                    arguments: [
                        "in=\(inputURLs[0].path)",
                        "out1=\(inputR1.path)",
                        "out2=\(inputR2.path)",
                        "interleaved=t",
                    ],
                    outputs: [inputR1, inputR2]
                )
                invocations.append(record)
                guard record.exitCode == 0 else {
                    throw CLIError.conversionFailed(reason: "reformat.sh deinterleave failed: \(record.stderr)")
                }
                deaconInputURLs = [inputR1, inputR2]
            }

            let classes: [(deplete: Bool, outputURLs: [URL])] = [
                (true, outputs.nonRRNAOutputURLs),
                (false, outputs.rRNAOutputURLs ?? []),
            ].filter { !$0.1.isEmpty }

            for readClass in classes {
                if isInterleaved, let finalOutputURL = readClass.outputURLs.first {
                    let stem = finalOutputURL.deletingPathExtension().lastPathComponent
                    let outputR1 = scratchDirectory.appendingPathComponent("\(stem).R1.fastq")
                    let outputR2 = scratchDirectory.appendingPathComponent("\(stem).R2.fastq")
                    let deaconRecord = try await runDeacon(
                        inputURLs: deaconInputURLs,
                        databaseURL: databaseURL,
                        outputURLs: [outputR1, outputR2],
                        deplete: readClass.deplete,
                        effectiveThreads: effectiveThreads
                    )
                    invocations.append(deaconRecord)
                    guard deaconRecord.exitCode == 0 else {
                        throw CLIError.conversionFailed(reason: "Deacon rRNA filter failed: \(deaconRecord.stderr)")
                    }
                    let joinRecord = try await Self.reformatPairs(
                        arguments: [
                            "in1=\(outputR1.path)",
                            "in2=\(outputR2.path)",
                            "out=\(finalOutputURL.path)",
                            "interleaved=t",
                        ],
                        outputs: [finalOutputURL]
                    )
                    invocations.append(joinRecord)
                    guard joinRecord.exitCode == 0 else {
                        throw CLIError.conversionFailed(reason: "reformat.sh interleave failed: \(joinRecord.stderr)")
                    }
                } else {
                    let record = try await runDeacon(
                        inputURLs: deaconInputURLs,
                        databaseURL: databaseURL,
                        outputURLs: readClass.outputURLs,
                        deplete: readClass.deplete,
                        effectiveThreads: effectiveThreads
                    )
                    invocations.append(record)
                    guard record.exitCode == 0 else {
                        throw CLIError.conversionFailed(reason: "Deacon rRNA filter failed: \(record.stderr)")
                    }
                }
            }
        } catch {
            try? await recordProvenance(
                inputURLs: inputURLs,
                originalInputURLs: originalInputURLs,
                inputRecords: try resolvedInputs.inputRecords(),
                materializationSteps: try resolvedInputs.materializationSteps(),
                databaseURL: databaseURL,
                outputDirectoryURL: outputDirectoryURL,
                retention: retention,
                effectiveThreads: effectiveThreads,
                resolvedDatabaseID: resolvedDatabaseID,
                toolVersion: toolVersion,
                isInterleaved: isInterleaved,
                readLayout: pairingDecision?.layout,
                readLayoutReason: pairingDecision?.resolution.reason,
                invocations: invocations,
                status: .failed
            )
            throw error
        }

        try await recordProvenance(
            inputURLs: inputURLs,
            originalInputURLs: originalInputURLs,
            inputRecords: try resolvedInputs.inputRecords(),
            materializationSteps: try resolvedInputs.materializationSteps(),
            databaseURL: databaseURL,
            outputDirectoryURL: outputDirectoryURL,
            retention: retention,
            effectiveThreads: effectiveThreads,
            resolvedDatabaseID: resolvedDatabaseID,
            toolVersion: toolVersion,
            isInterleaved: isInterleaved,
            readLayout: pairingDecision?.layout,
            readLayoutReason: pairingDecision?.resolution.reason,
            invocations: invocations,
            status: .completed
        )

        let retained = outputs.retainedOutputURLs.map(\.path).joined(separator: ", ")
        FileHandle.standardError.write(Data("Deacon rRNA outputs written to \(retained)\n".utf8))
    }

    /// - Parameter namedAfter: the paths the user gave, which name the
    ///   outputs, when `inputURLs` are files resolved for the run (a bundle's
    ///   joined or materialized reads). Formats come from `inputURLs`.
    static func plannedOutputs(
        inputURLs: [URL],
        namedAfter originalURLs: [URL]? = nil,
        outputDirectory: URL,
        retention: FASTQRiboDetectorRetention
    ) throws -> DeaconRiboOutputPlan {
        guard !inputURLs.isEmpty, inputURLs.count <= 2 else {
            throw ValidationError("Deacon rRNA filtering requires one input file or one paired-end R1/R2 input pair.")
        }
        let namingURLs = originalURLs ?? inputURLs

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
        let nonRRNA = namingURLs.map { inputURL in
            outputDirectory.appendingPathComponent("\(sequenceStem(for: inputURL)).norrna.\(ext)")
        }
        let rRNA = namingURLs.map { inputURL in
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
            toolName: "deacon",
            arguments: arguments,
            outputs: outputURLs,
            exitCode: result.exitCode,
            wallTime: wallTime,
            stderr: result.stderr
        )
    }

    /// Runs `reformat.sh` (BBTools) to split an interleaved file into R1/R2
    /// or join R1/R2 back into one interleaved file.
    private static func reformatPairs(
        arguments: [String],
        outputs: [URL]
    ) async throws -> DeaconRiboInvocationRecord {
        let runner = NativeToolRunner.shared
        let env = await bbToolsEnvironment(runner: runner)
        let startedAt = Date()
        let result = try await runner.run(.reformat, arguments: arguments, environment: env, timeout: 1800)
        return DeaconRiboInvocationRecord(
            toolName: "reformat",
            arguments: arguments,
            outputs: outputs,
            exitCode: result.exitCode,
            wallTime: Date().timeIntervalSince(startedAt),
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
        originalInputURLs: [URL],
        inputRecords: [FileRecord],
        materializationSteps: [ProvenanceStep],
        databaseURL: URL,
        outputDirectoryURL: URL,
        retention: FASTQRiboDetectorRetention,
        effectiveThreads: Int,
        resolvedDatabaseID: String,
        toolVersion: String,
        isInterleaved: Bool,
        readLayout: FASTQInputLayout?,
        readLayoutReason: String?,
        invocations: [DeaconRiboInvocationRecord],
        status: RunStatus
    ) async throws {
        let runID = await ProvenanceRecorder.shared.beginRun(
            name: "Deacon rRNA FASTQ filter",
            parameters: [
                "input": .file(originalInputURLs[0]),
                "inputs": .array(originalInputURLs.map { .file($0) }),
                "outputDirectory": .file(outputDirectoryURL),
                "retain": .string(retention.rawValue),
                "databaseID": .string(resolvedDatabaseID),
                "databasePath": .file(databaseURL),
                "absoluteThreshold": .integer(absoluteThreshold),
                "relativeThreshold": .number(relativeThreshold),
                "threads": .integer(effectiveThreads),
                "pairing": pairing.provenanceValue,
                "interleaved": .boolean(isInterleaved),
                "readLayout": .string((readLayout ?? .pairedFiles).rawValue),
                "readLayoutReason": readLayoutReason.map(ParameterValue.string) ?? .null,
                "condaEnvironment": .string("deacon"),
            ]
        )
        let reformatVersion = await NativeToolRunner.shared.getToolVersion(.reformat) ?? "unknown"

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
        let inputRecords = inputRecords + provenanceRecords(for: databaseURL, role: .reference)

        // The materialization or join that wrote a bundle's reads for the run.
        for step in materializationSteps {
            await ProvenanceRecorder.shared.recordStep(
                runID: runID,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                command: step.argv,
                inputs: step.inputs.map(Self.fileRecord),
                outputs: step.outputs.map(Self.fileRecord),
                exitCode: Int32(step.exitStatus ?? 0),
                wallTime: step.wallTimeSeconds ?? 0,
                stderr: step.stderr
            )
        }

        for invocation in invocations {
            let isDeacon = invocation.toolName == "deacon"
            await ProvenanceRecorder.shared.recordStep(
                runID: runID,
                toolName: invocation.toolName,
                toolVersion: isDeacon ? toolVersion : reformatVersion,
                command: isDeacon
                    ? CLIProvenanceSupport.condaCommand(
                        toolName: "deacon",
                        environment: "deacon",
                        arguments: invocation.arguments
                    )
                    : [NativeTool.reformat.executableName] + invocation.arguments,
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
        guard let envelope = ProvenanceRecorder.loadEnvelope(from: outputDirectoryURL) else { return }
        let writer = ProvenanceWriter(signingProvider: nil)
        for outputURL in invocations.flatMap(\.outputs) where FileManager.default.fileExists(atPath: outputURL.path) {
            let output = ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: outputURL, format: fileFormat, role: .output))
            try writer.write(envelope.focusedOnOutput(output), toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        }
    }

    /// The files the tool reads, once the resolved inputs plan valid outputs.
    private func validateInputs(_ resolvedInputs: [FASTQSubcommandInput]) throws -> [URL] {
        guard !resolvedInputs.isEmpty, resolvedInputs.count <= 2 else {
            throw ValidationError("Deacon rRNA filtering requires one input file or one paired-end R1/R2 input pair.")
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

    private static func fileRecord(_ descriptor: ProvenanceFileDescriptor) -> FileRecord {
        FileRecord(
            path: descriptor.path,
            sha256: descriptor.checksumSHA256,
            sizeBytes: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role
        )
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
