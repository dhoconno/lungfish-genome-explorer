// NaoMgsResultViewController+ResultViewport.swift - configure helper for NAO-MGS
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This file adds the shared configure surface to
// ``NaoMgsResultViewController`` via an extension, keeping the large
// implementation file untouched.
//
// - configure(result:) adapts parser output into cached viewport rows

import AppKit
import Foundation
import LungfishIO

// MARK: - NaoMgsResultViewController: configure

/// Adds the shared configure surface to ``NaoMgsResultViewController``.
///
/// Parser-backed ``NaoMgsResult`` values are displayed from cached rows. Imported
/// bundles should still use `configure(database:manifest:bundleURL:)` so detail
/// panes can query the SQLite database, and so the table export, which runs
/// `nao-mgs export table` on the result folder, can run.
extension NaoMgsResultViewController {

    /// Delegates to `configure(result:bundleURL:)` with `nil` bundle URL.
    public func configure(result: NaoMgsResult) {
        configure(result: result, bundleURL: nil)
    }
}
