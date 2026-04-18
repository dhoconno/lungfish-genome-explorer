// MetagenomicsDatabaseRegistry.swift - Metagenomics database installation manager
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "MetagenomicsDBRegistry")

// MARK: - MetagenomicsDatabaseRegistryError

/// Errors produced by ``MetagenomicsDatabaseRegistry`` operations.
public enum MetagenomicsDatabaseRegistryError: Error, LocalizedError, Sendable {
    /// No database with the given name exists in the registry.
    case databaseNotFound(name: String)

    /// A database with the given name is already registered.
    case duplicateDatabase(name: String)

    /// The directory does not contain the required Kraken2 files.
    case invalidDatabaseDirectory(path: String, missingFiles: [String])

    /// Security-scoped bookmark could not be resolved.
    case bookmarkResolutionFailed(name: String, reason: String)

    /// The manifest file could not be read or written.
    case manifestIOError(operation: String, underlying: Error)

    /// Download failed.
    case downloadFailed(name: String, reason: String)

    /// Download was cancelled.
    case downloadCancelled(name: String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let name):
            return "Database '\(name)' not found in registry"
        case .duplicateDatabase(let name):
            return "Database '\(name)' is already registered"
        case .invalidDatabaseDirectory(let path, let missing):
            return "Invalid database at '\(path)': missing \(missing.joined(separator: ", "))"
        case .bookmarkResolutionFailed(let name, let reason):
            return "Cannot resolve bookmark for '\(name)': \(reason)"
        case .manifestIOError(let operation, let underlying):
            return "Manifest \(operation) failed: \(underlying.localizedDescription)"
        case .downloadFailed(let name, let reason):
            return "Download of '\(name)' failed: \(reason)"
        case .downloadCancelled(let name):
            return "Download of '\(name)' was cancelled"
        }
    }
}

// MARK: - MetagenomicsDatabaseRegistry

