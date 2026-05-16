// MarkdupCommand.swift - CLI command for running samtools markdup on BAM files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct MarkdupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markdup",
        abstract: "Mark PCR duplicates in BAM files using samtools markdup"
    )

    struct ExecutionInput: Sendable {
        let path: String
        let force: Bool
        let sortThreads: Int
        let quiet: Bool
        let outputFormat: OutputFormat
    }

    struct Runtime {
        typealias Execute = (ExecutionInput, @escaping (String) -> Void) async throws -> [MarkdupResult]

        let execute: Execute

        static func live() -> Runtime {
            Runtime(execute: MarkdupCommand.runLive)
        }
    }

    @Argument(help: "Path to a BAM file or a directory containing BAMs")
    var path: String

    @Flag(name: .long, help: "Re-run markdup even if already marked")
    var force: Bool = false

    @Option(name: .customLong("sort-threads"), help: "Threads for samtools sort (default 4)")
    var sortThreads: Int = 4

    @OptionGroup var globalOptions: TextAndJSONGlobalOptions

    func run() async throws {
        let resolvedGlobalOptions = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
        _ = try await executeForTesting(
            runtime: .live(),
            resolvedGlobalOptions: resolvedGlobalOptions
        ) { print($0) }
    }

    func executeForTesting(
        runtime: Runtime = .live(),
        resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil,
        emit: @escaping (String) -> Void
    ) async throws -> [MarkdupResult] {
        try await Self.execute(
            input: makeExecutionInput(resolvedGlobalOptions: resolvedGlobalOptions),
            runtime: runtime,
            emit: emit
        )
    }

    static func execute(
        input: ExecutionInput,
        runtime: Runtime = .live(),
        emit: @escaping (String) -> Void
    ) async throws -> [MarkdupResult] {
        guard input.sortThreads >= 1 else {
            throw ValidationError("--sort-threads must be >= 1")
        }
        let results = try await runtime.execute(input, emit)
        emitResults(results, for: input, emit: emit)
        return results
    }

    private func makeExecutionInput(
        resolvedGlobalOptions: ResolvedTextAndJSONGlobalOptions? = nil
    ) -> ExecutionInput {
        let resolvedGlobalOptions = resolvedGlobalOptions
            ?? (try? globalOptions.resolved())
            ?? ResolvedTextAndJSONGlobalOptions(
                outputFormat: globalOptions.outputFormat,
                quiet: globalOptions.quiet
            )
        return ExecutionInput(
            path: path,
            force: force,
            sortThreads: sortThreads,
            quiet: resolvedGlobalOptions.quiet,
            outputFormat: resolvedGlobalOptions.outputFormat
        )
    }

    private static func runLive(
        input: ExecutionInput,
        emit: @escaping (String) -> Void
    ) async throws -> [MarkdupResult] {
        let inputURL = URL(fileURLWithPath: input.path)
        let fm = FileManager.default

        guard let samtoolsPath = locateSamtools() else {
            throw ValidationError("samtools binary not found")
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inputURL.path, isDirectory: &isDir) else {
            throw ValidationError("Path does not exist: \(inputURL.path)")
        }

        if isDir.boolValue {
            try materializeNaoMgsBamsIfNeeded(
                at: inputURL,
                samtoolsPath: samtoolsPath,
                input: input,
                emit: emit
            )

            emitIfNeeded(input, line: "Scanning \(inputURL.path) for BAM files...", emit: emit)
            let bamURLs = collectBAMFiles(in: inputURL)
            return try await markdupBAMsUsingSharedPipeline(
                bamURLs,
                commandInput: input,
                samtoolsPath: samtoolsPath,
                provenanceDirectory: inputURL
            )
        }

        guard inputURL.pathExtension == "bam" else {
            throw ValidationError("File is not a .bam: \(inputURL.path)")
        }

        return try await markdupBAMsUsingSharedPipeline(
            [inputURL],
            commandInput: input,
            samtoolsPath: samtoolsPath,
            provenanceDirectory: inputURL.deletingLastPathComponent()
        )
    }

    private static func collectBAMFiles(in dirURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var bamURLs: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "bam" {
            bamURLs.append(fileURL)
        }
        return bamURLs.sorted {
            $0.standardizedFileURL.path.localizedStandardCompare($1.standardizedFileURL.path) == .orderedAscending
        }
    }

    private static func markdupBAMsUsingSharedPipeline(
        _ bamURLs: [URL],
        commandInput: ExecutionInput,
        samtoolsPath: String,
        provenanceDirectory: URL
    ) async throws -> [MarkdupResult] {
        let startedAt = Date()
        var results: [MarkdupResult] = []
        var provenanceRecords: [MarkdupPipelineRunRecord] = []
        results.reserveCapacity(bamURLs.count)
        provenanceRecords.reserveCapacity(bamURLs.count)

        for bamURL in bamURLs {
            let outcome = try await markdupBAMUsingSharedPipeline(
                bamURL: bamURL,
                commandInput: commandInput,
                samtoolsPath: samtoolsPath
            )
            results.append(outcome.result)
            if let provenanceRecord = outcome.provenanceRecord {
                provenanceRecords.append(provenanceRecord)
                try await recordMarkdupProvenance(
                    provenanceRecords,
                    commandInput: commandInput,
                    samtoolsPath: samtoolsPath,
                    outputDirectory: provenanceDirectory,
                    startedAt: startedAt,
                    endedAt: Date()
                )
            }
        }

        return results
    }

    private static func markdupBAMUsingSharedPipeline(
        bamURL: URL,
        commandInput: ExecutionInput,
        samtoolsPath: String
    ) async throws -> (result: MarkdupResult, provenanceRecord: MarkdupPipelineRunRecord?) {
        let startedAt = Date()
        let fm = FileManager.default

        guard fm.fileExists(atPath: bamURL.path) else {
            throw MarkdupError.fileNotFound(bamURL)
        }

        let inputDescriptor = ProvenanceFileDescriptor(
            fileRecord: ProvenanceRecorder.fileRecord(url: bamURL, format: .bam, role: .input)
        )
        if !commandInput.force && MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtoolsPath) {
            let indexInvocation = try ensureFreshIndex(bamURL: bamURL, samtoolsPath: samtoolsPath)
            let total = (try? MarkdupService.countReads(
                bamURL: bamURL,
                accession: nil,
                flagFilter: 0x004,
                samtoolsPath: samtoolsPath
            )) ?? 0
            let nonDup = (try? MarkdupService.countReads(
                bamURL: bamURL,
                accession: nil,
                flagFilter: 0x404,
                samtoolsPath: samtoolsPath
            )) ?? 0
            return (
                MarkdupResult(
                    bamURL: bamURL,
                    wasAlreadyMarkduped: true,
                    totalReads: total,
                    duplicateReads: max(0, total - nonDup),
                    durationSeconds: Date().timeIntervalSince(startedAt)
                ),
                try indexInvocation.map { invocation in
                    let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
                    return MarkdupPipelineRunRecord(
                        input: inputDescriptor,
                        outputs: [try ProvenanceFileDescriptor.file(url: baiURL, role: .index)],
                        invocations: [invocation]
                    )
                }
            )
        }

        let tempBamURL = URL(fileURLWithPath: bamURL.path + ".markdup.tmp")
        let tempBaiURL = URL(fileURLWithPath: tempBamURL.path + ".bai")
        let finalBaiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        let finalCsiURL = URL(fileURLWithPath: bamURL.path + ".csi")

        try? fm.removeItem(at: tempBamURL)
        try? fm.removeItem(at: tempBaiURL)

        let runner = MarkdupPipelineSamtoolsRunner(samtoolsURL: URL(fileURLWithPath: samtoolsPath))
        let pipeline = AlignmentMarkdupPipeline(samtoolsRunner: runner)
        var committedOutput = false

        do {
            _ = try await pipeline.run(
                inputURL: bamURL,
                outputURL: tempBamURL,
                removeDuplicates: false,
                referenceFastaPath: nil,
                sortThreads: commandInput.sortThreads,
                progressHandler: nil
            )

            guard fm.fileExists(atPath: tempBamURL.path),
                  let attrs = try? fm.attributesOfItem(atPath: tempBamURL.path),
                  let size = attrs[.size] as? Int,
                  size > 0 else {
                throw MarkdupError.corruptOutput(reason: "output BAM missing or empty at \(tempBamURL.path)")
            }

            try? fm.removeItem(at: finalBaiURL)
            try? fm.removeItem(at: finalCsiURL)
            _ = try fm.replaceItemAt(bamURL, withItemAt: tempBamURL)
            committedOutput = true
            if fm.fileExists(atPath: tempBaiURL.path) {
                try fm.moveItem(at: tempBaiURL, to: finalBaiURL)
            }

            guard fm.fileExists(atPath: finalBaiURL.path) else {
                throw MarkdupError.indexFailed(stderr: "samtools index did not produce \(finalBaiURL.path)")
            }

            let total = try MarkdupService.countReads(
                bamURL: bamURL,
                accession: nil,
                flagFilter: 0x004,
                samtoolsPath: samtoolsPath
            )
            let nonDup = try MarkdupService.countReads(
                bamURL: bamURL,
                accession: nil,
                flagFilter: 0x404,
                samtoolsPath: samtoolsPath
            )

            let bamOutput = try ProvenanceFileDescriptor.file(url: bamURL, format: .bam, role: .output)
            let baiOutput = try ProvenanceFileDescriptor.file(url: finalBaiURL, role: .index)
            let invocations = await runner.snapshot()
            let result = MarkdupResult(
                bamURL: bamURL,
                wasAlreadyMarkduped: false,
                totalReads: total,
                duplicateReads: max(0, total - nonDup),
                durationSeconds: Date().timeIntervalSince(startedAt)
            )
            let provenanceRecord = MarkdupPipelineRunRecord(
                input: inputDescriptor,
                outputs: [bamOutput, baiOutput],
                invocations: invocations
            )
            return (result, provenanceRecord)
        } catch {
            try? fm.removeItem(at: tempBamURL)
            try? fm.removeItem(at: tempBaiURL)
            let reportedError: Error
            if let alignmentError = error as? AlignmentMarkdupPipelineError {
                switch alignmentError {
                case .samtoolsFailed(let message):
                    reportedError = MarkdupError.pipelineFailed(stage: "markdup-pipeline", stderr: message)
                }
            } else {
                reportedError = error
            }
            if committedOutput {
                let invocations = await runner.snapshot()
                try? await recordMarkdupFailureProvenance(
                    input: inputDescriptor,
                    bamURL: bamURL,
                    baiURL: finalBaiURL,
                    invocations: invocations,
                    commandInput: commandInput,
                    samtoolsPath: samtoolsPath,
                    startedAt: startedAt,
                    endedAt: Date(),
                    error: reportedError
                )
            }
            throw reportedError
        }
    }

    private static func ensureFreshIndex(bamURL: URL, samtoolsPath: String) throws -> MarkdupSamtoolsInvocation? {
        let fm = FileManager.default
        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        let csiURL = URL(fileURLWithPath: bamURL.path + ".csi")
        let baiHealthy: Bool = {
            guard fm.fileExists(atPath: baiURL.path),
                  let attrs = try? fm.attributesOfItem(atPath: baiURL.path),
                  let size = attrs[.size] as? Int else {
                return false
            }
            return size > 0
        }()

        if !baiHealthy {
            try? fm.removeItem(at: baiURL)
            try? fm.removeItem(at: csiURL)
            return try runIndex(bamPath: bamURL.path, samtoolsPath: samtoolsPath)
        }

        if fm.fileExists(atPath: csiURL.path) {
            try? fm.removeItem(at: csiURL)
        }
        return nil
    }

    private static func runIndex(bamPath: String, samtoolsPath: String) throws -> MarkdupSamtoolsInvocation {
        let startedAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        process.arguments = ["index", bamPath]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw MarkdupError.indexFailed(stderr: error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let completedAt = Date()
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let result = NativeToolResult(
            exitCode: process.terminationStatus,
            stdout: "",
            stderr: stderr,
            arguments: [samtoolsPath, "index", bamPath]
        )

        guard result.isSuccess else {
            throw MarkdupError.indexFailed(stderr: stderr)
        }
        return MarkdupSamtoolsInvocation(
            startedAt: startedAt,
            completedAt: completedAt,
            result: result
        )
    }

    private static func recordMarkdupProvenance(
        _ records: [MarkdupPipelineRunRecord],
        commandInput: ExecutionInput,
        samtoolsPath: String,
        outputDirectory: URL,
        startedAt: Date,
        endedAt: Date
    ) async throws {
        let command = reproducibleArgv(for: commandInput)
        let samtoolsVersion = await detectSamtoolsVersion(samtoolsPath: samtoolsPath)
        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish markdup",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish markdup",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(command)
        .reproducibleCommand(command.map { shellEscape($0) }.joined(separator: " "))
        .options(
            explicit: provenanceExplicitOptions(for: commandInput),
            defaults: provenanceDefaultOptions(),
            resolved: provenanceResolvedOptions(for: commandInput)
        )
        .runtime(ProvenanceRuntimeIdentity())

        for record in records {
            for output in record.outputs {
                builder = try builder.output(
                    URL(fileURLWithPath: output.path),
                    format: output.format,
                    role: output.role
                )
            }
            for step in provenanceSteps(
                for: record,
                samtoolsVersion: samtoolsVersion
            ) {
                builder = builder.step(step)
            }
        }

        let stderr = records
            .flatMap(\.invocations)
            .map(\.result.stderr)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        let envelope = try builder.complete(
            exitStatus: 0,
            stderr: stderr.isEmpty ? nil : stderr,
            startedAt: startedAt,
            endedAt: endedAt
        )

        let writer = ProvenanceWriter()
        try writer.write(envelope, to: outputDirectory)
        for output in envelope.outputs {
            let outputURL = URL(fileURLWithPath: output.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            let focusedEnvelope = markdupEnvelope(
                envelope,
                focusedOn: relatedMarkdupOutputs(for: output, in: envelope)
            )
            try writer.write(focusedEnvelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        }
    }

    private static func recordMarkdupFailureProvenance(
        input: ProvenanceFileDescriptor,
        bamURL: URL,
        baiURL: URL,
        invocations: [MarkdupSamtoolsInvocation],
        commandInput: ExecutionInput,
        samtoolsPath: String,
        startedAt: Date,
        endedAt: Date,
        error: Error
    ) async throws {
        var outputs: [ProvenanceFileDescriptor] = []
        if FileManager.default.fileExists(atPath: bamURL.path),
           let bamOutput = try? ProvenanceFileDescriptor.file(url: bamURL, format: .bam, role: .output) {
            outputs.append(bamOutput)
        }
        if FileManager.default.fileExists(atPath: baiURL.path),
           let baiOutput = try? ProvenanceFileDescriptor.file(url: baiURL, role: .index) {
            outputs.append(baiOutput)
        }
        guard !outputs.isEmpty else {
            return
        }

        let command = reproducibleArgv(for: commandInput)
        let samtoolsVersion = await detectSamtoolsVersion(samtoolsPath: samtoolsPath)
        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish markdup",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish markdup",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(command)
        .reproducibleCommand(command.map { shellEscape($0) }.joined(separator: " "))
        .options(
            explicit: provenanceExplicitOptions(for: commandInput),
            defaults: provenanceDefaultOptions(),
            resolved: provenanceResolvedOptions(for: commandInput)
        )
        .runtime(ProvenanceRuntimeIdentity())

        for output in outputs {
            builder = try builder.output(
                URL(fileURLWithPath: output.path),
                format: output.format,
                role: output.role
            )
        }

        let record = MarkdupPipelineRunRecord(input: input, outputs: outputs, invocations: invocations)
        for step in provenanceSteps(for: record, samtoolsVersion: samtoolsVersion) {
            builder = builder.step(step)
        }

        let stderrParts = invocations
            .map(\.result.stderr)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            + [error.localizedDescription]
        let envelope = try builder.complete(
            exitStatus: 1,
            stderr: stderrParts.joined(separator: "\n"),
            startedAt: startedAt,
            endedAt: endedAt
        )

        let writer = ProvenanceWriter()
        try writer.write(envelope, to: bamURL.deletingLastPathComponent())
        for output in envelope.outputs {
            let outputURL = URL(fileURLWithPath: output.path)
            let focusedEnvelope = markdupEnvelope(
                envelope,
                focusedOn: relatedMarkdupOutputs(for: output, in: envelope)
            )
            try writer.write(focusedEnvelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        }
    }

    private static func relatedMarkdupOutputs(
        for output: ProvenanceFileDescriptor,
        in envelope: ProvenanceEnvelope
    ) -> [ProvenanceFileDescriptor] {
        let pairedPaths: Set<String>
        if output.path.hasSuffix(".bam") {
            pairedPaths = [output.path, output.path + ".bai"]
        } else if output.path.hasSuffix(".bam.bai") {
            let bamPath = String(output.path.dropLast(".bai".count))
            pairedPaths = [bamPath, output.path]
        } else {
            pairedPaths = [output.path]
        }
        let related = envelope.outputs.filter { pairedPaths.contains($0.path) }
        guard !related.isEmpty else {
            return [output]
        }
        return related.filter { $0.path == output.path } + related.filter { $0.path != output.path }
    }

    private static func markdupEnvelope(
        _ envelope: ProvenanceEnvelope,
        focusedOn selectedOutputs: [ProvenanceFileDescriptor]
    ) -> ProvenanceEnvelope {
        let selectedByPath = Dictionary(selectedOutputs.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
        let files = envelope.files.compactMap { descriptor -> ProvenanceFileDescriptor? in
            if let selected = selectedByPath[descriptor.path] {
                return selected
            }
            if descriptor.role == .output || descriptor.role == .index {
                return nil
            }
            return descriptor
        }
        let steps = envelope.steps.map { step in
            ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                argv: step.argv,
                reproducibleCommand: step.reproducibleCommand,
                inputs: step.inputs,
                outputs: step.outputs.compactMap { selectedByPath[$0.path] },
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
        return ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            reproducibleCommand: envelope.reproducibleCommand,
            options: envelope.options,
            runtimeIdentity: envelope.runtimeIdentity,
            files: files,
            output: selectedOutputs.first,
            outputs: selectedOutputs,
            steps: steps,
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
    }

    private static func provenanceSteps(
        for record: MarkdupPipelineRunRecord,
        samtoolsVersion: String
    ) -> [ProvenanceStep] {
        record.invocations.enumerated().map { index, invocation in
            let subcommand = invocation.subcommand
            let inputs: [ProvenanceFileDescriptor]
            let outputs: [ProvenanceFileDescriptor]
            switch (index, subcommand) {
            case (0, "sort"):
                inputs = [record.input]
                outputs = []
            case (_, "markdup"):
                inputs = []
                outputs = record.outputs.filter { $0.role == .output }
            case (_, "index"):
                let bamOutputs = record.outputs.filter { $0.role == .output }
                inputs = bamOutputs.isEmpty ? [record.input] : bamOutputs
                outputs = record.outputs.filter { $0.role == .index }
            default:
                inputs = []
                outputs = []
            }
            return ProvenanceStep(
                toolName: "samtools",
                toolVersion: samtoolsVersion,
                argv: invocation.argv,
                inputs: inputs,
                outputs: outputs,
                exitStatus: Int(invocation.result.exitCode),
                wallTimeSeconds: invocation.wallTimeSeconds,
                stderr: invocation.result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : invocation.result.stderr,
                startedAt: invocation.startedAt,
                completedAt: invocation.completedAt
            )
        }
    }

    private static func reproducibleArgv(for input: ExecutionInput) -> [String] {
        let actual = ProcessInfo.processInfo.arguments
        if actual.contains("markdup") && actual.contains(input.path) {
            return actual
        }

        var argv = ["lungfish", "markdup", input.path, "--sort-threads", String(input.sortThreads)]
        if input.force {
            argv.append("--force")
        }
        if input.quiet {
            argv.append("--quiet")
        }
        if input.outputFormat != .text {
            argv += ["--format", input.outputFormat.rawValue]
        }
        return argv
    }

    private static func provenanceDefaultOptions() -> [String: ParameterValue] {
        [
            "force": .boolean(false),
            "sortThreads": .integer(4),
            "quiet": .boolean(false),
            "outputFormat": .string(OutputFormat.text.rawValue),
        ]
    }

    private static func provenanceResolvedOptions(for input: ExecutionInput) -> [String: ParameterValue] {
        [
            "path": .string(input.path),
            "force": .boolean(input.force),
            "sortThreads": .integer(input.sortThreads),
            "quiet": .boolean(input.quiet),
            "outputFormat": .string(input.outputFormat.rawValue),
        ]
    }

    private static func provenanceExplicitOptions(for input: ExecutionInput) -> [String: ParameterValue] {
        provenanceResolvedOptions(for: input)
    }

    private static func detectSamtoolsVersion(samtoolsPath: String) async -> String {
        do {
            let result = try await NativeToolRunner.shared.runProcess(
                executableURL: URL(fileURLWithPath: samtoolsPath),
                arguments: ["--version"],
                timeout: 30,
                toolName: "samtools"
            )
            let output = (result.stdout + "\n" + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
                return String(output[range])
            }
            if let firstLine = output.split(whereSeparator: \.isNewline).first {
                return String(firstLine)
            }
        } catch {
            return "unknown"
        }
        return "unknown"
    }

    private static func materializeNaoMgsBamsIfNeeded(
        at inputURL: URL,
        samtoolsPath: String,
        input: ExecutionInput,
        emit: @escaping (String) -> Void
    ) throws {
        let naoMgsDbURL = inputURL.appendingPathComponent("hits.sqlite")
        guard FileManager.default.fileExists(atPath: naoMgsDbURL.path) else {
            return
        }

        emitIfNeeded(
            input,
            line: "Detected NAO-MGS result directory; materializing BAMs from SQLite...",
            emit: emit
        )

        do {
            let materialized = try NaoMgsBamMaterializer.materializeAll(
                dbPath: naoMgsDbURL.path,
                resultURL: inputURL,
                samtoolsPath: samtoolsPath,
                force: input.force,
                markDuplicates: false
            )
            emitIfNeeded(input, line: "Materialized \(materialized.count) BAM file(s)", emit: emit)
        } catch {
            emitIfNeeded(
                input,
                line: "Warning: NAO-MGS BAM materialization failed: \(error.localizedDescription)",
                emit: emit
            )
        }
    }

    private static func emitSummary(
        _ results: [MarkdupResult],
        emit: @escaping (String) -> Void
    ) {
        let processed = results.count
        let skipped = results.filter { $0.wasAlreadyMarkduped }.count
        let totalReads = results.reduce(0) { $0 + $1.totalReads }
        let totalDups = results.reduce(0) { $0 + $1.duplicateReads }
        let totalTime = results.reduce(0.0) { $0 + $1.durationSeconds }

        emit("Processed \(processed) BAM file\(processed == 1 ? "" : "s") (\(skipped) already marked)")
        emit("Total reads: \(totalReads), duplicates: \(totalDups)")
        emit(String(format: "Elapsed: %.1fs", totalTime))
    }

    private static func emitResults(
        _ results: [MarkdupResult],
        for input: ExecutionInput,
        emit: @escaping (String) -> Void
    ) {
        if input.outputFormat == .json {
            if let line = encodeJSONOutput(results) {
                emit(line)
            }
            return
        }

        guard !input.quiet else {
            return
        }
        emitSummary(results, emit: emit)
    }

    private static func emitIfNeeded(
        _ input: ExecutionInput,
        line: String,
        emit: @escaping (String) -> Void
    ) {
        guard input.outputFormat != .json, !input.quiet else {
            return
        }
        emit(line)
    }

    private static func encodeJSONOutput(_ results: [MarkdupResult]) -> String? {
        let summary = JSONOutput(
            processedBAMs: results.count,
            alreadyMarkedBAMs: results.filter(\.wasAlreadyMarkduped).count,
            totalReads: results.reduce(0) { $0 + $1.totalReads },
            duplicateReads: results.reduce(0) { $0 + $1.duplicateReads },
            elapsedSeconds: results.reduce(0.0) { $0 + $1.durationSeconds },
            results: results.map {
                JSONOutput.Result(
                    bamPath: $0.bamURL.path,
                    wasAlreadyMarkduped: $0.wasAlreadyMarkduped,
                    totalReads: $0.totalReads,
                    duplicateReads: $0.duplicateReads,
                    durationSeconds: $0.durationSeconds
                )
            }
        )
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(summary) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private struct JSONOutput: Encodable {
        struct Result: Encodable {
            let bamPath: String
            let wasAlreadyMarkduped: Bool
            let totalReads: Int
            let duplicateReads: Int
            let durationSeconds: Double
        }

        let processedBAMs: Int
        let alreadyMarkedBAMs: Int
        let totalReads: Int
        let duplicateReads: Int
        let elapsedSeconds: Double
        let results: [Result]
    }

    static func locateSamtools(homeDirectory: URL = currentHomeDirectory()) -> String? {
        SamtoolsLocator.locate(homeDirectory: homeDirectory, searchPath: nil)
    }

    private static func currentHomeDirectory() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

private struct MarkdupPipelineRunRecord: Sendable {
    let input: ProvenanceFileDescriptor
    let outputs: [ProvenanceFileDescriptor]
    let invocations: [MarkdupSamtoolsInvocation]
}

private struct MarkdupSamtoolsInvocation: Sendable {
    let startedAt: Date
    let completedAt: Date
    let result: NativeToolResult

    var argv: [String] {
        result.arguments
    }

    var subcommand: String? {
        guard argv.count > 1 else { return nil }
        return argv[1]
    }

    var wallTimeSeconds: TimeInterval {
        completedAt.timeIntervalSince(startedAt)
    }
}

private actor MarkdupPipelineSamtoolsRunner: AlignmentSamtoolsRunning {
    private let samtoolsURL: URL
    private var invocations: [MarkdupSamtoolsInvocation] = []

    init(samtoolsURL: URL) {
        self.samtoolsURL = samtoolsURL
    }

    func runSamtools(arguments: [String], timeout: TimeInterval) async throws -> NativeToolResult {
        let startedAt = Date()
        let result = try await NativeToolRunner.shared.runProcess(
            executableURL: samtoolsURL,
            arguments: arguments,
            timeout: timeout,
            toolName: "samtools"
        )
        let completedAt = Date()
        invocations.append(
            MarkdupSamtoolsInvocation(
                startedAt: startedAt,
                completedAt: completedAt,
                result: result
            )
        )
        return result
    }

    func snapshot() -> [MarkdupSamtoolsInvocation] {
        invocations
    }
}
