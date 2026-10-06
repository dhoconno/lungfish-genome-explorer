// ClassificationPipeline+InputCopies.swift - Kraken2 inputs staged in the compression of R1, and the replay argv they leave
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension ClassificationPipeline {

    /// Stages a copy, in the compression of R1, of every input kraken2 would
    /// otherwise read in the other compression (``ClassificationConfig/kraken2InputURLs``),
    /// and records the staging as a provenance step. Returns its step ID, or
    /// nil when every input shares R1's compression and nothing is staged.
    func recordInputCopyStep(
        config: ClassificationConfig,
        runID: UUID,
        recorder: ProvenanceRecorder,
        dependsOn: [UUID]
    ) async throws -> UUID? {
        let copies = config.stagedInputCopies
        guard !copies.isEmpty else { return nil }
        let startedAt = Date()
        do {
            for item in copies {
                try FileManager.default.createDirectory(
                    at: item.copy.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Self.writeCopy(of: item.source, to: item.copy)
            }
        } catch {
            Self.removeStagedMates(for: config)
            throw error
        }
        return await recorder.recordStep(
            runID: runID,
            toolName: Self.inputCompressionStagingToolName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["LungfishWorkflow", "stage-in-r1-compression"]
                + copies.flatMap { ["--in", $0.source.path, "--out", $0.copy.path] },
            resolvedOptions: [
                "compression": .string(config.r1IsGzipCompressed ? "gzip" : "none"),
                "files": .integer(copies.count),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: copies.map {
                ProvenanceRecorder.fileRecord(url: $0.source, format: config.provenanceInputFileFormat, role: .input)
            },
            outputs: copies.map {
                ProvenanceRecorder.fileRecord(url: $0.copy, format: config.provenanceInputFileFormat, role: .output)
            },
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            dependsOn: dependsOn
        )
    }

    /// The kraken2 step's durable replay argv, kraken2 over files that
    /// outlive the run. A run that hands kraken2 files it stages and then
    /// deletes, the halves of an interleaved file, a header-only mate or a
    /// copy in the compression of R1, has no such command, so the step
    /// records none. Its argv still records what ran, and the run's recorded
    /// command reproduces it (final review A, note 5).
    static func durableKraken2ReplayArgv(
        effectiveConfig: ClassificationConfig,
        kraken2Config: ClassificationConfig,
        replayInputFiles: [URL]
    ) -> [String]? {
        guard !effectiveConfig.interleavedInput,
              kraken2Config.singleReadFiles.isEmpty,
              kraken2Config.stagedInputCopies.isEmpty else { return nil }
        var durableReplayConfig = effectiveConfig
        durableReplayConfig.inputFiles = replayInputFiles
        return ["kraken2"] + durableReplayConfig.kraken2Arguments()
    }
}
