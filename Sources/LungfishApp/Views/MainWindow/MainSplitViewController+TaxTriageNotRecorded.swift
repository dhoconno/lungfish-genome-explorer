// MainSplitViewController+TaxTriageNotRecorded.swift - The Inspector's TaxTriage settings for an import with no record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTIMPORT, row IMPORT-TAXTRIAGE-BATCH-HIDDEN, UX-IMPORT-BATCH item 4 widened by BIO-IMPORT-BATCH
// item 4. An import whose record lists no samples carries the importer's defaults (Illumina, confidence 0.20, top
// hits 10, 0.0 seconds), which the Inspector must not show as the run's.

import Foundation
import LungfishWorkflow

extension MainSplitViewController {
    /// A TaxTriage run setting as the Inspector shows it. A config that lists no samples was not read from the run,
    /// so its settings read Not recorded instead of the importer's defaults.
    static func taxTriageRunValue(_ config: TaxTriageConfig, _ value: @autoclosure () -> String) -> String {
        TaxTriageExportSource.controlsAreNotRecorded(in: config) ? TaxTriageBatchExporter.notRecorded : value()
    }
}
