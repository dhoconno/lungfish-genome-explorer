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
        help: "Output directory for FASTQ files"
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
            "Archive to try first (default: ena). \(SRADownloadSourcePreference.tradeOff)",
            valueName: "source"
        )
    )
    var preferSource: SRADownloadSourcePreference?

    @Flag(
        name: .customLong("bundle"),
        help: ArgumentHelp(
            "Import the run into a .lungfishfastq bundle of --project, as the app's SRA row does",
            discussion: "The run is downloaded, imported with the import settings below and published into "
                + "<project>/Imports/ by a rename, with a provenance record. SIGTERM removes what the run staged and exits 125."
        )
    )
    var bundle: Bool = false

    @Option(
        name: [.customLong("project"), .customShort("p")],
        help: "Path to the .lungfish project directory the bundle imports into (with --bundle)"
    )
    var project: String?

    /// The settings of the import, the ones `import fastq` takes. They apply with --bundle.
    @OptionGroup var importOptions: ImportFastqOptions

    @OptionGroup var globalOptions: GlobalOptions

    /// Makes the service `run()` downloads with. A test binds one that
    /// scripts ENA and the SRA Toolkit, so it reaches no network.
    @TaskLocal static var makeService: @Sendable () -> SRAService = { SRAService() }

    func run() async throws {
        let reporter = SRADownloadReporter(
            accession: accession,
            eventsOn: globalOptions.outputFormat == .json,
            quiet: globalOptions.quiet,
            useColors: globalOptions.useColors,
            downloadShare: bundle ? SRADownloadBundleRun.downloadShare : 1,
            projectDirectory: URL(fileURLWithPath: project ?? outputDir)
        )
        reporter.start()
        if bundle {
            try await runBundle(reporter: reporter)
        } else {
            try await runPlain(reporter: reporter)
        }
    }

    var request: SRADownloadRequest {
        SRADownloadRequest(accession: accession, useToolkit: useToolkit, sourcePreference: sourcePreference)
    }

    /// The download alone, the run's FASTQ files in `--output-dir` with a record beside them.
    private func runPlain(reporter: SRADownloadReporter) async throws {
        let runClock = ProvenanceRunClock()
        let trace = SRADownloadTraceCapture(downloadSource: initialStrategy == "sra-toolkit" ? .sraToolkit : .ena)
        let outputURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        reporter.info("Downloading FASTQ for \(accession)...")
        reporter.info(
            useToolkit || sourcePreference == .ncbi
                ? "Using SRA Toolkit (prefetch + fasterq-dump)" : "Using ENA direct download"
        )
        let service = Self.makeService()
        do {
            let files = try await request.downloadFiles(service: service, into: outputURL, trace: trace, reporter: reporter)
            // The lone-mate rule the window applies, with ENA's layout or NCBI's.
            let layoutWarning = try await request.sortRunReads(files, service: service, enaRecord: trace.enaRecord).layoutWarning
            if let layoutWarning { reporter.layoutWarning(layoutWarning) }
            try writeSRADownloadProvenance(
                files: files,
                outputURL: outputURL,
                trace: trace,
                layoutWarning: layoutWarning,
                startedAt: runClock.startedAt,
                completedAt: runClock.now
            )
            reporter.completePlain(files: files)
        } catch let refusal as SRARunRefusal {
            reportFailedToolOutput(trace.steps)
            reporter.failedEvent(refusal.reason)
            throw CLIError.workflowFailed(reason: refusal.reason)
        } catch is CancellationError {
            reporter.failedEvent("Download cancelled")
            throw CLIError.cancelled
        } catch let error as SRAError {
            reportFailedToolOutput(trace.steps)
            reporter.failedEvent(error.localizedDescription)
            throw CLIError.networkError(reason: error.localizedDescription)
        } catch {
            reportFailedToolOutput(trace.steps)
            let reason = "Download failed: \(SRADownloadMessages.reason(of: error))"
            reporter.failedEvent(reason)
            throw CLIError.networkError(reason: reason)
        }
    }

    /// The download and the import of one run into `--project` (``SRADownloadBundleRun``). SIGTERM,
    /// which the Operations panel's Cancel sends, cancels the run, so the staging folder is removed
    /// before the command exits 125. It listens before the task starts, and a SIGTERM caught before
    /// then cancels the task as soon as it exists. A second SIGTERM ends the command at once.
    private func runBundle(reporter: SRADownloadReporter) async throws {
        let run = SRADownloadBundleRun(
            request: request,
            reporter: reporter,
            trace: SRADownloadTraceCapture(downloadSource: initialStrategy == "sra-toolkit" ? .sraToolkit : .ena),
            projectURL: URL(fileURLWithPath: project ?? "").standardizedFileURL,
            settings: SRADownloadImportSettings(
                platform: importOptions.platform,
                pairing: importOptions.pairing,
                qualityBinning: importOptions.qualityBinning,
                compression: importOptions.compression,
                recipe: importOptions.recipe,
                switchOptions: importOptions.switchOptions,
                noOptimizeStorage: importOptions.noOptimizeStorage,
                clumpingTool: importOptions.clumpingTool,
                threads: globalOptions.threads,
                quiet: globalOptions.quiet,
                useColors: globalOptions.useColors
            ),
            argv: sraDownloadCommand()
        )
        let pendingCancel = PendingTaskCancel<SRADownloadBundleRun.Outcome>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        let task = Task { await run.execute() }
        pendingCancel.attach(task)
        let outcome = await task.value
        termination.end()
        try SRADownloadBundleRun.finish(outcome, reporter: reporter)
    }

    /// The command that makes this run, which its record states.
    func sraDownloadCommand() -> [String] {
        var command = [CLICommandIdentity.executableName, "fetch", "sra", "download", accession]
        if bundle {
            command += ["--bundle", "--project", project ?? ""]
        } else {
            command += ["--output-dir", outputDir]
        }
        command += ["--format", globalOptions.outputFormat.rawValue]
        if useToolkit {
            command.append("--use-toolkit")
        }
        command += preferSourceArguments
        if bundle {
            command += importOptionArguments
        }
        if globalOptions.quiet {
            command.append("--quiet")
        }
        return command
    }

    /// The import settings that differ from the defaults, as the flags that give them, and the binning, which the
    /// command names whenever it is decided before the reads arrive, so its record replays the same whatever the
    /// default is (lane C2-BINNING). With `--platform auto` and no binning named, the import bins with the default of
    /// the platform it detects, and the record's `qualityBinning` names the scheme the bundle holds (BIO-BIN).
    private var importOptionArguments: [String] {
        var arguments: [String] = []
        if importOptions.platform != "auto" { arguments += ["--platform", importOptions.platform] }
        if importOptions.pairing != "auto" { arguments += ["--pairing", importOptions.pairing] }
        if let binning = importOptions.resolvedQualityBinning { arguments += ["--quality-binning", binning] }
        if importOptions.compression != "balanced" { arguments += ["--compression", importOptions.compression] }
        if importOptions.recipe != "none" { arguments += ["--recipe", importOptions.recipe] }
        arguments += importOptions.switchOptionArguments
        if importOptions.noOptimizeStorage { arguments.append("--no-optimize-storage") }
        if let tool = importOptions.clumpingTool { arguments += ["--clumping-tool", tool] }
        return arguments
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
        let failedStepCount = trace.failedAttemptStepCount
        // The steps of an attempt that did not serve the run stay recorded, marked failed, as the window marks them.
        var steps = trace.stepExecutions()
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
        try ProvenanceWriter().write(run.canonicalEnvelope(), toSidecar: provenanceURL)
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

final class SRADownloadTraceCapture: @unchecked Sendable {
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