/// Actor that manages metagenomics database installations, verification,
/// and bookmark-based relocation.
///
/// The registry persists its state to a JSON manifest at
/// `<databasesBaseURL>/metagenomics-db-registry.json`. On first launch, the
/// manifest is populated with the built-in catalog entries (all in `.missing`
/// status). As the user downloads or registers databases, their entries are
/// updated with paths and status.
///
/// ## Storage Layout
///
/// ```
/// <databasesBaseURL>/
///     metagenomics-db-registry.json
///     kraken2/
///         standard-8/
///             hash.k2d
///             opts.k2d
///             taxo.k2d
///             ...
///         viral/
///             ...
/// ```
///
/// ## Configurable Storage Location
///
/// The storage location can be customized via UserDefaults key
/// `"DatabaseStorageLocation"`. Call ``setStorageLocation(_:migrateExisting:)``
/// to change it at runtime. The singleton reads the UserDefaults key on init
/// to determine the initial base directory.
///
/// ## External Volume Support
///
/// When a database is relocated to an external volume:
/// 1. Files are moved to the destination.
/// 2. A security-scoped bookmark is created for the new location.
/// 3. The bookmark is persisted in the manifest.
/// 4. On next launch, the bookmark is resolved to obtain the current path.
/// 5. If the volume is not mounted, the database status becomes `.volumeNotMounted`.
///
/// ## Thread Safety
///
/// All mutable state is isolated to this actor. External callers must `await`
/// every method.
public actor MetagenomicsDatabaseRegistry {

    /// Shared singleton instance.
    ///
    /// Uses the default manifest path at `<databasesBaseURL>/metagenomics-db-registry.json`,
    /// where `databasesBaseURL` is read from UserDefaults key `"DatabaseStorageLocation"`
    /// or falls back to `~/.lungfish/databases/`.
    public static let shared = MetagenomicsDatabaseRegistry()

    /// UserDefaults key matching ``AppSettings/databaseStorageLocationKey``.
    ///
    /// Duplicated here to avoid a compile-time dependency on the `@MainActor`
    /// `AppSettings` class from within this actor.
    private static let storageLocationKey = "DatabaseStorageLocation"

    // MARK: - Storage

    /// Path to the JSON manifest file.
    private(set) var manifestURL: URL

    /// Base directory for downloaded databases.
    private(set) var databasesBaseURL: URL

    /// In-memory database entries, keyed by name.
    private var databases: [String: MetagenomicsDatabaseInfo] = [:]

    /// Files required for a valid Kraken2 database directory.
    static let requiredKraken2Files = ["hash.k2d", "opts.k2d", "taxo.k2d"]

    // MARK: - Initialization

    /// Creates a registry backed by the configured or default `~/.lungfish/databases/` directory.
    ///
    /// Reads UserDefaults key `"DatabaseStorageLocation"` for a custom path.
    /// Falls back to `~/.lungfish/databases/` if no custom path is set.
    /// The directory and manifest file are created on first access if they do
    /// not already exist.
    public init() {
        let base = ManagedStorageConfigStore().currentLocation().databaseRootURL
        self.databasesBaseURL = base
        self.manifestURL = base.appendingPathComponent("metagenomics-db-registry.json")
    }

    /// Creates a registry backed by a custom directory.
    ///
    /// Primarily for testing -- allows each test to use an isolated temp directory.
    ///
    /// - Parameter baseDirectory: Root directory for the manifest and database storage.
    public init(baseDirectory: URL) {
        self.databasesBaseURL = baseDirectory
        self.manifestURL = baseDirectory.appendingPathComponent("metagenomics-db-registry.json")
    }

    // MARK: - Storage Location Management

    /// Changes the base storage directory at runtime.
    ///
    /// Optionally moves existing database files from the old location to the
    /// new one. The manifest is always regenerated at the new location.
    ///
    /// - Parameters:
    ///   - url: The new base directory URL.
    ///   - migrateExisting: If `true`, moves existing database files to the new location.
    ///     Defaults to `false`.
    public func setStorageLocation(_ url: URL, migrateExisting: Bool = false) throws {
        let oldBase = databasesBaseURL
        let newBase = url

        let fm = FileManager.default

        // Create the new directory if needed.
        if !fm.fileExists(atPath: newBase.path) {
            try fm.createDirectory(at: newBase, withIntermediateDirectories: true)
        }

        if migrateExisting && fm.fileExists(atPath: oldBase.path) {
            // Move the kraken2 subdirectory if it exists.
            let oldKraken2 = oldBase.appendingPathComponent("kraken2")
            let newKraken2 = newBase.appendingPathComponent("kraken2")
            if fm.fileExists(atPath: oldKraken2.path) && !fm.fileExists(atPath: newKraken2.path) {
                try fm.moveItem(at: oldKraken2, to: newKraken2)
                logger.info("Migrated kraken2 databases from \(oldBase.path, privacy: .public) to \(newBase.path, privacy: .public)")
            }

            // Update database paths in memory.
            for (name, var db) in databases {
                if let path = db.path, path.path.hasPrefix(oldBase.path) {
                    let relativePath = String(path.path.dropFirst(oldBase.path.count))
                    db.path = newBase.appendingPathComponent(relativePath)
                    databases[name] = db
                }
            }
        }

        // Update storage URLs.
        databasesBaseURL = newBase
        manifestURL = newBase.appendingPathComponent("metagenomics-db-registry.json")

        // Persist UserDefaults.
        let defaultBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lungfish/databases")
        if newBase.standardizedFileURL == defaultBase.standardizedFileURL {
            UserDefaults.standard.removeObject(forKey: Self.storageLocationKey)
        } else {
            UserDefaults.standard.set(newBase.path, forKey: Self.storageLocationKey)
        }

        // Save the manifest at the new location.
        if !databases.isEmpty {
            try saveManifest()
        }

        logger.info("Database storage location changed to \(newBase.path, privacy: .public)")
    }

    /// Returns the current base directory path for display purposes.
    public var storagePath: String {
        databasesBaseURL.path
    }

    /// Loads the manifest from disk, or initializes from the built-in catalog
    /// if no manifest exists yet.
    ///
    /// This method is idempotent -- calling it multiple times has no effect
    /// after the first successful load.
    public func loadIfNeeded() throws {
        guard databases.isEmpty else { return }

        let fm = FileManager.default

        // Ensure the base directory exists.
        if !fm.fileExists(atPath: databasesBaseURL.path) {
            do {
                try fm.createDirectory(at: databasesBaseURL, withIntermediateDirectories: true)
                logger.info("Created databases directory: \(self.databasesBaseURL.path, privacy: .public)")
            } catch {
                throw MetagenomicsDatabaseRegistryError.manifestIOError(
                    operation: "createDirectory", underlying: error
                )
            }
        }

        // Try loading an existing manifest.
        if fm.fileExists(atPath: manifestURL.path) {
            do {
                let data = try Data(contentsOf: manifestURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let manifest = try decoder.decode(DatabaseManifest.self, from: data)
                for db in manifest.databases {
                    databases[db.name] = db
                }
                logger.info(
                    "Loaded \(self.databases.count, privacy: .public) databases from manifest"
                )
            } catch {
                throw MetagenomicsDatabaseRegistryError.manifestIOError(
                    operation: "load", underlying: error
                )
            }

            // Merge any new built-in catalog entries that weren't in the
            // persisted manifest (e.g., EsViritu DB added in a newer version).
            var addedCount = 0
            for entry in MetagenomicsDatabaseInfo.builtInCatalog {
                if databases[entry.name] == nil {
                    databases[entry.name] = entry
                    addedCount += 1
                }
            }
            if addedCount > 0 {
                try saveManifest()
                logger.info("Merged \(addedCount, privacy: .public) new catalog entries into existing manifest")
            }
        } else {
            // First launch: populate from built-in catalog.
            for entry in MetagenomicsDatabaseInfo.builtInCatalog {
                databases[entry.name] = entry
            }
            try saveManifest()
            logger.info("Initialized manifest with \(self.databases.count, privacy: .public) catalog entries")
        }
    }

    // MARK: - CRUD

    /// Returns all registered databases, loading the manifest if needed.
    ///
    /// - Returns: Array of all database entries, sorted by name.
    public func availableDatabases() throws -> [MetagenomicsDatabaseInfo] {
        try loadIfNeeded()
        return databases.values.sorted { $0.name < $1.name }
    }

    /// Returns databases compatible with the specified tool.
    ///
    /// - Parameter tool: The metagenomics tool to filter by.
    /// - Returns: Database entries whose `tool` matches the given tool's raw value.
    public func databases(for tool: MetagenomicsTool) throws -> [MetagenomicsDatabaseInfo] {
        try loadIfNeeded()
        return databases.values
            .filter { $0.tool == tool.rawValue }
            .sorted { $0.name < $1.name }
    }

    /// Returns a specific database by name.
    ///
    /// - Parameter name: The database name (e.g., "Standard-8").
    /// - Returns: The database entry, or `nil` if not registered.
    public func database(named name: String) throws -> MetagenomicsDatabaseInfo? {
        try loadIfNeeded()
        return databases[name]
    }

    /// Returns the first installed (ready) database for the given tool, or nil.
    ///
    /// - Parameter tool: The metagenomics tool to find an installed database for.
    /// - Returns: The first database entry with matching tool, `.ready` status, and a non-nil path.
    public func installedDatabase(tool: MetagenomicsTool) throws -> MetagenomicsDatabaseInfo? {
        try loadIfNeeded()
        return databases.values.first { $0.tool == tool.rawValue && $0.status == .ready && $0.path != nil }
    }

    /// Registers an existing database directory.
    ///
    /// Validates that the directory contains the required Kraken2 files,
    /// then adds it to the registry. If a database with the same name
    /// already exists and is downloaded, throws ``MetagenomicsDatabaseRegistryError/duplicateDatabase(name:)``.
    ///
    /// - Parameters:
    ///   - url: Path to the database directory on disk.
    ///   - name: Display name for the database. If `nil`, the directory name is used.
    /// - Returns: The registered database info.
    @discardableResult
    public func registerExisting(at url: URL, name: String? = nil) throws -> MetagenomicsDatabaseInfo {
        try loadIfNeeded()

        let dbName = name ?? url.lastPathComponent

        // Check for duplicates (only if the existing entry is already downloaded).
        if let existing = databases[dbName], existing.isDownloaded {
            throw MetagenomicsDatabaseRegistryError.duplicateDatabase(name: dbName)
        }

        // Validate required files.
        let missingFiles = Self.missingRequiredFiles(in: url)
        if !missingFiles.isEmpty {
            throw MetagenomicsDatabaseRegistryError.invalidDatabaseDirectory(
                path: url.path, missingFiles: missingFiles
            )
        }

        // Compute size on disk.
        let sizeOnDisk = Self.directorySize(at: url)

        // Determine if this matches a catalog entry.
        let matchingCollection = DatabaseCollection.allCases.first { collection in
            url.lastPathComponent.lowercased().contains(collection.rawValue.replacingOccurrences(of: "-", with: ""))
                || dbName == collection.displayName
        }

        var info: MetagenomicsDatabaseInfo
        if let existing = databases[dbName] {
            // Update the existing catalog entry with the path.
            info = existing
            info.path = url
            info.status = .ready
            info.lastUpdated = Date()
        } else {
            // Create a new entry for a user-imported database.
            info = MetagenomicsDatabaseInfo(
                name: dbName,
                tool: MetagenomicsTool.kraken2.rawValue,
                version: nil,
                sizeBytes: sizeOnDisk,
                sizeOnDisk: sizeOnDisk,
                downloadURL: nil,
                description: "User-imported Kraken2 database",
                collection: matchingCollection,
                path: url,
                isExternal: false,
                bookmarkData: nil,
                lastUpdated: Date(),
                status: .ready,
                recommendedRAM: sizeOnDisk  // conservative: assume RAM ~= DB size
            )
        }

        databases[dbName] = info
        try saveManifest()

        logger.info("Registered database '\(dbName, privacy: .public)' at \(url.path, privacy: .public)")
        return info
    }

    /// Removes a database from the registry.
    ///
    /// This only removes the registry entry -- it does **not** delete the
    /// database files from disk. The caller is responsible for file cleanup
    /// if desired.
    ///
    /// - Parameter name: Name of the database to remove.
    public func removeDatabase(name: String) throws {
        try loadIfNeeded()

        guard databases[name] != nil else {
            throw MetagenomicsDatabaseRegistryError.databaseNotFound(name: name)
        }

        // If this is a catalog entry, reset to undownloaded state rather than deleting.
        if let collection = databases[name]?.collection {
            if let catalogEntry = MetagenomicsDatabaseInfo.catalogEntry(for: collection) {
                databases[name] = catalogEntry
                try saveManifest()
                logger.info("Reset catalog database '\(name, privacy: .public)' to undownloaded state")
                return
            }
        }

        databases.removeValue(forKey: name)
        try saveManifest()
        logger.info("Removed database '\(name, privacy: .public)' from registry")
    }

    /// Verifies that a database's files are intact.
    ///
    /// Checks that the required Kraken2 files exist at the database's path.
    /// Updates the database's status accordingly.
    ///
    /// - Parameter name: Name of the database to verify.
    /// - Returns: The updated status.
    @discardableResult
    public func verify(name: String) throws -> DatabaseStatus {
        try loadIfNeeded()

        guard var db = databases[name] else {
            throw MetagenomicsDatabaseRegistryError.databaseNotFound(name: name)
        }

        guard let path = db.path else {
            db.status = .missing
            databases[name] = db
            try saveManifest()
            return .missing
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            db.status = .missing
            db.path = nil
            databases[name] = db
            try saveManifest()
            return .missing
        }

        let missing = Self.missingRequiredFiles(in: path, tool: db.tool)
        if missing.isEmpty {
            db.status = .ready
            db.lastUpdated = Date()
        } else {
            db.status = .corrupt
            logger.warning(
                "Database '\(name, privacy: .public)' missing files: \(missing.joined(separator: ", "), privacy: .public)"
            )
        }

        databases[name] = db
        try saveManifest()
        return db.status
    }

    /// Relocates a database to a new directory.
    ///
    /// The registry entry is updated with the new path. If the destination
    /// is on an external volume, a security-scoped bookmark is created.
    /// The actual file move must be performed by the caller before calling
    /// this method.
    ///
    /// - Parameters:
    ///   - name: Name of the database to relocate.
    ///   - destination: The new directory URL.
    public func relocateDatabase(name: String, to destination: URL) throws {
        try loadIfNeeded()

        guard var db = databases[name] else {
            throw MetagenomicsDatabaseRegistryError.databaseNotFound(name: name)
        }

        // Validate the destination contains the required files.
        let missing = Self.missingRequiredFiles(in: destination, tool: db.tool)
        if !missing.isEmpty {
            throw MetagenomicsDatabaseRegistryError.invalidDatabaseDirectory(
                path: destination.path, missingFiles: missing
            )
        }

        db.path = destination
        db.isExternal = Self.isExternalVolume(destination)
        db.lastUpdated = Date()
        db.status = .ready

        // Create bookmark for external volumes.
        if db.isExternal {
            do {
                db.bookmarkData = try createBookmark(for: destination)
                logger.info(
                    "Created bookmark for '\(name, privacy: .public)' on external volume"
                )
            } catch {
                logger.warning(
                    "Failed to create bookmark for '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                // Continue without bookmark -- the path alone may still work.
            }
        } else {
            db.bookmarkData = nil
        }

        databases[name] = db
        try saveManifest()
        logger.info(
            "Relocated database '\(name, privacy: .public)' to \(destination.path, privacy: .public)"
        )
    }

    // MARK: - Bookmark Support

    /// Resolves a security-scoped bookmark to a current URL.
    ///
    /// If the bookmark resolves successfully, the database's path and status
    /// are updated. If the volume is not mounted, the status becomes
    /// `.volumeNotMounted`.
    ///
    /// - Parameter db: The database info containing bookmark data.
    /// - Returns: The resolved URL, or `nil` if the volume is not mounted.
    public func resolveBookmark(for db: MetagenomicsDatabaseInfo) -> URL? {
        guard let bookmarkData = db.bookmarkData else { return db.path }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                logger.info("Bookmark for '\(db.name, privacy: .public)' is stale, refreshing")
                // Update the bookmark in the background -- not critical if it fails.
                if var updated = databases[db.name] {
                    updated.bookmarkData = try? url.bookmarkData(options: .withSecurityScope)
                    updated.path = url
                    updated.status = .ready
                    databases[db.name] = updated
                    try? saveManifest()
                }
            }

            return url
        } catch {
            logger.warning(
                "Bookmark resolution failed for '\(db.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            // Mark as volume not mounted.
            if var updated = databases[db.name] {
                updated.status = .volumeNotMounted
                databases[db.name] = updated
                try? saveManifest()
            }
            return nil
        }
    }

    /// Creates a security-scoped bookmark for a URL.
    ///
    /// - Parameter url: The URL to bookmark.
    /// - Returns: Bookmark data that can be stored and later resolved.
    public func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves all bookmarks for external databases and updates their status.
    ///
    /// Call this at app launch to check which external volumes are mounted.
    public func resolveAllBookmarks() throws {
        try loadIfNeeded()

        for (name, db) in databases where db.isExternal && db.bookmarkData != nil {
            let resolved = resolveBookmark(for: db)
            if resolved == nil {
                logger.info("External database '\(name, privacy: .public)' volume not mounted")
            }
        }
    }

    // MARK: - RAM-Aware Recommendations

    /// Returns the recommended database for the current system's RAM.
    ///
    /// The recommendation logic follows the design document:
    /// - 72+ GB RAM: PlusPF (most comprehensive)
    /// - 32+ GB RAM: Standard
    /// - 16+ GB RAM: Standard-16
    /// - <16 GB RAM: Standard-8
    ///
    /// - Parameter ramBytes: Override for system RAM (defaults to
    ///   `ProcessInfo.processInfo.physicalMemory`). Pass explicitly for testing.
    /// - Returns: The recommended database info.
    public func recommendedDatabase(ramBytes: UInt64? = nil) throws -> MetagenomicsDatabaseInfo {
        try loadIfNeeded()

        let ram = ramBytes ?? UInt64(ProcessInfo.processInfo.physicalMemory)
        let collection = Self.recommendedCollection(forRAMBytes: ram)

        // Prefer an already-downloaded database of the recommended collection.
        if let db = databases[collection.displayName], db.isDownloaded {
            return db
        }

        // Fall back to the catalog entry.
        if let db = databases[collection.displayName] {
            return db
        }

        // Should never happen if the catalog was loaded, but return a safe default.
        return MetagenomicsDatabaseInfo.catalogEntry(for: collection)
            ?? MetagenomicsDatabaseInfo.builtInCatalog.first!
    }

    /// Returns the recommended collection for a given RAM amount.
    ///
    /// - Parameter ramBytes: Available physical memory in bytes.
    /// - Returns: The recommended database collection.
    public static func recommendedCollection(forRAMBytes ramBytes: UInt64) -> DatabaseCollection {
        let gb72: UInt64 = 72 * 1_073_741_824
        let gb32: UInt64 = 32 * 1_073_741_824
        let gb16: UInt64 = 16 * 1_073_741_824

        if ramBytes >= gb72 {
            return .plusPF
        } else if ramBytes >= gb32 {
            return .standard
        } else if ramBytes >= gb16 {
            return .standard16
        } else {
            return .standard8
        }
    }

    // MARK: - Download Support

    /// Downloads a database from the built-in catalog.
    ///
    /// The download uses `URLSessionDownloadTask` which supports automatic
    /// resume. The database tarball is downloaded to a temporary location,
    /// then extracted to `<databasesBaseURL>/kraken2/<collection>/`.
    ///
    /// - Parameters:
    ///   - name: Name of the database to download (must be a catalog entry).
    ///   - progress: Callback for download progress updates. The first parameter
    ///     is the fraction complete (0.0...1.0), the second is a status message.
    /// - Returns: The URL where the database was installed.
    public func downloadDatabase(
        name: String,
        progress: @Sendable @escaping (Double, String) -> Void
    ) async throws -> URL {
        try loadIfNeeded()

        guard var db = databases[name] else {
            throw MetagenomicsDatabaseRegistryError.databaseNotFound(name: name)
        }

        guard let urlString = db.downloadURL, let url = URL(string: urlString) else {
            throw MetagenomicsDatabaseRegistryError.downloadFailed(
                name: name, reason: "No download URL available"
            )
        }

        // Determine destination directory, organized by tool.
        let toolSubdir = db.tool.isEmpty ? "other" : db.tool
        let destDir = databasesBaseURL
            .appendingPathComponent(toolSubdir)
            .appendingPathComponent(name.lowercased().replacingOccurrences(of: " ", with: "-"))

        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Update status.
        db.status = .downloading
        databases[name] = db
        try saveManifest()

        progress(0.0, "Starting download of \(name)...")

        // Download using URLSession delegate for progress.
        let tarballURL: URL
        do {
            tarballURL = try await downloadFile(
                from: url,
                progress: { fraction, bytesWritten, totalBytes in
                    let mbWritten = Double(bytesWritten) / 1_048_576.0
                    let mbTotal = Double(totalBytes) / 1_048_576.0
                    progress(
                        fraction * 0.8, // 80% for download, 20% for extraction
                        String(format: "Downloading %.0f / %.0f MB", mbWritten, mbTotal)
                    )
                }
            )
        } catch {
            db.status = .missing
            databases[name] = db
            try? saveManifest()

            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                throw MetagenomicsDatabaseRegistryError.downloadCancelled(name: name)
            }
            throw MetagenomicsDatabaseRegistryError.downloadFailed(
                name: name, reason: error.localizedDescription
            )
        }

        // Extract tarball.
        progress(0.8, "Extracting database...")
        do {
            try await extractTarball(tarballURL, to: destDir)
        } catch {
            db.status = .missing
            databases[name] = db
            try? saveManifest()
            throw MetagenomicsDatabaseRegistryError.downloadFailed(
                name: name, reason: "Extraction failed: \(error.localizedDescription)"
            )
        }

        // Clean up tarball.
        try? fm.removeItem(at: tarballURL)

        // Verify the extracted database using tool-specific validation.
        let missing = Self.missingRequiredFiles(in: destDir, tool: db.tool)
        if !missing.isEmpty {
            db.status = .corrupt
            databases[name] = db
            try? saveManifest()
            throw MetagenomicsDatabaseRegistryError.invalidDatabaseDirectory(
                path: destDir.path, missingFiles: missing
            )
        }

        // Update registry.
        db.path = destDir
        db.status = .ready
        db.lastUpdated = Date()
        db.sizeOnDisk = Self.directorySize(at: destDir)
        databases[name] = db
        try saveManifest()

        progress(1.0, "Database \(name) installed successfully")
        logger.info("Installed database '\(name, privacy: .public)' at \(destDir.path, privacy: .public)")

        return destDir
    }

    // MARK: - Private Helpers

    /// Persists the current database entries to the manifest JSON file.
    private func saveManifest() throws {
        let manifest = DatabaseManifest(
            version: 1,
            databases: Array(databases.values.sorted { $0.name < $1.name })
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw MetagenomicsDatabaseRegistryError.manifestIOError(
                operation: "save", underlying: error
            )
        }
    }

    /// Returns the names of required files missing from a database directory.
    ///
    /// Validation is tool-aware: Kraken2 databases need `hash.k2d`, `opts.k2d`,
    /// `taxo.k2d`. EsViritu databases need at least one `.fasta` or `.fa` file.
    /// Unknown tools skip validation (return empty).
    static func missingRequiredFiles(in directory: URL, tool: String = "kraken2") -> [String] {
        let fm = FileManager.default

        switch tool {
        case MetagenomicsTool.kraken2.rawValue:
            return requiredKraken2Files.filter { filename in
                !fm.fileExists(atPath: directory.appendingPathComponent(filename).path)
            }

        case MetagenomicsTool.esviritu.rawValue:
            // EsViritu DB contains FASTA references + taxonomy metadata.
            // Check for any .fasta, .fa, or .fna file as a basic validation.
            let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let hasFasta = contents.contains { url in
                let ext = url.pathExtension.lowercased()
                return ext == "fasta" || ext == "fa" || ext == "fna" || ext == "mmi"
            }
            // Also check subdirectories (EsViritu DB may have nested structure)
            if !hasFasta {
                let subdirs = contents.filter { url in
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: url.path, isDirectory: &isDir)
                    return isDir.boolValue
                }
                for subdir in subdirs {
                    let subContents = (try? fm.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil)) ?? []
                    if subContents.contains(where: { ["fasta", "fa", "fna", "mmi"].contains($0.pathExtension.lowercased()) }) {
                        return []  // Valid
                    }
                }
                return ["*.fasta or *.fa reference files"]
            }
            return []

        case MetagenomicsTool.ncbiTaxonomy.rawValue:
            let required = ["names.dmp"]
            return required.filter { !fm.fileExists(atPath: directory.appendingPathComponent($0).path) }

        default:
            // Unknown tool — skip validation
            return []
        }
    }

    /// Returns whether a URL resides on an external (removable) volume.
    static func isExternalVolume(_ url: URL) -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsInternalKey])
            if let isRemovable = resourceValues.volumeIsRemovable, isRemovable {
                return true
            }
            if let isInternal = resourceValues.volumeIsInternal, !isInternal {
                return true
            }
        } catch {
            // If we can't determine, assume internal.
            logger.debug("Could not determine volume type for \(url.path, privacy: .public)")
        }
        return false
    }

    /// Computes the total size of all files in a directory, recursively.
    static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

    /// Downloads a file using URLSession with progress reporting.
    ///
    /// Bridges Swift Task cancellation to URLSession cancellation using
    /// `withTaskCancellationHandler`, so cancelling the parent Task
    /// (e.g., from the UI cancel button) also cancels the network download.
    private func downloadFile(
        from url: URL,
        progress: @Sendable @escaping (Double, Int64, Int64) -> Void
    ) async throws -> URL {
        // Use nonisolated(unsafe) for the task reference that crosses
        // the isolation boundary into the cancellation handler.
        nonisolated(unsafe) var downloadTask: URLSessionDownloadTask?

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let delegate = DownloadProgressDelegate(
                    progress: progress,
                    completion: { result in
                        switch result {
                        case .success(let url):
                            continuation.resume(returning: url)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                )

                let session = URLSession(
                    configuration: .default,
                    delegate: delegate,
                    delegateQueue: nil
                )
                let task = session.downloadTask(with: url)
                downloadTask = task
                task.resume()
            }
        } onCancel: {
            downloadTask?.cancel()
        }
    }

    /// Extracts a .tar.gz file to a destination directory.
    ///
    /// Uses `CheckedContinuation` with `terminationHandler` and concurrent
    /// pipe reading via `readabilityHandler` to avoid blocking the actor
    /// thread and to prevent pipe deadlocks when tar produces large stderr
    /// output.
    private func extractTarball(_ tarball: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            // Kraken2 databases from genome-idx.s3.amazonaws.com have files at the
            // top level (hash.k2d, opts.k2d, taxo.k2d), NOT inside a subdirectory.
            // Do NOT use --strip-components=1 as it would strip the filenames.
            process.arguments = ["xzf", tarball.path, "-C", destination.path]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            nonisolated(unsafe) let stderrBuffer = NSMutableData()
            nonisolated(unsafe) var continuationResumed = false

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stderrBuffer.append(data)
                }
            }

            process.terminationHandler = { terminatedProcess in
                // Small delay to let any remaining readabilityHandler
                // callbacks drain before we read the final buffer contents.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    guard !continuationResumed else { return }
                    continuationResumed = true

                    if terminatedProcess.terminationStatus != 0 {
                        let errorString = String(data: stderrBuffer as Data, encoding: .utf8)
                            ?? "Unknown error"
                        continuation.resume(
                            throwing: MetagenomicsDatabaseRegistryError.downloadFailed(
                                name: tarball.lastPathComponent,
                                reason: "tar extraction failed: \(errorString)"
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            }

            do {
                try process.run()
            } catch {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard !continuationResumed else { return }
                continuationResumed = true
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - DatabaseManifest

/// Top-level JSON structure for the manifest file.
///
/// The `version` field allows future schema migrations.
struct DatabaseManifest: Codable, Sendable {
    /// Manifest schema version.
    let version: Int

    /// All registered databases.
    let databases: [MetagenomicsDatabaseInfo]
}

// MARK: - DownloadProgressDelegate

/// URLSession delegate that reports byte-level download progress via a callback.
///
/// Uses the traditional delegate-based API instead of `session.download(for:)`
/// because the async API does not reliably call `didWriteData`.
///
/// The `hasFired` guard prevents double-resuming the continuation, which can
/// happen when `didFinishDownloadingTo` fires successfully but
/// `didCompleteWithError` is also called with a non-nil error (e.g., due to
/// session invalidation). Without this guard, the second resume crashes.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressCallback: @Sendable (Double, Int64, Int64) -> Void
    private let completionCallback: @Sendable (Result<URL, Error>) -> Void

    /// Guards against double-firing the completion callback. Accessed from
    /// the URLSession delegate queue which is serial, so no additional
    /// synchronization is needed beyond the atomic flag pattern.
    private let hasFired = LockedFlag()

    init(
        progress: @Sendable @escaping (Double, Int64, Int64) -> Void,
        completion: @Sendable @escaping (Result<URL, Error>) -> Void
    ) {
        self.progressCallback = progress
        self.completionCallback = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : totalBytesWritten
        let fraction = Double(totalBytesWritten) / Double(total)
        progressCallback(min(fraction, 1.0), totalBytesWritten, total)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard hasFired.testAndSet() else { return }

        // URLSession deletes the temp file after this callback returns,
        // so copy it to a stable location.
        let tempDir = FileManager.default.temporaryDirectory
        let stableURL = tempDir.appendingPathComponent(UUID().uuidString + ".tar.gz")
        do {
            try FileManager.default.copyItem(at: location, to: stableURL)
            completionCallback(.success(stableURL))
        } catch {
            completionCallback(.failure(error))
        }
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            guard hasFired.testAndSet() else { return }
            completionCallback(.failure(error))
            session.invalidateAndCancel()
        }
    }
}

// MARK: - LockedFlag

/// A thread-safe boolean flag that can be atomically tested and set.
///
/// Used to prevent double-firing of completion handlers in delegate callbacks.
private final class LockedFlag: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    /// Atomically tests the flag and sets it to `true`.
    ///
    /// - Returns: `true` if the flag was previously `false` (i.e., this is
    ///   the first caller to set it). `false` if it was already set.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _value { return false }
        _value = true
        return true
    }
}
