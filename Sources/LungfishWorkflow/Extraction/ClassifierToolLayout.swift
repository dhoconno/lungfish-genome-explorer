// ClassifierToolLayout.swift - Declarative result-layout metadata for ClassifierTool
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Classifier extraction accepts either a regular result file or a sentinel file
// inside a result directory, depending on the tool. Keeping that contract
// declarative here lets CLI pre-flight checks and GUI file choosers share the
// same result-layout rules.

import Foundation

public extension ClassifierTool {

    /// Whether this tool's result path is a single regular file or a directory
    /// from which the resolver navigates to sibling or sentinel artifacts.
    ///
    /// Used by:
    ///
    /// - The CLI pre-flight check in `ExtractReadsCommand.runByClassifier` to
    ///   decide whether the user-supplied result path must exist as a regular
    ///   file (`.file`) or as a directory (`.directorySentinel`).
    /// - The GUI file chooser to present the correct shape — a file picker
    ///   for `.file` tools vs a directory picker for `.directorySentinel`
    ///   tools.
    ///
    /// ## Dispatch rules
    ///
    /// - ``ClassifierTool/nvd`` and ``ClassifierTool/kraken2`` are
    ///   `.directorySentinel`: the user-facing handle is a directory.
    /// - ``ClassifierTool/esviritu``, ``ClassifierTool/taxtriage``, and
    ///   ``ClassifierTool/naomgs`` are `.file`: each tool's resolver opens a
    ///   single SQLite database file at the result path directly.
    enum ResultLayout: Sendable, Hashable {
        /// The result path points to a single regular file that must exist.
        ///
        /// Used by tools whose resolver opens the path directly (e.g. a
        /// SQLite database): EsViritu, TaxTriage, and NAO-MGS.
        case file

        /// The result path points to a directory from which the resolver
        /// navigates to sibling or sentinel artifacts.
        ///
        /// This case covers two subtly different directory-shaped layouts
        /// that both present the same "pick a directory" affordance to the
        /// user and therefore share the same file-chooser / pre-flight
        /// treatment:
        ///
        /// - **Scan-for-siblings** — the resolver lists the directory and
        ///   picks up sibling files matching a known pattern. NVD uses this
        ///   shape: `ClassifierReadResolver.resolveBAMURL` scans the
        ///   directory for `*.bam` files without a fixed sentinel filename.
        /// - **Fixed sentinel filename** — the directory contains a known
        ///   sentinel file that the resolver appends to the directory URL.
        ///   Kraken2 uses this shape: `ClassificationResult.load(from:)`
        ///   reads `classification-result.json` from inside the directory.
        case directorySentinel
    }

    /// Declarative description of this tool's on-disk result layout.
    ///
    /// See ``ResultLayout`` for how callers use this to drive pre-flight
    /// existence checks and file-picker shape.
    var expectedResultLayout: ResultLayout {
        switch self {
        case .esviritu, .taxtriage, .naomgs:
            // Each tool's resolver opens a single SQLite database file at
            // the result path. EsViritu: `results.db`. TaxTriage:
            // `taxtriage.db`. NAO-MGS: `naomgs.db`.
            return .file
        case .nvd:
            // NVD's resolver scans the result directory for sibling `*.bam`
            // files (see `ClassifierReadResolver.resolveBAMURL`). No fixed
            // sentinel filename.
            return .directorySentinel
        case .kraken2:
            // Kraken2's resolver loads `classification-result.json` from
            // inside the result directory via
            // `ClassificationResult.load(from:)`. The sentinel filename is
            // fixed but the user-facing handle is the enclosing directory
            // (e.g. `.../classification-001/`), which is what
            // `TaxonomyViewController.resolveKraken2ResultPath` and
            // `AppDelegate`'s auto-extract path both pass through.
            return .directorySentinel
        }
    }
}
