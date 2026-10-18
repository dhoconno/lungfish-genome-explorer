// BookmarkedVariantExport.swift - The bookmarked variants export that the variant drawer and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The bookmarked variants export (Phase 2.12 lane 12.39, ARCH ruling X-1 row B6).
///
/// The variant drawer's Export Bookmarks and `variants export bookmarked` read the bookmarks each variant database
/// stores in its `variant_bookmarks` table, database by database in the drawer's track order, and write the same
/// eight columns. Every column follows from the databases, so the export takes no selection file (ARCH ruling 1.1).
public enum BookmarkedVariantExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling X-1, row B6).
    public static let commandPath = ["variants", "export", "bookmarked"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish variants export bookmarked"

    /// The leaf's invocation for the drawer's variant databases, in its track order, with absolute standardized
    /// paths. The first database is the invocation's input and the rest follow it as positional arguments.
    public static func invocation(
        databaseURLs: [URL],
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        let paths = databaseURLs.map { $0.standardizedFileURL.path }
        return ViewerExportInvocation(
            commandPath: commandPath,
            input: paths.first ?? "",
            leafArguments: Array(paths.dropFirst()),
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }
}
