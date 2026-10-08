// ClassifyCommand+FailureRecord.swift - The provenance record conda classify writes for a failed run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

extension ClassifyCommand {

    /// The bytes of the provenance record `folder` holds, or nil when it
    /// holds none.
    static func provenanceRecordBytes(in folder: URL) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent(ProvenanceWriter.provenanceFilename))
    }

    /// Writes the record of a run that failed with `error` into its output
    /// folder, unless the classification stopped before anything ran and
    /// left the folder's record as the command found it.
    ///
    /// The classification saves no run when it refuses an input inside an
    /// output it would remove, or fails its validation in a folder that
    /// holds a record (``ClassificationPipeline/stoppedBeforeAnythingRan(_:)``).
    /// The command then writes none either, so an earlier run in the folder
    /// keeps its only record of how its results were made (review B-S4). A
    /// record the classification or the command wrote during this run, such
    /// as the record of a materialized input, is completed as before.
    ///
    /// - Parameters:
    ///   - profileState: The Bracken profile state the record names, from
    ///     `failureProfileState(for:)`.
    ///   - provenanceRecordAtStart: The bytes of the record the folder held
    ///     when the command started, or nil.
    static func recordFailure(
        _ error: Error,
        command: ClassifyCommand,
        context: ClassifyFailureProvenanceContext,
        argv: [String],
        profileState: String,
        runClock: ProvenanceRunClock,
        provenanceRecordAtStart: Data?
    ) throws {
        if context.pipelineStarted,
           ClassificationPipeline.stoppedBeforeAnythingRan(error),
           provenanceRecordBytes(in: context.outputDirectory) == provenanceRecordAtStart {
            return
        }
        let endedAt = runClock.now
        let failureMessage: String
        if let recordedMessage = context.failureMessage {
            failureMessage = recordedMessage
        } else if error is CancellationError {
            failureMessage = "Classification cancelled."
        } else {
            failureMessage = error.localizedDescription
        }

        do {
            _ = try writeFailureProvenance(
                command: command,
                context: context,
                argv: argv,
                exitStatus: failureExitStatus(for: error),
                profileState: profileState,
                stderr: failureMessage,
                startedAt: runClock.startedAt,
                endedAt: endedAt
            )
        } catch let provenanceError {
            throw CLIError.outputWriteFailed(
                path: context.outputDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename).path,
                reason: provenanceError.localizedDescription
            )
        }
    }
}
