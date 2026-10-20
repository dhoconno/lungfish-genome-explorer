// TaxTriageSerialBatchRunner.swift - Serial per-sample TaxTriage batch execution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public enum TaxTriageSerialBatchError: Error, LocalizedError, Sendable {
    case allSamplesFailed([TaxTriageSampleFailure])

    public var errorDescription: String? {
        switch self {
        case .allSamplesFailed(let failures):
            let first = failures.first?.errorDescription ?? "No sample completed"
            return "All TaxTriage samples failed. First failure: \(first)"
        }
    }
}

public struct TaxTriageSerialBatchRunner: Sendable {
    public typealias PipelineRun = @Sendable (
        TaxTriageConfig,
        (@Sendable (Double, String) -> Void)?
    ) async throws -> TaxTriageResult

    private let runPipeline: PipelineRun

    public init(runPipeline: @escaping PipelineRun = { config, progress in
        let pipeline = TaxTriagePipeline()
        return try await pipeline.run(config: config, progress: progress)
    }) {
        self.runPipeline = runPipeline
    }

    public func run(
        config: TaxTriageConfig,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> TaxTriageResult {
        guard config.samples.count > 1 else {
            return try await runPipeline(config, progress)
        }

        // N4. The pin resolves before the batch root exists, so an unpinned TaxTriage leaves no folder,
        // and every sample runs the revision the batch records.
        let pin = try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin()
        var config = config
        config.revision = config.launchRevision(pin: pin)

        let runClock = ProvenanceRunClock()
        let total = config.samples.count
        let root = config.outputDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let runID = await ProvenanceRecorder.shared.beginRun(
            name: "TaxTriage Serial Batch",
            parameters: provenanceParameters(for: config, pin: pin)
        )

        var usedDirectoryNames = Set<String>()
        var sampleResults: [TaxTriageResult] = []
        var sampleFailures: [TaxTriageSampleFailure] = []

        for (index, sample) in config.samples.enumerated() {
            try await throwIfCancelled(runID: runID, root: root)

            let directoryName = uniqueDirectoryName(for: sample.sampleId, usedNames: &usedDirectoryNames)
            let sampleOutputDirectory = root.appendingPathComponent(directoryName, isDirectory: true)
            var sampleConfig = config
            sampleConfig.samples = [sample]
            sampleConfig.outputDirectory = sampleOutputDirectory
            if let sourceBundleURLs = config.sourceBundleURLs,
               sourceBundleURLs.indices.contains(index) {
                sampleConfig.sourceBundleURLs = [sourceBundleURLs[index]]
            } else {
                sampleConfig.sourceBundleURLs = nil
            }

            let samplePrefix = "Sample \(index + 1)/\(total) (\(sample.sampleId))"
            progress?(Double(index) / Double(total), "\(samplePrefix): Starting TaxTriage")

            let sampleClock = ProvenanceRunClock()
            do {
                let result = try await runPipeline(sampleConfig) { sampleProgress, message in
                    let bounded = max(0, min(1, sampleProgress))
                    let overall = (Double(index) + bounded) / Double(total)
                    progress?(overall, "\(samplePrefix): \(message)")
                }
                sampleResults.append(result)
                await recordSampleProvenance(
                    runID: runID,
                    pin: pin,
                    sample: sample,
                    result: result,
                    exitCode: 0,
                    wallTime: sampleClock.elapsed,
                    stderr: nil
                )
            } catch _ where Task.isCancelled {
                // A cancel, from the request and never from how the engine ended, ends the batch
                // at the next sample, with this sample recorded as cancelled, not failed (T9, E5).
                await recordSampleFailureProvenance(
                    runID: runID,
                    pin: pin,
                    sample: sample,
                    config: sampleConfig,
                    outputDirectory: sampleOutputDirectory,
                    wallTime: sampleClock.elapsed,
                    error: TaxTriagePipelineError.cancelled,
                    exitCode: AnalysisRunExitCode.cancelled
                )
            } catch {
                let failure = TaxTriageSampleFailure(
                    sampleID: sample.sampleId,
                    outputDirectory: sampleOutputDirectory,
                    errorDescription: error.localizedDescription
                )
                sampleFailures.append(failure)
                await recordSampleFailureProvenance(
                    runID: runID,
                    pin: pin,
                    sample: sample,
                    config: sampleConfig,
                    outputDirectory: sampleOutputDirectory,
                    wallTime: sampleClock.elapsed,
                    error: error
                )
                progress?(
                    Double(index + 1) / Double(total),
                    "\(samplePrefix): Failed - \(error.localizedDescription)"
                )
            }
        }
        // A cancel after the last sample wins too, so no aggregate is written (T10).
        try await throwIfCancelled(runID: runID, root: root)

        guard !sampleResults.isEmpty else {
            await ProvenanceRecorder.shared.completeRun(runID, status: .failed)
            try await ProvenanceRecorder.shared.save(runID: runID, to: root)
            throw TaxTriageSerialBatchError.allSamplesFailed(sampleFailures)
        }

        let resultURL = root.appendingPathComponent("taxtriage-result.json")
        let allOutputFiles = (
            TaxTriageOutputArtifactPolicy.filterRetainedOutputFiles(
                sampleResults.flatMap(\.allOutputFiles),
                outputDirectory: root
            ) + [resultURL]
        )
            .uniquedByPath()
            .sorted { $0.path < $1.path }
        let aggregate = TaxTriageResult(
            config: config,
            runtime: runClock.elapsed,
            exitCode: 0,
            outputDirectory: root,
            reportFiles: sampleResults.flatMap(\.reportFiles).uniquedByPath().sorted { $0.path < $1.path },
            metricsFiles: sampleResults.flatMap(\.metricsFiles).uniquedByPath().sorted { $0.path < $1.path },
            kronaFiles: sampleResults.flatMap(\.kronaFiles).uniquedByPath().sorted { $0.path < $1.path },
            logFile: nil,
            traceFile: nil,
            allOutputFiles: allOutputFiles,
            sourceBundleURLs: config.sourceBundleURLs,
            ignoredFailures: sampleResults.flatMap(\.ignoredFailures),
            sampleFailures: sampleFailures
        )
        try aggregate.save()

        await recordAggregateProvenance(
            runID: runID,
            config: config,
            result: aggregate,
            wallTime: runClock.elapsed
        )
        await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
        try await ProvenanceRecorder.shared.save(runID: runID, to: root)

        progress?(1.0, "TaxTriage serial batch complete")
        return aggregate
    }

    private func uniqueDirectoryName(for sampleID: String, usedNames: inout Set<String>) -> String {
        SampleFolderNaming.uniqueDirectoryName(for: sampleID, usedNames: &usedNames)
    }

    /// Ends a cancelled batch with its record saved as cancelled (T9). The status comes from the
    /// cancel request, never from how an engine ended (2.7 E5).
    private func throwIfCancelled(runID: UUID, root: URL) async throws {
        guard Task.isCancelled else { return }
        await ProvenanceRecorder.shared.completeRun(runID, status: .cancelled)
        try await ProvenanceRecorder.shared.save(runID: runID, to: root)
        throw CancellationError()
    }

    private func provenanceParameters(for config: TaxTriageConfig, pin: NextflowPipelinePin) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "workflow": .string("taxtriage-serial-batch"),
            "sample_count": .integer(config.samples.count),
            "platform": .string(config.platform.rawValue),
            "classifiers": .array(config.classifiers.map { .string($0) }),
            "top_hits_count": .integer(config.topHitsCount),
            "k2_confidence": .number(config.k2Confidence),
            "rank": .string(config.rank),
            "skip_assembly": .boolean(config.skipAssembly),
            "skip_krona": .boolean(config.skipKrona),
            "max_memory": .string(config.maxMemory),
            "max_cpus": .integer(config.maxCpus),
            "profile": .string(config.profile),
            "revision": .string(config.launchRevision(pin: pin)),
            "extraArgs": .string(AdvancedCommandLineOptions.join(config.extraArguments)),
            "output_directory": .file(config.outputDirectory),
            "remove_taxids": .string(config.effectiveRemoveTaxids ?? ""),
        ]
        if let githubReleaseVersion = TaxTriageConfig.githubReleaseVersion(for: config.launchRevision(pin: pin), pin: pin) {
            parameters["github_release_version"] = .string(githubReleaseVersion)
        }
        return parameters
    }

    private func recordSampleProvenance(
        runID: UUID,
        pin: NextflowPipelinePin,
        sample: TaxTriageSample,
        result: TaxTriageResult,
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) async {
        // One warning line for each task failure TaxTriage ignored in the sample, the lines the sample's own
        // record holds, while the sample and the batch stay completed (T8).
        let stderrLines = ([stderr ?? ""] + TaxTriageRecordFacts.warningLines(for: result.ignoredFailures))
            .filter { !$0.isEmpty }
        await ProvenanceRecorder.shared.recordStep(
            runID: runID,
            toolName: TaxTriageRecordFacts.toolName,
            toolVersion: result.config.launchRevision(pin: pin),
            githubReleaseVersion: TaxTriageConfig.githubReleaseVersion(for: result.config.launchRevision(pin: pin), pin: pin),
            command: sampleCommand(for: result.config, pin: pin),
            inputs: inputRecords(for: sample),
            outputs: fileRecords(
                for: TaxTriageOutputArtifactPolicy.filterRetainedOutputFiles(
                    result.allOutputFiles,
                    outputDirectory: result.outputDirectory
                ),
                role: .output
            ),
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderrLines.isEmpty ? stderr : stderrLines.joined(separator: "\n")
        )
    }

    private func recordSampleFailureProvenance(
        runID: UUID,
        pin: NextflowPipelinePin,
        sample: TaxTriageSample,
        config: TaxTriageConfig,
        outputDirectory: URL,
        wallTime: TimeInterval,
        error: Error,
        exitCode: Int32 = 1
    ) async {
        var failedConfig = config
        failedConfig.samples = [sample]
        failedConfig.outputDirectory = outputDirectory
        await ProvenanceRecorder.shared.recordStep(
            runID: runID,
            toolName: TaxTriageRecordFacts.toolName,
            toolVersion: failedConfig.launchRevision(pin: pin),
            githubReleaseVersion: TaxTriageConfig.githubReleaseVersion(for: failedConfig.launchRevision(pin: pin), pin: pin),
            command: sampleCommand(for: failedConfig, pin: pin),
            inputs: inputRecords(for: sample),
            outputs: [],
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: error.localizedDescription
        )
    }

    private func recordAggregateProvenance(
        runID: UUID,
        config: TaxTriageConfig,
        result: TaxTriageResult,
        wallTime: TimeInterval
    ) async {
        await ProvenanceRecorder.shared.recordStep(
            runID: runID,
            toolName: "lungfish-app-taxtriage-serial-batch",
            toolVersion: WorkflowRun.currentAppVersion,
            command: [
                "lungfish-app",
                "taxtriage-serial-batch",
                "--output",
                config.outputDirectory.path,
            ],
            inputs: config.samples.flatMap(inputRecords(for:)),
            outputs: fileRecords(
                for: [
                    result.outputDirectory.appendingPathComponent("taxtriage-result.json"),
                ],
                role: .output
            ),
            exitCode: 0,
            wallTime: wallTime
        )
    }

    private func sampleCommand(for config: TaxTriageConfig, pin: NextflowPipelinePin) -> [String] {
        var command = [
            "nextflow",
            "run",
            pin.repository,
            "-r",
            config.launchRevision(pin: pin),
            "-profile",
            config.profile,
            "--input",
            config.samplesheetURL.path,
            "--outdir",
            config.outputDirectory.path,
        ]
        if let dbPath = config.kraken2DatabasePath {
            command += ["--db", dbPath.path]
        }
        command += [
            "--top_hits_count",
            String(config.topHitsCount),
            "--k2_confidence",
            String(config.k2Confidence),
            "--rank",
            config.rank,
            "--max_memory",
            config.maxMemory,
            "--max_cpus",
            String(config.maxCpus),
        ]
        if config.skipAssembly {
            command.append("--skip_assembly")
        }
        if config.skipKrona {
            command.append("--skip_krona")
        }
        if let removeTaxids = config.effectiveRemoveTaxids {
            command += ["--remove_taxids", removeTaxids]
        }
        command += config.extraArguments
        return command
    }

    private func inputRecords(for sample: TaxTriageSample) -> [FileRecord] {
        ([sample.fastq1] + (sample.fastq2.map { [$0] } ?? []))
            .map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) }
    }

    private func fileRecords(for urls: [URL], role: FileRole) -> [FileRecord] {
        urls
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
            .map { ProvenanceRecorder.fileRecord(url: $0, role: role) }
    }
}

private extension Array where Element == URL {
    func uniquedByPath() -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in self {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            result.append(url)
        }
        return result
    }
}
