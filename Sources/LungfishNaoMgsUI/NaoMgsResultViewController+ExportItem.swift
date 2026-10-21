// NaoMgsResultViewController+ExportItem.swift - the Export item follows what the viewer can export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishWorkflow

extension NaoMgsResultViewController {
    /// Sets the Export button from the viewer's state (Phase 2.13 lane 13.40, UX ruling W3). A result opens from its
    /// cached rows when its database is missing, and the export needs that database, so the button is disabled with
    /// the reason until `configure(database:manifest:bundleURL:)` replaces the cached rows with the database view.
    /// `database` calls this when it is set, which covers `configureWithCachedRows`, which sets it to nil.
    func refreshExportItem() {
        if database == nil {
            actionBar.setExportEnabled(false, reason: ClassifierExportWords.missingDatabaseHelp)
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
            at: bundleURL.appendingPathComponent(NaoMgsSummaryExport.databaseFileName),
            tool: "NAO-MGS",
            window: window,
            presenter: exportFailurePresenter
        )
    }
}
