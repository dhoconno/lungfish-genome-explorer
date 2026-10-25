// FASTQBatchImporter+RecipeArtifactNames.swift - The name of a recipe report's copy in a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQBatchImporter {

    /// A report copy's name: `<step>-<artifact>-<slug>-` and the work file's name. With `stem`, a work file name that
    /// leads with the work stem and `_` takes the sample name in its place, and any other name is kept as it is. The
    /// import passes no stem; `fastq adopt` passes the plan's fixed work stem and the bundle's sample name (vote C4-4
    /// D-3), so both name a copy through this one function.
    static func recipeArtifactFilename(
        stepIndex: Int,
        artifactIndex: Int,
        stepName: String,
        sourceURL: URL,
        stem: (work: String, sample: String)? = nil
    ) -> String {
        var source = sourceURL.lastPathComponent
        if let stem, source.hasPrefix(stem.work + "_") {
            source = stem.sample + source.dropFirst(stem.work.count)
        }
        let stem = stepName
            .lowercased()
            .unicodeScalars
            .map { scalar -> String in
                CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
            }
            .joined()
        let slug = String(stem)
            .split(separator: "-")
            .joined(separator: "-")
            .prefix(48)
        return "\(stepIndex + 1)-\(artifactIndex + 1)-\(slug)-\(source)"
    }
}
