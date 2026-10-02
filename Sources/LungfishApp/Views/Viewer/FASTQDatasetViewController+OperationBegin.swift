// FASTQDatasetViewController+OperationBegin.swift - Operations panel registration for the FASTQ dataset viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The begin helper for the Quality Report launch in the baselined
/// FASTQDatasetViewController.swift (finding R4). It lives here, not beside its
/// launch site, so the baselined file does not grow
/// (scripts/ratchets/file-size.sh). The helper registers its row through
/// `OperationReporting` and calls `launch` only when the row started, so a test
/// can check the row and its command without touching `OperationCenter.shared`.
extension FASTQDatasetViewController {
    /// Registers the Quality Report row and, only when it starts, calls `launch`
    /// with the operation ID. The row locks no bundle and carries no route
    /// context, as before.
    ///
    /// CLI parity gap. The row keeps recording the `seqkit stats` description it
    /// has always recorded, built by `qualityReportCommandDescription(for:)`.
    /// That text is not a `lungfish-cli` command and does not parse. The run
    /// calls `seqkit stats` through `NativeToolRunner` in this process, unless
    /// the import already cached a seqkit summary, then takes a 100,000-read
    /// `seqkit head` sample and stores the statistics in the dataset's metadata
    /// sidecar. The closest command is `lungfish-cli fastq qc-summary`, which
    /// computes its statistics with `FASTQReader` and writes them to a JSON
    /// file, so it neither runs seqkit nor updates the sidecar. A command that
    /// records the viewport's statistics would replace the description.
    @discardableResult
    static func beginQualityReportOperation(
        fastqURL: URL,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Quality Report",
            detail: fastqURL.lastPathComponent,
            operationType: .qualityReport,
            cliCommand: qualityReportCommandDescription(for: fastqURL)
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The text the Quality Report row shows in place of a command. It names the
    /// seqkit calls the run makes and describes the two steps that run in
    /// process with parenthesized notes.
    static func qualityReportCommandDescription(for fastqURL: URL) -> String {
        "seqkit stats -a -T \(fastqURL.path) && (count Q20/Q30 bases) && seqkit head -n 100000 \(fastqURL.path) | (sampled quality analysis)"
    }
}
