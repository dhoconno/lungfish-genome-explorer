// DemoProjectInstaller.swift - Download, verify, unpack and install demo projects
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What the installer writes into every demo project it installs, as `.lgedemo.json`.
public struct DemoProjectInstallRecord: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let sha256: String
    public let installedAt: Date

    public init(id: String, version: String, sha256: String, installedAt: Date) {
        self.id = id
        self.version = version
        self.sha256 = sha256
        self.installedAt = installedAt
    }
}

/// Whether a demo project is on disk, and whether the copy on disk is current.
public enum DemoProjectInstallStatus: Sendable, Equatable {
    case notDownloaded
    /// Installed. `version` is nil when the folder has no readable `.lgedemo.json`.
    case downloaded(version: String?)
    case updateAvailable(installedVersion: String, availableVersion: String)

    public var isInstalled: Bool {
        if case .notDownloaded = self { return false }
        return true
    }

    /// Short label shared by the app and `lungfish-cli demo list`.
    public var label: String {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .downloaded: return "Downloaded"
        case .updateAvailable: return "Update available"
        }
    }

    /// Machine-readable token for JSON output.
    public var token: String {
        switch self {
        case .notDownloaded: return "not-downloaded"
        case .downloaded: return "downloaded"
        case .updateAvailable: return "update-available"
        }
    }
}

/// Progress phases reported while installing.
public enum DemoProjectInstallPhase: Sendable, Equatable {
    case downloading(bytesReceived: Int64, totalBytes: Int64?)
    case verifying
    case extracting
    case installing
}

/// Outcome of a successful install.
public struct DemoProjectInstallResult: Sendable, Equatable {
    public let projectURL: URL
    /// Where the previous copy went when it was replaced (nil when nothing was replaced).
    public let previousCopyTrashURL: URL?
    public let replacedPreviousCopy: Bool
}

/// Downloads, verifies, safely unpacks and installs demo projects.
///
/// Shared by Help > Demo Projects… and `lungfish-cli demo fetch`. Nothing is
/// written at the final location until the archive has passed its size and
/// SHA-256 checks and unpacked cleanly into a hidden staging folder beside it;
/// the finished project is then moved into place with a single rename. A
/// replaced copy goes to the Trash, never a permanent delete.
public struct DemoProjectInstaller: Sendable {
    public static let recordFileName = ".lgedemo.json"
    public static let defaultFolderName = "LGE Demo Projects"
    static let stagingPrefix = ".lge-demo-staging-"

    /// Moves an item to the Trash and returns where it went.
    public typealias TrashHandler = @Sendable (URL) throws -> URL?

    public let loader: any DemoProjectArchiveLoading
    public let extractor: SafeZipExtractor
    public let appVersion: String
    private let trash: TrashHandler
    private let now: @Sendable () -> Date

    public init(
        loader: any DemoProjectArchiveLoading = URLSessionDemoProjectArchiveLoader(),
        extractor: SafeZipExtractor = SafeZipExtractor(),
        appVersion: String = LungfishAppVersion.short,
        trash: @escaping TrashHandler = DemoProjectInstaller.moveToTrash,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loader = loader
        self.extractor = extractor
        self.appVersion = appVersion
        self.trash = trash
        self.now = now
    }

