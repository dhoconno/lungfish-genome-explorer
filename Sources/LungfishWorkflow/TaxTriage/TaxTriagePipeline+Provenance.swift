// TaxTriagePipeline+Provenance.swift - The provenance record a TaxTriage run saves for itself
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension TaxTriagePipeline {

    // MARK: - Provenance

    func saveTaxTriageProvenanceOrThrow(
        runID: UUID,
        outputDirectory: URL,
        description: String,
        exitCode: Int32,
        stderr: String,
        logFile: URL?
    ) async throws {
        do {
            try await ProvenanceRecorder.shared.save(runID: runID, to: outputDirectory)
        } catch {
            let message = "Failed to save TaxTriage \(description) provenance: \(error.localizedDescription)"
            let combinedStderr = [stderr, message]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw TaxTriagePipelineError.pipelineFailed(
                exitCode: exitCode,
                stderr: combinedStderr,
                logFile: logFile
            )
        }
    }

    func taxTriagePersistenceFailure(
        artifactDescription: String,
        error: Error,
        logFile: URL?
    ) -> TaxTriagePipelineError {
        TaxTriagePipelineError.pipelineFailed(
            exitCode: -1,
            stderr: "Failed to save TaxTriage \(artifactDescription): \(error.localizedDescription)",
            logFile: logFile
        )
    }

    nonisolated func provenanceParameters(
        for config: TaxTriageConfig,
        interleavedSplits: [InterleavedSampleSplit] = []
    ) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "workflow": .string("taxtriage"),
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
            "extraArgs": .string(AdvancedCommandLineOptions.join(config.extraArguments)),
            "output_directory": .file(config.outputDirectory),
            "remove_taxids": .string(config.effectiveRemoveTaxids ?? ""),
        ]
        if let githubReleaseVersion = TaxTriageConfig.githubReleaseVersion(for: config.revision) {
            parameters["github_release_version"] = .string(githubReleaseVersion)
        }
        if !interleavedSplits.isEmpty {
            parameters["interleaved_samples_split_to_r1_r2"] = .array(
                interleavedSplits.map { .string($0.sampleId) }
            )
        }
        parameters.merge(Self.readSetProvenanceParameters(for: config)) { current, _ in current }
        return parameters
    }

    func recordTaxTriageProvenanceStep(
        runID: UUID,
        config: TaxTriageConfig,
        command: [String],
        outputFiles: [URL],
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) async {
        await ProvenanceRecorder.shared.recordStep(
            runID: runID,
            toolName: "TaxTriage",
            toolVersion: config.revision,
            githubReleaseVersion: TaxTriageConfig.githubReleaseVersion(for: config.revision),
            command: command,
            inputs: inputRecords(for: config),
            outputs: outputRecords(for: outputFiles),
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr
        )
    }

    private func inputRecords(for config: TaxTriageConfig) -> [FileRecord] {
        config.samples.flatMap { sample in
            ([sample.fastq1] + (sample.fastq2.map { [$0] } ?? []))
                .map { url in
                    ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)
                }
        }
    }

    private func outputRecords(for urls: [URL]) -> [FileRecord] {
        urls
            .taxTriageUniquedByPath()
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
            .map { ProvenanceRecorder.fileRecord(url: $0, role: .output) }
    }
}
