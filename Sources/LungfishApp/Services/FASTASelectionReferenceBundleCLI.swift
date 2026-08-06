// FASTASelectionReferenceBundleCLI.swift - Existing CLI route for selected FASTA reference bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Reuses the existing CLI contig-subset workflow when selected FASTA rows
/// all originated from one durable FASTA source. The CLI then creates the
/// reference bundle itself, including its canonical provenance.
enum FASTASelectionReferenceBundleCLI {
    static func arguments(
        sourceURL: URL,
        sequenceIDs: [String],
        projectURL: URL,
        bundleName: String
    ) -> [String] {
        ["extract", "contigs", "--contigs", sourceURL.standardizedFileURL.path]
            + sequenceIDs.flatMap { ["--contig", $0] }
            + ["--bundle", "--project-root", projectURL.standardizedFileURL.path,
               "--bundle-name", bundleName]
    }

    static func bundleURL(from output: String) -> URL? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return lines.last { $0.pathExtension.lowercased() == "lungfishref" }?.standardizedFileURL
    }
}
