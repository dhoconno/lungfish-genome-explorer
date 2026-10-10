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
        let runClock = ProvenanceRunClock()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let trace = SRADownloadTraceCapture(
            downloadSource: initialStrategy == "sra-toolkit" ? .sraToolkit : .ena
        )
        // With --format json, standard output holds the JSON result alone.
        let statusToStandardError = globalOptions.outputFormat == .json

        let outputURL = URL(fileURLWithPath: outputDir)

        // Create output directory if needed
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        if !globalOptions.quiet {
            Self.printStatus(formatter.info("Downloading FASTQ for \(accession)..."), toStandardError: statusToStandardError)
            if useToolkit || sourcePreference == .ncbi {
                Self.printStatus(formatter.info("Using SRA Toolkit (prefetch + fasterq-dump)"), toStandardError: statusToStandardError)
            } else {
                Self.printStatus(formatter.info("Using ENA direct download"), toStandardError: statusToStandardError)
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
                        Self.printStatus(
                            formatter.info("Download progress: \(Int(progress * 100))%"),
                            toStandardError: statusToStandardError
                        )
                    }
                } trace: { step in
                    trace.recordStep(step)
                }
            } else {
                let quiet = globalOptions.quiet
                let useColors = globalOptions.useColors
                files = try await service.downloadFASTQ(
                    accession: accession,
                    outputDir: outputURL,
                    preferring: sourcePreference,
                    progress: { progress in
                        if !quiet {
                            let formatter = TerminalFormatter(useColors: useColors)
                            Self.printStatus(
                                formatter.info("Download progress: \(Int(progress * 100))%"),
                                toStandardError: statusToStandardError
                            )
                        }
                    },
                    onFallback: { message in
                        trace.recordFallback(message)
                        if !quiet {
                            let formatter = TerminalFormatter(useColors: useColors)
                            Self.printStatus(formatter.info(message), toStandardError: statusToStandardError)
                        }
                    },
                    onSource: { source in
                        trace.recordSource(source)
                    },
                    onRecord: { record in
                        trace.recordENARecord(record)
                    },
                    trace: { step in
                        trace.recordStep(step)
                    }
                )
            }

            // The lone-mate rule the window applies, with ENA's layout or NCBI's.
            let layoutWarning = try await checkRunReads(files, service: service, enaRecord: trace.enaRecord)
            if let layoutWarning, !globalOptions.quiet {
                Self.printStatus(formatter.warning(layoutWarning), toStandardError: statusToStandardError)
            }

            try writeSRADownloadProvenance(
                files: files,
                outputURL: outputURL,
                trace: trace,
                layoutWarning: layoutWarning,
                startedAt: runClock.startedAt,
                completedAt: runClock.now
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
        } catch let refusal as SRARunRefusal {
            reportFailedToolOutput(trace.steps)
            throw CLIError.workflowFailed(reason: refusal.reason)
        } catch is CancellationError {
            throw CLIError.cancelled
        } catch let error as SRAError {
            reportFailedToolOutput(trace.steps)
            throw CLIError.networkError(reason: error.localizedDescription)
        } catch {
            reportFailedToolOutput(trace.steps)
            throw CLIError.networkError(reason: "Download failed: \(SRADownloadMessages.reason(of: error))")
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
        trace: SRADownloadTraceCapture,
        layoutWarning: String?
    ) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "accession": .string(accession),
            "outputDir": .string(URL(fileURLWithPath: outputDir).standardizedFileURL.path),
            "requestedStrategy": .string(requestedStrategy),
            "preferredSource": preferredSourceParameter,
            // The window's SRA import records the same names, from the same functions.
            "selectedStrategy": .string(SRADownloadStrategy.selected(
                preference: sourcePreference, toolkitOnly: useToolkit, source: trace.downloadSource
            )),
            "downloadSource": .string(trace.downloadSource.rawValue),
            "fallbackMessage": trace.fallbackMessage.map { .string($0) } ?? .null,
            "sourceInputs": .array(trace.sourceInputs.map { .string($0) }),
            "executedStepCount": .integer(trace.steps.count),
            "outputFormat": .string(globalOptions.outputFormat.rawValue),
            "quiet": .boolean(globalOptions.quiet),
            "containerRuntime": .string("none"),
            "condaEnvironment": .string(trace.downloadSource.recordedCondaEnvironment)
        ]
        if let layoutWarning {
            parameters["layoutWarning"] = .string(layoutWarning)
        }
        return parameters
    }

    private func writeSRADownloadProvenance(
        files: [URL],
        outputURL: URL,
        trace: SRADownloadTraceCapture,
        layoutWarning: String?,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let sraToolsVersion = try? ManagedToolLock.loadFromBundle().tool(named: "sra-tools")?.version
        let failedStepCount = trace.failedAttemptStepCount
        let failedAttempt = SRAService.FASTQDownloadStepTrace.failedAttemptOption
        var steps = trace.steps.enumerated().map { index, step in
            StepExecution(
                toolName: step.toolName,
                toolVersion: step.recordedToolVersion(sraToolsVersion: sraToolsVersion),
                command: step.command,
                // The steps of an attempt that did not serve the run stay
                // recorded, marked failed, as the window marks them.
                resolvedOptions: index < failedStepCount ? [failedAttempt.key: .string(failedAttempt.value)] : nil,
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
        // The command depends only on the steps that served the run.
        let servingStepIDs = steps.dropFirst(failedStepCount).map(\.id)
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
                dependsOn: servingStepIDs,
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
            parameters: sraDownloadProvenanceParameters(trace: trace, layoutWarning: layoutWarning)
        )
        let provenanceURL = outputURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try ProvenanceWriter(signingProvider: nil).write(run.canonicalEnvelope(), toSidecar: provenanceURL)
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

    /// Prints the whole standard error of each SRA Toolkit step that failed,
    /// under `--verbose`. The error the command ends with keeps one line.
    private func reportFailedToolOutput(_ steps: [SRAService.FASTQDownloadStepTrace]) {
        guard globalOptions.effectiveVerbosity > 0 else { return }
        for step in steps where (step.exitCode ?? 0) != 0 {
            guard let stderr = step.stderr, !stderr.isEmpty else { continue }
            FileHandle.standardError.write(Data("\(step.toolName) standard error:\n\(stderr)\n".utf8))
        }
    }
}

private final class SRADownloadTraceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _downloadSource: SRAFASTQDownloadSource
    private var _fallbackMessage: String?
    private var _failedAttemptStepCount = 0
    private var _enaRecord: ENAReadRecord?
    private var _steps: [SRAService.FASTQDownloadStepTrace] = []

    init(downloadSource: SRAFASTQDownloadSource) {
        self._downloadSource = downloadSource
    }

    /// How many of the first steps belong to the attempt that did not serve
    /// the run, which is every step recorded before the fallback started.
    var failedAttemptStepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _failedAttemptStepCount
    }

    /// ENA's record of the run, when ENA was asked and answered with one.
    var enaRecord: ENAReadRecord? {
        lock.lock()
        defer { lock.unlock() }
        return _enaRecord
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

    func recordFallback(_ message: String) {
        lock.lock()
        _fallbackMessage = message
        _failedAttemptStepCount = _steps.count
        lock.unlock()
    }

    func recordENARecord(_ record: ENAReadRecord) {
        lock.lock()
        _enaRecord = record
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
