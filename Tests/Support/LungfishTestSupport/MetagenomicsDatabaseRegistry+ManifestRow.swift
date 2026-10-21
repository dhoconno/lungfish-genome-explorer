// MetagenomicsDatabaseRegistry+ManifestRow.swift - A fixture row written through the manifest, as another process saves one
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.24 B66-DELETE. The registry once had a method that adopted a folder in process, and no
// shipped code called it. A real registry learns of a database it did not install the way the app does after
// `lungfish-cli conda db update`, by reading a manifest that another process saved. The fixtures that used the
// method now write the row into the manifest and call the public `reloadFromDisk()`, as the managed tools
// parity case did for its older version label.

import Foundation
import LungfishWorkflow

/// What `seedRowThroughManifest` throws besides the registry's own errors.
public enum ManifestRowFixtureError: Error, CustomStringConvertible {
    /// The row was written, and the registry did not hold it after it read the manifest again.
    case rowMissingAfterReload(name: String)

    public var description: String {
        switch self {
        case .rowMissingAfterReload(let name):
            return "the registry holds no row named '\(name)' after it read the manifest again"
        }
    }
}

/// The manifest file as the registry writes it. The registry keeps its own copy of this type to itself.
private struct ManifestRowFixtureFile: Codable {
    let version: Int
    let databases: [MetagenomicsDatabaseInfo]
}

extension MetagenomicsDatabaseRegistry {
    /// Adds a ready row for `folder` to the registry through its manifest and reads the manifest again.
    ///
    /// The row is the one the registry made when it adopted a folder in process. A name that matches a catalog
    /// row reuses that row, so the row keeps its catalog identity and records no version, because nothing
    /// checked the folder against the catalog's build. Any other name makes a user-imported Kraken2 row sized
    /// from the files in the folder. The folder is not validated.
    ///
    /// - Parameters:
    ///   - folder: The database folder.
    ///   - name: The row's name. The last path component of `folder` when `nil`.
    ///   - isExternal: Whether the row reads as on an external volume.
    ///   - bookmarkData: The bookmark the row carries.
    /// - Returns: The row as the registry holds it after it read the manifest again.
    @discardableResult
    public func seedRowThroughManifest(
        at folder: URL,
        name: String? = nil,
        isExternal: Bool = false,
        bookmarkData: Data? = nil
    ) throws -> MetagenomicsDatabaseInfo {
        let rowName = name ?? folder.lastPathComponent
        let now = Date()
        var rows = try availableDatabases()
        var row: MetagenomicsDatabaseInfo
        if let existing = rows.first(where: { $0.name == rowName }) {
            row = existing
            row.path = folder
            row.status = .ready
            row.version = nil
            row.installedAt = existing.installedAt ?? now
            row.lastUpdated = now
            row.isExternal = isExternal
            row.bookmarkData = bookmarkData
        } else {
            let size = Self.bytesBelow(folder)
            row = MetagenomicsDatabaseInfo(
                name: rowName,
                tool: MetagenomicsTool.kraken2.rawValue,
                version: nil,
                sizeBytes: size,
                sizeOnDisk: size,
                downloadURL: nil,
                description: "User-imported Kraken2 database",
                collection: Self.inferredCollection(of: folder, named: rowName),
                path: folder,
                isExternal: isExternal,
                bookmarkData: bookmarkData,
                installedAt: now,
                lastUpdated: now,
                status: .ready,
                recommendedRAM: size
            )
        }
        rows.removeAll { $0.name == rowName }
        rows.append(row)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestURL = URL(fileURLWithPath: storagePath, isDirectory: true)
            .appendingPathComponent("metagenomics-db-registry.json")
        let file = ManifestRowFixtureFile(version: 1, databases: rows.sorted { $0.name < $1.name })
        try encoder.encode(file).write(to: manifestURL, options: .atomic)

        try reloadFromDisk()
        guard let stored = try database(named: rowName) else {
            throw ManifestRowFixtureError.rowMissingAfterReload(name: rowName)
        }
        return stored
    }

    /// The total size of the files under `folder`, hidden files left out.
    private static func bytesBelow(_ folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in files {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// The first catalog collection whose name the folder's name contains, or whose display name is `name`.
    private static func inferredCollection(of folder: URL, named name: String) -> DatabaseCollection? {
        DatabaseCollection.allCases.first { collection in
            folder.lastPathComponent.lowercased().contains(collection.rawValue.replacingOccurrences(of: "-", with: ""))
                || name == collection.displayName
        }
    }
}
