// ProjectTempDirectory.swift - Project-local temp directory utility
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "ProjectTempDirectory")

// MARK: - TempScopePolicy

/// Policy controlling where temporary directories are created.
public enum TempScopePolicy: String, Sendable, Codable {
    /// Must create temp in project `.tmp/`. Throws if no project context found.
    case requireProjectContext
    /// Prefer project `.tmp/`, fall back to system temp if no project found.
    case preferProjectContext
    /// Always use system temp directory.
    case systemOnly
}

// MARK: - ProjectTempError

/// Errors from project temp directory operations.
public enum ProjectTempError: Error, LocalizedError {
    /// A `requireProjectContext` policy could not resolve a `.lungfish` project root.
    case projectContextRequired(contextURL: URL?)

    public var errorDescription: String? {
        switch self {
        case .projectContextRequired(let url):
            return "Project context required but no .lungfish root found above \(url?.path ?? "<nil>")"
        }
    }
}

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
    private static let lungfishExtension = "lungfish"

    // MARK: - findProjectRoot

    /// Walks up the directory tree from `url` to find the enclosing `.lungfish` project directory.
    ///
    /// Returns `nil` if no `.lungfish` ancestor is found before reaching the filesystem root.
    public static func findProjectRoot(_ url: URL) -> URL? {
        var current = url.standardizedFileURL
        // If url points to a file, start from its parent directory
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDir), !isDir.boolValue {
            current = current.deletingLastPathComponent()
        }

        // Walk up to filesystem root — no artificial depth limit
        while true {
            if current.pathExtension.lowercased() == lungfishExtension {
                return current
            }
            let parent = current.deletingLastPathComponent()
            // Stop when we reach filesystem root
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
        if let projectURL {
            let base = tempRoot(for: projectURL)
            let projectDescriptor: Int32
            do {
                projectDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(projectURL)
            } catch {
                throw OwnedWorkDirectoryMarkerError.unsafePath(projectURL.path)
            }
            defer { Darwin.close(projectDescriptor) }
            let createStatus = tmpDirName.withCString {
                Darwin.mkdirat(
                    projectDescriptor,
                    $0,
                    S_IRWXU | S_IRGRP | S_IXGRP
                )
            }
            if createStatus != 0, errno != EEXIST {
                throw OwnedWorkDirectoryMarkerError.systemFailure(
                    path: base.path,
                    operation: "create project temporary root",
                    code: errno
                )
            }
            guard Darwin.fsync(projectDescriptor) == 0 else {
                throw OwnedWorkDirectoryMarkerError.systemFailure(
                    path: projectURL.path,
                    operation: "fsync project temporary root",
                    code: errno
                )
            }
            let request = OwnedWorkDirectoryCreationRequest(
                projectURL: projectURL,
                parentDirectoryURL: base,
                prefix: prefix,
                runID: UUID(),
                processIdentity: try OwnedProcessIdentity.current(),
                state: .active,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "ProjectTempDirectory",
                toolVersion: currentToolVersion
            )
            let directory = try OwnedWorkDirectoryMarkerStore.createDirectory(request)
            logger.debug("Created attested project temp directory: \(directory.path, privacy: .public)")
            return directory
        }

        let base = FileManager.default.temporaryDirectory
        let dirName = "\(prefix)\(UUID().uuidString)"
        let dirURL = base.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        logger.debug("Created temp directory: \(dirURL.path, privacy: .public)")
        return dirURL
    }

    // MARK: - TempOriginMarker

    /// Provenance metadata written to each managed temp directory.
    public struct TempOriginMarker: Codable, Sendable {
        public let version: Int
        public let prefix: String
        public let policy: TempScopePolicy
        public let contextPath: String?
        public let resolvedProjectPath: String?
        public let pid: Int32
        public let createdAt: Date
        public let caller: String

        public static let fileName = ".lungfish-temp-origin.json"
        public static let currentVersion = 1
    }

    // MARK: - create (policy-aware)

    /// Creates a temp directory with explicit policy and provenance tracking.
    ///
    /// - Parameters:
    ///   - prefix: A string prepended to the UUID-based directory name.
    ///   - contextURL: Any URL inside a project (used to resolve project root). Can be nil for `systemOnly`.
    ///   - policy: Controls where the temp directory is created.
    ///   - caller: Auto-captured source location for provenance.
    ///   - line: Auto-captured source line for provenance.
    /// - Returns: URL of the newly created directory.
    public static func create(
        prefix: String,
        contextURL: URL?,
        policy: TempScopePolicy,
        caller: StaticString = #fileID,
        line: UInt = #line
    ) throws -> URL {
        let projectURL: URL?

        switch policy {
        case .requireProjectContext:
            guard let ctx = contextURL else {
                throw ProjectTempError.projectContextRequired(contextURL: nil)
            }
            guard let root = findProjectRoot(ctx) else {
                throw ProjectTempError.projectContextRequired(contextURL: ctx)
            }
            projectURL = root

        case .preferProjectContext:
            if let ctx = contextURL {
                projectURL = findProjectRoot(ctx)
                if projectURL == nil {
                    logger.warning("create(policy: preferProjectContext): no .lungfish root above \(ctx.path, privacy: .public) — falling back to system temp")
                }
            } else {
                projectURL = nil
            }

        case .systemOnly:
            projectURL = nil
        }

        let dirURL = try create(prefix: prefix, in: projectURL)

        // Write provenance marker
        let marker = TempOriginMarker(
            version: TempOriginMarker.currentVersion,
            prefix: prefix,
            policy: policy,
            contextPath: contextURL?.path,
            resolvedProjectPath: projectURL?.path,
            pid: ProcessInfo.processInfo.processIdentifier,
            createdAt: Date(),
            caller: "\(caller):\(line)"
        )
        writeMarker(marker, to: dirURL)

        return dirURL
    }

    /// Reads the provenance marker from a temp directory, if present.
    public static func readMarker(from dirURL: URL) -> TempOriginMarker? {
        guard let descriptor = try? NoFollowFileSystem.openDirectoryHierarchy(dirURL) else {
            return nil
        }
        defer { Darwin.close(descriptor) }
        guard let data = try? NoFollowFileSystem.readRegularFile(
            named: TempOriginMarker.fileName,
            inDirectory: descriptor,
            displayPath: dirURL.path
        ) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TempOriginMarker.self, from: data)
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
        try create(prefix: prefix, contextURL: contextURL, policy: .preferProjectContext)
    }

    // MARK: - Private Helpers

    private static func writeMarker(_ marker: TempOriginMarker, to dirURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(marker) else { return }
        _ = try? DurableAtomicFileStore().create(
            data,
            named: TempOriginMarker.fileName,
            in: dirURL
        )
    }

    private static var currentToolVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return version?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? version!
            : "debug"
    }

    // MARK: - cleanAll

    /// Removes only terminal, attested children of the project `.tmp/`.
    ///
    /// This compatibility entry point intentionally leaves the root, active
    /// work, explicitly retained work, and unmarked legacy children untouched.
    public static func cleanAll(in projectURL: URL) throws {
        let root = tempRoot(for: projectURL)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in contents {
            guard let marker = try? OwnedWorkDirectoryMarkerStore.load(
                from: entry,
                expectedProjectURL: projectURL
            ),
            marker.state != .active,
            !marker.keepIntermediates else {
                continue
            }
            try FileManager.default.removeItem(at: entry)
            logger.info("cleanAll: removed attested terminal child \(entry.path, privacy: .public)")
        }
    }

    // MARK: - cleanStale

    /// Removes terminal, attested children inside `.tmp/` whose modification
    /// date is older than `maxAge`.
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
            guard modDate < cutoff,
                  let marker = try? OwnedWorkDirectoryMarkerStore.load(
                    from: entry,
                    expectedProjectURL: projectURL
                  ),
                  marker.state != .active,
                  !marker.keepIntermediates else {
                continue
            }
            try FileManager.default.removeItem(at: entry)
            logger.info("cleanStale: removed \(entry.lastPathComponent, privacy: .public) (modified \(modDate))")
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
