// BAMImportCLICommand.swift — The user-runnable `lungfish-cli` equivalent of the BAM import helper.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// Builds the "Copy CLI Command" string the Operations panel shows for a BAM
/// import.
///
/// FEA-12: the import itself runs out-of-process by re-launching this same
/// app executable with `--bam-import-helper` (`BAMImportHelperClient.swift`),
/// which is not a `lungfish-cli` flag — copying that string into a terminal
/// failed immediately. `lungfish-cli import bam <path> --output-dir
/// <bundle.lungfishref> --name <name>` is the real, runnable equivalent: when
/// `--output-dir` names an existing `.lungfishref` bundle,
/// `ImportCommand.BAMSubcommand` attaches the alignment as a manifest track
/// through `PreparedAlignmentAttachmentService`, the same primitive the
/// helper uses.
enum BAMImportCLICommand {
    static func build(bamURL: URL, bundleURL: URL) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "import bam",
            args: [
                bamURL.path,
                "--output-dir", bundleURL.path,
                "--name", bamURL.lastPathComponent,
            ]
        )
    }
}
