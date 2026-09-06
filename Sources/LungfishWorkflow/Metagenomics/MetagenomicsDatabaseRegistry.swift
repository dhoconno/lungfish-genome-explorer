// MetagenomicsDatabaseRegistry.swift - Metagenomics database installation manager
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import CryptoKit
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

    /// The staged update payload did not match the checksum pinned in the dependency manifest.
    case checksumMismatch(name: String, expected: String, actual: String)

    /// This database cannot be updated in place through the staged update flow.
    case updateNotSupported(name: String, reason: String)

    /// The staged update payload was not a usable database.
    case invalidStagedPayload(name: String, missingFiles: [String])

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
        case .checksumMismatch(let name, let expected, let actual):
            return "Checksum mismatch for '\(name)': expected \(expected), got \(actual). The previously installed copy was kept."
        case .updateNotSupported(let name, let reason):
            return "'\(name)' cannot be updated automatically: \(reason)"
        case .invalidStagedPayload(let name, let missing):
            return "Staged update for '\(name)' is incomplete: missing \(missing.joined(separator: ", "))"
        }
    }
}

// MARK: - Checksum

/// A checksum algorithm the dependency manifest can pin for a database payload.
public enum MetagenomicsDatabaseChecksumAlgorithm: String, Sendable, Equatable {
    case md5
    case sha256
}

/// An expected payload checksum, as pinned in the dependency manifest.
public struct MetagenomicsDatabaseChecksum: Sendable, Equatable {
    public let algorithm: MetagenomicsDatabaseChecksumAlgorithm
    public let hex: String

