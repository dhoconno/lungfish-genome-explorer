// ProjectTempDirectory.swift - Project-local temp directory utility
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "ProjectTempDirectory")

// MARK: - ProjectTempDirectory

/// Utility for creating and managing project-scoped temporary directories.
///
/// All temp files are written to `<project>.lungfish/.tmp/` so they stay
/// co-located with the project and are never confused with system temp files.
/// A system-temp fallback is provided when no project context is available.
///
/// ## Directory Layout
///
/// ```
/// myproject.lungfish/
///   .tmp/
///     classify-<UUID>/     ← one sub-dir per operation
///     map-<UUID>/
/// ```
///
/// ## Usage
///
/// ```swift
/// // Create a temp dir for a classifier run
/// let tmp = try ProjectTempDirectory.create(prefix: "classify-", in: projectURL)
/// defer { try? FileManager.default.removeItem(at: tmp) }
///
/// // Or resolve project root automatically from any URL inside the project
/// let tmp = try ProjectTempDirectory.createFromContext(prefix: "map-", contextURL: bundleURL)
/// ```
public enum ProjectTempDirectory {

    // MARK: - Private Constants

    private static let tmpDirName = ".tmp"
    private static let maxWalkDepth = 10
    private static let lungfishExtension = "lungfish"

    // MARK: - findProjectRoot

    /// Walks up the directory tree from `url` to find the enclosing `.lungfish` project directory.
    ///
    /// Returns `nil` if no `.lungfish` ancestor is found within `maxWalkDepth` levels.
    public static func findProjectRoot(_ url: URL) -> URL? {
        var current = url.standardizedFileURL
        // If url points to a file, start from its parent directory
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDir), !isDir.boolValue {
            current = current.deletingLastPathComponent()
        }

        for _ in 0..<maxWalkDepth {
            if current.pathExtension.lowercased() == lungfishExtension {
                return current
            }
            let parent = current.deletingLastPathComponent()
            // Stop when we can't go further up
            if parent.standardizedFileURL == current {
                break
            }
            current = parent
        }
        return nil
    }

    // MARK: - tempRoot

    /// Returns the `.tmp/` directory URL inside the given project directory.
    ///
    /// The directory is not created by this method.
    public static func tempRoot(for projectURL: URL) -> URL {
        projectURL.appendingPathComponent(tmpDirName, isDirectory: true)
    }

    // MARK: - create

    /// Creates a new uniquely-named subdirectory inside the project's `.tmp/` directory.
    ///
    /// If `projectURL` is `nil`, falls back to the system temporary directory.
    ///
    /// - Parameters:
    ///   - prefix: A string prepended to the UUID-based directory name.
    ///   - projectURL: The `.lungfish` project directory, or `nil` for system fallback.
    /// - Returns: URL of the newly created directory.
    public static func create(prefix: String, in projectURL: URL?) throws -> URL {
        let base: URL
        if let projectURL {
            base = tempRoot(for: projectURL)
        } else {
            base = FileManager.default.temporaryDirectory
        }

        let dirName = "\(prefix)\(UUID().uuidString)"
        let dirURL = base.appendingPathComponent(dirName, isDirectory: true)

        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        logger.debug("Created temp directory: \(dirURL.path, privacy: .public)")
        return dirURL
    }

    // MARK: - createFromContext

    /// Resolves the project root from any URL inside a project tree, then calls `create`.
    ///
    /// Falls back to system temp when `contextURL` is not inside a `.lungfish` project.
    ///
    /// - Parameters:
    ///   - prefix: A string prepended to the UUID-based directory name.
    ///   - contextURL: Any URL inside (or at) a `.lungfish` project.
    /// - Returns: URL of the newly created directory.
    public static func createFromContext(prefix: String, contextURL: URL) throws -> URL {
        let projectURL = findProjectRoot(contextURL)
        if projectURL == nil {
            logger.warning("createFromContext: no .lungfish project found above \(contextURL.path, privacy: .public) — falling back to system temp")
        }
        return try create(prefix: prefix, in: projectURL)
    }

    // MARK: - cleanAll

    /// Removes the entire `.tmp/` directory inside the project. Idempotent — does not throw if
    /// the directory does not exist.
    public static func cleanAll(in projectURL: URL) throws {
        let root = tempRoot(for: projectURL)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        try FileManager.default.removeItem(at: root)
        logger.info("cleanAll: removed \(root.path, privacy: .public)")
    }

    // MARK: - cleanStale

    /// Removes subdirectories inside `.tmp/` whose modification date is older than `maxAge`.
    ///
    /// Subdirectories modified more recently than `maxAge` are left untouched.
    /// Does nothing if `.tmp/` does not exist.
    ///
    /// - Parameters:
    ///   - projectURL: The `.lungfish` project directory.
    ///   - maxAge: Maximum age in seconds. Entries older than this are removed.
    public static func cleanStale(in projectURL: URL, olderThan maxAge: TimeInterval) throws {
        let root = tempRoot(for: projectURL)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )

        let cutoff = Date(timeIntervalSinceNow: -maxAge)
        for entry in contents {
            let attrs = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modDate = attrs?.contentModificationDate else { continue }
            if modDate < cutoff {
                try FileManager.default.removeItem(at: entry)
                logger.info("cleanStale: removed \(entry.lastPathComponent, privacy: .public) (modified \(modDate))")
            }
        }
    }

    // MARK: - diskUsage

    /// Returns the total number of bytes consumed by all files inside `.tmp/`.
    ///
    /// Returns `0` when `.tmp/` does not exist.
    public static func diskUsage(in projectURL: URL) -> UInt64 {
        let root = tempRoot(for: projectURL)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return 0
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += UInt64(attrs?.fileSize ?? 0)
        }
        return total
    }
}
