import Foundation
import LungfishIO

/// Centralized routing logic for classifier result directories.
///
/// Determines whether a directory is a classifier result and whether it has
/// a pre-built SQLite database. Handles both top-level result directories and
/// per-sample subdirectories (walks up one level).
///
/// The tool of a folder comes from `AnalysesFolder.analysisInfo(for:)`, the identity the sidebar
/// row is built from, and is matched by its exact id. A folder name that only starts like a tool
/// names nothing, so a sample called `esviritu_ctrl` is a sample and not a result.
enum ClassifierDatabaseRouter {

    /// A routing decision for a classifier result directory.
    struct Route {
        /// The word `lungfish-cli build-db` takes (e.g. "taxtriage", "esviritu", "kraken2").
        let tool: String
        /// Human-readable tool name for UI display.
        let displayName: String
        /// The analysis kind, whose registry descriptor holds both names above.
        let analysisID: AnalysisToolID
        /// URL of the SQLite database file, or `nil` if no DB exists yet.
        let databaseURL: URL?
        /// URL of the top-level classifier result directory.
        let resultURL: URL
        /// Optional sample identifier when the input URL pointed at a per-sample subdir.
        let sampleId: String?
    }

    /// The classifiers with a SQLite database, each with the name of its index.
    private static let toolDefinitions: [(id: AnalysisToolID, dbName: String)] = [
        (.taxtriage, "taxtriage.sqlite"),
        (.esviritu,  "esviritu.sqlite"),
        (.kraken2,   "kraken2.sqlite"),
    ]

    /// The word the first releases used for a Kraken2 run, in `analysis-metadata.json` and as the folder
    /// prefix `classification-`. The registry does not know it, so the router maps it to Kraken2 itself.
    private static let legacyKraken2Token = "classification"

    /// The name the placeholder shows and the word `build-db` takes for the classifier `id`, both read
    /// from its registry descriptor. A kind the registry gives no token falls back to its id, which the
    /// CLI rejects with its own message.
    static func buildNames(for id: AnalysisToolID) -> (displayName: String, token: String) {
        let descriptor = AnalysisToolRegistry.descriptor(for: id)
        return (descriptor?.displayName ?? id.rawValue, descriptor?.buildDatabaseToken ?? id.rawValue)
    }

    /// Checks whether `url` is a classifier result directory or a per-sample
    /// subdirectory inside one.
    ///
    /// - If `url`'s parent is a classifier result, `url` is a sample of it whatever its name is. The
    ///   route has `sampleId = url.lastPathComponent` and `resultURL` pointing at the parent.
    /// - Otherwise, if `url` is a classifier result, returns a top-level `Route` with `sampleId = nil`.
    /// - Otherwise returns nil.
    static func route(for url: URL) -> Route? {
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path, !parent.lastPathComponent.isEmpty,
           let parentRoute = routeDirect(for: parent) {
            return Route(
                tool: parentRoute.tool,
                displayName: parentRoute.displayName,
                analysisID: parentRoute.analysisID,
                databaseURL: parentRoute.databaseURL,
                resultURL: parentRoute.resultURL,
                sampleId: url.lastPathComponent
            )
        }
        return routeDirect(for: url)
    }

    /// Direct match: the folder is the result of a classifier that has a database.
    private static func routeDirect(for url: URL) -> Route? {
        guard let definition = definition(for: url) else { return nil }
        let dbURL = url.appendingPathComponent(definition.dbName)
        let exists = FileManager.default.fileExists(atPath: dbURL.path)
        let names = buildNames(for: definition.id)
        return Route(
            tool: names.token,
            displayName: names.displayName,
            analysisID: definition.id,
            databaseURL: exists ? dbURL : nil,
            resultURL: url,
            sampleId: nil
        )
    }

    /// The classifier a folder is the result of, taken from `AnalysesFolder.analysisInfo(for:)`. That
    /// reads `analysis-metadata.json` first, which survives renames, then the registry's folder names
    /// with a timestamp, and last the files the tools leave, so a folder the user renamed or a
    /// command line output with a free name is placed as well. The id must match a classifier exactly.
    ///
    /// A folder `analysisInfo` cannot identify is a Kraken2 run only when its name has the `classification-`
    /// prefix of the first releases, which carried neither metadata nor a registry name.
    private static func definition(for url: URL) -> (id: AnalysisToolID, dbName: String)? {
        if let info = AnalysesFolder.analysisInfo(for: url) {
            let id = info.tool == legacyKraken2Token ? AnalysisToolID.kraken2 : AnalysisToolID(rawValue: info.tool)
            return toolDefinitions.first { $0.id == id }
        }
        guard url.lastPathComponent.hasPrefix(legacyKraken2Token + "-") else { return nil }
        return toolDefinitions.first { $0.id == .kraken2 }
    }
}
