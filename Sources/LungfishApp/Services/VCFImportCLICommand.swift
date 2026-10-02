// VCFImportCLICommand.swift — The user-runnable `lungfish-cli` equivalent of the VCF import helper.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit

/// Builds the "Copy CLI Command" string the Operations panel shows for a VCF
/// import into an existing reference bundle.
///
/// The import itself runs out of process by re-launching this same
/// app executable with `--vcf-import-helper`, which is not a `lungfish-cli`
/// flag. `lungfish-cli import vcf <path> --output-dir <bundle.lungfishref>
/// --import-profile <profile>` is the runnable equivalent: when `--output-dir`
/// names an existing `.lungfishref` bundle, `ImportCommand.VCFSubcommand`
/// attaches the variants through `VCFBundleVariantImport`, the same core the
/// helper path uses. The GUI never sets a custom track name, so `--name` is
/// not recorded.
enum VCFImportCLICommand {
    /// `replaceTrackID` records the `--replace <track-id>` the user confirmed
    /// in the Import Center; without it the CLI, like the GUI, adds a new track.
    static func build(
        vcfURL: URL, bundleURL: URL, importProfile: VCFImportProfile, replaceTrackID: String? = nil
    ) -> String {
        var args = [
            vcfURL.path,
            "--output-dir", bundleURL.path,
            "--import-profile", importProfile.rawValue,
        ]
        if let replaceTrackID {
            args += ["--replace", replaceTrackID]
        }
        return OperationCenter.buildCLICommand(subcommand: "import vcf", args: args)
    }
}
