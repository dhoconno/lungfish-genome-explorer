// DatabaseRegistry.swift - Bundled bioinformatics reference database management
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import CryptoKit

private let dbLogger = Logger(subsystem: LogSubsystem.workflow, category: "DatabaseRegistry")

// MARK: - HumanScrubberDatabaseError

/// User-actionable errors for the managed human-scrubber database.
public enum HumanScrubberDatabaseError: Error, LocalizedError, Sendable {
    case installRequired(databaseID: String, displayName: String)
    case installationCancelled(databaseID: String, displayName: String)
    case installationFailed(databaseID: String, displayName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .installRequired(_, let displayName):
            return "\(displayName) is required before running human-read scrubbing. Install it and try again."
        case .installationCancelled(_, let displayName):
            return "\(displayName) installation was cancelled. Human-read scrubbing remains unavailable."
        case .installationFailed(_, let displayName, let reason):
            return "Failed to install \(displayName): \(reason)"
        }
    }

    public var isInstallRequired: Bool {
        if case .installRequired = self {
            return true
        }
        return false
    }
}

// MARK: - HumanScrubberDatabaseInstaller

/// Focused installer for the managed human-scrubber database.
public actor HumanScrubberDatabaseInstaller {
    public static let databaseID = "human-scrubber"
    public static let shared = HumanScrubberDatabaseInstaller()

    private let registry: DatabaseRegistry

    public init(registry: DatabaseRegistry = .shared) {
        self.registry = registry
    }

    public func install(
        reinstall: Bool = false,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        try await registry.installManagedDatabase(Self.databaseID, reinstall: reinstall, progress: progress)
    }
}

// MARK: - DeaconPanhumanDatabaseInstaller

/// Focused installer for the managed Deacon panhuman host-depletion index.
public actor DeaconPanhumanDatabaseInstaller {
    public static let databaseID = "deacon-panhuman"
    public static let shared = DeaconPanhumanDatabaseInstaller()

    private let registry: DatabaseRegistry

    public init(registry: DatabaseRegistry = .shared) {
        self.registry = registry
    }

    public func install(
        reinstall: Bool = false,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        try await registry.installManagedDatabase(Self.databaseID, reinstall: reinstall, progress: progress)
    }
}

// MARK: - BundledDatabase

/// Metadata for a reference database advertised by the app bundle.
///
/// Manifests live in `Resources/Databases/<id>/manifest.json`.
/// Some databases also ship a bundled payload file in the same directory.
/// Others, such as `human-scrubber` and `deacon-panhuman`, use bundled metadata only and expect the
/// payload itself to be managed in user data.
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

public enum ManagedStorageAvailability: Sendable, Equatable {
    case available(ManagedStorageLocation)
    case unavailable(URL)
}

// MARK: - DatabaseRegistry

