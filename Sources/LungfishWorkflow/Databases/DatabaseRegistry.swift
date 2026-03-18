// DatabaseRegistry.swift - Bundled bioinformatics reference database management
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let dbLogger = Logger(subsystem: "com.lungfish.workflow", category: "DatabaseRegistry")

// MARK: - BundledDatabase

/// Metadata for a reference database bundled with the app.
///
/// Databases are stored in `Resources/Databases/<id>/` and can be overridden
/// by placing a newer file in `~/Library/Application Support/Lungfish/databases/<id>/`.
public struct BundledDatabase: Sendable, Codable {
    /// Machine-readable identifier (e.g. "human-scrubber").
    public let id: String
    /// Human-readable name shown in UI.
    public let displayName: String
    /// Which tool uses this database.
    public let tool: String
    /// Version string derived from the filename (e.g. "20250916v2").
    public let version: String
    /// Filename of the database file (e.g. "human_filter.db.20250916v2").
    public let filename: String
    /// ISO 8601 date when this version was released.
    public let releaseDate: String
    /// Human-readable description of what this database covers.
    public let description: String
    /// URL to the source project.
    public let sourceUrl: String
    /// URL to the releases page for checking for updates.
    public let releasesUrl: String
}

// MARK: - DatabaseRegistry

/// Resolves the runtime path of bundled reference databases.
///
/// Resolution priority:
/// 1. User-provided override in `~/Library/Application Support/Lungfish/databases/<id>/`
/// 2. Bundled database in the app's `Resources/Databases/<id>/` directory
///
/// To update a database without a full app update:
/// - Place the new database file in the override directory
/// - Update UserDefaults key `database.<id>.overrideFilename` with the new filename
///
/// Future releases will ship with newer bundled versions automatically.
public actor DatabaseRegistry {

    public static let shared = DatabaseRegistry()

    /// Loaded manifests indexed by database ID.
    private var manifests: [String: BundledDatabase] = [:]

    /// Root directory of bundled databases in Resources/Databases/.
    private var bundledDatabasesRoot: URL?

    /// User override directory base.
    private var userDatabasesRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Lungfish/databases")
    }

    private init() {}

    // MARK: - Public API

    /// All known bundled database IDs.
    public static let knownIDs: [String] = [
        "human-scrubber",
    ]

    /// Returns the manifest for a database, loading it if needed.
    public func manifest(for id: String) -> BundledDatabase? {
        if let cached = manifests[id] { return cached }
        guard let url = bundledManifestURL(for: id) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let db = try JSONDecoder().decode(BundledDatabase.self, from: data)
            manifests[id] = db
            return db
        } catch {
            dbLogger.error("Failed to load database manifest for '\(id)': \(error)")
            return nil
        }
    }

    /// Resolves the effective database file path for a given ID.
    ///
    /// Checks for a user override first, then falls back to the bundled database.
    /// Returns nil if neither is found.
    public func effectiveDatabasePath(for id: String) -> URL? {
        // 1. Check user override directory
        if let overridePath = userOverridePath(for: id) {
            dbLogger.info("Using user-override database for '\(id)': \(overridePath.lastPathComponent)")
            return overridePath
        }

        // 2. Fall back to bundled database
        if let bundledPath = bundledDatabasePath(for: id) {
            dbLogger.debug("Using bundled database for '\(id)': \(bundledPath.lastPathComponent)")
            return bundledPath
        }

        dbLogger.error("No database found for '\(id)'")
        return nil
    }

    /// Returns a human-readable version string for a database.
    public func versionString(for id: String) -> String {
        guard let db = manifest(for: id) else { return "unknown" }
        if userOverridePath(for: id) != nil {
            return "\(db.version) (user override)"
        }
        return db.version
    }

    // MARK: - Private Helpers

    private func bundledManifestURL(for id: String) -> URL? {
        databasesRoot()?
            .appendingPathComponent(id)
            .appendingPathComponent("manifest.json")
    }

    private func bundledDatabasePath(for id: String) -> URL? {
        guard let db = manifest(for: id) else { return nil }
        let url = databasesRoot()?
            .appendingPathComponent(id)
            .appendingPathComponent(db.filename)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func userOverridePath(for id: String) -> URL? {
        guard let base = userDatabasesRoot else { return nil }
        let dir = base.appendingPathComponent(id)

        // Check UserDefaults for a specific override filename
        let overrideKey = "database.\(id).overrideFilename"
        if let filename = UserDefaults.standard.string(forKey: overrideKey) {
            let url = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        // Fall back: scan directory for any file matching the database ID pattern
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }

        return contents
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // newest first by name
            .first
    }

    private func databasesRoot() -> URL? {
        if let cached = bundledDatabasesRoot { return cached }

        // Try the same discovery chain as NativeToolRunner uses for Tools/
        let candidates: [URL?] = [
            // SwiftPM module bundle (when run via `swift run` or in tests)
            Bundle.module.resourceURL?.appendingPathComponent("Databases"),
            // macOS app bundle
            Bundle.main.resourceURL?.appendingPathComponent("Databases"),
            // Executable-adjacent resources (CLI)
            {
                let exe = Bundle.main.executableURL
                return exe?.deletingLastPathComponent()
                    .appendingPathComponent("../Resources/Databases")
                    .standardized
            }(),
        ]

        for candidate in candidates.compactMap({ $0 }) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                bundledDatabasesRoot = candidate
                dbLogger.info("DatabaseRegistry root: \(candidate.path)")
                return candidate
            }
        }

        dbLogger.error("DatabaseRegistry: Could not find bundled Databases directory")
        return nil
    }
}
