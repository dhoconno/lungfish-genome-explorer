// ResultExportCoordinator+MissingDatabase.swift - one alert for an export whose result database is gone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension ResultExportCoordinator {
    /// Confirms an export's database file is still there before the export starts (Phase 2.13 lane 13.40, UX ruling
    /// W4, MD61). When it is gone this hands the viewer's failure presenter one alert in the app's words, titled
    /// `The <tool> result could not be exported`, and returns false so the caller stops before the save panel, before
    /// any Operations row begins and before any leaf runs. `reportFailure` stays as it is for its other callers,
    /// since its `Could not write <file>:` prefix would not fit these words.
    @MainActor
    public static func confirmDatabase(
        at databaseURL: URL,
        tool: String,
        window: NSWindow?,
        presenter: ExportFailurePresenting = DefaultExportFailurePresenter()
    ) -> Bool {
        if FileManager.default.fileExists(atPath: databaseURL.path) { return true }
        presenter.presentExportFailure(
            title: ClassifierExportWords.missingDatabaseTitle(tool: tool),
            message: ClassifierExportWords.missingDatabaseText,
            in: window
        )
        return false
    }
}
