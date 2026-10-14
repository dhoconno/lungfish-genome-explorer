// AppDelegate+ClassificationRowText.swift - Words of the classifier launches that stay in the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// The alert titles, the batch sample prefix and the database warning line of the Kraken2 and
/// EsViritu launches in AppDelegate+Classification.swift. They sit here so one place holds the
/// words of the legacy route and of the CLI route that replaces it, and
/// `ClassifierOperationRowTextTests` pins each one. The completion details are shared with the CLI
/// and live in `ClassificationCompletionDetail` in LungfishWorkflow.
extension AppDelegate {
    // MARK: - Alert titles

    /// The title of the alert after a single Kraken2 run fails.
    nonisolated static let classificationFailedAlertTitle = "Classification Failed"

    /// The title of the alert after every sample of a Kraken2 batch fails.
    nonisolated static let classificationBatchFailedAlertTitle = "Classification Batch Failed"

    /// The title of the alert after a single EsViritu run fails.
    nonisolated static let esVirituFailedAlertTitle = "EsViritu Failed"

    /// The title of the alert after every sample of an EsViritu batch fails.
    nonisolated static let esVirituBatchFailedAlertTitle = "EsViritu Batch Failed"

    // MARK: - Row lines

    /// The prefix of every progress line of a batch, `Sample 2/5 (air-B)`. A progress line reads
    /// `<prefix>: <message>`. The position counts from 1.
    nonisolated static func classificationBatchSamplePrefix(index: Int, sampleCount: Int, sampleID: String) -> String {
        "Sample \(index + 1)/\(sampleCount) (\(sampleID))"
    }

    /// The warning line a run logs when the viewer database could not be built after the run. It is the
    /// sentence the commands write too (``ClassificationCompletionDetail/viewerIndexWarning(_:)``), so the
    /// row reads the command's warning with ``CLIClassifierRowEvents/databaseBuildError(in:)``.
    nonisolated static func classificationDatabaseBuildWarning(_ dbError: String) -> String {
        ClassificationCompletionDetail.viewerIndexWarning(dbError)
    }
}
