// TaxTriageSerialBatchRunner.swift - Serial per-sample TaxTriage batch execution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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

        let startedAt = Date()
        let total = config.samples.count
        let root = config.outputDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let runID = await ProvenanceRecorder.shared.beginRun(
            name: "TaxTriage Serial Batch",
            parameters: provenanceParameters(for: config)
        )

        var usedDirectoryNames = Set<String>()
        var sampleResults: [TaxTriageResult] = []
        var sampleFailures: [TaxTriageSampleFailure] = []

        for (index, sample) in config.samples.enumerated() {
            try Task.checkCancellation()

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

            let sampleStart = Date()
            do {
                let result = try await runPipeline(sampleConfig) { sampleProgress, message in
                    let bounded = max(0, min(1, sampleProgress))
                    let overall = (Double(index) + bounded) / Double(total)
                    progress?(overall, "\(samplePrefix): \(message)")
                }
                sampleResults.append(result)
                await recordSampleProvenance(
                    runID: runID,
                    sample: sample,
                    result: result,
                    exitCode: 0,
                    wallTime: Date().timeIntervalSince(sampleStart),
                    stderr: nil
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
                    sample: sample,
                    config: sampleConfig,
                    outputDirectory: sampleOutputDirectory,
                    wallTime: Date().timeIntervalSince(sampleStart),
                    error: error
                )
                progress?(
                    Double(index + 1) / Double(total),
                    "\(samplePrefix): Failed - \(error.localizedDescription)"
                )
            }
        }

        guard !sampleResults.isEmpty else {
            await ProvenanceRecorder.shared.completeRun(runID, status: .failed)
            try? await ProvenanceRecorder.shared.save(runID: runID, to: root)
            throw TaxTriageSerialBatchError.allSamplesFailed(sampleFailures)
        }

        let resultURL = root.appendingPathComponent("taxtriage-result.json")
        let allOutputFiles = (sampleResults.flatMap(\.allOutputFiles) + [resultURL])
            .uniquedByPath()
            .sorted { $0.path < $1.path }
        let aggregate = TaxTriageResult(
            config: config,
            runtime: Date().timeIntervalSince(startedAt),
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
            wallTime: Date().timeIntervalSince(startedAt)
        )
        await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
        try await ProvenanceRecorder.shared.save(runID: runID, to: root)

        progress?(1.0, "TaxTriage serial batch complete")
        return aggregate
    }

    public static func sanitizedDirectoryName(for sampleID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = sampleID.unicodeScalars.map { scalar -> UnicodeScalar in
            allowed.contains(scalar) ? scalar : "_"
        }
        let candidate = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        if candidate.isEmpty || candidate == "." || candidate == ".." {
            return "sample"
        }
        return candidate
    }

    private func uniqueDirectoryName(for sampleID: String, usedNames: inout Set<String>) -> String {
        let base = Self.sanitizedDirectoryName(for: sampleID)
        var candidate = base
        var suffix = 2
        while usedNames.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        usedNames.insert(candidate)
        return candidate
    }

    private func provenanceParameters(for config: TaxTriageConfig) -> [String: ParameterValue] {
        [
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
            "revision": .string(config.revision),
            "output_directory": .file(config.outputDirectory),
        ]
    }

    private func recordSampleProvenance(
        runID: UUID,
        sample: TaxTriageSample,
        result: TaxTriageResult,
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) async {
        await ProvenanceRecorder.shared.recordStep(
            runID: runID,
            toolName: "taxtriage",
            toolVersion: result.config.revision,
            command: sampleCommand(for: result.config),
            inputs: inputRecords(for: sample),
            outputs: fileRecords(for: result.allOutputFiles, role: .output),
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr
        )
    }

    private func recordSampleFailureProvenance(
        runID: UUID,
        sample: TaxTriageSample,
        config: TaxTriageConfig,
        outputDirectory: URL,
        wallTime: TimeInterval,
        error: Error
    ) async {
        var failedConfig = config
        failedConfig.samples = [sample]
        failedConfig.outputDirectory = outputDirectory
        await ProvenanceRecorder.shared.recordStep(
            runID: runID,
            toolName: "taxtriage",
            toolVersion: failedConfig.revision,
            command: sampleCommand(for: failedConfig),
            inputs: inputRecords(for: sample),
            outputs: [],
            exitCode: 1,
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

    private func sampleCommand(for config: TaxTriageConfig) -> [String] {
        var command = [
            "nextflow",
            "run",
            TaxTriageConfig.pipelineRepository,
            "-r",
            config.revision,
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
