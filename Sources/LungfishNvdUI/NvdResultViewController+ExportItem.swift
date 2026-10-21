// NvdResultViewController+ExportItem.swift - the Export item follows what the viewer can export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishWorkflow

extension NvdResultViewController {
    /// Sets the Export button from the viewer's state (Phase 2.13 lane 13.40, UX ruling W3). The cached rows show
    /// before the database opens, or when it is missing, and then no sample is picked either, so the database is
    /// checked first. The reason is the opening words while the database file is in the result folder and the
    /// missing words otherwise. `database`, `selectedSamples` and `cachedRows` call this when they change, which
    /// covers a database load, a sample pick and the cached-rows path.
    func refreshExportItem() {
        if database == nil {
            let isThere = bundleURL.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(NvdContigsExport.databaseFileName).path)
            } ?? false
            actionBar.setExportEnabled(false, reason: isThere
                ? ClassifierExportWords.databaseOpeningHelp : ClassifierExportWords.missingDatabaseHelp)
        } else if selectedSamples.isEmpty {
            actionBar.setExportEnabled(false, reason: ClassifierExportWords.pickASample)
        } else {
            actionBar.setExportEnabled(true)
        }
    }

    /// Confirms the result's database is still in the result folder before an export starts (Phase 2.13 lane 13.40,
    /// UX ruling W4). When it is gone the viewer shows one alert in the app's words and the export stops before the
    /// save panel, so no Operations row begins and no leaf runs. A viewer with no result folder passes, since the
    /// export action already ends on that.
    func exportDatabaseIsPresent(in window: NSWindow?) -> Bool {
        guard let bundleURL else { return true }
        return ResultExportCoordinator.confirmDatabase(
            at: bundleURL.appendingPathComponent(NvdContigsExport.databaseFileName),
            tool: "NVD",
            window: window,
            presenter: exportFailurePresenter
        )
    }
}
