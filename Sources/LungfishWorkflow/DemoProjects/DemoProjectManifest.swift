// DemoProjectManifest.swift - Bundled catalogue of downloadable demo projects
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The bundled list of ready-to-analyse demo projects, one per conceptual
/// activity in the user manual.
///
/// The manifest ships as `Resources/DemoProjects/demo-projects.json` in the
/// LungfishWorkflow resource bundle so the app (Help > Demo Projects…) and
/// `lungfish-cli demo` read the same catalogue.
public struct DemoProjectManifest: Codable, Sendable, Equatable {
    /// The only schema version this build understands.
    public static let supportedSchemaVersion = 1

    /// Root that manifest chapter paths resolve against.
    public static let manualBaseURL = URL(string: "https://lungfish-genome-explorer.readthedocs.io/en/latest/")!

    /// Relative path of the manifest inside the LungfishWorkflow resource bundle.
    public static let bundledResourcePath = "DemoProjects/demo-projects.json"

    public let schemaVersion: Int
    public let projects: [DemoProject]

    public init(schemaVersion: Int = DemoProjectManifest.supportedSchemaVersion, projects: [DemoProject]) {
        self.schemaVersion = schemaVersion
        self.projects = projects
    }

    /// Looks up a project by id (exact, case-insensitive match).
    public func project(id: String) -> DemoProject? {
        projects.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    // MARK: - Loading

    /// Decodes and validates a manifest.
    public static func decode(from data: Data) throws -> DemoProjectManifest {
        let manifest: DemoProjectManifest
        do {
            manifest = try JSONDecoder().decode(DemoProjectManifest.self, from: data)
        } catch {
            throw DemoProjectError.invalidManifest("The demo project list could not be read: \(error.localizedDescription)")
        }
        try manifest.validate()
        return manifest
    }

    /// Loads and validates the manifest at `url`.
    public static func load(from url: URL) throws -> DemoProjectManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DemoProjectError.invalidManifest("The demo project list at \(url.path) could not be opened: \(error.localizedDescription)")
        }
        return try decode(from: data)
    }

    /// Location of the manifest bundled with this build.
    ///
    /// Release builds resolve it next to the installed app or CLI through
    /// ``RuntimeResourceLocator``; development builds fall back to SwiftPM's
    /// resource bundle.
    public static func bundledManifestURL() -> URL? {
        if let url = RuntimeResourceLocator.path(bundledResourcePath, in: .workflow) {
            return url
        }
        return Bundle.module.url(forResource: "demo-projects", withExtension: "json", subdirectory: "DemoProjects")
    }

    /// Loads the manifest bundled with this build.
    public static func loadBundled() throws -> DemoProjectManifest {
        guard let url = bundledManifestURL() else {
            throw DemoProjectError.invalidManifest("The demo project list is missing from this build of Lungfish Genome Explorer.")
        }
        return try load(from: url)
    }

    // MARK: - Validation

    /// Checks the structural rules every manifest must satisfy.
    ///
    /// A placeholder checksum (all zeros) is deliberately *not* an error here:
    /// the list must still display. It is refused when a download is attempted,
    /// see ``DemoProject/ensurePublished()``.
    public func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw DemoProjectError.invalidManifest(
                "The demo project list uses schema version \(schemaVersion), but this build understands version \(Self.supportedSchemaVersion). Update Lungfish Genome Explorer."
            )
        }
        var seen = Set<String>()
        for project in projects {
            try project.validate()
            guard seen.insert(project.id.lowercased()).inserted else {
                throw DemoProjectError.invalidManifest("The demo project list names “\(project.id)” more than once.")
            }
        }
    }
}

/// One downloadable demo project.
public struct DemoProject: Codable, Sendable, Equatable, Identifiable {
    public struct Chapter: Codable, Sendable, Equatable, Hashable {
        public let title: String
        public let path: String

        public init(title: String, path: String) {
            self.title = title
            self.path = path
        }

        /// Absolute URL of the chapter in the online manual.
        public var url: URL? {
            URL(string: path, relativeTo: DemoProjectManifest.manualBaseURL)?.absoluteURL
        }
    }

    public struct Archive: Codable, Sendable, Equatable {
        public let url: URL
        public let sha256: String
        public let bytes: Int64

        public init(url: URL, sha256: String, bytes: Int64) {
            self.url = url
            self.sha256 = sha256
            self.bytes = bytes
        }

        /// True while the manifest still carries the placeholder values that
        /// ship before the archive is published.
        public var isPlaceholder: Bool {
            bytes <= 0 || sha256.allSatisfy { $0 == "0" }
        }
    }

    public let id: String
    public let title: String
    public let summary: String
    public let chapters: [Chapter]
    public let projectFolderName: String
    public let archive: Archive
    public let version: String
    public let minimumAppVersion: String?

    public init(
        id: String,
        title: String,
        summary: String,
        chapters: [Chapter],
        projectFolderName: String,
        archive: Archive,
        version: String,
        minimumAppVersion: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.chapters = chapters
        self.projectFolderName = projectFolderName
        self.archive = archive
        self.version = version
        self.minimumAppVersion = minimumAppVersion
    }

    /// Whether this build of the app is new enough to open the project.
    public func isSupported(byAppVersion appVersion: String = LungfishAppVersion.short) -> Bool {
        guard let minimumAppVersion, !minimumAppVersion.isEmpty else { return true }
        return DemoProjectVersion.compare(appVersion, minimumAppVersion) != .orderedAscending
    }

    /// Throws when the manifest entry still carries placeholder archive values.
    public func ensurePublished() throws {
        if archive.isPlaceholder {
            throw DemoProjectError.archiveNotPublished(title: title)
        }
    }

    func validate() throws {
        func fail(_ message: String) -> DemoProjectError {
            .invalidManifest("Demo project “\(id)”: \(message)")
        }
        let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ idCharacters.contains($0) }) else {
            throw fail("the id must use only lowercase letters, digits and hyphens.")
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw fail("the title is empty.")
        }
        guard Self.isSafeFolderName(projectFolderName) else {
            throw fail("the project folder name “\(projectFolderName)” is not a plain folder name ending in .lungfish.")
        }
        guard archive.url.scheme?.lowercased() == "https", archive.url.host != nil else {
            throw fail("the archive URL must be an https URL.")
        }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard archive.sha256.count == 64, archive.sha256.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) else {
            throw fail("the archive SHA-256 must be 64 hexadecimal characters.")
        }
        guard archive.bytes >= 0 else {
            throw fail("the archive size cannot be negative.")
        }
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw fail("the version is empty.")
        }
        for chapter in chapters {
            guard Self.isSafeRelativePath(chapter.path), chapter.url != nil else {
                throw fail("the chapter path “\(chapter.path)” must be a relative manual path.")
            }
        }
    }

    static func isSafeFolderName(_ name: String) -> Bool {
        guard name.hasSuffix(".lungfish"), name.count > ".lungfish".count else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.hasPrefix(".") else { return false }
        return name != "." && name != ".."
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("://") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }
}

/// Dotted numeric version comparison ("2026.9.44" vs "2026.9.8").
public enum DemoProjectVersion {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}
