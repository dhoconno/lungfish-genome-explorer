// CzIdImportCLICommand.swift - The lungfish-cli import cz-id command the Import Center's CZ-ID row runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The `lungfish-cli import cz-id` command of the Import Center's CZ-ID import (Phase 2.12 lane 12.06, A63-M3).
///
/// The app runs it on `CLIBundleBuildRunner`, and `--format json` makes the command print the events the row
/// shows. The row records the same command without that switch (`AppDelegate.beginCzIdImportOperation`), which
/// is the command the bundle's record names. The sample name is one `--sample-name=` word, so a name that
/// starts with a hyphen stays a value.
enum CzIdImportCLICommand {
    /// The argv after `lungfish-cli` that imports `sourceURL` into the project's `Classifications` folder.
    static func arguments(sourceURL: URL, projectURL: URL, sampleName: String) -> [String] {
        [
            "import", "cz-id", sourceURL.path,
            "--project", projectURL.standardizedFileURL.path,
            "--sample-name=\(sampleName)",
            "--format", "json",
        ]
    }
}
