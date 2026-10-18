// VCFImportCLICommand.swift — The `lungfish-cli import vcf` command the Import Center's VCF row runs and shows.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The `lungfish-cli import vcf` command of the Import Center's VCF import (Phase 2.12 lane 12.07, A64).
///
/// The app runs the command on `CLIBundleBuildRunner`, and the Operations panel's "Copy CLI Command" shows the same
/// argv, so a copied command repeats the import. `--output-dir` names the existing `.lungfishref` bundle, which
/// `ImportCommand.VCFSubcommand` attaches the variants to through `VCFBundleVariantImport`, the core the app ran in
/// a helper process before. `--format json` makes the command print the events the row shows. The GUI never sets a
/// custom track name, so `--name` is not passed.
enum VCFImportCLICommand {
    /// How the command builds the track's database, the `import vcf` flag of each mode.
    enum Mode: String, Sendable, Equatable {
        /// Read the VCF into a new database.
        case fresh
        /// `--resume`, build the indexes of a replaced track whose import stopped at `import_state = indexing`.
        case resume
        /// `--materialize`, fill the INFO table of a replaced track whose materialization stopped.
        case materialize
    }

    /// The argv after `lungfish-cli` that imports `vcfURL` into `bundleURL`. `replaceTrackID` records the
    /// `--replace <track-id>` the user confirmed in the Import Center. Without it the command, like the GUI, adds a new
    /// track.
    static func arguments(
        vcfURL: URL,
        bundleURL: URL,
        importProfile: VCFImportProfile,
        replaceTrackID: String? = nil,
        mode: Mode = .fresh
    ) -> [String] {
        var args = [
            "import", "vcf", vcfURL.path,
            "--output-dir", bundleURL.path,
            "--import-profile", importProfile.rawValue,
        ]
        if let replaceTrackID {
            args += ["--replace", replaceTrackID]
        }
        switch mode {
        case .fresh: break
        case .resume: args.append("--resume")
        case .materialize: args.append("--materialize")
        }
        return args + ["--format", "json"]
    }

    static func build(
        vcfURL: URL,
        bundleURL: URL,
        importProfile: VCFImportProfile,
        replaceTrackID: String? = nil,
        mode: Mode = .fresh
    ) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "import vcf",
            args: Array(arguments(
                vcfURL: vcfURL, bundleURL: bundleURL, importProfile: importProfile,
                replaceTrackID: replaceTrackID, mode: mode
            ).dropFirst(2))
        )
    }

    /// The mode the Import Center runs for track `trackID` of `bundleURL`, read from the track's database
    /// (`variants/<track>.db`) as the app's helper sequence read it. A replaced track whose import stopped at
    /// `indexing` resumes, one whose materialization stopped materializes, and every other import, a new track
    /// included, reads the VCF again.
    static func mode(forTrackID trackID: String, replacing replaceTrackID: String?, in bundleURL: URL) -> Mode {
        guard replaceTrackID != nil else { return .fresh }
        let database = bundleURL
            .appendingPathComponent("variants", isDirectory: true)
            .appendingPathComponent(VCFBundleVariantImport.databaseFilename(trackID: trackID))
        guard FileManager.default.fileExists(atPath: database.path) else { return .fresh }
        switch VariantDatabase.importState(at: database) {
        case "indexing":
            return .resume
        case "inserting", nil:
            return .fresh
        default:
            return VariantDatabase.metadataValue(at: database, key: "materialize_state") == "materializing"
                ? .materialize : .fresh
        }
    }
}
