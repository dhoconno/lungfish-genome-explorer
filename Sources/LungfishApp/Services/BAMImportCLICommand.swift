// BAMImportCLICommand.swift — The `lungfish-cli import bam` command the Import Center's BAM row runs and shows.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The `lungfish-cli import bam` command of the Import Center's BAM import (Phase 2.11 lane A63, decision C12).
///
/// The app runs the command on `CLIBundleBuildRunner`, and the Operations panel's "Copy CLI Command" shows
/// the same argv, so a copied command repeats the import. `--output-dir` names the existing `.lungfishref`
/// bundle, which `ImportCommand.BAMSubcommand` attaches the alignment to as a manifest track through
/// `BAMImportService.importBAM`, the service the app ran in a helper process before. `--format json` makes
/// the command print the events the row shows. The name is one `--name=` word, so a file name that starts
/// with a hyphen stays a value.
enum BAMImportCLICommand {
    /// The argv after `lungfish-cli` that imports `bamURL` into `bundleURL`.
    static func arguments(bamURL: URL, bundleURL: URL) -> [String] {
        [
            "import", "bam", bamURL.path,
            "--output-dir", bundleURL.path,
            "--name=\(bamURL.lastPathComponent)",
            "--format", "json",
        ]
    }

    static func build(bamURL: URL, bundleURL: URL) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "import bam",
            args: Array(arguments(bamURL: bamURL, bundleURL: bundleURL).dropFirst(2))
        )
    }
}
