import Foundation
import LungfishIO

/// Centralized routing logic for classifier result directories.
///
/// Determines whether a directory is a classifier result and whether it has
/// a pre-built SQLite database. Handles both top-level result directories and
/// per-sample subdirectories (walks up one level).
enum ClassifierDatabaseRouter {

    /// A routing decision for a classifier result directory.
    struct Route {
        /// Tool identifier used by the CLI (e.g. "taxtriage", "esviritu", "kraken2").
        let tool: String
        /// Human-readable tool name for UI display.
        let displayName: String
        /// URL of the SQLite database file, or `nil` if no DB exists yet.
        let databaseURL: URL?
        /// URL of the top-level classifier result directory.
        let resultURL: URL
        /// Optional sample identifier when the input URL pointed at a per-sample subdir.
        let sampleId: String?
    }

    private static let toolDefinitions: [(prefix: String, dbName: String, tool: String, displayName: String)] = [
        ("taxtriage",      "taxtriage.sqlite", "taxtriage", "TaxTriage"),
        ("esviritu",       "esviritu.sqlite",  "esviritu",  "EsViritu"),
        ("kraken2",        "kraken2.sqlite",   "kraken2",   "Kraken2"),
        ("classification", "kraken2.sqlite",   "kraken2",   "Kraken2"),
    ]

    /// Checks whether `url` is a classifier result directory or a per-sample
    /// subdirectory inside one.
    ///
    /// - If `url` matches a tool prefix directly, returns a top-level `Route`
    ///   with `sampleId = nil`.
    /// - If `url`'s parent matches a tool prefix, returns a `Route` with
    ///   `sampleId = url.lastPathComponent` and `resultURL` pointing at the parent.
    /// - Otherwise returns nil.
    static func route(for url: URL) -> Route? {
        if let direct = routeDirect(for: url) {
            return direct
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, !parent.lastPathComponent.isEmpty else {
            return nil
        }
        if let parentRoute = routeDirect(for: parent) {
            return Route(
                tool: parentRoute.tool,
                displayName: parentRoute.displayName,
                databaseURL: parentRoute.databaseURL,
                resultURL: parentRoute.resultURL,
                sampleId: url.lastPathComponent
            )
        }
        return nil
    }

    /// Direct match: prefer the authoritative `analysis-metadata.json` tool id
    /// (survives renames); fall back to the directory-name prefix only when no
    /// metadata sidecar is present (legacy directories predating the sidecar).
    private static func routeDirect(for url: URL) -> Route? {
        let dirName = url.lastPathComponent
        let resolvedTool = AnalysesFolder.readAnalysisMetadata(from: url)?.tool ?? dirName
        for def in toolDefinitions where resolvedTool.hasPrefix(def.prefix) || dirName.hasPrefix(def.prefix) {
            let dbURL = url.appendingPathComponent(def.dbName)
            let exists = FileManager.default.fileExists(atPath: dbURL.path)
            return Route(
                tool: def.tool,
                displayName: def.displayName,
                databaseURL: exists ? dbURL : nil,
                resultURL: url,
                sampleId: nil
            )
        }
        return nil
    }
}
