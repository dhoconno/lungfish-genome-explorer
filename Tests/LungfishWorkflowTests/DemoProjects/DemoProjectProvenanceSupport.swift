// DemoProjectProvenanceSupport.swift - Shared pieces of the demo project provenance suites
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A released demo project is the one place in the repository where real,
// older provenance sidecars sit inside a real project. The suites in this
// folder install such a project with the real DemoProjectInstaller, read its
// provenance every way LGE reads it, and prove that no byte of the project
// moved. These helpers hold what both suites share. The reads themselves are
// in DemoProjectProvenanceReads.swift and the expected-file model is in
// DemoProjectProvenanceProjection.swift.

import CryptoKit
import Foundation
import LungfishCore
@testable import LungfishWorkflow

// MARK: - Fixture locations and the pinned catalogue entry

enum DemoProjectArchiveFixtures {
    static let mhcArchiveName = "lge-demo-mhc-genotyping-2026.9.58.zip"

    /// `Tests/Fixtures/demo-projects`, found from this file's own path.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demo-projects", isDirectory: true)
    }

    static var mhcArchiveURL: URL {
        directory.appendingPathComponent(mhcArchiveName)
    }

    static var mhcExpectedURL: URL {
        directory
            .appendingPathComponent("expected", isDirectory: true)
            .appendingPathComponent("mhc-genotyping-2026.9.58.provenance-projection.json")
    }

    /// The catalogue entry of the released archive, pinned here the way
    /// scripts/golden/captures.py pins it, so a newer demo release that
    /// changes the bundled catalogue cannot change this suite.
    static let mhcGenotyping = DemoProject(
        id: "mhc-genotyping",
        title: "MHC Genotyping",
        summary: "The released 2026.9.58 archive, pinned as a test fixture.",
        chapters: [],
        projectFolderName: "MHC Genotyping.lungfish",
        archive: DemoProject.Archive(
            url: URL(
                string: "https://github.com/dhoconno/lungfish-genome-explorer/releases/download/demo-projects/"
                    + mhcArchiveName
            )!,
            sha256: "f11b808067437ae3182efe31d50fc0a047857ae0a14cd20f564abd15b673fba0",
            bytes: 110_747
        ),
        version: "2026.9.58",
        minimumAppVersion: "2026.9.58"
    )
}

// MARK: - Installing through the real installer

