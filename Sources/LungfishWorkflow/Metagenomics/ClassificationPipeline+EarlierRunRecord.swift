// ClassificationPipeline+EarlierRunRecord.swift - A run that stops before anything ran leaves its folder's record as it was
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "ClassificationPipeline")

extension ClassificationPipeline {

    /// Whether a run that failed with `error` stopped in a folder it found,
    /// before any tool ran and before anything in the folder was removed.
    ///
    /// That is a refusal of an input inside an output the run would remove
    /// (``OutputReplacementRefusal``) and a configuration that failed its
    /// validation (``ClassificationConfigError``). A failure to create the
    /// output folder is not one, since no earlier record can sit in a folder
    /// that did not exist. `conda classify` asks it before it writes its own
    /// record of a failed run, so it never replaces a record the
    /// classification left alone.
    public static func stoppedBeforeAnythingRan(_ error: any Error) -> Bool {
        switch error {
        case is OutputReplacementRefusal:
            return true
        case let configError as ClassificationConfigError:
            if case .outputDirectoryCreationFailed = configError {
                return false
            }
            return true
        default:
            return false
        }
    }

    /// Whether a run that stopped with `error` before anything ran leaves the
    /// provenance record in `folder` as it was, so it saves none of its own.
    ///
    /// A refusal never saves, because nothing ran and nothing was removed. A
    /// failed validation saves only into a folder that holds no record yet.
    /// Either way an earlier run in the same folder keeps its only record of
    /// how its results were made, which a run that never ran would otherwise
    /// replace (review B-S4).
    static func keepsFolderRecord(after error: any Error, in folder: URL) -> Bool {
        guard stoppedBeforeAnythingRan(error) else { return false }
        if error is OutputReplacementRefusal {
            return true
        }
        return FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
        )
    }

    /// Ends a run that failed before kraken2 ran. It is saved as failed in its
    /// folder, unless `keepsFolderRecord(after:in:)` says the folder keeps the
    /// record it holds. Then the run is only marked failed, and the reason is
    /// logged.
    func endRunFailedBeforeKraken2(
        _ runID: UUID,
        recorder: ProvenanceRecorder,
        error: any Error,
        requestedConfig: ClassificationConfig,
        effectiveConfig: ClassificationConfig,
        resolution: BrackenProfileResolution?
    ) async throws {
        let folder = effectiveConfig.outputDirectory
        guard !Self.keepsFolderRecord(after: error, in: folder) else {
            await recorder.completeRun(runID, status: .failed)
            logger.warning(
                "Classification stopped before anything ran (\(error.localizedDescription, privacy: .public)), so no run is recorded in \(folder.path, privacy: .public) and the record it holds stays as it was"
            )
            return
        }
        try await persistInterruptedClassificationRun(
            provenanceRecorder: recorder,
            runID: runID,
            requestedConfig: requestedConfig,
            effectiveConfig: effectiveConfig,
            resolution: resolution,
            status: .failed,
            profileState: "failed"
        )
    }
}
