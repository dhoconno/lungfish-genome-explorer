import Foundation
import LungfishCore

/// Project-level store for user-editable haplotype definition sets.
///
/// Definition sets live as JSON files under a `Haplotype Definitions/`
/// folder in the project root, with the `.lungfishhaplotypedef.json`
/// suffix. Each file holds one `GenotypeHaplotypeDefinitionSet` (which is
/// already `Codable`). The store layers user-defined sets on top of the
/// built-in registry, so the genotype workflow + inspector pick up user
/// definitions automatically.
///
/// **Why JSON files (not a single registry blob):** one file per
/// definition set is easier to diff, share, and version in git. Users can
/// drop a colleague's definition file into their `Haplotype Definitions/`
/// folder and it appears in the picker on next open.
public struct HaplotypeDefinitionStore: Sendable {
    public static let folderName = "Haplotype Definitions"
    public static let fileSuffix = ".lungfishhaplotypedef.json"

    public let projectRoot: URL?

    public init(projectRoot: URL?) {
        self.projectRoot = projectRoot
    }

    /// Absolute URL of the definition-set folder, creating it lazily if a
    /// project root is set. Returns nil when there is no project context.
    public func definitionsFolderURL() -> URL? {
        guard let projectRoot else { return nil }
        return projectRoot.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// Ensure the folder exists on disk. Idempotent — safe to call from
    /// the editor sheet whenever the user adds a new definition.
    public func ensureFolderExists() throws {
        guard let url = definitionsFolderURL() else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// All user-defined sets currently on disk, parsed into native
    /// `GenotypeHaplotypeDefinitionSet` values. Sets that fail to decode
    /// are skipped (don't crash the inspector for one malformed file).
    public func loadAllUserSets() -> [GenotypeHaplotypeDefinitionSet] {
        guard let folder = definitionsFolderURL(),
              FileManager.default.fileExists(atPath: folder.path) else {
            return []
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.lastPathComponent.hasSuffix(Self.fileSuffix) }
            .compactMap { url -> GenotypeHaplotypeDefinitionSet? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: data)
            }
    }

    /// Save a definition set to disk. The file name is derived from the
    /// set ID (path-safe). Overwrites if a file with the same id exists.
    /// Bumps the set's `schemaVersion` and stamps `lastModified` so the
    /// provenance trail can identify which version produced a call.
    public func save(
        _ set: GenotypeHaplotypeDefinitionSet,
        changeNote: String? = nil
    ) throws {
        try ensureFolderExists()
        guard let url = fileURL(for: set.id) else {
            throw HaplotypeDefinitionStoreError.noProjectRoot
        }
        let versioned = GenotypeHaplotypeDefinitionSet(
            id: set.id,
            assayID: set.assayID,
            displayName: set.displayName,
            speciesName: set.speciesName,
            speciesCode: set.speciesCode,
            prefix: set.prefix,
            locusDefinitions: set.locusDefinitions,
            schemaVersion: (set.schemaVersion ?? 0) + 1,
            lastModified: ISO8601DateFormatter().string(from: Date()),
            changeNote: changeNote ?? set.changeNote
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(versioned)
        try data.write(to: url, options: .atomic)
    }

    /// Remove a user-defined set by id. Does nothing for built-in IDs.
    public func delete(id: String) throws {
        guard let url = fileURL(for: id),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(for id: String) -> URL? {
        guard let folder = definitionsFolderURL() else { return nil }
        let safeId = id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return folder.appendingPathComponent(safeId + Self.fileSuffix)
    }

    /// Merge the built-in registry with all user-defined sets. User sets
    /// with IDs matching built-in IDs override the built-in entry. The
    /// returned registry is what the inspector + workflow should consult.
    public func mergedRegistry() -> GenotypeHaplotypeDefinitionRegistry {
        let builtIn = GenotypeHaplotypeDefinitionRegistry.builtIn
        let userSets = loadAllUserSets()
        guard !userSets.isEmpty else { return builtIn }
        // Group user sets by assayID; merge into the matching built-in
        // assay (or create a new assay when the assay id is unknown).
        let userByAssay = Dictionary(grouping: userSets, by: \.assayID)
        var assays: [GenotypeHaplotypeAssay] = builtIn.assays.map { assay in
            let userInThisAssay = userByAssay[assay.id] ?? []
            var merged = assay.definitionSets
            for userSet in userInThisAssay {
                if let existing = merged.firstIndex(where: { $0.id == userSet.id }) {
                    merged[existing] = userSet
                } else {
                    merged.append(userSet)
                }
            }
            return GenotypeHaplotypeAssay(
                id: assay.id,
                displayName: assay.displayName,
                definitionSets: merged
            )
        }
        // Surface user sets whose assay isn't in the built-in registry
        // as new assays so the picker can still find them.
        let knownAssayIDs = Set(assays.map(\.id))
        let novelAssayIDs = userByAssay.keys.filter { !knownAssayIDs.contains($0) }
        for assayID in novelAssayIDs {
            let sets = userByAssay[assayID] ?? []
            assays.append(GenotypeHaplotypeAssay(
                id: assayID,
                displayName: assayID,
                definitionSets: sets
            ))
        }
        return GenotypeHaplotypeDefinitionRegistry(
            assays: assays,
            defaultDefinitionSetID: builtIn.defaultDefinitionSetID
        )
    }
}

public enum HaplotypeDefinitionStoreError: Error, LocalizedError {
    case noProjectRoot

    public var errorDescription: String? {
        switch self {
        case .noProjectRoot:
            return "Open a Lungfish project before adding a haplotype definition set."
        }
    }
}
