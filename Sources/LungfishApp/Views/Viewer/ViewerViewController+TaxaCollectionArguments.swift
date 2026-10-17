// ViewerViewController+TaxaCollectionArguments.swift - The command behind the taxa collection Extract button
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension ViewerViewController {
    /// The argv after `lungfish-cli` that the Extract button of the taxa collections drawer runs
    /// (Phase 2.11 lane A66): `extract taxa-collection` on the classification result `resultDirectory`,
    /// with one `--target <taxId>,<children|exact>,<display name>` for each taxon of `collection` in
    /// order, the folder `outputDirectory` for the per-taxon files, and `--format json` for the events
    /// the row shows. The row records this argv as its command, so Copy CLI Command replays the run.
    static func taxaCollectionExtractionArguments(
        collection: TaxaCollection,
        resultDirectory: URL,
        outputDirectory: URL
    ) -> [String] {
        var arguments = [
            "extract", "taxa-collection",
            "--result", resultDirectory.path,
            "--collection-id", collection.id,
            "--collection-name", collection.name,
        ]
        for target in collection.taxa {
            arguments += ["--target", "\(target.taxId),\(target.includeChildren ? "children" : "exact"),\(target.displayName)"]
        }
        arguments += ["--output-dir", outputDirectory.path, "--format", "json"]
        return arguments
    }
}
