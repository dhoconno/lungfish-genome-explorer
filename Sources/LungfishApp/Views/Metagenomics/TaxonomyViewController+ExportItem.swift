// TaxonomyViewController+ExportItem.swift - the Kraken2 table export checks its source file first
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

extension TaxonomyViewController {
    /// Confirms the file the table export would read is still there before the export starts (Phase 2.13 lane 13.40,
    /// UX ruling W4). That file is `kraken2.sqlite` on the database route and the sidecar on the other. When it is
    /// gone the viewer shows one alert in the app's words through its warning presenter and the export stops before
    /// the save panel, so no Operations row begins and no leaf runs. The beep follows the failure closure of the
    /// export, and a test that sets `warningPresenter` takes the alert in place of both.
    func exportDatabaseIsPresent(_ sourceURL: URL, in window: NSWindow?) -> Bool {
        let isPresent = ResultExportCoordinator.confirmDatabase(
            at: sourceURL,
            tool: "Kraken2",
            window: window,
            presenter: WarningPresenterExportAdapter { [weak self] title, message in
                self?.presentWarning(title: title, message: message)
            }
        )
        if !isPresent, warningPresenter == nil { NSSound.beep() }
        return isPresent
    }
}
