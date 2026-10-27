// FASTQBatchImporter+Outcome.swift - How the batch records a failed or a cancelled sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

private let outcomeLogger = Logger(subsystem: LogSubsystem.workflow, category: "FASTQBatchImporter")

extension FASTQBatchImporter {

    /// Whether a sample that ended with an error was stopped by a cancel.
    /// `lungfish-cli import fastq` turns SIGTERM into a cancel. Such a sample
    /// is not a failure, so the batch reports no `sampleFailed` line for it.
    ///
    /// Any error counts while the task is cancelled, not only a bare
    /// `CancellationError`. The pipeline wraps a cancelled storage tool's
    /// error as `clumpifyFailed`, and the window ends the CLI's tools before
    /// the CLI itself, so a tool can exit on SIGTERM and fail its step just
    /// before the cancel lands. A `CancellationError` thrown while the task
    /// is not cancelled stays a failure.
    static func failureEndedByCancel() -> Bool {
        Task.isCancelled
    }

    /// Stops a sample whose own files are in the old Phred+64 encoding, before any recipe step (BIO-BIN-QIN N2, fix round
    /// 4 item 2). Every storage step tells BBTools the scores are Phred+33, and a recipe's quality trims read the original
    /// reads as Phred+33 too, so they trim nothing, while a step that rewrites scores could carry the file past the
    /// pipeline's own check of its input. The pipeline still checks what it stores, and the refusal's words reach the
    /// sample's failure unchanged.
    static func refuseLegacyPhred64(_ pair: SamplePair) throws {
        try QualityEncoding.refuseLegacyPhred64(pair.inputFiles, launcher: ToolProcessChildLauncher())
    }

    /// Records a failed sample: one `sampleFailed` event, one log line and
    /// one entry in the batch's errors.
    static func recordFailure(
        _ error: Error,
        of sample: String,
        log: (@Sendable (ImportLogEvent) -> Void)?,
        into errors: inout [(sample: String, error: String)]
    ) {
        let message = error.localizedDescription
        log?(.sampleFailed(sample: sample, error: message))
        outcomeLogger.error("Sample \(sample) failed: \(message)")
        errors.append((sample: sample, error: message))
    }

    /// Records a sample that a cancel stopped.
    static func recordCancel(of sample: String) {
        outcomeLogger.info("Sample \(sample) cancelled")
    }
}