    /// `~/Documents/LGE Demo Projects`.
    public static func defaultInstallDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(defaultFolderName, isDirectory: true)
    }

    /// The production trash handler.
    public static let moveToTrash: TrashHandler = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    // MARK: - Status

    public static func projectURL(for project: DemoProject, in directory: URL) -> URL {
        directory.appendingPathComponent(project.projectFolderName, isDirectory: true)
    }

    public static func readRecord(inProjectAt projectURL: URL) -> DemoProjectInstallRecord? {
        let url = projectURL.appendingPathComponent(recordFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DemoProjectInstallRecord.self, from: data)
    }

    public static func status(for project: DemoProject, in directory: URL) -> DemoProjectInstallStatus {
        let projectURL = projectURL(for: project, in: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .notDownloaded
        }
        guard let record = readRecord(inProjectAt: projectURL), record.id == project.id else {
            return .downloaded(version: nil)
        }
        if record.version != project.version {
            return .updateAvailable(installedVersion: record.version, availableVersion: project.version)
        }
        return .downloaded(version: record.version)
    }

    // MARK: - Verification

    /// Checks the archive's byte count, then its SHA-256.
    public static func verifyArchive(
        at url: URL,
        expectedBytes: Int64,
        expectedSHA256: String
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualBytes == expectedBytes else {
            throw DemoProjectError.sizeMismatch(expected: expectedBytes, actual: actualBytes)
        }
        let digest = try FileDigest.sha256(of: url) {
            if Task.isCancelled { throw DemoProjectError.cancelled }
        }
        guard digest.lowercased() == expectedSHA256.lowercased() else {
            throw DemoProjectError.checksumMismatch(expected: expectedSHA256.lowercased(), actual: digest)
        }
    }

    // MARK: - Install

    /// Downloads, verifies and installs `project` into `directory`.
    ///
    /// - Parameter replaceExisting: When false and the project folder already
    ///   exists, throws ``DemoProjectError/alreadyInstalled(_:)`` before any
    ///   download. When true the existing folder is moved to the Trash only
    ///   after the new copy has been verified and unpacked.
    public func install(
        _ project: DemoProject,
        into directory: URL,
        replaceExisting: Bool,
        progress: @escaping @Sendable (DemoProjectInstallPhase) -> Void = { _ in }
    ) async throws -> DemoProjectInstallResult {
        try project.ensurePublished()
        guard project.isSupported(byAppVersion: appVersion) else {
            throw DemoProjectError.requiresNewerApp(title: project.title, minimumVersion: project.minimumAppVersion ?? "")
        }

        let fileManager = FileManager.default
        let targetURL = Self.projectURL(for: project, in: directory)
        if fileManager.fileExists(atPath: targetURL.path), !replaceExisting {
            throw DemoProjectError.alreadyInstalled(targetURL)
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DemoProjectError.installFailed("the folder \(directory.path) could not be created (\(error.localizedDescription))")
        }

        // Staging lives beside the destination so the final move is a same-volume rename.
        let stagingURL = directory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stagingURL) }

        let archiveURL = stagingURL.appendingPathComponent("archive.zip")
        progress(.downloading(bytesReceived: 0, totalBytes: project.archive.bytes))
        let expectedBytes = project.archive.bytes
        try await loader.download(from: project.archive.url, to: archiveURL) { received, total in
            progress(.downloading(bytesReceived: received, totalBytes: total ?? expectedBytes))
        }
        try checkCancellation()

        progress(.verifying)
        try Self.verifyArchive(at: archiveURL, expectedBytes: project.archive.bytes, expectedSHA256: project.archive.sha256)
        try checkCancellation()

        progress(.extracting)
        let extractedURL = stagingURL.appendingPathComponent("extracted", isDirectory: true)
        try await extractor.extract(archiveURL, to: extractedURL)
        try? fileManager.removeItem(at: archiveURL)
        try checkCancellation()

        progress(.installing)
        let unpackedProjectURL = try Self.locateProjectFolder(in: extractedURL, expectedName: project.projectFolderName)
        try writeRecord(for: project, into: unpackedProjectURL)
        try checkCancellation()

        var trashedURL: URL?
        var replaced = false
        if fileManager.fileExists(atPath: targetURL.path) {
            do {
                trashedURL = try trash(targetURL)
                replaced = true
            } catch {
                throw DemoProjectError.installFailed(
                    "the existing copy at \(targetURL.path) could not be moved to the Trash (\(error.localizedDescription))"
                )
            }
        }
        do {
            try fileManager.moveItem(at: unpackedProjectURL, to: targetURL)
        } catch {
            let note = replaced ? " The previous copy is in the Trash." : ""
            throw DemoProjectError.installFailed(
                "the project could not be moved to \(targetURL.path) (\(error.localizedDescription)).\(note)"
            )
        }
        return DemoProjectInstallResult(projectURL: targetURL, previousCopyTrashURL: trashedURL, replacedPreviousCopy: replaced)
    }

    /// Finds the project folder inside an unpacked archive.
    ///
    /// Accepts the expected `<projectFolderName>` at the archive root, or a
    /// single top-level `*.lungfish` folder under another name.
    static func locateProjectFolder(in extractedURL: URL, expectedName: String) throws -> URL {
        let fileManager = FileManager.default
        let expected = extractedURL.appendingPathComponent(expectedName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: expected.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return expected
        }
        let children = (try? fileManager.contentsOfDirectory(
            at: extractedURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = children.filter { url in
            guard url.lastPathComponent != "__MACOSX", url.pathExtension == "lungfish" else { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        if candidates.count == 1 { return candidates[0] }
        throw DemoProjectError.projectFolderMissing(expectedName)
    }

    private func writeRecord(for project: DemoProject, into projectURL: URL) throws {
        let record = DemoProjectInstallRecord(
            id: project.id,
            version: project.version,
            sha256: project.archive.sha256.lowercased(),
            installedAt: now()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(record).write(to: projectURL.appendingPathComponent(Self.recordFileName), options: .atomic)
        } catch {
            throw DemoProjectError.installFailed("the demo record could not be written (\(error.localizedDescription))")
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw DemoProjectError.cancelled }
    }
}
