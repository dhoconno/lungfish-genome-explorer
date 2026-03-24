// EsVirituDatabaseManager.swift - EsViritu viral database download and management
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "EsVirituDB")

// MARK: - EsVirituDatabaseError

/// Errors that can occur during EsViritu database operations.
public enum EsVirituDatabaseError: Error, LocalizedError, Sendable {

    /// The download URL could not be resolved.
    case downloadURLResolutionFailed(String)

    /// The download failed.
    case downloadFailed(String)

    /// The download was cancelled.
    case downloadCancelled

    /// Extraction of the database archive failed.
    case extractionFailed(String)

    /// The database directory is missing required files after extraction.
    case validationFailed(missing: [String])

    /// Insufficient disk space for the database.
    case insufficientDiskSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .downloadURLResolutionFailed(let msg):
            return "Failed to resolve EsViritu database download URL: \(msg)"
        case .downloadFailed(let msg):
            return "EsViritu database download failed: \(msg)"
        case .downloadCancelled:
            return "EsViritu database download was cancelled"
        case .extractionFailed(let msg):
            return "Failed to extract EsViritu database: \(msg)"
        case .validationFailed(let missing):
            return "EsViritu database validation failed. Missing files: \(missing.joined(separator: ", "))"
        case .insufficientDiskSpace(let required, let available):
            let reqStr = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let avlStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Insufficient disk space for EsViritu database: requires \(reqStr), available \(avlStr)"
        }
    }
}

// MARK: - EsVirituDatabaseManager

