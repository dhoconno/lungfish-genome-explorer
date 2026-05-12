// FastqScrubHumanSubcommand.swift - CLI subcommand to remove human reads from FASTQ
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

private struct ScrubHumanProvenanceFile: Sendable {
    let url: URL
    let format: FileFormat?
    let role: FileRole
}

private struct ScrubHumanInvocationRecord: Sendable {
    let tool: NativeTool
    let argv: [String]
    let inputs: [ScrubHumanProvenanceFile]
    let outputs: [ScrubHumanProvenanceFile]
    let exitCode: Int32
    let wallTime: TimeInterval
    let stderr: String
    let startedAt: Date
    let completedAt: Date
}

struct FastqScrubHumanSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scrub-human",
        abstract: "Remove human reads from FASTQ"
    )

    @Argument(help: "Input FASTQ file path")
    var input: String

    @OptionGroup var output: OutputOptions

    @Option(name: .customLong("database-id"), help: "Human read removal database identifier")
    var databaseID: String

    @Flag(
        name: .customLong("remove-reads"),
        help: "Deprecated compatibility flag; ignored because Deacon always removes matched reads"
    )
    var compatibilityRemoveReads: Bool = false

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        _ = compatibilityRemoveReads

        let runner = NativeToolRunner.shared
        let resolvedDatabaseID = Self.canonicalHumanReadRemovalDatabaseID(for: databaseID)
        let dbPath = try await DatabaseRegistry.shared.requiredDatabasePath(for: resolvedDatabaseID)
        let outputURL = URL(fileURLWithPath: output.output)
        let shouldCompressOutput = output.compress || outputURL.pathExtension.lowercased() == "gz"
        let workspace = outputURL.deletingLastPathComponent()
        let threads = ProcessInfo.processInfo.activeProcessorCount
        let startedAt = Date()
        var invocations: [ScrubHumanInvocationRecord] = []

        var decompressedInput: URL? = nil
        let scrubInputURL: URL
        if inputURL.pathExtension.lowercased() == "gz" {
            let tmp = workspace.appendingPathComponent("scrub-human-input-\(UUID().uuidString).fastq")
            let pigzArguments = ["-d", "-c", inputURL.path]
            let stepStartedAt = Date()
            let pigzResult = try await runner.runWithFileOutput(
                .pigz,
                arguments: pigzArguments,
                outputFile: tmp
            )
            invocations.append(Self.invocationRecord(
                tool: .pigz,
                result: pigzResult,
                startedAt: stepStartedAt,
                inputs: [.init(url: inputURL, format: .fastq, role: .input)],
                outputs: [.init(url: tmp, format: .fastq, role: .output)]
            ))
            guard pigzResult.isSuccess else {
                throw CLIError.conversionFailed(reason: "Failed to decompress input for deacon: \(pigzResult.stderr)")
            }
            scrubInputURL = tmp
            decompressedInput = tmp
        } else {
            scrubInputURL = inputURL
        }
        defer {
            if let decompressedInput {
                try? FileManager.default.removeItem(at: decompressedInput)
            }
        }

        let plainOutputURL = shouldCompressOutput
            ? workspace.appendingPathComponent("scrub-human-output-\(UUID().uuidString).fastq")
            : outputURL
        defer {
            if shouldCompressOutput {
                try? FileManager.default.removeItem(at: plainOutputURL)
            }
        }

        if try await Self.looksInterleavedFASTQ(at: scrubInputURL) {
            let inputR1 = workspace.appendingPathComponent("scrub-human-input-\(UUID().uuidString)-R1.fastq")
            let inputR2 = workspace.appendingPathComponent("scrub-human-input-\(UUID().uuidString)-R2.fastq")
            let outputR1 = workspace.appendingPathComponent("scrub-human-output-\(UUID().uuidString)-R1.fastq")
            let outputR2 = workspace.appendingPathComponent("scrub-human-output-\(UUID().uuidString)-R2.fastq")
            defer {
                try? FileManager.default.removeItem(at: inputR1)
                try? FileManager.default.removeItem(at: inputR2)
                try? FileManager.default.removeItem(at: outputR1)
                try? FileManager.default.removeItem(at: outputR2)
            }

            invocations.append(try await Self.deinterleaveFASTQ(
                inputFASTQ: scrubInputURL,
                outputR1: inputR1,
                outputR2: inputR2,
                runner: runner
            ))
            invocations.append(try await Self.runDeaconFilter(
                inputR1: inputR1,
                inputR2: inputR2,
                outputR1: outputR1,
                outputR2: outputR2,
                databasePath: dbPath,
                threads: threads,
                runner: runner
            ))
            invocations.append(try await Self.interleaveFASTQ(
                inputR1: outputR1,
                inputR2: outputR2,
                outputFASTQ: plainOutputURL,
                runner: runner
            ))
        } else {
            invocations.append(try await Self.runDeaconFilter(
                inputFASTQ: scrubInputURL,
                outputFASTQ: plainOutputURL,
                databasePath: dbPath,
                threads: threads,
                runner: runner
            ))
        }

        if shouldCompressOutput {
            let pigzArguments = ["-p", "\(threads)", "-c", plainOutputURL.path]
            let stepStartedAt = Date()
            let compressionResult = try await runner.runWithFileOutput(
                .pigz,
                arguments: pigzArguments,
                outputFile: outputURL
            )
            invocations.append(Self.invocationRecord(
                tool: .pigz,
                result: compressionResult,
                startedAt: stepStartedAt,
                inputs: [.init(url: plainOutputURL, format: .fastq, role: .input)],
                outputs: [.init(url: outputURL, format: .fastq, role: .output)]
            ))
            guard compressionResult.isSuccess else {
                throw CLIError.conversionFailed(reason: "Compression after deacon failed: \(compressionResult.stderr)")
            }
        }

        var cliArguments = ["scrub-human", inputURL.path, "--output", output.output, "--database-id", databaseID]
        if compatibilityRemoveReads {
            cliArguments.append("--remove-reads")
        }
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let parameters: [String: ParameterValue] = [
            "input": .file(inputURL),
            "output": .file(outputURL),
            "databaseID": .string(databaseID),
            "resolvedDatabaseID": .string(resolvedDatabaseID),
            "databasePath": .file(dbPath),
            "removeReadsCompatibilityFlag": .boolean(compatibilityRemoveReads),
            "force": .boolean(output.force),
            "compress": .boolean(output.compress),
            "resolvedCompressOutput": .boolean(shouldCompressOutput),
            "threads": .integer(threads)
        ]
        try await recordProvenance(
            parameters: parameters,
            defaults: [
                "removeReadsCompatibilityFlag": .boolean(false),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            command: ["lungfish", "fastq"] + cliArguments,
            inputURL: inputURL,
            outputURL: outputURL,
            dbPath: dbPath,
            startedAt: startedAt,
            endedAt: Date(),
            invocations: invocations
        )
    }

    private func recordProvenance(
        parameters: [String: ParameterValue],
        defaults: [String: ParameterValue],
        command: [String],
        inputURL: URL,
        outputURL: URL,
        dbPath: URL,
        startedAt: Date,
        endedAt: Date,
        invocations: [ScrubHumanInvocationRecord]
    ) async throws {
        let output = ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: outputURL, format: .fastq, role: .output))
        var files = [ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input))]
        files += provenanceRecords(for: dbPath, role: .reference).map { ProvenanceFileDescriptor(fileRecord: $0) }
        files.append(output)

        var steps: [ProvenanceStep] = []
        for invocation in invocations {
            let inputDescriptors = Self.descriptors(for: invocation.inputs)
            let outputDescriptors = Self.descriptors(for: invocation.outputs)
            files += inputDescriptors + outputDescriptors
            let toolVersion = await NativeToolRunner.shared.getToolVersion(invocation.tool) ?? "unknown"
            steps.append(ProvenanceStep(
                toolName: invocation.tool.rawValue,
                toolVersion: toolVersion,
                argv: invocation.argv,
                inputs: inputDescriptors,
                outputs: outputDescriptors,
                exitStatus: Int(invocation.exitCode),
                wallTimeSeconds: invocation.wallTime,
                stderr: Self.normalizedStderr(invocation.stderr),
                startedAt: invocation.startedAt,
                completedAt: invocation.completedAt
            ))
        }

        let envelope = ProvenanceEnvelope(
            workflowName: "lungfish fastq scrub-human",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish fastq scrub-human",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: command,
            options: ProvenanceOptions(explicit: parameters, defaults: defaults, resolvedDefaults: parameters),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: Self.deduplicated(files),
            output: output,
            outputs: [output],
            steps: steps,
            wallTimeSeconds: endedAt.timeIntervalSince(startedAt),
            exitStatus: 0,
            stderr: nil
        )
        let writer = ProvenanceWriter()
        try writer.write(envelope, to: outputURL.deletingLastPathComponent())
        try writer.write(envelope.focusedOnOutput(output), toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
    }
}

