// ClassifierExportWords.swift - the words of a disabled Export item and of the missing-database alert
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The words a result viewer uses when its Export item cannot export (Phase 2.13 lane 13.40, UX rulings W3 and W4).
/// The leaf commands keep their own words for Terminal, so these are the app's words only.
public enum ClassifierExportWords {
    /// Help tag of a disabled Export item while no sample is picked.
    public static let pickASample = "Pick a sample to export."

    /// Help tag of a disabled Export item while the viewer shows cached rows because the result's database is
    /// missing.
    public static let missingDatabaseHelp =
        "Export needs this result's database, which is missing. Import the result again to export it."

    /// Text of the alert an export shows when it finds the database gone from the result folder.
    public static let missingDatabaseText =
        "Its database is missing from the result folder. Import the result again, then export."

    /// Title of that alert for one tool, which is `NAO-MGS`, `NVD`, `EsViritu`, `TaxTriage` or `Kraken2`.
    public static func missingDatabaseTitle(tool: String) -> String {
        "The \(tool) result could not be exported"
    }
}