/// Manages the EsViritu viral reference database.
///
/// Downloads, extracts, and validates the curated viral database from Zenodo.
/// The database is stored in `~/.lungfish/databases/esviritu/<version>/`.
///
/// ## Database Structure
///
/// The EsViritu database contains:
/// - Viral reference genomes (FASTA)
/// - Pre-built indices for alignment
/// - Taxonomy mapping files
/// - Metadata for viral species identification
///
/// ## Download
///
/// The database is downloaded from Zenodo (DOI: 10.5281/zenodo.17716199) as
/// a compressed tarball and extracted to the local storage directory.
///
/// ## Usage
///
/// ```swift
/// let manager = EsVirituDatabaseManager.shared
/// if await !manager.isInstalled() {
///     let dbPath = try await manager.download { fraction, message in
///         print("\(Int(fraction * 100))% \(message)")
///     }
/// }
/// let dbPath = await manager.databaseURL
/// ```
public actor EsVirituDatabaseManager {

    /// Shared singleton instance.
    public static let shared = EsVirituDatabaseManager()

    /// Current database version.
    public static let currentVersion = "v3.2.4"

    /// Zenodo DOI for the database.
    public static let zenodoDOI = "10.5281/zenodo.17716199"

    /// Direct download URL for the database tarball from Zenodo.
    ///
    /// This URL points to the specific version of the database archive.
    /// Updated when ``currentVersion`` changes.
    public static let downloadURL = "https://zenodo.org/records/17716199/files/esviritu_db_v3.2.4.tar.gz"

    /// Approximate download size in bytes (~2 GB compressed).
    public static let approximateDownloadSize: Int64 = 2_147_483_648

    /// Approximate extracted size in bytes (~5 GB).
    public static let approximateExtractedSize: Int64 = 5_368_709_120

    /// Root storage directory for all Lungfish databases.
    private let databasesRoot: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.databasesRoot = home.appendingPathComponent(".lungfish/databases")
    }

    /// Creates a database manager with a custom storage root (for testing).
    ///
    /// - Parameter storageRoot: Custom root directory for database storage.
    init(storageRoot: URL) {
        self.databasesRoot = storageRoot
    }

    // MARK: - Path Computation

    /// The storage path for the current version of the EsViritu database.
    ///
    /// Returns `~/.lungfish/databases/esviritu/<version>/`.
    public var databaseURL: URL {
        databasesRoot
            .appendingPathComponent("esviritu")
            .appendingPathComponent(Self.currentVersion)
    }

    // MARK: - Status

    /// Whether the database is installed and contains the expected files.
    ///
    /// Checks two locations:
    /// 1. The legacy versioned path (`~/.lungfish/databases/esviritu/<version>/`)
    /// 2. The registry-managed path (from ``MetagenomicsDatabaseRegistry``)
    ///
    /// - Returns: `true` if the database appears to be installed and valid.
    public func isInstalled() -> Bool {
        // Check the registry first (preferred — this is where the Plugin Manager stores it)
        if let registryPath = registryDatabasePath() {
            return directoryContainsEsVirituDB(registryPath)
        }

        // Fall back to the legacy versioned path
        return directoryContainsEsVirituDB(databaseURL)
    }

    /// Returns the database path from the registry-managed location.
    ///
    /// Checks the registry download path directly via filesystem
    /// rather than querying the `MetagenomicsDatabaseRegistry` actor, avoiding
    /// cross-actor isolation issues. Uses the same `databasesRoot` as this manager.
    private func registryDatabasePath() -> URL? {
        let registryDir = databasesRoot
            .appendingPathComponent("esviritu/esviritu-viral-db")
        if FileManager.default.fileExists(atPath: registryDir.path) {
            return registryDir
        }
        return nil
    }

    /// Checks whether a directory contains EsViritu database files.
    private func directoryContainsEsVirituDB(_ dbDir: URL) -> Bool {
        let fm = FileManager.default

        guard fm.fileExists(atPath: dbDir.path) else { return false }

        // Check for key database files — look for any FASTA or index files.
        // EsViritu DB structure varies by version, so check broadly.
        let contents = (try? fm.contentsOfDirectory(at: dbDir, includingPropertiesForKeys: nil)) ?? []

        // Check top-level and one level of subdirectories
        let allFiles = contents + contents.flatMap { subdir -> [URL] in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subdir.path, isDirectory: &isDir), isDir.boolValue else { return [] }
            return (try? fm.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil)) ?? []
        }

        let hasFasta = allFiles.contains { url in
            let ext = url.pathExtension.lowercased()
            return ext == "fasta" || ext == "fa" || ext == "fna" || ext == "mmi"
        }

        return hasFasta
    }

    /// Returns the names of required Kraken2 files missing from a directory.
    /// Kept for backward compatibility but no longer used for EsViritu validation.
    private func _legacyCheck(_ dbDir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbDir.path) else { return false }

        let markerFiles = ["refseq_viral.fasta", "taxonomy", "metadata"]
        for marker in markerFiles {
            let markerPath = dbDir.appendingPathComponent(marker)
            if fm.fileExists(atPath: markerPath.path) {
                return true
            }
        }

        // If the directory exists but has no known markers, check if it
        // has any contents at all (may be a different db layout version).
        let contents = (try? fm.contentsOfDirectory(atPath: dbDir.path)) ?? []
        return !contents.isEmpty
    }

    /// Returns information about the installed database, if any.
    ///
    /// - Returns: A tuple of (version, path, sizeBytes), or `nil` if not installed.
    public func installedDatabaseInfo() -> (version: String, path: URL, sizeBytes: Int64)? {
        guard isInstalled() else { return nil }

        // Prefer the registry-managed path
        if let registryPath = registryDatabasePath() {
            let resolved = resolveDBDirectory(registryPath)
            let size = directorySize(at: resolved)
            return (version: Self.currentVersion, path: resolved, sizeBytes: size)
        }

        // Fall back to legacy path
        let dbDir = databaseURL
        let size = directorySize(at: dbDir)
        return (version: Self.currentVersion, path: dbDir, sizeBytes: size)
    }

    /// Resolves the actual directory containing EsViritu DB files.
    ///
    /// The registry may store the database at a parent directory (e.g.,
    /// `esviritu-viral-db/`) while the actual files are in a version
    /// subdirectory (e.g., `esviritu-viral-db/v3.2.4/`). This method
    /// finds the deepest directory containing `.fna`, `.fasta`, or `.mmi` files.
    private func resolveDBDirectory(_ dir: URL) -> URL {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []

        // If this directory directly contains DB files, return it
        if contents.contains(where: { ["fna", "fasta", "fa", "mmi"].contains($0.pathExtension.lowercased()) }) {
            return dir
        }

        // Check subdirectories
        for subdir in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subdir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let subContents = (try? fm.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil)) ?? []
            if subContents.contains(where: { ["fna", "fasta", "fa", "mmi"].contains($0.pathExtension.lowercased()) }) {
                return subdir
            }
        }

        return dir
    }

    // MARK: - Download

    /// Downloads and installs the EsViritu database.
    ///
    /// The download proceeds in these steps:
    /// 1. Check available disk space
    /// 2. Download the compressed tarball from Zenodo
    /// 3. Extract to the database directory
    /// 4. Validate the extracted contents
    ///
    /// - Parameter progress: Progress callback reporting download and extraction progress.
    /// - Returns: The path to the installed database directory.
    /// - Throws: ``EsVirituDatabaseError`` on failure.
    @discardableResult
    public func download(
        progress: @Sendable @escaping (Double, String) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let dbDir = databaseURL

        // Step 1: Check disk space.
        progress(0.0, "Checking disk space...")
        try checkDiskSpace()

        // Step 2: Create parent directories.
        let parentDir = dbDir.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // Step 3: Download the tarball.
        progress(0.02, "Downloading EsViritu database (\(Self.currentVersion))...")

        guard let url = URL(string: Self.downloadURL) else {
            throw EsVirituDatabaseError.downloadURLResolutionFailed("Invalid URL: \(Self.downloadURL)")
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("esviritu-db-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tarballPath = tempDir.appendingPathComponent("esviritu_db.tar.gz")

        // Use delegate-based download for progress reporting.
        // (URLSession async download API doesn't reliably call didWriteData.)
        let downloadedURL = try await downloadWithProgress(
            from: url,
            to: tarballPath,
            expectedSize: Self.approximateDownloadSize,
            progress: { fraction in
                // Download is 0.02 -- 0.70 of total progress.
                let scaledProgress = 0.02 + fraction * 0.68
                let pctStr = String(format: "%.0f", fraction * 100)
                progress(scaledProgress, "Downloading database... \(pctStr)%")
            }
        )

        // Step 4: Extract the tarball.
        progress(0.72, "Extracting database...")

        // Remove existing database directory if present.
        if fm.fileExists(atPath: dbDir.path) {
            try fm.removeItem(at: dbDir)
        }
        try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)

        try await extractTarball(at: downloadedURL, to: dbDir)

        // Step 5: Clean up tarball.
        progress(0.92, "Cleaning up...")
        try? fm.removeItem(at: tempDir)

        // Step 6: Validate.
        progress(0.95, "Validating database...")
        try validateDatabase(at: dbDir)

        progress(1.0, "EsViritu database \(Self.currentVersion) installed")

        logger.info("EsViritu database installed at \(dbDir.path)")
        return dbDir
    }

    /// Removes the installed database.
    ///
    /// - Throws: File system errors.
    public func remove() throws {
        let fm = FileManager.default
        let dbDir = databaseURL
        if fm.fileExists(atPath: dbDir.path) {
            try fm.removeItem(at: dbDir)
            logger.info("Removed EsViritu database at \(dbDir.path)")
        }
    }

    // MARK: - Private Helpers

    /// Checks that sufficient disk space is available for the database.
    private func checkDiskSpace() throws {
        let fm = FileManager.default
        let parentDir = databasesRoot

        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        if let attrs = try? fm.attributesOfFileSystem(forPath: parentDir.path),
           let freeSpace = attrs[.systemFreeSize] as? Int64 {
            // Need space for both the compressed download and the extraction.
            let requiredSpace = Self.approximateDownloadSize + Self.approximateExtractedSize
            if freeSpace < requiredSpace {
                throw EsVirituDatabaseError.insufficientDiskSpace(
                    required: requiredSpace,
                    available: freeSpace
                )
            }
        }
    }

    /// Downloads a file with byte-level progress reporting using URLSession
    /// delegate-based API.
    ///
    /// The async URLSession.download(for:) API does not reliably report
    /// progress via delegate callbacks. This method uses the traditional
    /// downloadTask + CheckedContinuation pattern instead.
    private func downloadWithProgress(
        from url: URL,
        to destination: URL,
        expectedSize: Int64,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let delegate = DownloadProgressDelegate(
                destination: destination,
                expectedSize: expectedSize,
                progress: progress,
                continuation: continuation
            )

            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )

            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    /// Extracts a tar.gz archive to the specified directory.
    private func extractTarball(at tarball: URL, to destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "xzf", tarball.path,
            "-C", destination.path,
            "--strip-components=1",
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw EsVirituDatabaseError.extractionFailed(stderr)
        }
    }

    /// Validates that the extracted database contains expected files.
    private func validateDatabase(at directory: URL) throws {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []

        if contents.isEmpty {
            throw EsVirituDatabaseError.validationFailed(missing: ["(empty directory)"])
        }

        logger.info(
            "Database validated with \(contents.count) entries at \(directory.path)"
        )
    }

    /// Computes the total size of a directory and its contents.
    private func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - DownloadProgressDelegate

/// URLSession delegate that reports download progress and copies the
/// completed file to a destination path.
///
/// Uses CheckedContinuation to bridge the delegate-based API to async/await.
/// The temp file from URLSession is copied in `urlSession(_:downloadTask:didFinishDownloadingTo:)`
/// because URLSession deletes it after the delegate method returns.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int64
    private let progress: @Sendable (Double) -> Void
    private let continuation: CheckedContinuation<URL, Error>
    private var resumed = false

    init(
        destination: URL,
        expectedSize: Int64,
        progress: @Sendable @escaping (Double) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : expectedSize
        let fraction = Double(totalBytesWritten) / Double(max(total, 1))
        progress(min(fraction, 1.0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // MUST copy the file here -- URLSession deletes location after this returns.
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: location, to: destination)
        } catch {
            guard !resumed else { return }
            resumed = true
            continuation.resume(throwing: EsVirituDatabaseError.downloadFailed(error.localizedDescription))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !resumed else { return }
        resumed = true

        if let error {
            continuation.resume(throwing: EsVirituDatabaseError.downloadFailed(error.localizedDescription))
        } else {
            continuation.resume(returning: destination)
        }
    }
}
