// EsVirituResultViewController+ExportItem.swift - the Export item follows what the viewer can export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishWorkflow

extension EsVirituResultViewController {
    /// Sets the Export button from the viewer's state (Phase 2.13 lane 13.40, UX ruling W3). A batch view with no
    /// sample picked has nothing to export, since the leaf reads no sample as every sample and the export action
    /// returns before the save panel, so the button is disabled with the reason. `esVirituResult` calls this after
    /// `applyBatchSampleFilter()` sets it, which follows every pick.
    func refreshExportItem() {
        if isBatchMode, samplePickerState?.selectedSamples.isEmpty == true {
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
        guard let batchURL else { return true }
        return ResultExportCoordinator.confirmDatabase(
            at: batchURL.appendingPathComponent(EsVirituDetectionExport.databaseFileName),
            tool: "EsViritu",
            window: window,
            presenter: exportFailurePresenter
        )
    }
}
