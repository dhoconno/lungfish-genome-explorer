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

extension BookmarkedVariantExport {
    /// One bookmarked variant as the export writes it, from a database's `bookmarkedVariants()`.
    package struct Row: Sendable, Equatable {
        let name: String
        let type: String
        let chromosome: String
        let start: Int
        let ref: String?
        let alt: String?
        let quality: Double?
        let filter: String?

        package init(
            name: String,
            type: String,
            chromosome: String,
            start: Int,
            ref: String?,
            alt: String?,
            quality: Double?,
            filter: String?
        ) {
            self.name = name
            self.type = type
            self.chromosome = chromosome
            self.start = start
            self.ref = ref
            self.alt = alt
            self.quality = quality
            self.filter = filter
        }
    }

    /// The eight-column TSV of the rows in their order. `Pos` is the stored 0-based start plus one, a negative or
    /// missing quality prints `.` and so does a missing ref, alt or filter.
    package static func tsv(rows: [Row]) -> String {
        var lines = [["ID", "Type", "Chrom", "Pos", "Ref", "Alt", "Quality", "Filter"].joined(separator: "\t")]
        for row in rows {
            let quality = row.quality.map { $0 < 0 ? "." : String(format: "%.1f", $0) } ?? "."
            lines.append([row.name, row.type, row.chromosome, "\(row.start + 1)",
                row.ref ?? ".", row.alt ?? ".", quality, row.filter ?? "."].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
