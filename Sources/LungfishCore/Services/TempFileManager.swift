// TempFileManager.swift - Temporary file housekeeping
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - TempFileManager

/// Manages cleanup of temporary files created by Lungfish.
///
/// This service handles housekeeping tasks to prevent disk space exhaustion:
/// - Cleaning up stale temp directories from previous sessions
/// - Removing orphaned files from interrupted operations
/// - Periodic cleanup during long-running operations
///
/// ## Usage
///
/// Call `cleanupOnLaunch()` during app startup to remove stale temp files:
///
/// ```swift
/// func applicationDidFinishLaunching(_ notification: Notification) {
///     Task {
///         await TempFileManager.shared.cleanupOnLaunch()
///     }
/// }
/// ```
public actor TempFileManager {

    // MARK: - Singleton

    /// Shared instance for app-wide temp file management.
    public static let shared = TempFileManager()

    // MARK: - Properties

    private let logger = Logger(
        subsystem: "com.lungfish.browser",
        category: "TempFileManager"
    )

    /// Prefixes used by Lungfish for temp directories.
    /// These are used to identify directories that can be safely cleaned up.
    private let lungfishTempPrefixes = [
        "lungfish-extract-",
        "lungfish-genbank-",
        "lungfish-genome-",
        "lungfish-batch-",
        ".lungfish-temp-",
        "lungfish-debug"
    ]

    /// Maximum age (in seconds) for temp files before they're considered stale.
    /// Default: 24 hours
    private let maxTempFileAge: TimeInterval = 24 * 60 * 60

    /// Tracks temp directories created during this session for cleanup.
    private var sessionTempDirectories: Set<URL> = []

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Performs cleanup of stale Lungfish temp files on app launch.
    ///
    /// This should be called early in the app lifecycle to reclaim disk space
    /// from previous sessions that may have crashed or been terminated.
    ///
    /// - Returns: The total bytes reclaimed.
    @discardableResult
    public func cleanupOnLaunch() async -> UInt64 {
        logger.info("Starting temp file cleanup on launch")

        var totalBytesReclaimed: UInt64 = 0

        // Clean up system temp directory
        let systemTempDir = FileManager.default.temporaryDirectory
        totalBytesReclaimed += await cleanupDirectory(systemTempDir)

        // Also check /tmp directly (macOS sometimes uses this)
        let tmpDir = URL(fileURLWithPath: "/tmp")
        if tmpDir != systemTempDir {
            totalBytesReclaimed += await cleanupDirectory(tmpDir)
        }

        // Check /private/tmp (the actual location on macOS)
        let privateTmpDir = URL(fileURLWithPath: "/private/tmp")
        if privateTmpDir != systemTempDir && privateTmpDir != tmpDir {
            totalBytesReclaimed += await cleanupDirectory(privateTmpDir)
        }

        // Check volume root for any misplaced temp files
        // (This can happen if code incorrectly constructs paths)
        let volumeRoot = URL(fileURLWithPath: "/")
        totalBytesReclaimed += await cleanupMisplacedFiles(in: volumeRoot)

        if totalBytesReclaimed > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let formattedSize = formatter.string(fromByteCount: Int64(totalBytesReclaimed))
            logger.info("Temp file cleanup complete: reclaimed \(formattedSize)")
        } else {
            logger.info("Temp file cleanup complete: no stale files found")
        }

        return totalBytesReclaimed
    }

    /// Registers a temp directory created during this session.
    ///
    /// Registered directories will be cleaned up when the session ends or
    /// when `cleanupSessionFiles()` is called.
    ///
    /// - Parameter url: The temp directory URL.
    public func registerSessionTempDirectory(_ url: URL) {
        sessionTempDirectories.insert(url)
        logger.debug("Registered session temp directory: \(url.path)")
    }

    /// Unregisters a temp directory (call after successful cleanup).
    ///
    /// - Parameter url: The temp directory URL.
    public func unregisterSessionTempDirectory(_ url: URL) {
        sessionTempDirectories.remove(url)
        logger.debug("Unregistered session temp directory: \(url.path)")
    }

    /// Cleans up all temp directories created during this session.
    ///
    /// Call this during app termination or when recovering from errors.
    ///
    /// - Returns: The total bytes reclaimed.
    @discardableResult
    public func cleanupSessionFiles() async -> UInt64 {
        logger.info("Cleaning up \(self.sessionTempDirectories.count) session temp directories")

        var totalBytesReclaimed: UInt64 = 0

        for url in sessionTempDirectories {
            totalBytesReclaimed += await removeItem(at: url)
        }

        sessionTempDirectories.removeAll()

        return totalBytesReclaimed
    }

    /// Cleans up a specific temp directory after an operation completes.
    ///
    /// - Parameter url: The temp directory to clean up.
    /// - Returns: The bytes reclaimed.
    @discardableResult
    public func cleanupTempDirectory(_ url: URL) async -> UInt64 {
        unregisterSessionTempDirectory(url)
        return await removeItem(at: url)
    }

    /// Creates a new temp directory for Lungfish operations.
    ///
    /// The directory is automatically registered for cleanup tracking.
    ///
    /// - Parameter prefix: The prefix for the directory name (e.g., "lungfish-extract-").
    /// - Returns: The URL of the created directory.
    /// - Throws: If the directory cannot be created.
    public func createTempDirectory(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        // Track this directory for potential cleanup
        sessionTempDirectories.insert(tempDir)

        logger.debug("Created temp directory: \(tempDir.path)")

        return tempDir
    }

    // MARK: - Private Methods

    /// Cleans up Lungfish temp files in a directory.
    private func cleanupDirectory(_ directory: URL) async -> UInt64 {
        let fileManager = FileManager.default
        var totalBytesReclaimed: UInt64 = 0

        guard fileManager.fileExists(atPath: directory.path) else {
            return 0
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            // Also check hidden files for .lungfish-temp- pattern
            let hiddenContents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            ).filter { $0.lastPathComponent.hasPrefix(".") }

            let allContents = contents + hiddenContents

            for itemURL in allContents {
                // Check if this is a Lungfish temp item
                let itemName = itemURL.lastPathComponent
                let isLungfishTemp = lungfishTempPrefixes.contains { itemName.hasPrefix($0) }

                guard isLungfishTemp else { continue }

                // Check if it's stale (older than maxTempFileAge)
                if await isStale(itemURL) {
                    logger.info("Removing stale temp item: \(itemURL.path)")
                    totalBytesReclaimed += await removeItem(at: itemURL)
                }
            }
        } catch {
            logger.warning("Failed to enumerate temp directory \(directory.path): \(error.localizedDescription)")
        }

        return totalBytesReclaimed
    }

    /// Cleans up Lungfish files that may have been misplaced at the volume root.
    private func cleanupMisplacedFiles(in directory: URL) async -> UInt64 {
        let fileManager = FileManager.default
        var totalBytesReclaimed: UInt64 = 0

        do {
            // Only look at top-level items (don't recurse into system directories)
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: []
            )

            for itemURL in contents {
                let itemName = itemURL.lastPathComponent

                // Check for Lungfish temp patterns at root (these should never be here)
                let isLungfishTemp = lungfishTempPrefixes.contains { itemName.hasPrefix($0) }

                // Also check for .lungfishref bundles that might be orphaned
                let isOrphanedBundle = itemName.hasSuffix(".lungfishref") && itemName.hasPrefix(".")

                if isLungfishTemp || isOrphanedBundle {
                    logger.warning("Found misplaced Lungfish file at volume root: \(itemURL.path)")
                    totalBytesReclaimed += await removeItem(at: itemURL)
                }
            }
        } catch {
            // Expected to fail if we don't have permissions - that's fine
            logger.debug("Could not scan volume root: \(error.localizedDescription)")
        }

        return totalBytesReclaimed
    }

    /// Checks if a file/directory is older than the max age threshold.
    private func isStale(_ url: URL) async -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modDate = resourceValues.contentModificationDate else {
                // If we can't get the date, assume it's stale
                return true
            }

            let age = Date().timeIntervalSince(modDate)
            return age > maxTempFileAge
        } catch {
            // If we can't read attributes, assume it's stale
            return true
        }
    }

    /// Removes an item and returns the bytes reclaimed.
    private func removeItem(at url: URL) async -> UInt64 {
        let fileManager = FileManager.default

        // Calculate size before removal
        let size = await calculateSize(of: url)

        do {
            try fileManager.removeItem(at: url)
            logger.info("Removed: \(url.path) (\(size) bytes)")
            return size
        } catch {
            logger.warning("Failed to remove \(url.path): \(error.localizedDescription)")
            return 0
        }
    }

    /// Calculates the total size of a file or directory.
    private func calculateSize(of url: URL) async -> UInt64 {
        // Run file enumeration on a background thread since FileManager.enumerator
        // is not available from async contexts
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let size = Self.calculateSizeSync(of: url)
                continuation.resume(returning: size)
            }
        }
    }

    /// Synchronous helper for calculating directory size.
    private static func calculateSizeSync(of url: URL) -> UInt64 {
        let fileManager = FileManager.default

        do {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .totalFileSizeKey, .fileSizeKey])

            if resourceValues.isDirectory == true {
                // For directories, enumerate and sum all contents
                var totalSize: UInt64 = 0

                if let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for case let fileURL as URL in enumerator {
                        let fileResourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
                        totalSize += UInt64(fileResourceValues?.fileSize ?? 0)
                    }
                }

                return totalSize
            } else {
                // For files, use the file size directly
                return UInt64(resourceValues.totalFileSize ?? resourceValues.fileSize ?? 0)
            }
        } catch {
            return 0
        }
    }
}
