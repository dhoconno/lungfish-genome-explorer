// EsVirituResultViewController+ExportItem.swift - the Export item follows what the viewer can export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

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
}
