// TaxTriageResultViewController+ExportItem.swift - the results export checks its database first
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishWorkflow

extension TaxTriageResultViewController {
    /// Confirms the result's database is still in the result folder before a results or organism matrix export
    /// starts (Phase 2.13 lane 13.40, UX ruling W4). When it is gone the viewer shows one alert in the app's words
    /// and the export stops before the save panel, so no Operations row begins and no leaf runs. A viewer with no
    /// result folder passes, since the export action already ends on that.
    func exportDatabaseIsPresent(in window: NSWindow?) -> Bool {
        guard let batchGroupURL else { return true }
        return ResultExportCoordinator.confirmDatabase(
            at: batchGroupURL.appendingPathComponent(TaxTriageExportLoader.databaseFileName),
            tool: "TaxTriage",
            window: window,
            presenter: exportFailurePresenter
        )
    }
}
