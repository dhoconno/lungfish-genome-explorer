// FASTQBatchImporter+Outcome.swift - How the batch records a failed or a cancelled sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

private let outcomeLogger = Logger(subsystem: LogSubsystem.workflow, category: "FASTQBatchImporter")

extension FASTQBatchImporter {

    /// Whether a sample ended because its task was cancelled. `lungfish-cli
    /// import fastq` turns SIGTERM into a cancel. Such a sample is not a
    /// failure, so the batch reports no `sampleFailed` line for it. A
    /// `CancellationError` thrown while the task is not cancelled stays a
    /// failure.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError && Task.isCancelled
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
