// MSADiscriminatingSitesRequest.swift - What one `msa discriminating-sites` run asks for
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The selections and settings behind one `lungfish-cli msa discriminating-sites`
/// invocation, in the CLI's own vocabulary so the GUI and a terminal run are
/// interchangeable.
///
/// Exactly one of `exclusions` (rows already in the bundle) and
/// `exclusionSequencesURL` (a FASTA or `.lungfishref` aligned on with the managed
/// MAFFT) is set, mirroring the CLI's `--exclusions` / `--exclusion-sequences`
/// choice. `targets` is `nil` when every row not named as an exclusion is a
/// target, which is the CLI default and keeps the argv as short as the manual's.
struct MSADiscriminatingSitesRequest: Equatable, Sendable {
    let bundleURL: URL
    /// Comma-separated target row names, or `nil` for the CLI default.
    let targets: String?
    /// Comma-separated exclusion row names inside the bundle.
    let exclusions: String?
    /// A FASTA file or reference bundle whose sequences are aligned on as exclusions.
    let exclusionSequencesURL: URL?
    /// The target row whose coordinates the report uses, or `nil` for the first target.
    let template: String?
    let targetMismatchTolerance: Int
    /// How many exclusion sequences must differ; `nil` means all of them.
    let minimumExclusionDifferences: Int?
    let windowLength: Int

    init(
        bundleURL: URL,
        targets: String? = nil,
        exclusions: String? = nil,
        exclusionSequencesURL: URL? = nil,
        template: String? = nil,
        targetMismatchTolerance: Int = 0,
        minimumExclusionDifferences: Int? = nil,
        windowLength: Int = 25
    ) {
        self.bundleURL = bundleURL
        self.targets = targets
        self.exclusions = exclusions
        self.exclusionSequencesURL = exclusionSequencesURL
        self.template = template
        self.targetMismatchTolerance = targetMismatchTolerance
        self.minimumExclusionDifferences = minimumExclusionDifferences
        self.windowLength = windowLength
    }

    /// The candidate-window TSV the CLI writes beside `outputURL` when no
    /// `--windows-output` is passed.
    static func defaultWindowsOutputURL(for outputURL: URL) -> URL {
        outputURL.deletingPathExtension().appendingPathExtension("windows.tsv")
    }

    /// The JSON report the CLI writes beside `outputURL` when no `--json-output`
    /// is passed. The Inspector reads this file back to fill its tables.
    static func defaultJSONOutputURL(for outputURL: URL) -> URL {
        outputURL.deletingPathExtension().appendingPathExtension("json")
    }
}

/// The columns and row roles the alignment viewport draws after a
/// discriminating-sites run, handed from the Inspector over the window-scoped
/// `.msaDiscriminatingSitesHighlightChanged` notification.
struct MSADiscriminatingSitesHighlight: Equatable, Sendable {
    enum RowRole: String, Equatable, Sendable {
        case target = "Target"
        case exclusion = "Exclusion"
    }

    /// 1-based alignment columns the report found.
    let columns: [Int]
    /// Roles of the rows inside the displayed bundle, keyed by bundle row ID.
    /// Exclusion sequences aligned on from a file have no row here; they are
    /// named by `exclusionSourceName` and counted by `exclusionCount`.
    let rowRolesByID: [String: RowRole]
    let targetCount: Int
    let exclusionCount: Int
    /// The file or reference bundle the exclusions came from, when not rows.
    let exclusionSourceName: String?

    /// The one-line legend the viewport shows above the alignment.
    var legendText: String {
        var text = "Discriminating sites: \(columns.count) column\(columns.count == 1 ? "" : "s") · "
        text += "Target rows \(targetCount) · Exclusion "
        if let exclusionSourceName {
            text += "sequences \(exclusionCount) from \(exclusionSourceName)"
        } else {
            text += "rows \(exclusionCount)"
        }
        return text
    }
}