extension FastqScrubHumanSubcommand {
    static func canonicalHumanReadRemovalDatabaseID(for requestedID: String) -> String {
        let canonical = DatabaseRegistry.canonicalDatabaseID(for: requestedID)
        if canonical == HumanScrubberDatabaseInstaller.databaseID {
            return DeaconPanhumanDatabaseInstaller.databaseID
        }
        return canonical
    }
}

private extension FastqScrubHumanSubcommand {
    static func looksInterleavedFASTQ(at url: URL) async throws -> Bool {
        let reader = FASTQReader(validateSequence: false)
        var iterator = reader.records(from: url).makeAsyncIterator()
        guard let first = try await iterator.next(),
              let second = try await iterator.next(),
              let firstPair = first.readPair,
              let secondPair = second.readPair else {
            return false
        }
        return firstPair.pairId == secondPair.pairId
            && firstPair.readNumber == 1
            && secondPair.readNumber == 2
    }

    static func deinterleaveFASTQ(
        inputFASTQ: URL,
        outputR1: URL,
        outputR2: URL,
        runner: NativeToolRunner
    ) async throws -> ScrubHumanInvocationRecord {
        let env = await bbToolsEnvironment(runner: runner)
        let arguments = [
            "in=\(inputFASTQ.path)",
            "out1=\(outputR1.path)",
            "out2=\(outputR2.path)",
            "interleaved=t",
        ]
        let startedAt = Date()
        let result = try await runner.run(
            .reformat,
            arguments: arguments,
            environment: env,
            timeout: 1800
        )
        let record = invocationRecord(
            tool: .reformat,
            result: result,
            startedAt: startedAt,
            inputs: [.init(url: inputFASTQ, format: .fastq, role: .input)],
            outputs: [
                .init(url: outputR1, format: .fastq, role: .output),
                .init(url: outputR2, format: .fastq, role: .output),
            ]
        )
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "reformat.sh deinterleave failed: \(result.stderr)")
        }
        return record
    }

    static func interleaveFASTQ(
        inputR1: URL,
        inputR2: URL,
        outputFASTQ: URL,
        runner: NativeToolRunner
    ) async throws -> ScrubHumanInvocationRecord {
        let env = await bbToolsEnvironment(runner: runner)
        let arguments = [
            "in1=\(inputR1.path)",
            "in2=\(inputR2.path)",
            "out=\(outputFASTQ.path)",
            "interleaved=t",
        ]
        let startedAt = Date()
        let result = try await runner.run(
            .reformat,
            arguments: arguments,
            environment: env,
            timeout: 1800
        )
        let record = invocationRecord(
            tool: .reformat,
            result: result,
            startedAt: startedAt,
            inputs: [
                .init(url: inputR1, format: .fastq, role: .input),
                .init(url: inputR2, format: .fastq, role: .input),
            ],
            outputs: [.init(url: outputFASTQ, format: .fastq, role: .output)]
        )
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "reformat.sh interleave failed: \(result.stderr)")
        }
        return record
    }

    static func runDeaconFilter(
        inputFASTQ: URL,
        outputFASTQ: URL,
        databasePath: URL,
        threads: Int,
        runner: NativeToolRunner
    ) async throws -> ScrubHumanInvocationRecord {
        let arguments = [
            "filter",
            "-d", databasePath.path,
            inputFASTQ.path,
            "-o", outputFASTQ.path,
            "-t", "\(threads)",
        ]
        let startedAt = Date()
        let result = try await runner.run(
            .deacon,
            arguments: arguments,
            timeout: 7200
        )
        let record = invocationRecord(
            tool: .deacon,
            result: result,
            startedAt: startedAt,
            inputs: [
                .init(url: inputFASTQ, format: .fastq, role: .input),
                .init(url: databasePath, format: nil, role: .reference),
            ],
            outputs: [.init(url: outputFASTQ, format: .fastq, role: .output)]
        )
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "deacon filter failed: \(result.stderr)")
        }
        return record
    }

    static func runDeaconFilter(
        inputR1: URL,
        inputR2: URL,
        outputR1: URL,
        outputR2: URL,
        databasePath: URL,
        threads: Int,
        runner: NativeToolRunner
    ) async throws -> ScrubHumanInvocationRecord {
        let arguments = [
            "filter",
            "-d", databasePath.path,
            inputR1.path,
            inputR2.path,
            "-o", outputR1.path,
            "-O", outputR2.path,
            "-t", "\(threads)",
        ]
        let startedAt = Date()
        let result = try await runner.run(
            .deacon,
            arguments: arguments,
            timeout: 7200
        )
        let record = invocationRecord(
            tool: .deacon,
            result: result,
            startedAt: startedAt,
            inputs: [
                .init(url: inputR1, format: .fastq, role: .input),
                .init(url: inputR2, format: .fastq, role: .input),
                .init(url: databasePath, format: nil, role: .reference),
            ],
            outputs: [
                .init(url: outputR1, format: .fastq, role: .output),
                .init(url: outputR2, format: .fastq, role: .output),
            ]
        )
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "deacon filter failed: \(result.stderr)")
        }
        return record
    }

    static func invocationRecord(
        tool: NativeTool,
        result: NativeToolResult,
        startedAt: Date,
        inputs: [ScrubHumanProvenanceFile],
        outputs: [ScrubHumanProvenanceFile]
    ) -> ScrubHumanInvocationRecord {
        ScrubHumanInvocationRecord(
            tool: tool,
            argv: result.arguments,
            inputs: inputs,
            outputs: outputs,
            exitCode: result.exitCode,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: result.stderr,
            startedAt: startedAt,
            completedAt: Date()
        )
    }

    static func descriptors(for files: [ScrubHumanProvenanceFile]) -> [ProvenanceFileDescriptor] {
        files.flatMap { file in
            provenanceRecords(for: file.url, format: file.format, role: file.role)
                .map { ProvenanceFileDescriptor(fileRecord: $0) }
        }
    }

    static func deduplicated(_ files: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for file in files {
            let key = "\(file.role.rawValue)\u{0}\(file.path)"
            if seen.insert(key).inserted {
                result.append(file)
            }
        }
        return result
    }

    static func normalizedStderr(_ stderr: String) -> String? {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let maxLength = 10_240
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "\n... [truncated]"
    }
}