    public init(algorithm: MetagenomicsDatabaseChecksumAlgorithm, hex: String) {
        self.algorithm = algorithm
        self.hex = hex
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
/// The storage location follows the shared managed storage root. Call
/// ``setStorageLocation(_:migrateExisting:)`` to change it at runtime.
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

    struct BookmarkResolution: Sendable {
        let url: URL
        let isStale: Bool

        init(url: URL, isStale: Bool) {
            self.url = url
            self.isStale = isStale
        }
    }

    /// Shared singleton instance.
    ///
    /// Uses the current shared managed storage root for each access.
    public static let shared = MetagenomicsDatabaseRegistry()

    // MARK: - Storage

    /// Path to the JSON manifest file.
    private(set) var manifestURL: URL

    /// Base directory for downloaded databases.
    private(set) var databasesBaseURL: URL

    /// Storage configuration source for shared managed storage resolution.
    private let storageConfigStore: ManagedStorageConfigStore?

    /// In-memory database entries, keyed by name.
    private var databases: [String: MetagenomicsDatabaseInfo] = [:]

    /// Catalog entries supplied by this build. Persisted rows may retain a
    /// historical recipe, so installation must resolve against this catalog.
    private let catalog: [MetagenomicsDatabaseInfo]

    private let externalVolumeDetector: @Sendable (URL) -> Bool
    private let bookmarkCreator: @Sendable (URL) throws -> Data
    private let bookmarkResolver: @Sendable (Data) throws -> BookmarkResolution
    private let securityScopedAccessStarter: @Sendable (URL) -> Bool
    private let securityScopedAccessStopper: @Sendable (URL) -> Void
    private let databaseInstaller: any MetagenomicsDatabaseInstalling
    private let manifestWriter: @Sendable (Data, URL) throws -> Void
    private var activeSecurityScopedURLs: [String: URL] = [:]

    // MARK: - Update Seams

    /// Downloads and unpacks an archive recipe into `destination`, returning the
    /// downloaded archive file when one exists so its checksum can be verified.
    ///
    /// Test seam: the live default downloads and extracts through the same archive
    /// transfer the installer uses. Doubles return `nil` when they synthesize a
    /// payload without a real archive.
    typealias ArchiveInstalling = @Sendable (
        _ source: URL,
        _ destination: URL,
        _ progress: @Sendable @escaping (Double, String) -> Void
    ) async throws -> URL?

    /// Resolves the checksum the manifest pins for a database, if any.
    ///
    /// Test seam. The live default reads `sha256` (preferred) then `md5` from the
    /// manifest spec, so it returns `nil` for the entries that pin neither today,
    /// making verification a no-op rather than a hard failure.
    typealias ExpectedChecksumResolving = @Sendable (DatabaseSpec) -> MetagenomicsDatabaseChecksum?

    /// Computes a checksum over a downloaded archive.
    ///
    /// Test seam. The live default streams the file through CryptoKit.
    typealias ChecksumComputing = @Sendable (URL, MetagenomicsDatabaseChecksumAlgorithm) throws -> String

    private var archiveInstaller: ArchiveInstalling
    private var expectedChecksum: ExpectedChecksumResolving
    private var computeChecksum: ChecksumComputing

    /// Writes the canonical receipt for a promoted update.
    private let provenanceWriter: CanonicalMetagenomicsDatabaseInstallProvenanceWriter

    /// Files required for a valid Kraken2 database directory.
    static let requiredKraken2Files = ["hash.k2d", "opts.k2d", "taxo.k2d"]

    // MARK: - Initialization

    /// Creates a registry backed by the current shared managed storage root.
    public init() {
        let storageConfigStore = ManagedStorageConfigStore()
        let base = storageConfigStore.currentLocation().databaseRootURL
        self.storageConfigStore = storageConfigStore
        self.databasesBaseURL = base
        self.manifestURL = base.appendingPathComponent("metagenomics-db-registry.json")
        self.catalog = MetagenomicsDatabaseInfo.builtInCatalog
        self.externalVolumeDetector = Self.isExternalVolume
        self.bookmarkCreator = Self.defaultBookmarkData
        self.bookmarkResolver = Self.defaultBookmarkResolution
        self.securityScopedAccessStarter = { $0.startAccessingSecurityScopedResource() }
        self.securityScopedAccessStopper = { $0.stopAccessingSecurityScopedResource() }
        self.databaseInstaller = Self.productionDatabaseInstaller()
        self.manifestWriter = Self.defaultManifestWriter
        self.archiveInstaller = Self.liveArchiveInstaller
        self.expectedChecksum = Self.manifestChecksum
        self.computeChecksum = Self.fileChecksum
        self.provenanceWriter = CanonicalMetagenomicsDatabaseInstallProvenanceWriter()
    }

    init(storageConfigStore: ManagedStorageConfigStore) {
        let base = storageConfigStore.currentLocation().databaseRootURL
        self.storageConfigStore = storageConfigStore
        self.databasesBaseURL = base
        self.manifestURL = base.appendingPathComponent("metagenomics-db-registry.json")
        self.catalog = MetagenomicsDatabaseInfo.builtInCatalog
        self.externalVolumeDetector = Self.isExternalVolume
        self.bookmarkCreator = Self.defaultBookmarkData
        self.bookmarkResolver = Self.defaultBookmarkResolution
        self.securityScopedAccessStarter = { $0.startAccessingSecurityScopedResource() }
        self.securityScopedAccessStopper = { $0.stopAccessingSecurityScopedResource() }
        self.databaseInstaller = Self.productionDatabaseInstaller()
        self.manifestWriter = Self.defaultManifestWriter
        self.archiveInstaller = Self.liveArchiveInstaller
        self.expectedChecksum = Self.manifestChecksum
        self.computeChecksum = Self.fileChecksum
        self.provenanceWriter = CanonicalMetagenomicsDatabaseInstallProvenanceWriter()
    }

    /// Creates a registry backed by a custom directory.
    ///
    /// Primarily for testing -- allows each test to use an isolated temp directory.
    ///
    /// - Parameter baseDirectory: Root directory for the manifest and database storage.
    public init(baseDirectory: URL) {
        self.storageConfigStore = nil
        self.databasesBaseURL = baseDirectory
        self.manifestURL = baseDirectory.appendingPathComponent("metagenomics-db-registry.json")
        self.catalog = MetagenomicsDatabaseInfo.builtInCatalog
        self.externalVolumeDetector = Self.isExternalVolume
        self.bookmarkCreator = Self.defaultBookmarkData
        self.bookmarkResolver = Self.defaultBookmarkResolution
        self.securityScopedAccessStarter = { $0.startAccessingSecurityScopedResource() }
        self.securityScopedAccessStopper = { $0.stopAccessingSecurityScopedResource() }
        self.databaseInstaller = Self.productionDatabaseInstaller()
        self.manifestWriter = Self.defaultManifestWriter
        self.archiveInstaller = Self.liveArchiveInstaller
        self.expectedChecksum = Self.manifestChecksum
        self.computeChecksum = Self.fileChecksum
        self.provenanceWriter = CanonicalMetagenomicsDatabaseInstallProvenanceWriter()
    }

    init(
        baseDirectory: URL,
        catalog: [MetagenomicsDatabaseInfo] = MetagenomicsDatabaseInfo.builtInCatalog,
        externalVolumeDetector: @escaping @Sendable (URL) -> Bool = MetagenomicsDatabaseRegistry.isExternalVolume,
        bookmarkCreator: @escaping @Sendable (URL) throws -> Data = MetagenomicsDatabaseRegistry.defaultBookmarkData,
        bookmarkResolver: @escaping @Sendable (Data) throws -> BookmarkResolution = MetagenomicsDatabaseRegistry.defaultBookmarkResolution,
        securityScopedAccessStarter: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        securityScopedAccessStopper: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        databaseInstaller: (any MetagenomicsDatabaseInstalling)? = nil,
        manifestWriter: @escaping @Sendable (Data, URL) throws -> Void = MetagenomicsDatabaseRegistry.defaultManifestWriter
    ) {
        self.storageConfigStore = nil
        self.databasesBaseURL = baseDirectory
        self.manifestURL = baseDirectory.appendingPathComponent("metagenomics-db-registry.json")
        self.catalog = catalog
        self.externalVolumeDetector = externalVolumeDetector
        self.bookmarkCreator = bookmarkCreator
        self.bookmarkResolver = bookmarkResolver
        self.securityScopedAccessStarter = securityScopedAccessStarter
        self.securityScopedAccessStopper = securityScopedAccessStopper
        self.databaseInstaller = databaseInstaller ?? Self.productionDatabaseInstaller()
        self.manifestWriter = manifestWriter
        self.archiveInstaller = Self.liveArchiveInstaller
        self.expectedChecksum = Self.manifestChecksum
        self.computeChecksum = Self.fileChecksum
        self.provenanceWriter = CanonicalMetagenomicsDatabaseInstallProvenanceWriter()
    }

    deinit {
        for url in activeSecurityScopedURLs.values {
            securityScopedAccessStopper(url)
        }
    }

    // MARK: - Storage Location Management

    /// Changes the base storage directory at runtime.
    ///
    /// Optionally moves existing database files from the old location to the
    /// new one. The manifest is always regenerated at the new location.
    ///
    /// - Parameters:
    ///   - url: The new shared storage root, or its `databases/` subdirectory.
    ///   - migrateExisting: If `true`, moves existing database files to the new location.
    ///     Defaults to `false`.
    public func setStorageLocation(_ url: URL, migrateExisting: Bool = false) throws {
        refreshStorageLocationFromConfigIfNeeded(resetLoadedState: false)

        let oldBase = databasesBaseURL
        let normalized = Self.normalizeStorageLocation(url)
        let newBase = normalized.databaseBaseURL

        let fm = FileManager.default

        if let storageConfigStore {
            try storageConfigStore.setActiveRoot(normalized.sharedRootURL)
            LungfishAppIdentity.current.preferences.removeObject(forKey: "DatabaseStorageLocation")
        }

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

        // Save the manifest at the new location.
        if !databases.isEmpty {
            try saveManifest()
        }

        logger.info("Database storage location changed to \(newBase.path, privacy: .public)")
    }

    /// Returns the current base directory path for display purposes.
    public var storagePath: String {
        refreshStorageLocationFromConfigIfNeeded()
        return databasesBaseURL.path
    }

    /// Loads the manifest from disk, or initializes from the built-in catalog
    /// if no manifest exists yet.
    ///
    /// This method is idempotent -- calling it multiple times has no effect
    /// after the first successful load.
    public func loadIfNeeded() throws {
        refreshStorageLocationFromConfigIfNeeded()
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
            var didMigrateVersion = false
            do {
                let data = try Data(contentsOf: manifestURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let manifest = try decoder.decode(DatabaseManifest.self, from: data)
                for var db in manifest.databases {
                    if db.path != nil, db.installedAt == nil {
                        db.installedAt = db.lastUpdated
                    }
                    if let catalogVersion = currentCatalogVersionProvenByReceipt(for: db),
                       db.version != catalogVersion {
                        db.version = catalogVersion
                        didMigrateVersion = true
                    }
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
            for entry in catalog {
                let alreadyPresent = databases.values.contains { persisted in
                    Self.matchesCatalogEntry(persisted, catalog: entry)
                }
                if !alreadyPresent {
                    databases[entry.name] = entry
                    addedCount += 1
                }
            }
            let recoveredCount = recoverInterruptedUpdates()
            let correctedCount = reconcileCatalogURLs()
            if addedCount > 0 || correctedCount > 0 || recoveredCount > 0 || didMigrateVersion {
                try saveManifest()
                logger.info(
                    "Merged \(addedCount, privacy: .public) new catalog entries, corrected \(correctedCount, privacy: .public) stale download URLs, recovered \(recoveredCount, privacy: .public) interrupted updates, migrated special versions: \(didMigrateVersion, privacy: .public)"
                )
            }
        } else {
            // First launch: populate from built-in catalog.
            for entry in catalog {
                databases[entry.name] = entry
            }
            try saveManifest()
            logger.info("Initialized manifest with \(self.databases.count, privacy: .public) catalog entries")
        }
    }

    // MARK: - CRUD

    /// Reads recorded installations for dependency planning without initializing
    /// storage, saving catalog changes, or recovering interrupted transactions.
    public func installedDatabaseSnapshot() throws -> [MetagenomicsDatabaseInfo] {
        let base = storageConfigStore?.currentLocation().databaseRootURL ?? databasesBaseURL
        let snapshotURL = base.appendingPathComponent("metagenomics-db-registry.json")
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DatabaseManifest.self, from: Data(contentsOf: snapshotURL))
        return manifest.databases.filter { $0.status == .ready }.map { recorded in
            var database = recorded
            // Apply the same receipt-backed version interpretation as the GUI
            // loader, but leave the persisted registry and payload untouched.
            if let version = currentCatalogVersionProvenByReceipt(for: database) {
                database.version = version
            }
            return database
        }.sorted { $0.name < $1.name }
    }

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
        let isExternal = externalVolumeDetector(url)
        let bookmarkData: Data?
        if isExternal {
            do {
                bookmarkData = try createBookmark(for: url)
            } catch {
                bookmarkData = nil
                logger.warning(
                    "Failed to create bookmark for imported database '\(dbName, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
        } else {
            bookmarkData = nil
        }

        // Determine if this matches a catalog entry.
        let matchingCollection = DatabaseCollection.allCases.first { collection in
            url.lastPathComponent.lowercased().contains(collection.rawValue.replacingOccurrences(of: "-", with: ""))
                || dbName == collection.displayName
        }

        var info: MetagenomicsDatabaseInfo
        let now = Date()
        if let existing = databases[dbName] {
            // Update the existing catalog entry with the path.
            info = existing
            info.path = url
            info.status = .ready
            info.installedAt = info.installedAt ?? now
            info.lastUpdated = now
            info.isExternal = isExternal
            info.bookmarkData = bookmarkData
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
                isExternal: isExternal,
                bookmarkData: bookmarkData,
                installedAt: now,
                lastUpdated: now,
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

        guard let existing = databases[name] else {
            throw MetagenomicsDatabaseRegistryError.databaseNotFound(name: name)
        }

        // If this is a catalog entry, reset to undownloaded state rather than deleting.
        let catalogEntry = catalogEntry(matching: existing)
        if let catalogEntry {
            endSecurityScopedAccess(for: name)
            databases[name] = catalogEntry
            try saveManifest()
            logger.info("Reset catalog database '\(name, privacy: .public)' to undownloaded state")
            return
        }

        endSecurityScopedAccess(for: name)
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
        let managedPayloadIsValid = db.payloadDigest.map {
            Self.validateManagedPayload(database: db, at: path, expectedDigest: $0)
        } ?? true
        if missing.isEmpty && managedPayloadIsValid {
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

        let prior = db
        let source = db.path?.standardizedFileURL
        let final = destination.standardizedFileURL
        let startedAt = Date()
        let boundIdentity = db.canonicalReceiptSHA256 != nil && db.payloadDigest != nil
        if boundIdentity {
            _ = try MetagenomicsDatabaseConformanceIdentity.verify(db, readingPayloadAt: final)
        }
        let restoreMovedPayload = boundIdentity && source != final
            && source.map { !FileManager.default.fileExists(atPath: $0.path) } == true
        var publication: ScientificFilePublicationTransaction?
        var receiptStage: URL?
        defer { if let receiptStage { try? FileManager.default.removeItem(at: receiptStage) } }
        do {
            if boundIdentity, let source {
                let sidecar = final.appendingPathComponent(ProvenanceWriter.provenanceFilename)
                let receiptBytes = try Data(contentsOf: sidecar)
                let receiptSHA = SHA256.hash(data: receiptBytes).map { String(format: "%02x", $0) }.joined()
                let receipt = try ProvenanceEnvelopeReader.decodeCanonical(receiptBytes)
                let previousReceipt = ProvenanceFileDescriptor(path: sidecar.path, checksumSHA256: receiptSHA,
                    fileSize: UInt64(receiptBytes.count), role: .input)
                guard receiptSHA == prior.canonicalReceiptSHA256 else {
                    throw MetagenomicsDatabaseIdentityError.changed(name)
                }
                publication = try ScientificFilePublicationTransaction(protectedURLs: [sidecar], fileDestinations: [sidecar])
                let stage = FileManager.default.temporaryDirectory.appendingPathComponent("database-relocation-\(UUID().uuidString)")
                receiptStage = stage
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                var pathMap = [source.path: final.path]
                for output in receipt.outputs {
                    let relative = String(output.path.dropFirst(source.path.count + 1))
                    pathMap[output.path] = final.appendingPathComponent(relative).path
                }
                let relocated = try ProvenanceRehydrator.rehydrate(sourceDirectory: final, finalDirectory: stage, pathMap: pathMap)
                let withRelocation = CanonicalMetagenomicsDatabaseInstallProvenanceWriter.appendingRelocation(
                    to: relocated, databaseName: name, from: source, to: final,
                    previousReceipt: previousReceipt, startedAt: startedAt)
                try ProvenanceWriter(signingProvider: nil).write(withRelocation, to: stage)
                try publication?.publish(stagedURL: stage.appendingPathComponent(ProvenanceWriter.provenanceFilename), to: sidecar)
                db.canonicalReceiptSHA256 = try ProvenanceFileHasher.sha256(of: sidecar)
            }
            db.path = destination
            db.isExternal = externalVolumeDetector(destination)
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
                endSecurityScopedAccess(for: name)
            }

            if boundIdentity {
                _ = try MetagenomicsDatabaseConformanceIdentity.verify(db, readingPayloadAt: nil, publication: publication)
            }
            databases[name] = db
            try saveManifest()
            publication?.commit()
        } catch let originalError {
            databases[name] = prior
            if let publication {
                do { try publication.rollback(after: originalError) }
                catch let recovery as ScientificPublicationRecoveryRequired { throw recovery }
                catch { /* Receipt restored; restore a verified caller move below. */ }
            }
            if restoreMovedPayload, let source {
                do {
                    _ = try MetagenomicsDatabaseConformanceIdentity.verify(prior, readingPayloadAt: final)
                    try FileManager.default.moveItem(at: final, to: source)
                } catch {
                    throw ScientificPublicationRecoveryRequired(originalError: originalError, restorationError: error,
                        recoveryURLs: [final, source])
                }
            }
            throw originalError
        }
        logger.info("Relocated database '\(name, privacy: .public)' to \(destination.path, privacy: .public)")
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
        guard let bookmarkData = db.bookmarkData else {
            if db.isExternal, let path = db.path {
                beginSecurityScopedAccess(for: db.name, url: path)
            }
            return db.path
        }

        do {
            let resolution = try bookmarkResolver(bookmarkData)
            let url = resolution.url
            beginSecurityScopedAccess(for: db.name, url: url)

            if resolution.isStale {
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
            endSecurityScopedAccess(for: db.name)
            return nil
        }
    }

    /// Creates a security-scoped bookmark for a URL.
    ///
    /// - Parameter url: The URL to bookmark.
    /// - Returns: Bookmark data that can be stored and later resolved.
    public func createBookmark(for url: URL) throws -> Data {
        try bookmarkCreator(url)
    }

    static func defaultBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func defaultBookmarkResolution(for data: Data) throws -> BookmarkResolution {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return BookmarkResolution(url: url, isStale: isStale)
    }

    @discardableResult
    private func beginSecurityScopedAccess(for name: String, url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        if activeSecurityScopedURLs[name]?.standardizedFileURL == standardizedURL {
            return true
        }
        endSecurityScopedAccess(for: name)
        guard securityScopedAccessStarter(standardizedURL) else {
            logger.warning(
                "Security-scoped access failed for external database '\(name, privacy: .public)' at \(standardizedURL.path, privacy: .public)"
            )
            return false
        }
        activeSecurityScopedURLs[name] = standardizedURL
        return true
    }

    private func endSecurityScopedAccess(for name: String) {
        guard let url = activeSecurityScopedURLs.removeValue(forKey: name) else {
            return
        }
        securityScopedAccessStopper(url)
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
    /// The recommendation logic prefers the largest general-purpose collection
    /// that fits within 60% of physical memory. If none meet that headroom
    /// threshold, it falls back to the smallest general-purpose collection that
    /// fits physical memory. Systems below the smallest supported collection's
    /// RAM requirement receive no recommendation instead of highlighting an
    /// oversized database.
    ///
    /// - Parameter ramBytes: Override for system RAM (defaults to
    ///   `ProcessInfo.processInfo.physicalMemory`). Pass explicitly for testing.
    /// - Returns: The recommended database info.
    public func recommendedDatabase(ramBytes: UInt64? = nil) throws -> MetagenomicsDatabaseInfo? {
        try loadIfNeeded()

        let ram = ramBytes ?? UInt64(ProcessInfo.processInfo.physicalMemory)
        guard let collection = Self.recommendedCollection(forRAMBytes: ram) else {
            return nil
        }
        let recommendationLimit = Self.recommendationLimit(forRAMBytes: ram)

        guard let catalogEntry = MetagenomicsDatabaseInfo.catalogEntry(for: collection),
              Self.databaseFitsRecommendationLimit(catalogEntry, limitBytes: recommendationLimit) else {
            return nil
        }

        // Prefer the persisted row when it still fits the current recommendation
        // policy; otherwise use the fresh catalog metadata for the selected collection.
        if let db = databases[collection.displayName],
           Self.databaseFitsRecommendationLimit(db, limitBytes: recommendationLimit) {
            return db
        }

        return catalogEntry
    }

    /// Returns the recommended collection for a given RAM amount.
    ///
    /// - Parameter ramBytes: Available physical memory in bytes.
    /// - Returns: The recommended database collection.
    public static func recommendedCollection(forRAMBytes ramBytes: UInt64) -> DatabaseCollection? {
        let candidates = recommendedCollections
        let headroomLimit = UInt64(Double(ramBytes) * recommendationHeadroomFraction)

        if let headroomFit = candidates
            .filter({ ramRequirementBytes(for: $0) <= headroomLimit })
            .max(by: recommendationAscending) {
            return headroomFit
        }

        if let viableFit = candidates
            .filter({ ramRequirementBytes(for: $0) <= ramBytes })
            .min(by: smallestRecommendationAscending) {
            return viableFit
        }

        return nil
    }

    private static let recommendationHeadroomFraction = 0.6

    /// General-purpose Kraken2 collections eligible for system recommendations.
    /// Specialist catalogs such as Viral, MinusB, and EuPathDB remain visible
    /// but are not used as whole-system defaults.
    private static let recommendedCollections: [DatabaseCollection] = [
        .plusPF,
        .standard,
        .plusPF16,
        .standard16,
        .plusPF8,
        .standard8,
    ]

    private static func recommendationAscending(
        lhs: DatabaseCollection,
        rhs: DatabaseCollection
    ) -> Bool {
        let lhsRAM = ramRequirementBytes(for: lhs)
        let rhsRAM = ramRequirementBytes(for: rhs)
        if lhsRAM != rhsRAM {
            return lhsRAM < rhsRAM
        }
        return recommendationRank(for: lhs) < recommendationRank(for: rhs)
    }

    private static func smallestRecommendationAscending(
        lhs: DatabaseCollection,
        rhs: DatabaseCollection
    ) -> Bool {
        let lhsRAM = ramRequirementBytes(for: lhs)
        let rhsRAM = ramRequirementBytes(for: rhs)
        if lhsRAM != rhsRAM {
            return lhsRAM < rhsRAM
        }
        return recommendationRank(for: lhs) > recommendationRank(for: rhs)
    }

    private static func recommendationRank(for collection: DatabaseCollection) -> Int {
        switch collection {
        case .standard8:   return 0
        case .plusPF8:     return 1
        case .minusB:      return 2
        case .standard16:  return 3
        case .plusPF16:    return 4
        case .standard:    return 5
        case .plusPF:      return 6
        case .viral:       return -2
        case .euPathDB46:  return -1
        }
    }

    private static func ramRequirementBytes(for collection: DatabaseCollection) -> UInt64 {
        UInt64(max(collection.approximateRAMBytes, 0))
    }

    private static func recommendationLimit(forRAMBytes ramBytes: UInt64) -> UInt64 {
        let headroomLimit = UInt64(Double(ramBytes) * recommendationHeadroomFraction)
        let hasHeadroomFit = recommendedCollections.contains {
            ramRequirementBytes(for: $0) <= headroomLimit
        }
        return hasHeadroomFit ? headroomLimit : ramBytes
    }

    private static func databaseFitsRecommendationLimit(
        _ database: MetagenomicsDatabaseInfo,
        limitBytes: UInt64
    ) -> Bool {
        UInt64(max(database.recommendedRAM, 0)) <= limitBytes
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

        guard let prior = databases[name] else {
            throw MetagenomicsDatabaseRegistryError.databaseNotFound(name: name)
        }
        guard prior.installationRecipe != nil else {
            throw MetagenomicsDatabaseRegistryError.downloadFailed(
                name: name, reason: "No installation recipe available"
            )
        }

        // Persisted catalog rows can contain an older recipe. Resolve through
        // the stable catalog identity before preparation so the actual build,
        // canonical receipt, and stored version all describe the current recipe.
        let preparationDatabase = catalogEntry(matching: prior) ?? prior

        var db = prior
        db.status = .downloading
        databases[name] = db
        do {
            try saveManifest()
        } catch {
            databases[name] = prior
            throw error
        }

        let prepared: PreparedMetagenomicsDatabaseInstallation
        do {
            prepared = try await databaseInstaller.prepareInstallation(
                database: preparationDatabase,
                databasesBaseURL: databasesBaseURL,
                threads: 4,
                progress: progress
            )
        } catch {
            databases[name] = prior
            try? saveManifest()
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                throw MetagenomicsDatabaseRegistryError.downloadCancelled(name: name)
            }
            throw MetagenomicsDatabaseRegistryError.downloadFailed(
                name: name, reason: error.localizedDescription
            )
        }

        let installedAt = prior.installedAt ?? Date()
        db.path = prepared.result.finalURL
        if case .kraken2Special? = preparationDatabase.installationRecipe {
            db.version = preparationDatabase.version
                ?? prepared.result.version
        } else {
            db.version = prepared.result.version
        }
        db.payloadDigest = prepared.result.payloadDigest
        db.sizeOnDisk = prepared.result.sizeOnDisk
        db.installedAt = installedAt
        db.lastUpdated = Date()
        db.status = .ready
        db.isExternal = false
        db.bookmarkData = nil
        databases[name] = db

        do {
            db.canonicalReceiptSHA256 = try ProvenanceFileHasher.sha256(of:
                prepared.result.finalURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
            databases[name] = db
            try saveManifest()
        } catch let persistenceError {
            let rollbackError: Error?
            do {
                try databaseInstaller.rollback(prepared)
                rollbackError = nil
            } catch {
                rollbackError = error
            }
            databases[name] = prior
            do {
                try saveManifest()
            } catch {
                throw MetagenomicsDatabaseRegistryError.manifestIOError(
                    operation: "restore after failed installation publication",
                    underlying: error
                )
            }
            if let rollbackError {
                throw MetagenomicsDatabaseRegistryError.downloadFailed(
                    name: name,
                    reason: "Manifest persistence failed and rollback also failed: \(rollbackError.localizedDescription)"
                )
            }
            throw persistenceError
        }

        // Cleanup occurs after the durable ready row. A cleanup diagnostic must
        // not roll back scientifically valid, already-published data.
        try databaseInstaller.finalize(prepared)
        logger.info("Installed database '\(name, privacy: .public)' at \(prepared.result.finalURL.path, privacy: .public)")

        return prepared.result.finalURL
    }

    // MARK: - Update Support

    /// Replaces an installed catalog database with the version pinned in the
    /// dependency manifest, without ever leaving the user without a usable copy.
    ///
    /// The new payload is downloaded into a staging directory that is a sibling of
    /// the installed directory (so promotion is a rename on the same volume), verified
    /// against the manifest checksum when one is pinned, and only then swapped in. The
    /// superseded copy is removed after the swap succeeds. Any failure before the swap
    /// leaves the installed database untouched; a failure during the swap restores it.
    ///
    /// - Parameters:
    ///   - catalogID: Stable catalog identity of the database to update (e.g. `kraken2-viral`),
    ///     or the display name of an installed row (e.g. `Viral`).
    ///   - progress: Receives fraction complete and a status message.
    public func updateDatabase(
        catalogID: String,
        progress: @Sendable @escaping (Double, String) -> Void
    ) async throws {
        try loadIfNeeded()

        guard let (name, installed, catalogEntry) = resolveUpdateTarget(identifier: catalogID) else {
            throw MetagenomicsDatabaseRegistryError.databaseNotFound(name: catalogID)
        }
        guard let installedPath = installed.path,
              FileManager.default.fileExists(atPath: installedPath.path) else {
            throw MetagenomicsDatabaseRegistryError.databaseNotFound(name: name)
        }

        // Locally built databases are produced by kraken2-build/bracken-build through
        // the installer's own staged transaction, which owns its final path. Routing
        // that into this flow's staging directory would mean duplicating the
        // installer's promotion logic, so those rebuild through `downloadDatabase`.
        guard case .archive(let source)? = catalogEntry.installationRecipe else {
            throw MetagenomicsDatabaseRegistryError.updateNotSupported(
                name: name,
                reason: "locally built databases are rebuilt by reinstalling, not updated in place"
            )
        }

        // An external-volume database is reachable only inside a security scope, and
        // its bookmark encodes the directory identity that the swap replaces. Access
        // is held across the renames and the bookmark is re-created afterwards, the
        // same way `relocateDatabase` handles a moved external database.
        if installed.isExternal {
            guard beginSecurityScopedAccess(for: name, url: installedPath) else {
                throw MetagenomicsDatabaseRegistryError.updateNotSupported(
                    name: name,
                    reason: "its external volume is not currently accessible; reconnect the volume and try again"
                )
            }
        }

        // This is a requested catalog label (possibly "live"), not proof of bytes.
        // The receipt below binds the received archive and retained payload identity.
        guard let targetVersion = catalogEntry.version else {
            throw MetagenomicsDatabaseRegistryError.updateNotSupported(
                name: name,
                reason: "the catalog entry has no requested version label"
            )
        }

        let startedAt = Date()
        let parent = installedPath.deletingLastPathComponent()
        let staging = Self.stagingURL(for: installedPath, version: targetVersion)

        let fm = FileManager.default
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }

        // Declared outside the transaction block so the cleanup below covers every
        // exit path, including a checksum mismatch. A database tarball can be tens of
        // gigabytes, so it must never be left behind in the temp directory.
        var downloadedArchive: URL?
        let snapshot: MetagenomicsDatabasePayloadSnapshot
        let canonicalReceiptSHA256: String
        defer {
            if let downloadedArchive {
                try? fm.removeItem(at: downloadedArchive)
            }
        }

        do {
            progress(0, "Downloading \(name)…")
            let archiveURL = try await archiveInstaller(source, staging) { fraction, message in
                progress(min(fraction * 0.85, 0.85), message)
            }
            downloadedArchive = archiveURL

            try Task.checkCancellation()
            progress(0.88, "Verifying \(name)…")
            // Keyed on the resolved entry's identity rather than the caller's
            // argument: the caller may have named the row by display name, and a
            // lookup on that string would silently find no spec and skip verification.
            if let resolvedCatalogID = catalogEntry.catalogID,
               let spec = ManagedToolLock.bundled.database(id: resolvedCatalogID),
               let expected = expectedChecksum(spec) {
                guard let archiveURL else {
                    throw MetagenomicsDatabaseRegistryError.updateNotSupported(
                        name: name, reason: "expected archive checksum cannot be verified because the downloaded archive is unavailable"
                    )
                }
                let actual = try computeChecksum(archiveURL, expected.algorithm)
                guard actual.caseInsensitiveCompare(expected.hex) == .orderedSame else {
                    throw MetagenomicsDatabaseRegistryError.checksumMismatch(
                        name: name, expected: expected.hex, actual: actual
                    )
                }
            }

            // A staged payload that is not a usable database must never replace a
            // working one, checksum or no checksum.
            let missing = Self.missingRequiredFiles(in: staging, tool: installed.tool)
            guard missing.isEmpty else {
                throw MetagenomicsDatabaseRegistryError.invalidStagedPayload(
                    name: name, missingFiles: missing
                )
            }
            snapshot = try MetagenomicsDatabasePayloadDigester.snapshot(at: staging)
            try writeUpdateProvenance(
                database: installed, finalURL: installedPath, catalogEntry: catalogEntry,
                source: source, archiveURL: archiveURL, snapshot: snapshot, startedAt: startedAt
            )
            canonicalReceiptSHA256 = try ProvenanceFileHasher.sha256(of:
                staging.appendingPathComponent(ProvenanceWriter.provenanceFilename))
            try Task.checkCancellation()
        } catch {
            try? fm.removeItem(at: staging)
            logger.error(
                "Update of '\(name, privacy: .public)' failed before promotion; installed copy retained: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        progress(0.92, "Installing \(name)…")
        let retired = parent.appendingPathComponent(
            "\(Self.retiredPrefix(for: installedPath))\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.moveItem(at: installedPath, to: retired)
        do {
            try fm.moveItem(at: staging, to: installedPath)
        } catch {
            // Promotion failed: put the previous copy back before surfacing the error.
            try? fm.moveItem(at: retired, to: installedPath)
            try? fm.removeItem(at: staging)
            throw MetagenomicsDatabaseRegistryError.downloadFailed(
                name: name, reason: "Could not install the updated database: \(error.localizedDescription)"
            )
        }

        let previous = databases[name]
        var updated = installed
        updated.path = installedPath
        updated.version = catalogEntry.version
        // A row registered by `registerExisting` carries no catalog identity, so it was
        // resolved here by display name and tool. Stamping the identity it just proved
        // it has means the next update, the reconciler, and the plan all address it by
        // its stable id rather than re-deriving the match from a display name the user
        // is free to change.
        updated.catalogID = installed.catalogID ?? catalogEntry.catalogID
        updated.downloadURL = catalogEntry.downloadURL
        updated.installationRecipe = catalogEntry.installationRecipe
        updated.sizeOnDisk = Self.directorySize(at: installedPath)
        updated.payloadDigest = snapshot.aggregateSHA256
        updated.canonicalReceiptSHA256 = canonicalReceiptSHA256
        updated.installedAt = Date()
        updated.lastUpdated = Date()
        updated.status = .ready
        // The swap replaced the directory the old bookmark resolved to, so an external
        // database needs a bookmark for the new one. A stale bookmark would strand the
        // database on the next launch, but the payload itself is already correct, so a
        // refresh failure downgrades to path-only access rather than failing the update.
        if updated.isExternal {
            do {
                updated.bookmarkData = try createBookmark(for: installedPath)
                beginSecurityScopedAccess(for: name, url: installedPath)
            } catch {
                updated.bookmarkData = nil
                logger.warning(
                    "Updated '\(name, privacy: .public)' but could not refresh its external-volume bookmark: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        databases[name] = updated

        do {
            try saveManifest()
        } catch {
            databases[name] = previous
            // Keep the previous payload until both provenance and registry commit.
            try? fm.removeItem(at: installedPath)
            try? fm.moveItem(at: retired, to: installedPath)
            throw error
        }
        Self.removeTransactionSiblings(for: installedPath, name: name)

        progress(1, "Updated \(name)")
        logger.info(
            "Updated '\(name, privacy: .public)' to version \(catalogEntry.version ?? "unknown", privacy: .public)"
        )
    }

    /// Resolves the installed row an update should replace, and the catalog entry it
    /// should be replaced with.
    ///
    /// A row installed through the catalog carries its `catalogID`, but the rows real
    /// users actually have are usually registered by `registerExisting`, which records
    /// no catalog identity at all. Matching only on `catalogID` therefore reported
    /// every hand-registered database as "not found in registry" while `db list` and
    /// `db info` were happily advertising an update for it, because those read
    /// ``MetagenomicsDatabaseInfo/availableUpdateVersion``, which falls back to a
    /// name-and-tool match against the built-in catalog.
    ///
    /// This applies the same two-step match, in the same order, so the command that
    /// applies an update sees exactly the set of rows the commands that advertise one
    /// do. The identifier may be either a catalog id (`kraken2-viral`) or the display
    /// name of an installed row (`Viral`). ``MetagenomicsDatabaseInfo/resolvedCatalogEntry``
    /// is the shared expression of that match; this method adds only the reverse
    /// direction, resolving an identifier to a row rather than a row to an entry.
    ///
    /// Candidate rows are sorted by name so a manifest that somehow holds two rows for
    /// one catalog identity resolves the same way on every run.
    private func resolveUpdateTarget(
        identifier: String
    ) -> (name: String, installed: MetagenomicsDatabaseInfo, catalogEntry: MetagenomicsDatabaseInfo)? {
        let installedRows = databases
            .filter { $0.value.path != nil }
            .sorted { $0.key < $1.key }

        // 1. The row that records this catalog identity, which is the identity the
        //    catalog entry is then looked up by.
        if let match = installedRows.first(where: { $0.value.catalogID == identifier }),
           let entry = MetagenomicsDatabaseInfo.catalogEntry(catalogID: identifier) {
            return (match.key, match.value, entry)
        }

        // 2. Otherwise the identifier names a catalog entry, or the display name of a row,
        //    that resolves through the shared name+tool fallback. Each candidate row is
        //    resolved by ``MetagenomicsDatabaseInfo/resolvedCatalogEntry`` itself, so the
        //    survivor when a display name maps to two catalog entries is exactly the one
        //    the reconciler and `availableUpdateVersion` pick. Rows that already carry a
        //    different catalogID resolve to that entry (or to nil) and therefore never
        //    match by name collision.
        for (name, row) in installedRows where row.catalogID == nil {
            guard let entry = row.resolvedCatalogEntry else { continue }
            if entry.catalogID == identifier || entry.name == identifier || name == identifier {
                return (name, row, entry)
            }
        }

        return nil
    }

    /// Prepare the receipt alongside the staged payload. Receipt failure prevents
    /// publication; descriptor paths still name the final retained directory.
    private func writeUpdateProvenance(
        database: MetagenomicsDatabaseInfo,
        finalURL: URL,
        catalogEntry: MetagenomicsDatabaseInfo,
        source: URL,
        archiveURL: URL?,
        snapshot: MetagenomicsDatabasePayloadSnapshot,
        startedAt: Date
    ) throws {
        let resolved: [String: ParameterValue] = [
            "databaseRoot": .file(finalURL),
            "updatedFromVersion": .string(database.version ?? "unknown"),
            "updatedToVersion": .string(catalogEntry.version ?? "unknown"),
            "archiveInstaller": .string("Lungfish archive update workflow"),
            "invocationKind": .string("swift-api"),
        ]
        let inputs = try archiveURL.map { [try ProvenanceFileDescriptor.file(url: $0, role: .input)] } ?? []
        let completedAt = Date()
        // The transfer seam exposes no child-process result. Record the actual
        // workflow and its options, never invent an executed tar command/version.
        let step = MetagenomicsDatabaseInstallStepEvidence(
            toolName: "Lungfish database archive update", toolVersion: WorkflowRun.currentAppVersion,
            argv: ["MetagenomicsDatabaseRegistry.updateDatabase(catalogID:progress:)", catalogEntry.catalogID ?? database.name],
            durableReplayArgv: [], resolvedOptions: resolved,
            runtimeIdentity: ProvenanceRuntimeIdentity(), inputs: inputs, outputs: snapshot.files,
            exitStatus: 0, startedAt: startedAt, completedAt: completedAt, stderr: ""
        )
        let attempt = MetagenomicsDatabaseInstallAttempt(
            database: catalogEntry, finalURL: finalURL, recipeSource: source.absoluteString,
            explicitOptions: ["catalogID": .string(catalogEntry.catalogID ?? "unknown")],
            defaultOptions: [:], resolvedOptions: resolved, steps: [step],
            startedAt: startedAt, completedAt: completedAt
        )
        try provenanceWriter.writeSuccess(attempt, snapshot: snapshot, to: snapshot.rootURL)
    }

    /// Downloads and extracts an archive recipe into `destination`, returning the
    /// downloaded archive so its checksum can be verified.
    private static let liveArchiveInstaller: ArchiveInstalling = { source, destination, progress in
        let transfer = URLSessionTarDatabaseArchiveTransfer()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let archive = try await transfer.download(from: source) { fraction in
            progress(fraction, "Downloading…")
        }
        progress(0.9, "Extracting…")
        let extraction = try await transfer.extract(archive: archive, destination: destination)
        guard extraction.exitStatus == 0 else {
            throw MetagenomicsDatabaseInstallerError.toolFailed(
                tool: "tar", exitStatus: extraction.exitStatus, stderr: String(extraction.stderr.prefix(16_384))
            )
        }
        return archive
    }

    /// Reads the checksum the manifest pins for a database spec, preferring sha256.
    private static let manifestChecksum: ExpectedChecksumResolving = { spec in
        if let sha256 = spec.sha256, !sha256.isEmpty {
            return MetagenomicsDatabaseChecksum(algorithm: .sha256, hex: sha256)
        }
        if let md5 = spec.md5, !md5.isEmpty {
            return MetagenomicsDatabaseChecksum(algorithm: .md5, hex: md5)
        }
        return nil
    }

    /// Streams a file through the requested digest.
    static let fileChecksum: ChecksumComputing = { url, algorithm in
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        var sha256 = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            switch algorithm {
            case .md5: md5.update(data: chunk)
            case .sha256: sha256.update(data: chunk)
            }
        }
        switch algorithm {
        case .md5: return md5.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha256: return sha256.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Replaces characters that are awkward in a path component.
    private static func safeSuffix(_ version: String) -> String {
        String(version.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" })
    }

    // MARK: - Update Transaction Naming
    //
    // Transaction directories are dot-prefixed siblings of the installed directory,
    // matching the installer's `.install-<uuid>` / `.backup-<uuid>` convention. The
    // dot keeps them out of `skipsHiddenFiles` enumerations, so payload digesting and
    // directory sizing never see a half-written or superseded copy.

    /// `.<name>.staging-<version>`, a sibling of the installed directory.
    static func stagingURL(for installedPath: URL, version: String) -> URL {
        installedPath.deletingLastPathComponent().appendingPathComponent(
            ".\(installedPath.lastPathComponent).staging-\(safeSuffix(version))",
            isDirectory: true
        )
    }

    /// Prefix shared by every retired copy of a database: `.<name>.old-`.
    static func retiredPrefix(for installedPath: URL) -> String {
        ".\(installedPath.lastPathComponent).old-"
    }

    /// Prefix shared by every staging directory of a database: `.<name>.staging-`.
    static func stagingPrefix(for installedPath: URL) -> String {
        ".\(installedPath.lastPathComponent).staging-"
    }

    /// Sibling transaction directories (`.old-*` / `.staging-*`) belonging to a database.
    private static func transactionSiblings(for installedPath: URL) -> [URL] {
        let parent = installedPath.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return [] }
        let retired = retiredPrefix(for: installedPath)
        let staging = stagingPrefix(for: installedPath)
        return contents.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(retired) || name.hasPrefix(staging)
        }
    }

    /// Deletes any leftover transaction directories for a database.
    ///
    /// Runs after a successful update so an interrupted earlier attempt cannot leave
    /// stale copies consuming disk space next to the live database.
    private static func removeTransactionSiblings(for installedPath: URL, name: String) {
        for orphan in transactionSiblings(for: installedPath) {
            do {
                try FileManager.default.removeItem(at: orphan)
                logger.info(
                    "Removed leftover update directory for '\(name, privacy: .public)': \(orphan.lastPathComponent, privacy: .public)"
                )
            } catch {
                logger.warning(
                    "Could not remove leftover update directory \(orphan.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Test Seams

    func setArchiveInstallerForTesting(_ installer: @escaping ArchiveInstalling) {
        archiveInstaller = installer
    }

    func setExpectedChecksumForTesting(_ resolver: @escaping ExpectedChecksumResolving) {
        expectedChecksum = resolver
    }

    func setComputeChecksumForTesting(_ compute: @escaping ChecksumComputing) {
        computeChecksum = compute
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
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try manifestWriter(data, manifestURL)
        } catch {
            throw MetagenomicsDatabaseRegistryError.manifestIOError(
                operation: "save", underlying: error
            )
        }
    }

    private static func productionDatabaseInstaller() -> any MetagenomicsDatabaseInstalling {
        MetagenomicsDatabaseInstaller(
            toolRunner: ManagedMetagenomicsDatabaseToolRunner(),
            archiveTransfer: URLSessionTarDatabaseArchiveTransfer(),
            provenanceWriter: CanonicalMetagenomicsDatabaseInstallProvenanceWriter()
        )
    }

    static func defaultManifestWriter(_ data: Data, _ url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// Repairs databases left mid-swap by a crash during ``updateDatabase(catalogID:progress:)``.
    ///
    /// The swap is two renames (installed -> `.old-<uuid>`, staging -> installed). A
    /// process death between them leaves the manifest claiming a `.ready` database at
    /// a path that no longer exists. Nothing else sweeps that state, so it is repaired
    /// at load, before any caller can read a row pointing at a missing directory.
    ///
    /// Recovery prefers the previous copy, because it is the payload the row's recorded
    /// version actually describes:
    /// 1. A `.old-*` sibling is renamed back into place (the crash happened between the
    ///    two renames, so the row's version still matches this payload).
    /// 2. Otherwise a complete `.staging-<version>` sibling is promoted, and the row's
    ///    version is taken from the directory name, which is where the target version
    ///    was recorded when staging began.
    /// 3. Otherwise the row is marked `.missing` with a nil path.
    ///
    /// Any leftover transaction directories are removed once the outcome is decided.
    ///
    /// - Returns: The number of rows changed, so the caller knows to persist.
    private func recoverInterruptedUpdates() -> Int {
        let fm = FileManager.default
        var recovered = 0

        for (name, db) in databases {
            guard let path = db.path, !fm.fileExists(atPath: path.path) else { continue }

            // An external database that is merely unmounted looks identical to a
            // missing one. `resolveAllBookmarks`/`verify` own that case and can mark it
            // `.volumeNotMounted`; recovery must not race them into `.missing`.
            guard !db.isExternal else { continue }

            let siblings = Self.transactionSiblings(for: path)
            guard !siblings.isEmpty else {
                // No transaction residue: this is an ordinary missing database (an
                // unmounted volume or a user deletion), which `verify` already models.
                continue
            }

            let retiredPrefix = Self.retiredPrefix(for: path)
            let stagingPrefix = Self.stagingPrefix(for: path)
            var updated = db
            var didRecover = false

            if let retired = siblings
                .filter({ $0.lastPathComponent.hasPrefix(retiredPrefix) })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .first,
               (try? fm.moveItem(at: retired, to: path)) != nil {
                updated.status = .ready
                updated.lastUpdated = Date()
                didRecover = true
                logger.notice(
                    "Restored '\(name, privacy: .public)' from an interrupted update; the previously installed version is in place"
                )
            } else if let staged = siblings
                .filter({ $0.lastPathComponent.hasPrefix(stagingPrefix) })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .first,
                Self.missingRequiredFiles(in: staged, tool: db.tool).isEmpty,
                (try? fm.moveItem(at: staged, to: path)) != nil {
                updated.status = .ready
                // The suffix is `safeSuffix(version)`, which preserves letters, digits,
                // dots, and dashes, so real pinned versions ("20240904", "v3.2.4") round
                // trip unchanged. A version containing other characters would recover
                // with them replaced by dashes, which is cosmetic: the payload is
                // correct, and the next update overwrites the string from the catalog.
                updated.version = String(
                    staged.lastPathComponent.dropFirst(stagingPrefix.count)
                )
                updated.payloadDigest = nil
                updated.canonicalReceiptSHA256 = nil
                updated.sizeOnDisk = Self.directorySize(at: path)
                updated.installedAt = Date()
                updated.lastUpdated = Date()
                didRecover = true
                logger.notice(
                    "Completed an interrupted update of '\(name, privacy: .public)' from its staged copy"
                )
            } else {
                updated.status = .missing
                updated.path = nil
                didRecover = true
                logger.warning(
                    "'\(name, privacy: .public)' was left without a usable copy by an interrupted update and is marked missing"
                )
            }

            if didRecover {
                databases[name] = updated
                recovered += 1
                Self.removeTransactionSiblings(for: path, name: name)
            }
        }

        return recovered
    }

    /// Re-points catalog-backed entries that are not installed at the currently pinned
    /// archive, so registries written before a manifest bump stop referencing retired
    /// upstream downloads (for example the withdrawn EuPathDB 20240904 build).
    ///
    /// Installed databases keep the build they were installed from; only the metadata of
    /// entries that still have to be downloaded is refreshed.
    ///
    /// - Returns: The number of entries corrected.
    private func reconcileCatalogURLs() -> Int {
        var corrected = 0
        for (name, db) in databases where db.status != .ready && db.path == nil {
            guard let catalogID = db.catalogID,
                  let fresh = MetagenomicsDatabaseInfo.catalogEntry(catalogID: catalogID),
                  fresh.downloadURL != db.downloadURL || fresh.version != db.version else { continue }
            var updated = db
            updated.version = fresh.version
            updated.downloadURL = fresh.downloadURL
            updated.installationRecipe = fresh.installationRecipe
            databases[name] = updated
            corrected += 1
            logger.notice(
                "Corrected catalog download for \(name, privacy: .public): \(fresh.downloadURL ?? "built locally", privacy: .public)"
            )
        }
        return corrected
    }

    private static func matchesCatalogEntry(
        _ persisted: MetagenomicsDatabaseInfo,
        catalog: MetagenomicsDatabaseInfo
    ) -> Bool {
        if let catalogID = catalog.catalogID, let persistedID = persisted.catalogID {
            return catalogID == persistedID
        }
        // Old manifests have no catalogID. An exact built-in display name is the
        // safe compatibility key; collection alone is also set on imported rows.
        return persisted.catalogID == nil
            && persisted.name == catalog.name
            && (persisted.collection == nil || persisted.collection == catalog.collection)
    }

    private func catalogEntry(
        matching database: MetagenomicsDatabaseInfo
    ) -> MetagenomicsDatabaseInfo? {
        if let catalogID = database.catalogID {
            return catalog.first { $0.catalogID == catalogID }
        }
        return catalog.first {
            database.name == $0.name
                && (database.collection == nil || database.collection == $0.collection)
        }
    }

    private func currentCatalogVersionProvenByReceipt(
        for database: MetagenomicsDatabaseInfo
    ) -> String? {
        guard database.status == .ready,
              database.version?.hasPrefix("built-") == true,
              case .some(.kraken2Special) = database.installationRecipe,
              let catalogID = database.catalogID,
              let currentCatalog = catalogEntry(matching: database),
              currentCatalog.catalogID == catalogID,
              let catalogVersion = currentCatalog.version,
              !catalogVersion.isEmpty,
              let path = database.path,
              let payloadDigest = database.payloadDigest else {
            return nil
        }

        let sidecar = path.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        guard let envelope = try? ProvenanceEnvelopeReader.loadCanonical(fromSidecar: sidecar),
              envelope.workflowName == "metagenomics.database.install",
              envelope.workflowVersion == catalogVersion,
              envelope.exitStatus == 0,
              envelope.options.resolvedDefaults["payloadAggregateSHA256"]?.stringValue == payloadDigest,
              envelope.options.resolvedDefaults["intendedFinalPath"]?.stringValue
                == path.standardizedFileURL.path else {
            return nil
        }

        return catalogVersion
    }

    private static func validateManagedPayload(
        database: MetagenomicsDatabaseInfo,
        at path: URL,
        expectedDigest: String
    ) -> Bool {
        do {
            if database.tool == MetagenomicsTool.kraken2.rawValue {
                let distribution = path.appendingPathComponent("database150mers.kmer_distrib")
                guard isNonEmptyRegularFile(distribution) else { return false }
                if case .kraken2Special = database.installationRecipe {
                    guard isNonEmptyRegularFile(path.appendingPathComponent("taxonomy/nodes.dmp")),
                          isNonEmptyRegularFile(path.appendingPathComponent("taxonomy/names.dmp")),
                          hasNonEmptyRegularLibraryFile(at: path.appendingPathComponent("library", isDirectory: true)) else {
                        return false
                    }
                }
            }

            let snapshot = try MetagenomicsDatabasePayloadDigester.snapshot(at: path)
            guard snapshot.aggregateSHA256 == expectedDigest else { return false }
            let sidecar = path.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            guard let envelope = try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: sidecar),
                  envelope.exitStatus == 0,
                  envelope.options.resolvedDefaults["payloadAggregateSHA256"]?.stringValue == expectedDigest,
                  envelope.options.resolvedDefaults["intendedFinalPath"]?.stringValue == path.standardizedFileURL.path,
                  !envelope.outputs.isEmpty else {
                return false
            }
            let rootPrefix = path.standardizedFileURL.path + "/"
            return envelope.outputs.allSatisfy {
                $0.path.hasPrefix(rootPrefix)
                    && $0.checksumSHA256?.isEmpty == false
                    && $0.fileSize != nil
            }
        } catch {
            return false
        }
    }

    private static func isNonEmptyRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
    }

    private static func hasNonEmptyRegularLibraryFile(at root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator where isNonEmptyRegularFile(url) {
            return true
        }
        return false
    }

    private func refreshStorageLocationFromConfigIfNeeded(resetLoadedState: Bool = true) {
        guard let configuredBaseURL = storageConfigStore?.currentLocation().databaseRootURL.standardizedFileURL,
              configuredBaseURL != databasesBaseURL.standardizedFileURL else {
            return
        }

        databasesBaseURL = configuredBaseURL
        manifestURL = configuredBaseURL.appendingPathComponent("metagenomics-db-registry.json")
        if resetLoadedState {
            databases.removeAll()
        }
    }

    private static func normalizeStorageLocation(_ url: URL) -> (
        sharedRootURL: URL,
        databaseBaseURL: URL
    ) {
        let standardizedURL = url.standardizedFileURL
        if standardizedURL.lastPathComponent == "databases" {
            return (
                sharedRootURL: standardizedURL.deletingLastPathComponent(),
                databaseBaseURL: standardizedURL
            )
        }

        return (
            sharedRootURL: standardizedURL,
            databaseBaseURL: standardizedURL.appendingPathComponent("databases", isDirectory: true)
        )
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
        let taskBox = DownloadTaskCancellationBox()

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
                taskBox.store(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    /// Extracts a .tar.gz file to a destination directory.
    ///
    /// Uses `CheckedContinuation` with `terminationHandler` and background
    /// pipe draining to avoid blocking the actor thread and to prevent pipe
    /// deadlocks when tar produces large output.
    private func extractTarball(_ tarball: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            // Kraken2 databases from genome-idx.s3.amazonaws.com have files at the
            // top level (hash.k2d, opts.k2d, taxo.k2d), NOT inside a subdirectory.
            // Do NOT use --strip-components=1 as it would strip the filenames.
            process.arguments = ["xzf", tarball.path, "-C", destination.path]

            let stderrPipe = Pipe()
            let stdoutPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = stdoutPipe

            let processState = MetagenomicsProcessCompletionState()
            let drainGroup = DispatchGroup()
            drainGroup.enter()
            drainGroup.enter()

            process.terminationHandler = { terminatedProcess in
                drainGroup.notify(queue: .global(qos: .utility)) {
                    guard processState.markCompleted() else { return }

                    if terminatedProcess.terminationStatus != 0 {
                        continuation.resume(
                            throwing: MetagenomicsDatabaseRegistryError.downloadFailed(
                                name: tarball.lastPathComponent,
                                reason: "tar extraction failed: \(processState.stderrText)"
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            }

            do {
                try process.run()
                DispatchQueue.global(qos: .utility).async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    processState.appendStderr(data)
                    drainGroup.leave()
                }
                DispatchQueue.global(qos: .utility).async {
                    _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }
            } catch {
                drainGroup.leave()
                drainGroup.leave()
                guard processState.markCompleted() else { return }
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Process Completion State

final class MetagenomicsProcessCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var stderrData = Data()
    private var completed = false

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        stderrData.append(data)
    }

    var stderrText: String {
        lock.lock()
        let data = stderrData
        lock.unlock()
        guard !data.isEmpty else { return "Unknown error" }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    func markCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
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
