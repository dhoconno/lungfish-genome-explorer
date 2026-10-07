// ClassifyCommand+FailureRecord.swift - The provenance record conda classify writes for a failed run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension ClassifyCommand {

    /// The bytes of the provenance record `folder` holds, or nil when it
    /// holds none.
    static func provenanceRecordBytes(in folder: URL) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent(ProvenanceWriter.provenanceFilename))
    }

    /// Writes the record of a run that failed with `error` into its output
    /// folder.
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
        startedAt: Date,
        provenanceRecordAtStart: Data?
    ) throws {
        let endedAt = Date()
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
                startedAt: startedAt,
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
