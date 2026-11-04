// TaxTriageResultViewController+ControlNotice.swift - What the viewer says about the negative controls of a result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTCONTROLS, row TAXTRIAGE-VIEWER-CONTROL-SILENT (BIO backlog 1 of the TTBUILDDB review). The exports
// say Not checked for a control that failed or cannot be found, and the viewer's Risk flag stayed blank, which reads
// as a clean control. The strip above the table now carries the words the exports use.

import Foundation
import LungfishWorkflow

extension TaxTriageResultViewController {

    /// The words for the strip above the table, or nil when the result needs none.
    ///
    /// - A record that lists no samples names no control, so the table's No may be wrong (BIO-IMPORT-BATCH item 5).
    /// - Otherwise the words are the ones the batch report prints, from the same ``TaxTriageControlMatch``. They name a
    ///   control that failed or cannot be found, and two sample names that the pipeline gives one name, so screen and
    ///   file say one thing. A control that ran needs none.
    func controlNoticeWords() -> String? {
        guard let config = taxTriageConfig, !TaxTriageExportSource.controlsAreNotRecorded(in: config) else {
            return TaxTriageNotRecordedNoticeView.words
        }
        return TaxTriageControlMatch(
            samples: config.samples,
            failedSampleIDs: taxTriageResult?.sampleFailures.map(\.sampleID) ?? [],
            ignoredFailures: taxTriageResult?.ignoredFailures ?? [],
            databaseSampleIds: sampleIds
        ).noticeWords
    }
}
