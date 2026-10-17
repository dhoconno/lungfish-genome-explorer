// ClassificationPipeline+KrakenOutputCompaction.swift - The per-read output kept as gzip with its index
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "ClassificationPipeline")

extension ClassificationPipeline {
    /// The tool name of the step that records the removal of the per-read output once its gzip
    /// copy and index exist, here and in `build-db kraken2`.
    public static let kraken2OutputRemovalToolName = "Lungfish Kraken2 Output Removal"

    /// What a compaction leaves: the gzip copy that holds the per-read output now, and the index step and gzip
    /// step that read the original. A step that names the copy or the index waits for both (row 271 of Phase 2.8).
    struct KrakenOutputCompaction {
        let url: URL
        /// The index step then the gzip step.
        let stepIDs: [UUID]
    }

    func compactKrakenOutputIfPossible(
        rawURL: URL,
        provenanceRecorder: ProvenanceRecorder,
        runID: UUID,
        dependsOn: [UUID]
    ) async -> KrakenOutputCompaction? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rawURL.path) else { return nil }

        let compressedURL = rawURL.appendingPathExtension("gz")
        let indexURL = KrakenIndexDatabase.indexURL(for: compressedURL)
        let indexClock = ProvenanceRunClock()
        var indexStepID: UUID?
        var gzipStepID: UUID?

        do {
            try? fm.removeItem(at: indexURL)
            try KrakenIndexDatabase.build(
                from: rawURL,
                to: indexURL,
                includeUnclassified: false
            )
            let indexCompletedAt = indexClock.now
            // Hashed once for the index, gzip and removal steps that name it.
            let rawRecord = ProvenanceRecorder.fileRecord(url: rawURL, format: .text, role: .input)
            indexStepID = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "lungfish-kraken2-index",
                toolVersion: WorkflowRun.currentAppVersion,
                command: [
                    CLICommandIdentity.executableName,
                    "internal",
                    "kraken2-index",
                    "--classified-only",
                    rawURL.path,
                    indexURL.path,
                ],
                inputs: [
                    rawRecord,
                ],
                outputs: [
                    ProvenanceRecorder.fileRecord(url: indexURL, format: .unknown, role: .index),
                ],
                exitCode: 0,
                wallTime: indexCompletedAt.timeIntervalSince(indexClock.startedAt),
                dependsOn: dependsOn
            )

            let gzipClock = ProvenanceRunClock()
            // The one gzip helper writes a part file and names the copy only when it is whole. The recorded command
            // below replays it as `/bin/sh -c`, which is what a user can run by hand.
            try DurableGzip.compress(source: rawURL, to: compressedURL)
            let gzipCompletedAt = gzipClock.now
            gzipStepID = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "gzip",
                toolVersion: "system",
                command: gzipReplayCommand(source: rawURL, destination: compressedURL),
                inputs: [
                    rawRecord,
                ],
                outputs: [
                    ProvenanceRecorder.fileRecord(url: compressedURL, format: .text, role: .output),
                ],
                exitCode: 0,
                wallTime: gzipCompletedAt.timeIntervalSince(gzipClock.startedAt),
                dependsOn: dependsOn
            )

            try fm.removeItem(at: rawURL)
            // The kraken2, index and gzip steps keep naming the per-read output, so its
            // removal is a step of the record too (P1 of Phase 2.8). The index and gzip
            // steps both read it, so the removal waits for both.
            let readerStepIDs = [indexStepID, gzipStepID].compactMap { $0 }
            await RecordedRemovalStep.record(
                in: provenanceRecorder, runID: runID, toolName: Self.kraken2OutputRemovalToolName,
                api: "FileManager.removeItem(at:)", removing: [rawRecord], dependsOn: readerStepIDs
            )
            logger.info(
                "Compacted Kraken2 output to \(compressedURL.lastPathComponent, privacy: .public) and \(indexURL.lastPathComponent, privacy: .public)"
            )
            return KrakenOutputCompaction(url: compressedURL, stepIDs: readerStepIDs)
        } catch {
            logger.warning("Failed to compact Kraken2 output; retaining raw output: \(error.localizedDescription, privacy: .public)")
            // A copy whose step is recorded stays, because the record names it and cleanup deletes nothing a
            // record names (ARCH 5, row 268 of Phase 2.8). Removing the raw output is the call that fails after
            // both steps are recorded. A copy with no step is what a compaction that stopped half way left.
            if gzipStepID == nil { try? fm.removeItem(at: compressedURL) }
            if indexStepID == nil { try? fm.removeItem(at: indexURL) }
        }
        return nil
    }

    private func gzipReplayCommand(source: URL, destination: URL) -> [String] {
        let command = "/usr/bin/gzip -c \(shellEscape(source.path)) > \(shellEscape(destination.path))"
        return ["/bin/sh", "-c", command]
    }

}
