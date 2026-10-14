// RunSubcommand+NFCore.swift - The nf-core path of `workflow run` (nf-core/viralrecon)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension RunSubcommand {
    func runNFCoreWorkflow(
        workflowParams: [String: String],
        output: WorkflowRunOutput
    ) async throws {
        let normalizedWorkflow = try validateViralReconWorkflowName()
        guard let supportedWorkflow = NFCoreSupportedWorkflowCatalog.workflow(named: normalizedWorkflow) else {
            throw CLIError.workflowFailed(reason: "Unsupported nf-core workflow: \(workflow)")
        }
        // N2 and N4. The lock's pin is the one source of the revision, so a lock without it refuses the run with 126
        // before anything is written, and no fallback release takes the pin's place.
        do {
            _ = try NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()
        } catch let refusal as NextflowDescriptorRefusal {
            throw CLIError.missingTool(reason: refusal.message)
        }
        guard !input.isEmpty else {
            throw CLIError.workflowFailed(reason: "nf-core/viralrecon needs one --input samplesheet.csv, or one or more --input .lungfishfastq bundles or FASTQ files")
        }

        let inputURLs = input.map { URL(fileURLWithPath: $0).standardizedFileURL }
        for inputURL in inputURLs where !FileManager.default.fileExists(atPath: inputURL.path) {
            throw CLIError.inputFileNotFound(path: inputURL.path)
        }

        try requireExpectedOutputsForExecution()
        let outputURL = URL(fileURLWithPath: resultsDir).standardizedFileURL
        let expectedOutputURLs = expectedOutput.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let runBundleURL = try resolveRunBundleURL(workflowName: supportedWorkflow.name)

        // The app hands over a samplesheet it built from the chosen bundles;
        // a bare CLI call may hand over the bundles and get the same
        // samplesheet. Either way the Illumina rows are read back so the
        // read pairing decisions below are made from the same data.
        var params = workflowParams
        let resolvedInputs: ViralReconCLIInputs.Resolved
        do {
            resolvedInputs = try ViralReconCLIInputs.resolve(
                inputURLs: inputURLs,
                runBundleURL: runBundleURL,
                params: &params
            )
        } catch let error as ViralReconCLIInputs.InputError {
            throw CLIError.workflowFailed(reason: error.localizedDescription)
        } catch let error as ViralReconReadPairing.PairingError {
            throw CLIError.workflowFailed(reason: error.localizedDescription)
        }
        let callerSamplesheetURL = resolvedInputs.samplesheetURL

        // Read pairing (Illumina): a strictly interleaved bundle file is split
        // into R1/R2 inside the run so viralrecon sees fastq_1 AND fastq_2;
        // the decision for every row is recorded before anything else runs.
        var pairingDecisions = resolvedInputs.illuminaSamples.map(ViralReconReadPairing.decisions(for:)) ?? []
        let decisionsURL = runBundleURL
            .appendingPathComponent("inputs", isDirectory: true)
            .appendingPathComponent(ViralReconReadPairing.decisionsFilename)
        if !pairingDecisions.isEmpty {
            try ViralReconReadPairing.writeDecisions(pairingDecisions, to: decisionsURL)
            reportReadPairing(pairingDecisions, output: output)
        }

        let request = NFCoreRunRequest(
            workflow: supportedWorkflow,
            version: version,
            executor: executor,
            inputURLs: [callerSamplesheetURL],
            outputDirectory: outputURL,
            expectedOutputURLs: expectedOutputURLs,
            params: params,
            resume: resume,
            workDirectory: workDir.map { URL(fileURLWithPath: $0) }
        )
        // Same gate the app applies (ViralReconWorkflowExecutionService):
        // only Docker reaches a working run, so refuse conda/local before a
        // run bundle is written rather than letting Nextflow fail later.
        try Self.requireSupportedExecutor(request)
        let stagedAnnotation = try NFCoreLaunchStaging.stageAnnotation(for: request, runBundleURL: runBundleURL)
        if let stagedAnnotation { output.info(stagedAnnotation.summary) }
        // A fact about the input before the launch, not the run's outcome, so an info event under --format json.
        if stagedAnnotation == nil, let notice = ViralReconAnnotationStaging.missingAnnotationNotice(params: request.params) {
            output.notice(notice)
        }
        let bundleClock = ProvenanceRunClock()
        try NFCoreRunBundleStore.write(
            request.manifest(createdAt: bundleClock.startedAt, executionStatus: .prepared),
            to: runBundleURL
        )

        output.info("Created run bundle: \(runBundleURL.path)")
        output.info(request.commandPreview)
        if prepareOnly {
            try writeRunBundleProvenance(
                request: request,
                bundleURL: runBundleURL,
                prepareOnly: true,
                status: .completed,
                exitCode: 0,
                wallTime: bundleClock.elapsed,
                stderr: nil,
                readPairing: pairingDecisions,
                effectiveSamplesheetURL: nil,
                stagedAnnotation: stagedAnnotation
            )
            output.complete([runBundleURL])
            return
        }

        // The managed Nextflow must exist before the bundle is marked
        // running: a missing engine is reported as such (exit 126, naming
        // Required Setup) with the bundle recorded as failed, instead of
        // launching whatever `nextflow` is on PATH and failing inside it.
        let processClock = ProvenanceRunClock()
        do {
            try Self.nfCoreWorkflowProcessRunner.preflightEngine()
            // The docker profile waits for the Docker daemon. A cancel ends the wait at once, and a Docker
            // Desktop that cannot be started fails the run at once (2.9 N9). The wait's two lines keep the
            // engine's words (rule 2 of the contract's section 5), and under --format json they are progress events.
            try await Self.nfCoreWorkflowProcessRunner.waitForDocker(
                profile: request.executor.rawValue,
                progress: { fraction, message in output.progress(fraction, message) }
            )
        } catch is CancellationError {
            // A cancel during the Docker wait is recorded as one during the engine's run is (SWIFT 3).
            recordCancelledRun(
                request: request,
                runBundleURL: runBundleURL,
                createdAt: bundleClock.startedAt,
                startedAt: processClock.startedAt,
                endedAt: processClock.now,
                readPairing: pairingDecisions,
                effectiveSamplesheetURL: nil,
                stagedAnnotation: stagedAnnotation
            )
            throw CancellationError()
        } catch {
            let dockerUnavailable = error is NextflowEngineError
            let exitCode = (dockerUnavailable ? CLIExitCode.containerError : CLIExitCode.dependency).rawValue
            let endedAt = processClock.now
            let stderrLogURL = runBundleURL.appendingPathComponent("logs/stderr.log")
            try PortablePath.sanitize(text: error.localizedDescription, forFileAt: stderrLogURL)
                .write(to: stderrLogURL, atomically: true, encoding: .utf8)
            try NFCoreRunBundleStore.write(
                request.manifest(
                    createdAt: bundleClock.startedAt,
                    executionStatus: .failed,
                    startedAt: processClock.startedAt,
                    completedAt: endedAt,
                    exitCode: exitCode,
                    stderrLogPath: "logs/stderr.log"
                ),
                to: runBundleURL
            )
            try writeRunBundleProvenance(
                request: request,
                bundleURL: runBundleURL,
                prepareOnly: false,
                status: .failed,
                exitCode: exitCode,
                wallTime: endedAt.timeIntervalSince(processClock.startedAt),
                stderr: error.localizedDescription,
                readPairing: pairingDecisions,
                effectiveSamplesheetURL: nil,
                stagedAnnotation: stagedAnnotation
            )
            throw dockerUnavailable ? CLIError.containerUnavailable : error
        }
        try NFCoreRunBundleStore.write(
            request.manifest(
                createdAt: bundleClock.startedAt,
                executionStatus: .running,
                startedAt: processClock.startedAt
            ),
            to: runBundleURL
        )
        // Nextflow's `.nextflow/` cache + history need POSIX file locks and
        // a volume free of AppleDouble `._` xattr sidecars (see
        // NextflowScratchVolumeProbe). The scratch stays on the bundle's
        // volume when it qualifies (external SSDs usually dwarf the boot
        // volume) and moves to local storage only when it does not; when the
        // caller did not pin --work-dir, the work tree follows the scratch.
        let scratchEngine = ProcessNFCoreWorkflowProcessRunner.engine(profile: request.executor.rawValue)
        let scratch = try scratchEngine.makeScratch(contextURL: runBundleURL)
        // A cancelled run leaves its scratch for the abandoned-scratch sweep, and
        // every other run removes it (P3, 2.9 N7).
        defer { scratchEngine.finish(scratch, Task.isCancelled ? .leaveForSweep : .remove) }
        let launchScratch = scratch.launchDirectory
        // Tasks run inside the work tree, and QUAST refuses a path containing a
        // space, so the tree leaves the scratch when the project name has one.
        // A fallback folder goes or stays with the scratch.
        let scratchWork = try NFCoreLaunchStaging.workDirectory(preferring: launchScratch)
        defer {
            if scratchWork.isFallback, !Task.isCancelled {
                try? FileManager.default.removeItem(at: scratchWork.root)
            }
        }
        let scratchWorkDirectory = scratchWork.root
        // nf-core schemas reject path parameters containing whitespace, and a
        // Lungfish project directory routinely has spaces in its name, so the
        // engine gets whitespace-free copies under the launch scratch. Only the
        // engine's view changes: the manifest and provenance written above and
        // below still record the caller's real paths.
        // The scratch itself may carry the project's whitespace, in which case
        // the staged copies go to a system temp directory of their own.
        let stagingRoot = try NFCoreLaunchStaging.stagingRoot(preferring: launchScratch)
        defer {
            if stagingRoot.isFallback, !Task.isCancelled {
                try? FileManager.default.removeItem(at: stagingRoot.root)
            }
        }

        // Split interleaved pairs now, inside the run: the mate files are
        // large, so they live under the whitespace-free staging root (the
        // samplesheet schema rejects a FASTQ path with a space) and go away
        // with it. The samplesheet viralrecon reads is kept in the bundle.
        // Nextflow also reads the staged annotation in place of the caller's.
        var launchRequest = request.replacing(params: ViralReconAnnotationStaging.launchParams(request.params, using: stagedAnnotation))
        var effectiveSamplesheetURL: URL?
        if let samples = resolvedInputs.illuminaSamples, pairingDecisions.contains(where: \.needsSplit) {
            let splitRoot = stagingRoot.root.appendingPathComponent(
                ViralReconReadPairing.splitDirectoryName,
                isDirectory: true
            )
            let prepared: ViralReconPreparedIlluminaSamples
            do {
                prepared = try await ViralReconReadPairing.prepareIlluminaSamples(
                    samples,
                    splitRoot: splitRoot,
                    progress: { message in output.plain(message) }
                )
            } catch let error as ViralReconReadPairing.PairingError {
                try NFCoreRunBundleStore.write(
                    request.manifest(
                        createdAt: bundleClock.startedAt,
                        executionStatus: .failed,
                        startedAt: processClock.startedAt,
                        completedAt: processClock.now,
                        exitCode: 1
                    ),
                    to: runBundleURL
                )
                try writeRunBundleProvenance(
                    request: request,
                    bundleURL: runBundleURL,
                    prepareOnly: false,
                    status: .failed,
                    exitCode: 1,
                    wallTime: processClock.elapsed,
                    stderr: error.localizedDescription,
                    readPairing: pairingDecisions,
                    effectiveSamplesheetURL: nil,
                    stagedAnnotation: stagedAnnotation
                )
                throw CLIError.workflowFailed(reason: error.localizedDescription)
            } catch is CancellationError {
                // Recorded here, before the scratch's defers leave it for the sweep (SWIFT 3, P3).
                recordCancelledRun(
                    request: request,
                    runBundleURL: runBundleURL,
                    createdAt: bundleClock.startedAt,
                    startedAt: processClock.startedAt,
                    endedAt: processClock.now,
                    readPairing: pairingDecisions,
                    effectiveSamplesheetURL: nil,
                    stagedAnnotation: stagedAnnotation
                )
                throw CancellationError()
            }
            pairingDecisions = prepared.decisions
            try ViralReconReadPairing.writeDecisions(pairingDecisions, to: decisionsURL)
            let pairedSamplesheetURL = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(
                samples: prepared.samples,
                in: runBundleURL.appendingPathComponent("inputs", isDirectory: true),
                filename: ViralReconReadPairing.pairedSamplesheetFilename
            )
            effectiveSamplesheetURL = pairedSamplesheetURL
            reportReadPairing(pairingDecisions, output: output)
            launchRequest = launchRequest.replacing(inputURLs: [pairedSamplesheetURL])
        }

        // Without --workdir the engine's request names the scratch's work
        // folder, so the launch writes it after -r as the descriptor does
        // (fit difference 4). The records keep the caller's request.
        if launchRequest.workDirectory == nil {
            launchRequest = launchRequest.replacing(workDirectory: scratchWorkDirectory)
        }
        let stagedRequest = try NFCoreLaunchStaging.stage(launchRequest, in: stagingRoot.root)
        // Newer nf-core releases express resource caps as Nextflow's
        // process.resourceLimits instead of --max_cpus / --max_memory.
        let resourcePlan = try NFCoreResourceLimits.plan(for: stagedRequest, in: launchScratch)
        let plannedRequest = resourcePlan.request
        // The Viral Recon descriptor writes the launch's argv, the one samplesheet as --input and the
        // -c files before run (N1). The request holds the one samplesheet this route built above.
        guard let engineSamplesheetURL = plannedRequest.inputURLs.first else {
            throw CLIError.workflowFailed(reason: "nf-core/viralrecon launches with one samplesheet")
        }
        let launchArguments = NextflowWorkflowDescriptor.viralRecon.nextflowArguments(
            for: plannedRequest.viralReconLaunch(samplesheet: engineSamplesheetURL, configFiles: resourcePlan.configFiles))
        // From here the manifest records the command the engine got, never the request's preview (Q33 fix 8).
        let launchCommand = NFCoreRunCommandBuilder.commandPreview(nextflowArguments: launchArguments)
        // N3. The Nextflow the launch starts is asked its version before the launch, never inside a cancel.
        let versionProbe = await (Self.nfCoreWorkflowProcessRunner as? any NFCoreEngineVersionProbing)?.probeEngineVersion()
        let logFile = runBundleURL.appendingPathComponent("logs/nextflow.log")
        // The engine streams its output into logs/nextflow.log as it runs (2.9 N8).
        let processResult: NFCoreWorkflowProcessResult
        do {
            processResult = try await Self.nfCoreWorkflowProcessRunner.runNextflow(NFCoreWorkflowLaunch(
                arguments: launchArguments,
                profile: plannedRequest.executor.rawValue,
                workingDirectory: launchScratch,
                workDirectory: plannedRequest.workDirectory ?? scratchWorkDirectory,
                environment: plannedRequest.launchEnvironment,
                logFile: logFile
            ))
        } catch is CancellationError {
            // The run is recorded as cancelled before its scratch is left for the sweep (SWIFT 3, P3).
            recordCancelledRun(
                request: request,
                runBundleURL: runBundleURL,
                createdAt: bundleClock.startedAt,
                startedAt: processClock.startedAt,
                endedAt: processClock.now,
                readPairing: pairingDecisions,
                effectiveSamplesheetURL: effectiveSamplesheetURL,
                stagedAnnotation: stagedAnnotation,
                launchCommand: launchCommand,
                engine: ViralReconEngineFacts.read(launchFolder: launchScratch, consoleLog: logFile, probe: versionProbe)
            )
            throw CancellationError()
        }
        try writeProcessLogs(processResult, to: runBundleURL.appendingPathComponent("logs", isDirectory: true))
        let processCompletedAt = processClock.now
        let executionStatus: NFCoreRunExecutionStatus = processResult.exitCode == 0 ? .completed : .failed
        try NFCoreRunBundleStore.write(
            request.manifest(
                createdAt: bundleClock.startedAt,
                executionStatus: executionStatus,
                startedAt: processClock.startedAt,
                completedAt: processCompletedAt,
                exitCode: processResult.exitCode,
                stdoutLogPath: "logs/stdout.log",
                stderrLogPath: "logs/stderr.log",
                commandPreview: launchCommand
            ),
            to: runBundleURL
        )
        try writeRunBundleProvenance(
            request: request,
            bundleURL: runBundleURL,
            prepareOnly: false,
            status: processResult.exitCode == 0 ? .completed : .failed,
            exitCode: processResult.exitCode,
            wallTime: processCompletedAt.timeIntervalSince(processClock.startedAt),
            stderr: processResult.standardError,
            readPairing: pairingDecisions,
            effectiveSamplesheetURL: effectiveSamplesheetURL,
            stagedAnnotation: stagedAnnotation,
            engine: ViralReconEngineFacts.read(launchFolder: launchScratch, consoleLog: logFile, probe: versionProbe)
        )
        if processResult.exitCode != 0 {
            throw CLIError.workflowFailed(
                reason: Self.engineFailureReason(
                    engineName: "Nextflow",
                    exitCode: processResult.exitCode,
                    stderr: processResult.standardError,
                    runBundleURL: runBundleURL
                )
            )
        }
        // After exit 0 the run's own trace and results say whether a task was ignored or a sample failed (N5).
        // Each kind is one warning line on standard error, even under --quiet, as a read pairing warning is, and
        // a warning `log` event under --format json.
        for line in Self.outcomeLines(
            request: request,
            samplesheetURL: effectiveSamplesheetURL ?? callerSamplesheetURL,
            launchedAt: processClock.startedAt
        ) {
            output.outcome(line)
        }
        output.complete([runBundleURL, request.outputDirectory])
    }

    /// The outcome lines of a Viral Recon run that exited 0, one for every ignored task and one for every failed
    /// sample, in UX's words (ARCH's ruling on A30 M3, decision N5).
    ///
    /// The trace is the newest one the release wrote in the results folder's `pipeline_info` since the launch
    /// (`nextflow.config:305-307`), and the samples are those of the samplesheet viralrecon read.
    static func outcomeLines(request: NFCoreRunRequest, samplesheetURL: URL, launchedAt: Date) -> [String] {
        let results = request.outputDirectory
        let traceText = NextflowTraceTask.newestTrace(
            in: results.appendingPathComponent("pipeline_info", isDirectory: true),
            writtenSince: launchedAt
        ).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let ignored = NextflowTraceTask.ignoredTasksLine(
            workflowName: AnalysisToolRegistry.displayName(forRawID: NextflowWorkflowDescriptor.viralRecon.toolID.rawValue),
            tasks: NextflowTraceTask.ignored(inTrace: traceText ?? "")
        )
        let failed = ViralReconRunOutcome.failedSamplesLine(ViralReconRunOutcome.failedSamples(
            ViralReconRunOutcome.sampleNames(inSamplesheetAt: samplesheetURL),
            resultsDirectory: results,
            params: request.effectiveParams,
            traceText: traceText
        ))
        return [ignored, failed].compactMap { $0 }
    }

    /// Prints one line per samplesheet row saying how viralrecon gets its
    /// reads. Warnings (a mixed file that must run single-end) go to stderr
    /// even under --quiet, the same way the fastq subcommands report a
    /// pairing fallback.
    private func reportReadPairing(_ decisions: [ViralReconReadPairingDecision], output: WorkflowRunOutput) {
        for decision in decisions {
            output.info("Read pairing: \(decision.summary)")
            if let warning = decision.warning {
                FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
            }
        }
    }

    /// Rejects an executor the nf-core run cannot use, with the message the
    /// app shows for the same request.
    static func requireSupportedExecutor(_ request: NFCoreRunRequest) throws {
        do {
            try request.validateExecutorSupported()
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    /// Records a cancelled run, the manifest and then the provenance, with the command's own exit code, 125, for a
    /// cancel during the Docker wait, the read split or the engine's run. After the engine's run its tree is gone and
    /// its whole output is in `logs/nextflow.log`. A record that cannot be written is reported on standard error and
    /// leaves the cancel as it is.
    private func recordCancelledRun(
        request: NFCoreRunRequest,
        runBundleURL: URL,
        createdAt: Date,
        startedAt: Date,
        endedAt: Date,
        readPairing: [ViralReconReadPairingDecision],
        effectiveSamplesheetURL: URL?,
        stagedAnnotation: ViralReconStagedAnnotation?,
        launchCommand: String? = nil,
        engine: ViralReconEngineFacts? = nil
    ) {
        let message = "Workflow cancelled"
        let exitCode = CLIExitCode.cancelled.rawValue
        do {
            let stderrLogURL = runBundleURL.appendingPathComponent("logs/stderr.log")
            try PortablePath.sanitize(text: message, forFileAt: stderrLogURL)
                .write(to: stderrLogURL, atomically: true, encoding: .utf8)
            try NFCoreRunBundleStore.write(
                request.manifest(
                    createdAt: createdAt,
                    executionStatus: .cancelled,
                    startedAt: startedAt,
                    completedAt: endedAt,
                    exitCode: exitCode,
                    stderrLogPath: "logs/stderr.log",
                    commandPreview: launchCommand
                ),
                to: runBundleURL
            )
            try writeRunBundleProvenance(
                request: request,
                bundleURL: runBundleURL,
                prepareOnly: false,
                status: .cancelled,
                exitCode: exitCode,
                wallTime: endedAt.timeIntervalSince(startedAt),
                stderr: message,
                readPairing: readPairing,
                effectiveSamplesheetURL: effectiveSamplesheetURL,
                stagedAnnotation: stagedAnnotation,
                engine: engine
            )
        } catch {
            FileHandle.standardError.write(Data("Could not record the cancelled run: \(error.localizedDescription)\n".utf8))
        }
    }

    private func writeProcessLogs(_ result: NFCoreWorkflowProcessResult, to logsURL: URL) throws {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try Self.writePortableLog(result.standardOutput, to: logsURL.appendingPathComponent("stdout.log"))
        try Self.writePortableLog(result.standardError, to: logsURL.appendingPathComponent("stderr.log"))
    }

    private func writeRunBundleProvenance(
        request: NFCoreRunRequest,
        bundleURL: URL,
        prepareOnly: Bool,
        status: RunStatus,
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?,
        readPairing: [ViralReconReadPairingDecision] = [],
        effectiveSamplesheetURL: URL? = nil,
        stagedAnnotation: ViralReconStagedAnnotation? = nil,
        engine: ViralReconEngineFacts? = nil
    ) throws {
        let command = [CLICommandIdentity.executableName] + request.cliArguments(
            bundlePath: bundleURL,
            prepareOnly: prepareOnly
        ) + (globalOptions.quiet ? ["--quiet"] : [])
        let inputs = Self.viralReconInputRecords(request: request, readPairing: readPairing, hashesReads: status != .cancelled)
        let outputs = [
            ProvenanceRecorder.fileOrDirectoryRecord(url: bundleURL, role: .output),
            ProvenanceRecorder.fileOrDirectoryRecord(url: request.outputDirectory, role: .output),
            ProvenanceRecorder.fileRecord(
                url: bundleURL.appendingPathComponent("manifest.json"),
                format: .json,
                role: .output
            )
        ] + expectedOutputRecords(for: request.expectedOutputURLs)
        // 2.9 R1. The step is the pipeline at the revision that ran, with its tag and launch source, and LGE's command
        // is the run's argv. The options split by 2.7 E12.
        let facts = Self.viralReconStepFacts(for: request)
        let options = viralReconRunOptions(request: request, prepareOnly: prepareOnly, releaseVersion: facts.githubReleaseVersion)
        var parameters = options.explicit
        if !request.expectedOutputURLs.isEmpty {
            parameters["expectedOutputs"] = .array(request.expectedOutputURLs.map { .file($0) })
        }
        if let workDirectory = request.workDirectory {
            parameters["workDirectory"] = .file(workDirectory)
        }
        if !readPairing.isEmpty {
            parameters["readPairing"] = .array(readPairing.map(\.provenanceValue))
        }
        if let effectiveSamplesheetURL {
            parameters["effectiveSamplesheet"] = .file(effectiveSamplesheetURL)
        }
        if let stagedAnnotation {
            parameters[ViralReconAnnotationStaging.provenanceKey] = stagedAnnotation.provenanceValue
        }

        // The run's real window, as the manifest written just before holds it, in place of the moment of writing.
        let window = Self.viralReconRunWindow(bundleURL: bundleURL, recordedAt: Date())
        let step = StepExecution(
            toolName: facts.toolName,
            toolVersion: facts.toolVersion,
            githubReleaseVersion: facts.githubReleaseVersion,
            command: command,
            resolvedOptions: Self.viralReconResolvedOptions(facts, engine: engine),
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr,
            startTime: window.start, endTime: window.end
        )
        let run = WorkflowRun(
            name: request.displayTitle,
            startTime: window.start, endTime: window.end,
            status: status,
            steps: [step],
            parameters: parameters
        )
        try ProvenanceWriter().write(run.canonicalEnvelope(resolvedDefaults: options.resolvedDefaults), to: bundleURL)
        if !prepareOnly, status == .completed {
            try writeExpectedOutputProvenance(run, to: request.expectedOutputURLs, resolvedDefaults: options.resolvedDefaults)
        }
    }
}
