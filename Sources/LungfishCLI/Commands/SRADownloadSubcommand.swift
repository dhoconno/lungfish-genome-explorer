// SRADownloadSubcommand.swift - Download FASTQ from SRA via ENA
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Download FASTQ from SRA via ENA
struct SRADownloadSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download FASTQ files from SRA"
    )

    @Argument(help: "SRA run accession (e.g., SRR11140748)")
    var accession: String

    @Option(
        name: .customLong("output-dir"),
        help: "Output directory for FASTQ files (default: current directory)"
    )
    var outputDir: String = "."

    @Flag(
        name: .customLong("use-toolkit"),
        help: "Fetch with the SRA Toolkit only, with no fallback to ENA (requires prefetch/fasterq-dump)"
    )
    var useToolkit: Bool = false

    @Option(
        name: .customLong("prefer-source"),
        help: ArgumentHelp(
            "Archive to try first, ena (default) or ncbi. \(SRADownloadSourcePreference.tradeOff)",
            valueName: "source"
        )
    )
    var preferSource: SRADownloadSourcePreference?

    @OptionGroup var globalOptions: GlobalOptions

    /// Makes the service `run()` downloads with. A test binds one that
    /// scripts ENA and the SRA Toolkit, so it reaches no network.
    @TaskLocal static var makeService: @Sendable () -> SRAService = { SRAService() }

    func run() async throws {
        let startedAt = Date()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let trace = SRADownloadTraceCapture(
            selectedStrategy: initialStrategy,
            downloadSource: initialStrategy == "sra-toolkit" ? .sraToolkit : .ena
        )

        let outputURL = URL(fileURLWithPath: outputDir)

        // Create output directory if needed
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        if !globalOptions.quiet {
            print(formatter.info("Downloading FASTQ for \(accession)..."))
            if useToolkit || sourcePreference == .ncbi {
                print(formatter.info("Using SRA Toolkit (prefetch + fasterq-dump)"))
            } else {
                print(formatter.info("Using ENA direct download"))
            }
        }

        let service = Self.makeService()

        do {
            let files: [URL]

            if useToolkit {
                files = try await service.downloadFASTQ(
                    accession: accession,
                    outputDir: outputURL
                ) { progress in
                    if !globalOptions.quiet {
                        print(formatter.info("Download progress: \(Int(progress * 100))%"))
                    }
                } trace: { step in
                    trace.recordStep(step)
                }
            } else {
                let quiet = globalOptions.quiet
                let useColors = globalOptions.useColors
                let fallbackStrategy = fallbackStrategy
                files = try await service.downloadFASTQ(
                    accession: accession,
                    outputDir: outputURL,
                    preferring: sourcePreference,
                    progress: { progress in
                        if !quiet {
                            let formatter = TerminalFormatter(useColors: useColors)
                            print(formatter.info("Download progress: \(Int(progress * 100))%"))
                        }
                    },
                    onFallback: { message in
                        trace.recordFallback(message, strategy: fallbackStrategy)
                        if !quiet {
                            let formatter = TerminalFormatter(useColors: useColors)
                            print(formatter.info(message))
                        }
                    },
                    onSource: { source in
                        trace.recordSource(source)
                    },
                    trace: { step in
                        trace.recordStep(step)
                    }
                )
            }

            try writeSRADownloadProvenance(
                files: files,
                outputURL: outputURL,
                trace: trace,
                startedAt: startedAt,
                completedAt: Date()
            )

            if globalOptions.outputFormat == .json {
                let result = SRADownloadResult(
                    accession: accession,
                    files: files.map { $0.path },
                    outputDir: outputDir
                )
                let handler = JSONOutputHandler()
                handler.writeData(result, label: nil)
            } else {
                print(formatter.success("Downloaded \(files.count) FASTQ file(s):"))
                for file in files {
                    print("  - \(file.lastPathComponent)")
                }
            }
        } catch let error as SRAError {
            throw CLIError.networkError(reason: error.localizedDescription)
        } catch {
            throw CLIError.networkError(reason: "Download failed: \(error.localizedDescription)")
        }
    }

    private func sraDownloadCommand() -> [String] {
        var command = [
            CLICommandIdentity.executableName,
            "fetch",
            "sra",
            "download",
            accession,
            "--output-dir", outputDir,
            "--format", globalOptions.outputFormat.rawValue
        ]
        if useToolkit {
            command.append("--use-toolkit")
        }
        command += preferSourceArguments
        if globalOptions.quiet {
            command.append("--quiet")
        }
        return command
    }

    private func sraDownloadProvenanceParameters(
        trace: SRADownloadTraceCapture
    ) -> [String: ParameterValue] {
        [
            "accession": .string(accession),
            "outputDir": .string(URL(fileURLWithPath: outputDir).standardizedFileURL.path),
            "requestedStrategy": .string(requestedStrategy),
            "preferredSource": preferredSourceParameter,
            "selectedStrategy": .string(trace.selectedStrategy),
            // The window's SRA import records the same names.
            "downloadSource": .string(trace.downloadSource.rawValue),
            "fallbackMessage": trace.fallbackMessage.map { .string($0) } ?? .null,
            "sourceInputs": .array(trace.sourceInputs.map { .string($0) }),
            "executedStepCount": .integer(trace.steps.count),
            "outputFormat": .string(globalOptions.outputFormat.rawValue),
            "quiet": .boolean(globalOptions.quiet),
            "containerRuntime": .string("none"),
            // The SRA Toolkit runs in the managed sra-tools environment, as the window records.
            "condaEnvironment": .string(trace.downloadSource.usesSRAToolkit ? "managed sra-tools" : "none")
        ]
    }

    private func writeSRADownloadProvenance(
        files: [URL],
        outputURL: URL,
        trace: SRADownloadTraceCapture,
        startedAt: Date,
        completedAt: Date
    ) throws {
        var steps = trace.steps.map { step in
            StepExecution(
                toolName: step.toolName,
                toolVersion: sraStepToolVersion(step.toolVersion),
                command: step.command,
                inputs: step.inputs.map { input in
                    FileRecord(path: input, format: detectSRAInputFormat(input), role: .input)
                },
                outputs: step.outputs.map {
                    ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output)
                },
                exitCode: step.exitCode,
                wallTime: step.wallTime,
                stderr: step.stderr,
                startTime: step.startedAt,
                endTime: step.completedAt
            )
        }
        steps.append(
            StepExecution(
                toolName: CLICommandIdentity.executableName,
                toolVersion: LungfishCLI.configuration.version,
                command: sraDownloadCommand(),
                inputs: trace.sourceInputs.map { input in
                    FileRecord(path: input, format: detectSRAInputFormat(input), role: .input)
                },
                outputs: files.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) },
                exitCode: 0,
                wallTime: completedAt.timeIntervalSince(startedAt),
                stderr: trace.fallbackMessage,
                dependsOn: steps.last.map { [$0.id] } ?? [],
                startTime: startedAt,
                endTime: completedAt
            )
        )

        let run = WorkflowRun(
            name: "sra-fastq-download",
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            appVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
            hostOS: WorkflowRun.currentHostOS,
            steps: steps,
            parameters: sraDownloadProvenanceParameters(trace: trace)
        )
        let provenanceURL = outputURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try run.writeSidecar(to: provenanceURL)
    }

    private func detectSRAInputFormat(_ input: String) -> FileFormat? {
        let lowercase = input.lowercased()
        if lowercase.hasSuffix(".fastq") || lowercase.hasSuffix(".fq")
            || lowercase.hasSuffix(".fastq.gz") || lowercase.hasSuffix(".fq.gz") {
            return .fastq
        }
        if lowercase.hasSuffix(".sra") {
            return .unknown
        }
        return nil
    }

    private func sraStepToolVersion(_ version: String) -> String {
        guard version == "sra-tools",
              let lockVersion = try? ManagedToolLock.loadFromBundle().tool(named: "sra-tools")?.version else {
            return version
        }
        return "sra-tools \(lockVersion)"
    }
}

