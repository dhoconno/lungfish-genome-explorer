// NvdResultViewController+ExportItem.swift - the Export item follows what the viewer can export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

extension NvdResultViewController {
    /// Sets the Export button from the viewer's state (Phase 2.13 lane 13.40, UX ruling W3). The cached rows show
    /// before the database opens, or when it is missing, and then no sample is picked either, so the database is
    /// checked first. `database`, `selectedSamples` and `cachedRows` call this when they change, which covers a
    /// database load, a sample pick and the cached-rows path.
    func refreshExportItem() {
        if database == nil {
            actionBar.setExportEnabled(false, reason: ClassifierExportWords.missingDatabaseHelp)
        } else if selectedSamples.isEmpty {
            actionBar.setExportEnabled(false, reason: ClassifierExportWords.pickASample)
        } else {
            actionBar.setExportEnabled(true)
        }
    }
}
