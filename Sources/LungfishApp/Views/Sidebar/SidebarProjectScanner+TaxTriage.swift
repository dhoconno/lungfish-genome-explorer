// SidebarProjectScanner+TaxTriage.swift - The sidebar subtitle of a TaxTriage result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

extension SidebarProjectScanner {
    /// The subtitle of a TaxTriage batch row, or nil when the folder holds no samples to count.
    ///
    /// No batch manifest. The run's `taxtriage-result.json` names its samples, since a one-sample run's process folders lie
    /// flat in the root (U30 W1). A record that loads with none comes from an import that did not keep them (an earlier
    /// release wrote `samples: []`), so the row says that the samples are not recorded, or that the folder holds no reports.
    /// Listing reads the record and writes nothing (Phase 3.2 lane TTIMPORT, UX 6).
    static func taxTriageBatchSubtitle(for info: AnalysesFolder.AnalysisDirectoryInfo, timestamp: String) -> String? {
        let record = try? TaxTriageResult.load(from: info.url)
        if let record, record.config.samples.isEmpty {
            return "\(record.reportFiles.isEmpty ? "No reports" : "Samples not recorded") · \(timestamp)"
        }
        let count = record?.config.samples.count ?? countBatchSampleSubdirectories(in: info.url, sidecarCheck: { _ in true })
        return count > 0 ? "\(count) samples · \(timestamp)" : nil
    }
}
