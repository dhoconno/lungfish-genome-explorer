// GenotypeWorkbookSnapshot+Script.swift - Loads the genotype snapshot Python script
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// SIMP-16 (2026-09-23 best-practices audit): this script used to live as a
// 550-line raw string literal in this file, which meant no syntax
// highlighting, no linting, and noisy Swift diffs for every Python change.
// The script itself is unchanged (byte-identical) and now lives at
// Resources/GenotypeWorkbook/snapshot.py, loaded once via Bundle.module.

import Foundation

extension GenotypeWorkbookPresentation {
    /// The Python script that renders a genotype workbook snapshot payload
    /// into an `.xlsx` file via `openpyxl`. See
    /// `Resources/GenotypeWorkbook/snapshot.py` for the script itself.
    public static let snapshotPythonScript: String = {
        guard let url = Bundle.module.url(
            forResource: "snapshot",
            withExtension: "py",
            subdirectory: "GenotypeWorkbook"
        ), let script = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing bundled resource GenotypeWorkbook/snapshot.py")
        }
        return script
    }()
}