/// Resolves the runtime path of reference databases.
///
/// Resolution priority:
/// 1. User-installed copy in `~/Library/Application Support/Lungfish/databases/<id>/`
/// 2. Bundled payload in the app's `Resources/Databases/<id>/` directory, but only
///    for databases that actually ship a bundled payload
///
/// Managed user-data databases such as `human-scrubber` and `deacon-panhuman` keep their manifest metadata
/// in the bundle but do not fall back to bundled payload resolution.
///
/// To update a database without a full app update:
/// - Place the new database file in the override directory
/// - Update UserDefaults key `database.<id>.overrideFilename` with the new filename
///
/// Future releases can update bundled metadata and any bundled-payload databases
/// automatically.
public actor DatabaseRegistry {

    public static let shared = DatabaseRegistry()
    private static let databaseIDAliases: [String: String] = [
        "deacon": "deacon-panhuman",
        "sra-human-scrubber": "human-scrubber",
    ]

    private static let managedUserDataIDs: Set<String> = [
        "human-scrubber",
        "deacon-panhuman",
    ]

    /// Loaded manifests indexed by database ID.
    private var manifests: [String: BundledDatabase] = [:]

    /// Root directory of bundled databases in Resources/Databases/.
    private var bundledDatabasesRoot: URL?

    /// User-managed database directory base.
    private let userDatabasesRootProvider: @Sendable () -> URL?

    private init() {
        let storageConfigStore = ManagedStorageConfigStore()
        self.userDatabasesRootProvider = {
            storageConfigStore.currentLocation().databaseRootURL
        }
    }

    init(bundledDatabasesRoot: URL?, userDatabasesRoot: URL?) {
        self.bundledDatabasesRoot = bundledDatabasesRoot
        self.userDatabasesRootProvider = { userDatabasesRoot }
    }

    init(bundledDatabasesRoot: URL?, storageConfigStore: ManagedStorageConfigStore) {
        self.bundledDatabasesRoot = bundledDatabasesRoot
        self.userDatabasesRootProvider = {
            storageConfigStore.currentLocation().databaseRootURL
        }
    }

    // MARK: - Public API

    /// All known bundled database IDs.
    public static let knownIDs: [String] = [
        "human-scrubber",
        "deacon-panhuman",
    ]

    public nonisolated static func managedStorageAvailability(
        storageConfigStore: ManagedStorageConfigStore = ManagedStorageConfigStore(),
        fileManager: FileManager = .default
    ) -> ManagedStorageAvailability {
        let location = storageConfigStore.currentLocation()
        let defaultRoot = storageConfigStore.defaultLocation.rootURL.standardizedFileURL
        let currentRoot = location.rootURL.standardizedFileURL

        if currentRoot == defaultRoot || fileManager.fileExists(atPath: currentRoot.path) {
            return .available(location)
        }

        return .unavailable(currentRoot)
    }

    /// Returns the canonical ID for a database, mapping legacy aliases when needed.
    public static func canonicalDatabaseID(for id: String) -> String {
        normalizedDatabaseID(id)
    }

    /// Returns the manifest for a database, loading it if needed.
    public func manifest(for id: String) -> BundledDatabase? {
        let resolvedID = Self.normalizedDatabaseID(id)
        if let cached = manifests[resolvedID] { return cached }
        guard let url = bundledManifestURL(for: resolvedID) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let db = try JSONDecoder().decode(BundledDatabase.self, from: data)
            manifests[resolvedID] = db
            return db
        } catch {
            dbLogger.error("Failed to load database manifest for '\(resolvedID)': \(error)")
            return nil
        }
    }

    /// Resolves the effective runtime database file path for a given ID.
    ///
    /// Checks for a user-installed copy first.
    /// Falls back to a bundled payload only when that database ships with one.
    /// Managed user-data databases such as `human-scrubber` and `deacon-panhuman` return `nil` when no
    /// installed copy exists, even though bundled manifest metadata is still available.
    public func effectiveDatabasePath(for id: String) -> URL? {
        let resolvedID = Self.normalizedDatabaseID(id)

        // 1. Check user-managed database directory
        if let installedPath = userInstalledPath(for: resolvedID) {
            dbLogger.info("Using user-installed database for '\(resolvedID)': \(installedPath.lastPathComponent)")
            return installedPath
        }

        if Self.managedUserDataIDs.contains(resolvedID) {
            dbLogger.error("Managed database '\(resolvedID)' is not installed")
            return nil
        }

        // 2. Fall back to bundled database
        if let bundledPath = bundledDatabasePath(for: resolvedID) {
            dbLogger.debug("Using bundled database for '\(resolvedID)': \(bundledPath.lastPathComponent)")
            return bundledPath
        }

        dbLogger.error("No database found for '\(resolvedID)'")
        return nil
    }

    /// Returns a human-readable version string for a database.
    public func versionString(for id: String) -> String {
        let resolvedID = Self.normalizedDatabaseID(id)
        guard let db = manifest(for: resolvedID) else { return "unknown" }
        if userInstalledPath(for: resolvedID) != nil {
            let suffix = Self.managedUserDataIDs.contains(resolvedID) ? "installed" : "user override"
            return "\(db.version) (\(suffix))"
        }
        return db.version
    }

    /// Returns the manifest for a required managed database, when available.
    public func requiredDatabaseManifest(for id: String) -> BundledDatabase? {
        manifest(for: id)
    }

    /// Returns whether a managed database is installed and resolvable.
    public func isDatabaseInstalled(_ id: String) -> Bool {
        effectiveDatabasePath(for: id) != nil
    }

    /// Resolves a managed database path or throws an actionable install-required error.
    public func requiredDatabasePath(for id: String) throws -> URL {
        let resolvedID = Self.normalizedDatabaseID(id)
        if let path = effectiveDatabasePath(for: id) {
            return path
        }

        let displayName = manifest(for: resolvedID)?.displayName ?? resolvedID
        throw HumanScrubberDatabaseError.installRequired(databaseID: resolvedID, displayName: displayName)
    }

    public func copyManagedDatabases(from sourceRoot: URL, to destinationRoot: URL) throws {
        let sourceRoot = sourceRoot.standardizedFileURL
        let destinationRoot = destinationRoot.standardizedFileURL
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sourceRoot.path) else {
            return
        }

        for databaseID in Self.managedUserDataIDs.sorted() {
            let sourceDirectory = managedDatabaseDirectory(for: databaseID, under: sourceRoot)
            guard fileManager.fileExists(atPath: sourceDirectory.path) else {
                continue
            }

            let destinationDirectory = managedDatabaseDirectory(for: databaseID, under: destinationRoot)
            try fileManager.createDirectory(
                at: destinationDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationDirectory.path) {
                try fileManager.removeItem(at: destinationDirectory)
            }
            try fileManager.copyItem(at: sourceDirectory, to: destinationDirectory)
        }
    }

    public func verifyManagedDatabases(at databaseRoot: URL) throws {
        let databaseRoot = databaseRoot.standardizedFileURL
        let fileManager = FileManager.default

        for databaseID in Self.managedUserDataIDs.sorted() {
            let directory = managedDatabaseDirectory(for: databaseID, under: databaseRoot)
            guard fileManager.fileExists(atPath: directory.path) else {
                continue
            }

            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            guard contents.contains(where: isUsableInstalledDatabaseCandidate) else {
                let displayName = manifest(for: databaseID)?.displayName ?? databaseID
                throw HumanScrubberDatabaseError.installationFailed(
                    databaseID: databaseID,
                    displayName: displayName,
                    reason: "Migrated database files are missing from \(directory.path)"
                )
            }
        }
    }

    /// Downloads and installs a managed database into user storage.
    public func installManagedDatabase(
        _ id: String,
        reinstall: Bool = false,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let resolvedID = Self.normalizedDatabaseID(id)
        if reinstall {
            try clearManagedDatabaseInstall(resolvedID)
        } else if let existing = effectiveDatabasePath(for: id) {
            progress?(1.0, "Using installed \(manifest(for: resolvedID)?.displayName ?? resolvedID)")
            return existing
        }

        guard Self.managedUserDataIDs.contains(resolvedID),
              let manifest = manifest(for: resolvedID) else {
            throw HumanScrubberDatabaseError.installationFailed(
                databaseID: resolvedID,
                displayName: resolvedID,
                reason: "Unsupported managed database"
            )
        }

        switch resolvedID {
        case HumanScrubberDatabaseInstaller.databaseID:
            return try await installChecksummedManagedDatabase(
                databaseID: resolvedID,
                manifest: manifest,
                progress: progress
            )
        case DeaconPanhumanDatabaseInstaller.databaseID:
            return try await installDeaconManagedDatabase(
                databaseID: resolvedID,
                manifest: manifest,
                progress: progress
            )
        default:
            throw HumanScrubberDatabaseError.installationFailed(
                databaseID: resolvedID,
                displayName: manifest.displayName,
                reason: "Unsupported managed database"
            )
        }
    }

    private func installChecksummedManagedDatabase(
        databaseID: String,
        manifest: BundledDatabase,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        guard let artifactURLs = managedDatabaseArtifactURLs(for: manifest) else {
            throw HumanScrubberDatabaseError.installationFailed(
                databaseID: databaseID,
                displayName: manifest.displayName,
                reason: "No download URL is available"
            )
        }
        let downloadURL = artifactURLs.databaseURL
        let md5URL = artifactURLs.md5URL

        guard let installDirectory = managedDatabaseDirectory(for: databaseID) else {
            throw HumanScrubberDatabaseError.installationFailed(
                databaseID: databaseID,
                displayName: manifest.displayName,
                reason: "No writable database storage location is configured"
            )
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true, attributes: nil)

        let tempDownloadURL = installDirectory.appendingPathComponent("\(manifest.filename).download")
        let tempMD5URL = installDirectory.appendingPathComponent("\(manifest.filename).md5.download")
        let destinationURL = installDirectory.appendingPathComponent(manifest.filename)

        try? fileManager.removeItem(at: tempDownloadURL)
        try? fileManager.removeItem(at: tempMD5URL)

        progress?(0.02, "Preparing \(manifest.displayName)…")

        do {
            let downloadedURL = try await downloadFile(from: downloadURL) { fraction, bytesWritten, totalBytes in
                let scaled = 0.04 + (fraction * 0.72)
                progress?(
                    scaled,
                    "Downloading \(manifest.displayName)… \(Self.formatByteCount(bytesWritten)) of \(Self.formatByteCount(totalBytes))"
                )
            }

            progress?(0.78, "Downloading checksum for \(manifest.displayName)…")
            let downloadedMD5URL = try await downloadFile(from: md5URL) { fraction, _, _ in
                let scaled = 0.78 + (fraction * 0.04)
                progress?(scaled, "Downloading checksum for \(manifest.displayName)…")
            }

            progress?(0.84, "Checking \(manifest.displayName)…")

            let expectedMD5 = try parseExpectedMD5(from: downloadedMD5URL)
            let actualMD5 = try md5Hex(of: downloadedURL) { fraction in
                let scaled = 0.84 + (fraction * 0.12)
                progress?(scaled, "Checking \(manifest.displayName)…")
            }
            guard actualMD5.lowercased() == expectedMD5.lowercased() else {
                throw HumanScrubberDatabaseError.installationFailed(
                    databaseID: databaseID,
                    displayName: manifest.displayName,
                    reason: "MD5 mismatch: expected \(expectedMD5), got \(actualMD5)"
                )
            }

            progress?(0.97, "Saving \(manifest.displayName)…")
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: downloadedURL, to: tempDownloadURL)
            try fileManager.moveItem(at: tempDownloadURL, to: destinationURL)
            try? fileManager.removeItem(at: downloadedMD5URL)
            try? fileManager.removeItem(at: tempMD5URL)
            UserDefaults.standard.set(
                manifest.filename,
                forKey: overrideFilenameKey(for: databaseID)
            )
            progress?(1.0, "Installed \(manifest.displayName)")
            return destinationURL
        } catch is CancellationError {
            try? fileManager.removeItem(at: tempDownloadURL)
            try? fileManager.removeItem(at: tempMD5URL)
            throw HumanScrubberDatabaseError.installationCancelled(
                databaseID: databaseID,
                displayName: manifest.displayName
            )
        } catch let error as HumanScrubberDatabaseError {
            try? fileManager.removeItem(at: tempDownloadURL)
            try? fileManager.removeItem(at: tempMD5URL)
            throw error
        } catch {
            try? fileManager.removeItem(at: tempDownloadURL)
            try? fileManager.removeItem(at: tempMD5URL)
            throw HumanScrubberDatabaseError.installationFailed(
                databaseID: databaseID,
                displayName: manifest.displayName,
                reason: error.localizedDescription
            )
        }
    }

    private func installDeaconManagedDatabase(
        databaseID: String,
        manifest: BundledDatabase,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        guard let installDirectory = managedDatabaseDirectory(for: databaseID) else {
            throw HumanScrubberDatabaseError.installationFailed(
                databaseID: databaseID,
                displayName: manifest.displayName,
                reason: "No writable database storage location is configured"
            )
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true, attributes: nil)

        let destinationURL = installDirectory.appendingPathComponent(manifest.filename)
        let tempOutputURL = installDirectory.appendingPathComponent("\(manifest.filename).partial")
        let tempFetchURL = tempOutputURL.appendingPathExtension("tmp")

        try? fileManager.removeItem(at: tempOutputURL)
        try? fileManager.removeItem(at: tempFetchURL)

        progress?(0.02, "Preparing \(manifest.displayName)…")

        do {
            progress?(0.08, "Downloading \(manifest.displayName)…")
            let fetchResult = try await CondaManager.shared.runTool(
                name: "deacon",
                arguments: ["index", "fetch", manifest.version, "-o", tempOutputURL.path],
                environment: "deacon",
                timeout: 7200,
                stderrHandler: { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if trimmed.hasPrefix("Fetching ") {
                        progress?(0.14, "Downloading \(manifest.displayName)…")
                    }
                }
            )
            guard fetchResult.exitCode == 0 else {
                let message = fetchResult.stderr.isEmpty ? fetchResult.stdout : fetchResult.stderr
                throw HumanScrubberDatabaseError.installationFailed(
                    databaseID: databaseID,
                    displayName: manifest.displayName,
                    reason: message.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            guard fileManager.fileExists(atPath: tempOutputURL.path) else {
                throw HumanScrubberDatabaseError.installationFailed(
                    databaseID: databaseID,
                    displayName: manifest.displayName,
                    reason: "Deacon did not create the fetched index"
                )
            }

            progress?(0.88, "Checking \(manifest.displayName)…")
            let infoResult = try await CondaManager.shared.runTool(
                name: "deacon",
                arguments: ["index", "info", tempOutputURL.path],
                environment: "deacon",
                timeout: 300
            )
            guard infoResult.exitCode == 0 else {
                throw HumanScrubberDatabaseError.installationFailed(
                    databaseID: databaseID,
                    displayName: manifest.displayName,
                    reason: infoResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            progress?(0.97, "Saving \(manifest.displayName)…")
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempOutputURL, to: destinationURL)
            UserDefaults.standard.set(
                manifest.filename,
                forKey: overrideFilenameKey(for: databaseID)
            )
            progress?(1.0, "Installed \(manifest.displayName)")
            return destinationURL
        } catch is CancellationError {
            try? fileManager.removeItem(at: tempOutputURL)
            try? fileManager.removeItem(at: tempFetchURL)
            throw HumanScrubberDatabaseError.installationCancelled(
                databaseID: databaseID,
                displayName: manifest.displayName
            )
        } catch let error as HumanScrubberDatabaseError {
            try? fileManager.removeItem(at: tempOutputURL)
            try? fileManager.removeItem(at: tempFetchURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: tempOutputURL)
            try? fileManager.removeItem(at: tempFetchURL)
            throw HumanScrubberDatabaseError.installationFailed(
                databaseID: databaseID,
                displayName: manifest.displayName,
                reason: error.localizedDescription
            )
        }
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

    private func userInstalledPath(for id: String) -> URL? {
        guard let base = userDatabasesRootProvider() else { return nil }
        let dir = base.appendingPathComponent(id)

        // Check UserDefaults for a specific override filename
        let overrideKey = overrideFilenameKey(for: id)
        if let filename = UserDefaults.standard.string(forKey: overrideKey) {
            let url = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        // Fall back: scan directory for any file matching the database ID pattern
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }

        return contents
            .filter { isUsableInstalledDatabaseCandidate($0) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // newest first by name
            .first
    }

    private func isUsableInstalledDatabaseCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        guard !name.hasSuffix(".tmp") else { return false }
        guard !name.hasSuffix(".download") else { return false }
        guard !name.hasSuffix(".partial") else { return false }
        return true
    }

    private func managedDatabaseDirectory(for id: String) -> URL? {
        userDatabasesRootProvider()?.appendingPathComponent(id, isDirectory: true)
    }

    private func managedDatabaseDirectory(for id: String, under databaseRoot: URL) -> URL {
        databaseRoot.appendingPathComponent(id, isDirectory: true)
    }

    private func clearManagedDatabaseInstall(_ id: String) throws {
        let resolvedID = Self.normalizedDatabaseID(id)
        if let installDirectory = managedDatabaseDirectory(for: resolvedID),
           FileManager.default.fileExists(atPath: installDirectory.path)
        {
            try FileManager.default.removeItem(at: installDirectory)
        }
        UserDefaults.standard.removeObject(forKey: overrideFilenameKey(for: resolvedID))
    }

    func managedDatabaseArtifactURLs(for manifest: BundledDatabase) -> (databaseURL: URL, md5URL: URL)? {
        guard manifest.id == "human-scrubber" else { return nil }
        // The human-scrubber database is distributed by NCBI under this stable path.
        guard let databaseURL = URL(string: "https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/\(manifest.filename)") else {
            return nil
        }
        return (databaseURL, databaseURL.appendingPathExtension("md5"))
    }

    private func parseExpectedMD5(from md5URL: URL) throws -> String {
        let contents = try String(contentsOf: md5URL, encoding: .utf8)
        for token in contents
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "=" || $0 == "*" })
        {
            if token.count == 32, token.allSatisfy(\.isHexDigit) {
                return String(token)
            }
        }
        throw HumanScrubberDatabaseError.installationFailed(
            databaseID: "human-scrubber",
            displayName: "Human Read Scrubber Database",
            reason: "Could not parse MD5 file \(md5URL.lastPathComponent)"
        )
    }

    private func md5Hex(
        of fileURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let totalBytes = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var hasher = Insecure.MD5()
        var bytesRead: Int64 = 0
        while true {
            let data = try handle.read(upToCount: 1_048_576)
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
            bytesRead += Int64(data.count)
            if totalBytes > 0 {
                progress?(min(Double(bytesRead) / Double(totalBytes), 1.0))
            }
        }
        progress?(1.0)

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func downloadFile(
        from url: URL,
        progress: @Sendable @escaping (Double, Int64, Int64) -> Void
    ) async throws -> URL {
        nonisolated(unsafe) var downloadTask: URLSessionDownloadTask?

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let delegate = ManagedDatabaseDownloadDelegate(
                    suggestedExtension: url.pathExtension,
                    progress: progress,
                    completion: { result in
                        continuation.resume(with: result)
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

    private func overrideFilenameKey(for id: String) -> String {
        "database.\(id).overrideFilename"
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    private static func normalizedDatabaseID(_ id: String) -> String {
        databaseIDAliases[id] ?? id
    }

    private func databasesRoot() -> URL? {
        if let cached = bundledDatabasesRoot { return cached }

        if let candidate = RuntimeResourceLocator.path("Databases", in: .workflow) {
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

private final class ManagedDatabaseDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let suggestedExtension: String
    private let progressCallback: @Sendable (Double, Int64, Int64) -> Void
    private let completionCallback: @Sendable (Result<URL, Error>) -> Void
    private let hasFired = LockedFlag()

    init(
        suggestedExtension: String,
        progress: @Sendable @escaping (Double, Int64, Int64) -> Void,
        completion: @Sendable @escaping (Result<URL, Error>) -> Void
    ) {
        self.suggestedExtension = suggestedExtension
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
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(totalBytesWritten, 1)
        let fraction = Double(totalBytesWritten) / Double(total)
        progressCallback(min(fraction, 1.0), totalBytesWritten, total)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard hasFired.testAndSet() else { return }

        let stableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suggestedExtension)

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

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}
