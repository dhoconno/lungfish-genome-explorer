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
        formatter: TerminalFormatter
    ) async throws {
        let normalizedWorkflow = try validateViralReconWorkflowName()
        guard let supportedWorkflow = NFCoreSupportedWorkflowCatalog.workflow(named: normalizedWorkflow) else {
            throw CLIError.workflowFailed(reason: "Unsupported nf-core workflow: \(workflow)")
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
            reportReadPairing(pairingDecisions, formatter: formatter)
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
        if let stagedAnnotation, !globalOptions.quiet { print(formatter.info(stagedAnnotation.summary)) }
        let bundleClock = ProvenanceRunClock()
        try NFCoreRunBundleStore.write(
            request.manifest(createdAt: bundleClock.startedAt, executionStatus: .prepared),
            to: runBundleURL
        )

        if !globalOptions.quiet {
            print(formatter.info("Created run bundle: \(runBundleURL.path)"))
            print(formatter.info(request.commandPreview))
        }
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
            print(runBundleURL.path)
            return
        }

        // The managed Nextflow must exist before the bundle is marked
        // running: a missing engine is reported as such (exit 126, naming
        // Required Setup) with the bundle recorded as failed, instead of
        // launching whatever `nextflow` is on PATH and failing inside it.
        let processClock = ProvenanceRunClock()
        do {
            try Self.nfCoreWorkflowProcessRunner.preflightEngine()
        } catch {
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
                    exitCode: CLIExitCode.dependency.rawValue,
                    stderrLogPath: "logs/stderr.log"
                ),
                to: runBundleURL
            )
            try writeRunBundleProvenance(
                request: request,
                bundleURL: runBundleURL,
                prepareOnly: false,
                status: .failed,
                exitCode: CLIExitCode.dependency.rawValue,
                wallTime: endedAt.timeIntervalSince(processClock.startedAt),
                stderr: error.localizedDescription,
                readPairing: pairingDecisions,
                effectiveSamplesheetURL: nil,
                stagedAnnotation: stagedAnnotation
            )
            throw error
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
        defer { scratchEngine.finish(scratch, .remove) }
        let launchScratch = scratch.launchDirectory
        // Tasks run inside the work tree, and QUAST refuses a path containing a
        // space, so the tree leaves the scratch when the project name has one.
        let scratchWork = try NFCoreLaunchStaging.workDirectory(preferring: launchScratch)
        defer {
            if scratchWork.isFallback {
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
            if stagingRoot.isFallback {
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
            let quiet = globalOptions.quiet
            let prepared: ViralReconPreparedIlluminaSamples
            do {
                prepared = try await ViralReconReadPairing.prepareIlluminaSamples(
                    samples,
                    splitRoot: splitRoot,
                    progress: { message in
                        if !quiet { print(message) }
                    }
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
            }
            pairingDecisions = prepared.decisions
            try ViralReconReadPairing.writeDecisions(pairingDecisions, to: decisionsURL)
            let pairedSamplesheetURL = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(
                samples: prepared.samples,
                in: runBundleURL.appendingPathComponent("inputs", isDirectory: true),
                filename: ViralReconReadPairing.pairedSamplesheetFilename
            )
            effectiveSamplesheetURL = pairedSamplesheetURL
            reportReadPairing(pairingDecisions, formatter: formatter)
            launchRequest = launchRequest.replacing(inputURLs: [pairedSamplesheetURL])
        }

        let stagedRequest = try NFCoreLaunchStaging.stage(launchRequest, in: stagingRoot.root)
        // Newer nf-core releases express resource caps as Nextflow's
        // process.resourceLimits instead of --max_cpus / --max_memory.
        let resourcePlan = try NFCoreResourceLimits.plan(for: stagedRequest, in: launchScratch)
        let plannedRequest = resourcePlan.request
        var launchArguments = resourcePlan.nextflowArguments(base: plannedRequest.nextflowArguments)
        if plannedRequest.workDirectory == nil {
            launchArguments += ["-work-dir", scratchWorkDirectory.path]
        }
        // The engine streams its output into logs/nextflow.log as it runs (2.9 N8).
        let processResult = try await Self.nfCoreWorkflowProcessRunner.runNextflow(NFCoreWorkflowLaunch(
            arguments: launchArguments,
            profile: plannedRequest.executor.rawValue,
            workingDirectory: launchScratch,
            workDirectory: plannedRequest.workDirectory ?? scratchWorkDirectory,
            environment: plannedRequest.launchEnvironment,
            logFile: runBundleURL.appendingPathComponent("logs/nextflow.log")
        ))
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
                stderrLogPath: "logs/stderr.log"
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
            stagedAnnotation: stagedAnnotation
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
        print(runBundleURL.path)
    }

    /// Prints one line per samplesheet row saying how viralrecon gets its
    /// reads. Warnings (a mixed file that must run single-end) go to stderr
    /// even under --quiet, the same way the fastq subcommands report a
    /// pairing fallback.
    private func reportReadPairing(_ decisions: [ViralReconReadPairingDecision], formatter: TerminalFormatter) {
        for decision in decisions {
            if !globalOptions.quiet {
                print(formatter.info("Read pairing: \(decision.summary)"))
            }
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
        stagedAnnotation: ViralReconStagedAnnotation? = nil
    ) throws {
        let command = [CLICommandIdentity.executableName] + request.cliArguments(
            bundlePath: bundleURL,
            prepareOnly: prepareOnly
        ) + (globalOptions.quiet ? ["--quiet"] : [])
        let inputs = request.inputURLs.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .text, role: .input)
        }
        let outputs = [
            ProvenanceRecorder.fileOrDirectoryRecord(url: bundleURL, role: .output),
            ProvenanceRecorder.fileOrDirectoryRecord(url: request.outputDirectory, role: .output),
            ProvenanceRecorder.fileRecord(
                url: bundleURL.appendingPathComponent("manifest.json"),
                format: .json,
                role: .output
            )
        ] + expectedOutputRecords(for: request.expectedOutputURLs)
        var parameters = request.effectiveParams.mapValues { ParameterValue.string($0) }
        parameters["executor"] = .string(request.executor.rawValue)
        parameters["github_release_version"] = .string(request.version)
        parameters["resume"] = .boolean(request.resume)
        parameters["prepareOnly"] = .boolean(prepareOnly)
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

        let recordedAt = Date(), step = StepExecution(
            toolName: "\(CLICommandIdentity.executableName) workflow run",
            toolVersion: LungfishCLI.configuration.version,
            githubReleaseVersion: request.version,
            command: command,
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr,
            startTime: recordedAt, endTime: recordedAt
        )
        let run = WorkflowRun(
            name: request.displayTitle,
            startTime: recordedAt, endTime: recordedAt,
            status: status,
            steps: [step],
            parameters: parameters
        )
        try ProvenanceWriter().write(run.canonicalEnvelope(), to: bundleURL)
        if !prepareOnly, status == .completed {
            try writeExpectedOutputProvenance(run, to: request.expectedOutputURLs)
        }
    }
}
