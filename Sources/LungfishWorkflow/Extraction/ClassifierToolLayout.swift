// ClassifierToolLayout.swift - Declarative result-layout metadata for ClassifierTool
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5 simplification-pass addition. This extension declares, per
// classifier tool, whether the tool's result path is a regular file (that
// must exist before any resolver can read it) or a sentinel file inside a
// directory that the resolver scans for sibling artifacts.
//
// The enum lives in its own file layered on top of `ClassifierRowSelector.swift`
// (Phase 1) so Phase 5's declarative contract is clearly separable from the
// Phase 1 value type. Phase 6/7/8 can consume `expectedResultLayout` in the
// CLI pre-flight check and the GUI file chooser without touching Phase 1 code.

import Foundation

public extension ClassifierTool {

    /// Whether this tool's result path is a single regular file or a sentinel
    /// file whose parent directory the resolver scans for sibling artifacts.
    ///
    /// Used by:
    ///
    /// - The CLI pre-flight check in `ExtractReadsCommand.runByClassifier` to
    ///   decide whether the user-supplied result path must exist as-is
    ///   (`.file`) or may be relaxed to a parent-directory scan
    ///   (`.directorySentinel`).
    /// - The GUI file chooser to present the correct shape — a file picker
    ///   for `.file` tools vs a directory picker that picks the scan root
    ///   for `.directorySentinel` tools.
    ///
    /// ## Dispatch rules
    ///
    /// - ``ClassifierTool/nvd`` is `.directorySentinel` because NVD stores its
    ///   result as a `classification.json` (or similar) alongside sibling
    ///   per-contig BAM files that the resolver discovers by scanning the
    ///   containing directory.
    /// - ``ClassifierTool/esviritu``, ``ClassifierTool/taxtriage``,
    ///   ``ClassifierTool/naomgs``, and ``ClassifierTool/kraken2`` are all
    ///   `.file`: the resolver opens the result path directly and extracts
    ///   everything it needs from that single file.
    enum ResultLayout: Sendable, Hashable {
        /// The result path points to a single regular file that must exist.
        case file

        /// The result path points to a sentinel file inside a directory; the
        /// resolver discovers sibling artifacts by scanning that directory.
        case directorySentinel
    }

    /// Declarative description of this tool's on-disk result layout.
    ///
    /// See ``ResultLayout`` for how callers use this to drive pre-flight
    /// existence checks and file-picker shape.
    var expectedResultLayout: ResultLayout {
        switch self {
        case .nvd:
            return .directorySentinel
        case .esviritu, .taxtriage, .naomgs, .kraken2:
            return .file
        }
    }
}
