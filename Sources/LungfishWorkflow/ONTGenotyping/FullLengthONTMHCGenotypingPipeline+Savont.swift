import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension FullLengthONTMHCGenotypingPipeline {
    internal func selectSavontClusters(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        execution: FullLengthONTMHCSampleExecutionConfiguration,
        progressFraction: Double,
        progressHandler: (@Sendable (Double, String) -> Void)?,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> FullLengthONTMHCSavontSelectedClusters {
        let strictPreset = FullLengthONTMHCSavontPreset.requested(for: request)
        do {
            let strictClustering = try await runSavontClustering(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                execution: execution,
                preset: strictPreset,
                progressFraction: progressFraction,
                progressHandler: progressHandler,
                steps: &steps
            )
            let strictRecords = try FullLengthONTMHCClusterGenotyper.readFASTARecords(
                from: strictClustering.normalizedFASTAURL
            )
            guard strictRecords.isEmpty,
                  shouldRunHiddenSavontNoCallFallback(for: request) else {
                return try materializeSelectedSavontClusters(
                    strictClustering,
                    scheduled: scheduled,
                    preparedFASTQ: preparedFASTQ,
                    fallbackReason: nil,
                    handledSavontFailure: false,
                    steps: &steps
                )
            }
            progressHandler?(
                progressFraction,
                "No strict Savont ASVs for \(scheduled.sample); retrying with hidden QV90/min cluster size 1 fallback."
            )
            return try await runHiddenSavontNoCallFallback(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                execution: execution,
                progressFraction: progressFraction,
                progressHandler: progressHandler,
                fallbackReason: "strict-no-clusters",
                steps: &steps
            )
        } catch let error as FullLengthONTMHCGenotypingError {
            guard case .processFailed(let tool, _, _) = error,
                  tool == "savont",
                  shouldRunHiddenSavontNoCallFallback(for: request) else {
                throw error
            }
            progressHandler?(
                progressFraction,
                "Strict Savont failed for \(scheduled.sample); retrying with hidden QV90/min cluster size 1 fallback."
            )
            return try await runHiddenSavontNoCallFallback(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                execution: execution,
                progressFraction: progressFraction,
                progressHandler: progressHandler,
                fallbackReason: "strict-savont-failure",
                steps: &steps
            )
        }
    }

    internal func runHiddenSavontNoCallFallback(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        execution: FullLengthONTMHCSampleExecutionConfiguration,
        progressFraction: Double,
        progressHandler: (@Sendable (Double, String) -> Void)?,
        fallbackReason: String,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> FullLengthONTMHCSavontSelectedClusters {
        let fallbackPreset = FullLengthONTMHCSavontPreset.hiddenNoCallFallback
        do {
            let fallbackClustering = try await runSavontClustering(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                execution: execution,
                preset: fallbackPreset,
                progressFraction: progressFraction,
                progressHandler: progressHandler,
                steps: &steps
            )
            return try materializeSelectedSavontClusters(
                fallbackClustering,
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                fallbackReason: fallbackReason,
                handledSavontFailure: false,
                steps: &steps
            )
        } catch FullLengthONTMHCGenotypingError.processFailed(let tool, _, let stderr) where tool == "savont" {
            progressHandler?(
                progressFraction,
                "Savont fallback failed for \(scheduled.sample); recording sample as a no-call."
            )
            return try writeHandledSavontFailureNoCall(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                preset: fallbackPreset,
                fallbackReason: fallbackReason,
                stderr: stderr,
                steps: &steps
            )
        }
    }

    internal func shouldRunHiddenSavontNoCallFallback(for request: FullLengthONTMHCGenotypingRunRequest) -> Bool {
        request.savontQualityValueCutoff == FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff
            && request.savontMinimumClusterSize == FullLengthONTMHCGenotypingRunRequest.defaultSavontMinimumClusterSize
    }

    internal func runSavontClustering(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        execution: FullLengthONTMHCSampleExecutionConfiguration,
        preset: FullLengthONTMHCSavontPreset,
        progressFraction: Double,
        progressHandler: (@Sendable (Double, String) -> Void)?,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> FullLengthONTMHCSavontClusteringResult {
        let sampleOutputDirectory = request.outputDirectory
            .appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent(scheduled.sample, isDirectory: true)
            .appendingPathComponent("savont", isDirectory: true)
        let presetOutputDirectory = sampleOutputDirectory.appendingPathComponent(preset.directoryName, isDirectory: true)
        let rawOutputDirectory = presetOutputDirectory.appendingPathComponent("raw", isDirectory: true)
        if FileManager.default.fileExists(atPath: rawOutputDirectory.path) {
            try FileManager.default.removeItem(at: rawOutputDirectory)
        }
        try FileManager.default.createDirectory(at: presetOutputDirectory, withIntermediateDirectories: true)
        let normalizedFASTAURL = presetOutputDirectory
            .appendingPathComponent("\(scheduled.sample).\(preset.directoryName).savont-clusters.fasta")

        let firstAttempt = try await runSavontClusteringAttempt(
            scheduled: scheduled,
            preparedFASTQ: preparedFASTQ,
            sampleOutputDirectory: sampleOutputDirectory,
            finalRawOutputDirectory: rawOutputDirectory,
            request: request,
            preset: preset,
            savontThreads: max(1, execution.savontThreads),
            singleStrand: false,
            attempt: 1
        )
        if firstAttempt.exitCode == 0 {
            try finishSavontClusteringAttempt(
                firstAttempt,
                normalizedFASTAURL: normalizedFASTAURL,
                preparedFASTQ: preparedFASTQ,
                steps: &steps
            )
            return FullLengthONTMHCSavontClusteringResult(
                preset: preset,
                normalizedFASTAURL: normalizedFASTAURL,
                completedAttempt: firstAttempt
            )
        }
        steps.append(savontProvenanceStep(
            for: firstAttempt,
            preparedFASTQ: preparedFASTQ,
            outputs: []
        ))

        let retryDecision = FullLengthONTMHCSavontRunSupport.retryDecision(
            exitCode: firstAttempt.exitCode,
            attemptedThreads: firstAttempt.savontThreads,
            attemptedSingleStrand: firstAttempt.savontSingleStrand,
            stderr: firstAttempt.stderr
        )
        switch retryDecision {
        case .singleThread, .singleStrand:
            let retryThreads: Int
            let retrySingleStrand: Bool
            let retryDetail: String
            switch retryDecision {
            case .singleThread:
                retryThreads = 1
                retrySingleStrand = firstAttempt.savontSingleStrand
                retryDetail = "using 1 Savont thread"
            case .singleStrand:
                retryThreads = firstAttempt.savontThreads
                retrySingleStrand = true
                retryDetail = "using Savont --single-strand"
            case .none:
                retryThreads = firstAttempt.savontThreads
                retrySingleStrand = firstAttempt.savontSingleStrand
                retryDetail = "retrying"
            case .emptyClusters:
                retryThreads = firstAttempt.savontThreads
                retrySingleStrand = firstAttempt.savontSingleStrand
                retryDetail = "continuing with empty clusters"
            }
            progressHandler?(
                progressFraction,
                "Retrying \(scheduled.sample) after Savont exited with status \(firstAttempt.exitCode); \(retryDetail)."
            )
            let retryAttempt = try await runSavontClusteringAttempt(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                sampleOutputDirectory: sampleOutputDirectory,
                finalRawOutputDirectory: rawOutputDirectory,
                request: request,
                preset: preset,
                savontThreads: retryThreads,
                singleStrand: retrySingleStrand,
                attempt: 2
            )
            if retryAttempt.exitCode == 0 {
                try finishSavontClusteringAttempt(
                    retryAttempt,
                    normalizedFASTAURL: normalizedFASTAURL,
                    preparedFASTQ: preparedFASTQ,
                    steps: &steps
                )
                return FullLengthONTMHCSavontClusteringResult(
                    preset: preset,
                    normalizedFASTAURL: normalizedFASTAURL,
                    completedAttempt: retryAttempt
                )
            }
            steps.append(savontProvenanceStep(
                for: retryAttempt,
                preparedFASTQ: preparedFASTQ,
                outputs: []
            ))
            if FullLengthONTMHCSavontRunSupport.isLowCoverageNoClusterFailure(
                exitCode: retryAttempt.exitCode,
                attemptedSingleStrand: retryAttempt.savontSingleStrand,
                stderr: retryAttempt.stderr
            ) {
                try writeEmptySavontClusters(
                    normalizedFASTAURL: normalizedFASTAURL,
                    sample: scheduled.sample,
                    preparedFASTQ: preparedFASTQ,
                    stderr: retryAttempt.stderr,
                    steps: &steps
                )
                progressHandler?(
                    progressFraction,
                    "No Savont ASVs for \(scheduled.sample) after single-strand retry; continuing with empty cluster set."
                )
                return FullLengthONTMHCSavontClusteringResult(
                    preset: preset,
                    normalizedFASTAURL: normalizedFASTAURL,
                    completedAttempt: nil
                )
            }
            throw FullLengthONTMHCGenotypingError.processFailed(
                tool: "savont",
                status: retryAttempt.exitCode,
                stderr: retryAttempt.stderr
            )
        case .emptyClusters:
            try writeEmptySavontClusters(
                normalizedFASTAURL: normalizedFASTAURL,
                sample: scheduled.sample,
                preparedFASTQ: preparedFASTQ,
                stderr: firstAttempt.stderr,
                steps: &steps
            )
            progressHandler?(
                progressFraction,
                "No Savont ASVs for \(scheduled.sample); continuing with empty cluster set."
            )
            return FullLengthONTMHCSavontClusteringResult(
                preset: preset,
                normalizedFASTAURL: normalizedFASTAURL,
                completedAttempt: nil
            )
        case .none:
            break
        }

        throw FullLengthONTMHCGenotypingError.processFailed(
            tool: "savont",
            status: firstAttempt.exitCode,
            stderr: firstAttempt.stderr
        )
    }

    internal func materializeSelectedSavontClusters(
        _ clustering: FullLengthONTMHCSavontClusteringResult,
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        fallbackReason: String?,
        handledSavontFailure: Bool,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) throws -> FullLengthONTMHCSavontSelectedClusters {
        let sampleOutputDirectory = clustering.normalizedFASTAURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let selectedClustersFASTAURL = sampleOutputDirectory
            .appendingPathComponent("\(scheduled.sample).savont-clusters.fasta")
        if FileManager.default.fileExists(atPath: selectedClustersFASTAURL.path) {
            try FileManager.default.removeItem(at: selectedClustersFASTAURL)
        }
        try FileManager.default.copyItem(at: clustering.normalizedFASTAURL, to: selectedClustersFASTAURL)

        var inputs = [clustering.normalizedFASTAURL]
        var outputs = [selectedClustersFASTAURL]
        let selectedRawOutputDirectory = sampleOutputDirectory.appendingPathComponent("raw", isDirectory: true)
        if let completedAttempt = clustering.completedAttempt {
            try FullLengthONTMHCSavontRunSupport.materializeCompletedRawOutput(
                from: completedAttempt.plan.finalRawOutputDirectory,
                to: selectedRawOutputDirectory
            )
            inputs += try retainedSavontOutputURLs(in: completedAttempt.plan.finalRawOutputDirectory)
            outputs += try retainedSavontOutputURLs(in: selectedRawOutputDirectory)
        } else if FileManager.default.fileExists(atPath: selectedRawOutputDirectory.path) {
            try FileManager.default.removeItem(at: selectedRawOutputDirectory)
        }

        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish select Savont preset",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                CLICommandIdentity.executableName,
                "fastq",
                "full-length-ont-mhc-genotype",
                "select-savont-preset",
                scheduled.sample,
                "--savont-preset",
                clustering.preset.label,
            ],
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            stderr: fallbackReason,
            startedAt: completedAt,
            completedAt: completedAt
        ))

        return FullLengthONTMHCSavontSelectedClusters(
            preset: clustering.preset,
            clustersFASTAURL: selectedClustersFASTAURL,
            fallbackReason: fallbackReason,
            handledSavontFailure: handledSavontFailure
        )
    }

    internal func writeHandledSavontFailureNoCall(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        preset: FullLengthONTMHCSavontPreset,
        fallbackReason: String,
        stderr: String,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) throws -> FullLengthONTMHCSavontSelectedClusters {
        let sampleOutputDirectory = scheduled.sampleDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent(scheduled.sample, isDirectory: true)
            .appendingPathComponent("savont", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleOutputDirectory, withIntermediateDirectories: true)
        let selectedClustersFASTAURL = sampleOutputDirectory
            .appendingPathComponent("\(scheduled.sample).savont-clusters.fasta")
        let selectedRawOutputDirectory = sampleOutputDirectory.appendingPathComponent("raw", isDirectory: true)
        if FileManager.default.fileExists(atPath: selectedRawOutputDirectory.path) {
            try FileManager.default.removeItem(at: selectedRawOutputDirectory)
        }
        try Data().write(to: selectedClustersFASTAURL, options: .atomic)
        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish handled Savont failure",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                CLICommandIdentity.executableName,
                "fastq",
                "full-length-ont-mhc-genotype",
                "handled-savont-failure",
                scheduled.sample,
                "--savont-preset",
                preset.label,
            ],
            inputs: [preparedFASTQ],
            outputs: [selectedClustersFASTAURL],
            exitStatus: 0,
            stderr: stderr,
            startedAt: completedAt,
            completedAt: completedAt
        ))
        return FullLengthONTMHCSavontSelectedClusters(
            preset: preset,
            clustersFASTAURL: selectedClustersFASTAURL,
            fallbackReason: fallbackReason,
            handledSavontFailure: true
        )
    }

    internal func runSavontClusteringAttempt(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        sampleOutputDirectory: URL,
        finalRawOutputDirectory: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        preset: FullLengthONTMHCSavontPreset,
        savontThreads: Int,
        singleStrand: Bool,
        attempt: Int
    ) async throws -> FullLengthONTMHCSavontAttemptResult {
        let plan = FullLengthONTMHCSavontRunSupport.makePlan(
            sample: scheduled.sample,
            finalRawOutputDirectory: finalRawOutputDirectory,
            attempt: attempt
        )
        try FileManager.default.createDirectory(at: plan.scratchRootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plan.scratchRootDirectory) }
        var arguments = [
            "asv",
            preparedFASTQ.path,
            "-o", plan.scratchRawOutputDirectory.path,
            "-t", String(max(1, savontThreads)),
            "--min-read-length", String(request.minimumLength),
            "--max-read-length", String(request.maximumLength),
            "--quality-value-cutoff", String(preset.qualityValueCutoff),
            "--min-cluster-size", String(preset.minimumClusterSize),
        ]
        if singleStrand {
            arguments.append("--single-strand")
        }
        let startedAt = Date()
        let result = try await condaManager.runTool(
            name: "savont",
            arguments: arguments,
            environment: FullLengthONTMHCGenotypingRunRequest.savontCondaEnvironment,
            workingDirectory: sampleOutputDirectory,
            timeout: 7_200
        )
        if result.exitCode == 0 {
            try FullLengthONTMHCSavontRunSupport.materializeCompletedRawOutput(
                from: plan.scratchRawOutputDirectory,
                to: plan.finalRawOutputDirectory
            )
        }
        return FullLengthONTMHCSavontAttemptResult(
            plan: plan,
            savontThreads: max(1, savontThreads),
            savontSingleStrand: singleStrand,
            arguments: arguments,
            stderr: result.stderr,
            exitCode: result.exitCode,
            startedAt: startedAt,
            completedAt: Date()
        )
    }

    internal func finishSavontClusteringAttempt(
        _ attempt: FullLengthONTMHCSavontAttemptResult,
        normalizedFASTAURL: URL,
        preparedFASTQ: URL,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) throws {
        try FullLengthONTMHCSavontClusterNormalizer.normalize(
            savontFinalASVFASTAURL: attempt.plan.finalASVFASTAURL,
            outputFASTAURL: normalizedFASTAURL
        )
        steps.append(savontProvenanceStep(
            for: attempt,
            preparedFASTQ: preparedFASTQ,
            outputs: try retainedSavontOutputURLs(for: attempt) + [normalizedFASTAURL]
        ))
    }

    internal func retainedSavontOutputURLs(for attempt: FullLengthONTMHCSavontAttemptResult) throws -> [URL] {
        try retainedSavontOutputURLs(in: attempt.plan.finalRawOutputDirectory)
    }

    internal func retainedSavontOutputURLs(in rawOutputDirectory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let logs = try fileManager.contentsOfDirectory(
            at: rawOutputDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "log" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return [rawOutputDirectory.appendingPathComponent("final_asvs.fasta")] + logs
    }

    internal func savontProvenanceStep(
        for attempt: FullLengthONTMHCSavontAttemptResult,
        preparedFASTQ: URL,
        outputs: [URL]
    ) -> FullLengthONTMHCProvenanceStep {
        FullLengthONTMHCProvenanceStep(
            toolName: "savont",
            toolVersion: FullLengthONTMHCGenotypingRunRequest.savontToolVersion,
            argv: ["savont"] + attempt.arguments,
            inputs: [preparedFASTQ],
            outputs: outputs,
            exitStatus: attempt.exitCode,
            stderr: attempt.stderr,
            startedAt: attempt.startedAt,
            completedAt: attempt.completedAt
        )
    }

    internal func writeEmptySavontClusters(
        normalizedFASTAURL: URL,
        sample: String,
        preparedFASTQ: URL,
        stderr: String,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) throws {
        try Data().write(to: normalizedFASTAURL, options: .atomic)
        let completedAt = Date()
        steps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish empty Savont clusters",
            toolVersion: FullLengthONTMHCGenotypingRunRequest.savontToolVersion,
            argv: [
                CLICommandIdentity.executableName,
                "fastq",
                "full-length-ont-mhc-genotype",
                "empty-savont-clusters",
                sample,
            ],
            inputs: [preparedFASTQ],
            outputs: [normalizedFASTAURL],
            exitStatus: 0,
            stderr: stderr,
            startedAt: completedAt,
            completedAt: completedAt
        ))
    }

    internal func prepareReadsForSavont(
        inputFASTQ: URL,
        sample: String,
        sampleDirectory: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        execution: FullLengthONTMHCSampleExecutionConfiguration,
        steps: inout [FullLengthONTMHCProvenanceStep]
    ) async throws -> URL {
        var currentFASTQ = inputFASTQ
        if let orientReferenceURL = request.orientReferenceURL {
            let output = sampleDirectory.appendingPathComponent("01-oriented.fastq")
            let args = [
                "--orient", currentFASTQ.path,
                "--db", orientReferenceURL.path,
                "--fastqout", output.path,
                "--threads", String(execution.workerThreads),
            ]
            try await runNativeTool(
                .vsearch,
                arguments: args,
                inputs: [currentFASTQ, orientReferenceURL],
                outputs: [output],
                workingDirectory: sampleDirectory,
                provenanceOutputs: [],
                steps: &steps
            )
            currentFASTQ = output
        }

        if let forwardPrimerURL = request.forwardPrimerURL {
            let output = sampleDirectory.appendingPathComponent("02-forward-trimmed.fastq")
            let args = [
                "in=\(currentFASTQ.path)",
                "out=\(output.path)",
                "ref=\(forwardPrimerURL.path)",
                "k=15",
                "mink=11",
                "hdist=1",
                "ktrim=l",
                "rcomp=t",
                "threads=1",
            ]
            try await runNativeTool(
                .bbduk,
                arguments: args,
                inputs: [currentFASTQ, forwardPrimerURL],
                outputs: [output],
                workingDirectory: sampleDirectory,
                provenanceOutputs: [],
                steps: &steps
            )
            currentFASTQ = output
        }

        if let reversePrimerURL = request.reversePrimerURL {
            let output = sampleDirectory.appendingPathComponent("03-reverse-trimmed.fastq")
            let args = [
                "in=\(currentFASTQ.path)",
                "out=\(output.path)",
                "ref=\(reversePrimerURL.path)",
                "k=15",
                "mink=11",
                "hdist=1",
                "ktrim=r",
                "rcomp=t",
                "threads=1",
            ]
            try await runNativeTool(
                .bbduk,
                arguments: args,
                inputs: [currentFASTQ, reversePrimerURL],
                outputs: [output],
                workingDirectory: sampleDirectory,
                provenanceOutputs: [],
                steps: &steps
            )
            currentFASTQ = output
        }

        let filtered = sampleDirectory.appendingPathComponent("04-length-filtered.fastq")
        try await runNativeTool(
            .reformat,
            arguments: [
                "in=\(currentFASTQ.path)",
                "out=\(filtered.path)",
                "minlength=\(request.minimumLength)",
                "maxlength=\(request.maximumLength)",
                "threads=1",
            ],
            inputs: [currentFASTQ],
            outputs: [filtered],
            workingDirectory: sampleDirectory,
            provenanceOutputs: [],
            steps: &steps
        )

        _ = sample
        return filtered
    }
}