private final class SRADownloadTraceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _selectedStrategy: String
    private var _downloadSource: SRAFASTQDownloadSource
    private var _fallbackMessage: String?
    private var _steps: [SRAService.FASTQDownloadStepTrace] = []

    init(selectedStrategy: String, downloadSource: SRAFASTQDownloadSource) {
        self._selectedStrategy = selectedStrategy
        self._downloadSource = downloadSource
    }

    var selectedStrategy: String {
        lock.lock()
        defer { lock.unlock() }
        return _selectedStrategy
    }

    var downloadSource: SRAFASTQDownloadSource {
        lock.lock()
        defer { lock.unlock() }
        return _downloadSource
    }

    var fallbackMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return _fallbackMessage
    }

    var steps: [SRAService.FASTQDownloadStepTrace] {
        lock.lock()
        defer { lock.unlock() }
        return _steps
    }

    var sourceInputs: [String] {
        lock.lock()
        defer { lock.unlock() }
        let inputs = _steps.flatMap(\.inputs)
        return Array(Set(inputs)).sorted()
    }

    func recordFallback(_ message: String, strategy: String) {
        lock.lock()
        _selectedStrategy = strategy
        _fallbackMessage = message
        lock.unlock()
    }

    func recordSource(_ source: SRAFASTQDownloadSource) {
        lock.lock()
        _downloadSource = source
        lock.unlock()
    }

    func recordStep(_ step: SRAService.FASTQDownloadStepTrace) {
        lock.lock()
        _steps.append(step)
        lock.unlock()
    }
}
