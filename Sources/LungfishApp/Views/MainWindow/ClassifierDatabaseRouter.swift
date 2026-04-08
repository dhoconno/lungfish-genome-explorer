// Sources/LungfishApp/Views/MainWindow/ClassifierDatabaseRouter.swift

import Foundation

/// Centralized routing logic for classifier result directories.
///
/// Determines whether a directory is a classifier result and whether it has
/// a pre-built SQLite database. Used by `MainSplitViewController` to decide
/// between DB-backed display, auto-build, or non-classifier handling.
enum ClassifierDatabaseRouter {

    /// A routing decision for a classifier result directory.
    struct Route {
        /// Tool identifier used by the CLI (e.g. "taxtriage", "esviritu", "kraken2").
        let tool: String
        /// Human-readable tool name for UI display (e.g. "TaxTriage", "EsViritu", "Kraken2").
        let displayName: String
        /// URL of the SQLite database file, or `nil` if no DB exists yet.
        let databaseURL: URL?
    }

    private static let toolDefinitions: [(prefix: String, dbName: String, tool: String, displayName: String)] = [
        ("taxtriage",      "taxtriage.sqlite", "taxtriage", "TaxTriage"),
        ("esviritu",       "esviritu.sqlite",  "esviritu",  "EsViritu"),
        ("kraken2",        "kraken2.sqlite",   "kraken2",   "Kraken2"),
        ("classification", "kraken2.sqlite",   "kraken2",   "Kraken2"),
    ]

    /// Checks whether `url` is a classifier result directory.
    ///
    /// - Returns: `Route` with `databaseURL` set if the DB exists, `databaseURL=nil`
    ///   if the directory is a classifier result but has no DB yet, or `nil` if the
    ///   directory is not a classifier result at all.
    static func route(for url: URL) -> Route? {
        let dirName = url.lastPathComponent
        for def in toolDefinitions {
            guard dirName.hasPrefix(def.prefix) else { continue }
            let dbURL = url.appendingPathComponent(def.dbName)
            if FileManager.default.fileExists(atPath: dbURL.path) {
                return Route(tool: def.tool, displayName: def.displayName, databaseURL: dbURL)
            } else {
                return Route(tool: def.tool, displayName: def.displayName, databaseURL: nil)
            }
        }
        return nil
    }
}
