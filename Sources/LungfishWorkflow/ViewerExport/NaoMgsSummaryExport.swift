// NaoMgsSummaryExport.swift - The NAO-MGS summary export that the viewer and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The NAO-MGS summary table export (Phase 2.12 lane 12.31 M4, ARCH ruling 1.1).
///
/// The view and `nao-mgs export table` choose the shown rows and write the table with these functions, so the view,
/// the in-app writer and the leaf agree on the rows, their order and the bytes.
public enum NaoMgsSummaryExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1). `nao-mgs summary` already exists, so the leaf is
    /// named `table`.
    public static let commandPath = ["nao-mgs", "export", "table"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish nao-mgs export table"
}