enum DemoProjectInstallHarness {
    /// Installs `archive` for `project` with the real `DemoProjectInstaller`
    /// and a loader that serves a local copy, so nothing touches the network.
    ///
    /// The project lands three folders below `workRoot`, so the finder's
    /// five-level walk up from any item of the project stops inside `workRoot`
    /// and cannot reach a sidecar another test left in the temporary folder.
    /// The archive is copied into `workRoot` first, so no code reads the
    /// checked-in file directly.
    static func install(_ project: DemoProject, archive: URL, under workRoot: URL) async throws -> URL {
        let fileManager = FileManager.default
        let archives = workRoot.appendingPathComponent("archives", isDirectory: true)
        try fileManager.createDirectory(at: archives, withIntermediateDirectories: true)
        let archiveCopy = archives.appendingPathComponent(archive.lastPathComponent)
        try fileManager.copyItem(at: archive, to: archiveCopy)

        let trash = TestTrash(directory: workRoot.appendingPathComponent("Trash", isDirectory: true))
        let installer = DemoProjectInstaller(
            loader: FixtureArchiveLoader(fixtureURL: archiveCopy),
            appVersion: project.minimumAppVersion ?? project.version,
            trash: trash.handler,
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
        let installDirectory = workRoot
            .appendingPathComponent("sandbox", isDirectory: true)
            .appendingPathComponent("installs", isDirectory: true)
            .appendingPathComponent(DemoProjectInstaller.defaultFolderName, isDirectory: true)
        let result = try await installer.install(project, into: installDirectory, replaceExisting: false)
        return result.projectURL
    }

    /// A folder for exports, beside the install and never inside the project.
    static func exportRoot(under workRoot: URL) throws -> URL {
        let url = workRoot.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Whole-tree snapshot

/// Every entry of a project folder: relative path, kind, size, SHA-256,
/// permissions and modification time. Two snapshots are equal only when no
/// file was added, removed, rewritten (even with identical bytes) or touched.
struct DemoProjectTreeSnapshot: Equatable {
    struct Entry: Equatable {
        enum Kind: String {
            case file, directory, symlink, other
        }

        var kind: Kind
        var size: UInt64
        var sha256: String
        var permissions: Int
        var modified: TimeInterval
        var linkTarget: String

        var summary: String {
            "\(kind.rawValue) size \(size) sha256 \(sha256.prefix(12)) mode \(String(permissions, radix: 8)) mtime \(modified)"
        }
    }

    private(set) var entries: [String: Entry]

    var fileCount: Int { entries.values.filter { $0.kind == .file }.count }
    var directoryCount: Int { entries.values.filter { $0.kind == .directory }.count }

    static func capture(of root: URL) throws -> DemoProjectTreeSnapshot {
        let fileManager = FileManager.default
        var entries: [String: Entry] = [:]
        for relative in try fileManager.subpathsOfDirectory(atPath: root.path) {
            let path = root.appendingPathComponent(relative).path
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType
            let kind: Entry.Kind
            switch type {
            case .typeRegular: kind = .file
            case .typeDirectory: kind = .directory
            case .typeSymbolicLink: kind = .symlink
            default: kind = .other
            }
            var size: UInt64 = 0
            var digest = ""
            var linkTarget = ""
            switch kind {
            case .file:
                size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                digest = try sha256(ofFileAt: path)
            case .symlink:
                linkTarget = (try? fileManager.destinationOfSymbolicLink(atPath: path)) ?? ""
            case .directory, .other:
                break
            }
            entries[relative] = Entry(
                kind: kind,
                size: size,
                sha256: digest,
                permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1,
                modified: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0,
                linkTarget: linkTarget
            )
        }
        return DemoProjectTreeSnapshot(entries: entries)
    }

    /// What changed from `before` to `self`, one line per path, empty when nothing did.
    func differences(from before: DemoProjectTreeSnapshot) -> [String] {
        var lines: [String] = []
        for path in Set(before.entries.keys).union(entries.keys).sorted() {
            switch (before.entries[path], entries[path]) {
            case (nil, let after?):
                lines.append("added \(path) (\(after.summary))")
            case (let was?, nil):
                lines.append("removed \(path) (\(was.summary))")
            case (let was?, let after?) where was != after:
                lines.append("changed \(path) from [\(was.summary)] to [\(after.summary)]")
            default:
                break
            }
        }
        return lines
    }

    /// Streams the file, so a large archive member never sits in memory.
    static func sha256(ofFileAt path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Masking the reading machine out of decoded paths

/// Turns the paths a reader resolves for this Mac back into stable tokens.
///
/// The reader replaces `@/` with the installed project's path, `<tool-root>`
/// and `<storage-root>` with the managed roots of the process, and a
/// `<workspace>` path with a real temporary file when one still exists. None
/// of those belongs in a committed file. Masking maps each root back to a
/// token with the same prefix table the reader resolves with.
///
/// - `@/` stands for the installed project folder.
/// - `<tool-root>` and `<storage-root>` stand for the managed roots.
/// - `<tmp>` stands for any system temporary folder that the bytes record
///   literally, as the demo build recorded its scratch folder.
/// - `<workspace>` stands for itself. The reader leaves the placeholder alone
///   while the scratch file it names is missing, and a reader that began to
///   resolve it to a path that does not exist would show in the comparison.
///   The comparison is skipped on a Mac where the scratch file exists.
/// - A file parameter is the one place where the working directory sneaks in.
///   The decoder reads it with `URL(fileURLWithPath:)`, which puts the working
///   directory in front of a relative placeholder, so
///   `<working directory>/<workspace>/...` is turned back into
///   `<workspace>/...`.
struct DemoProvenancePathMask {
    private struct Rule {
        let prefix: String
        let followedBySlash: NSRegularExpression
        let slashToken: String
        let bare: NSRegularExpression
        let bareToken: String
    }

    private static let leadIn = "(?<![A-Za-z0-9_.~@<>/-])"
    private static let trailingNameCharacter = "[A-Za-z0-9_.~/-]"

    private let rules: [Rule]
    /// Every spelling of the project folder the masker removes.
    let projectPaths: [String]
    /// Every spelling of the working directory, apart from the root folder.
    private let workingDirectoryPaths: [String]

    init(
        projectURL: URL,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) {
        var found: [(prefix: String, token: String, bare: String)] = []
        var seen = Set<String>()
        func add(_ url: URL, token: String, bare: String) {
            for prefix in Self.spellings(of: url) {
                guard prefix.count > 1, seen.insert(prefix).inserted else { continue }
                found.append((prefix, token, bare))
            }
        }
        add(projectURL, token: "@", bare: "@/")
        let managed = PortablePath.defaultManagedRoots
        add(managed.toolRoot, token: "<tool-root>", bare: "<tool-root>")
        add(managed.storageRoot, token: "<storage-root>", bare: "<storage-root>")
        for root in PortablePath.defaultTemporaryRoots {
            add(root, token: "<tmp>", bare: "<tmp>")
        }
        // The working directory in front of a relative placeholder. At the
        // root folder the prefix is the placeholder with its leading slash.
        let workingSpellings = Self.spellings(of: workingDirectory)
        for spelling in workingSpellings {
            let prefix = (spelling == "/" ? "" : spelling) + "/<workspace>"
            guard seen.insert(prefix).inserted else { continue }
            found.append((prefix, "<workspace>", "<workspace>"))
        }
        workingDirectoryPaths = workingSpellings.filter { $0.count > 1 }
        // The longest prefix first, so the project wins over the temporary
        // folder it sits in.
        found.sort { $0.prefix.count > $1.prefix.count }
        projectPaths = found.filter { $0.token == "@" }.map(\.prefix)
        rules = found.compactMap { item -> Rule? in
            let escaped = NSRegularExpression.escapedPattern(for: item.prefix)
            guard let slash = try? NSRegularExpression(pattern: Self.leadIn + escaped + "(?=/)"),
                  let bare = try? NSRegularExpression(
                      pattern: Self.leadIn + escaped + "(?!\(Self.trailingNameCharacter))"
                  ) else { return nil }
            return Rule(
                prefix: item.prefix,
                followedBySlash: slash,
                slashToken: NSRegularExpression.escapedTemplate(for: item.token),
                bare: bare,
                bareToken: NSRegularExpression.escapedTemplate(for: item.bare)
            )
        }
    }

    func apply(_ text: String) -> String {
        guard text.contains("/") else { return text }
        var result = text
        for rule in rules where result.contains(rule.prefix) {
            result = Self.replace(rule.followedBySlash, with: rule.slashToken, in: result)
            result = Self.replace(rule.bare, with: rule.bareToken, in: result)
        }
        return result
    }

    /// Machine-specific text that survived masking in `text`.
    func leaks(in text: String) -> [String] {
        var needles = projectPaths + workingDirectoryPaths
        needles.append(NSHomeDirectory())
        needles.append(contentsOf: ["/Users/", "/private/", "/var/folders", "/tmp"])
        let temporary = NSTemporaryDirectory()
        needles.append(temporary.hasSuffix("/") ? String(temporary.dropLast()) : temporary)
        return Set(needles.filter { $0.count > 1 && text.contains($0) }).sorted()
    }

    /// `standardizedFileURL` and `resolvingSymlinksInPath` both drop a leading
    /// /private, so the physical spelling is added on its own.
    private static func spellings(of url: URL) -> [String] {
        [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path, CanonicalFilePath.path(for: url)]
            .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    private static func replace(_ regex: NSRegularExpression, with template: String, in text: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
