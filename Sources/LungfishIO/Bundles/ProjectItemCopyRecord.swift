// ProjectItemCopyRecord.swift - Cross-project copy receipt and missing-source model
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// When a bundle or an analysis result folder is copied from one project into
// another, its sidecar JSON files still point at source data in the project it
// came from (the input FASTQ bundle, the source reference bundle, the classifier
// database). Those links are allowed to break. The copy must still land, still
// be recognised by the sidebar, and still open. What the new project owes the
// user is a clear list of which source data is not available here.
//
// `ProjectItemLinkRewriter` walks the copied item's JSON sidecars once, rewrites
// every path that can be resolved in the new project, and reports the rest.
// `ProjectItemCopyRecord` persists that outcome as `project-copy.json` inside
// the copied item so the Inspector and the viewport can show it later without
// re-deriving anything.

import Foundation
import os.log

private let copyRecordLogger = Logger(subsystem: "com.lungfish.io", category: "ProjectItemCopy")

// MARK: - Link

/// One path found in a copied item's sidecar that pointed at data in the
/// source project.
public struct ProjectItemCopyLink: Codable, Sendable, Equatable, Identifiable {
    /// Sidecar file, relative to the copied item.
    public let file: String
    /// JSON key path of the value, for example `config.inputFiles[0]`.
    public let keyPath: String
    /// The path exactly as it was stored in the source project.
    public let originalPath: String
    /// The absolute path this link now points at in the new project, or nil
    /// when the referenced data is not present there.
    public let resolvedPath: String?
    /// A short human label derived from the key, for example "Input reads".
    public let role: String

    public init(file: String, keyPath: String, originalPath: String, resolvedPath: String?, role: String) {
        self.file = file
        self.keyPath = keyPath
        self.originalPath = originalPath
        self.resolvedPath = resolvedPath
        self.role = role
    }

    public var id: String { "\(file)#\(keyPath)" }
    public var isResolved: Bool { resolvedPath != nil }

    /// The last path component of the original path, without a `file://` prefix.
    public var displayName: String {
        let name = URL(fileURLWithPath: ProjectItemLinkRewriter.plainPath(from: originalPath)).lastPathComponent
        return name.isEmpty ? originalPath : name
    }

    /// Whether the original path pointed inside a FASTQ read bundle.
    public var pointsIntoReadBundle: Bool {
        originalPath.lowercased().contains(".lungfishfastq")
    }
}

// MARK: - Record

/// Persisted receipt for an item copied between projects.
public struct ProjectItemCopyRecord: Codable, Sendable, Equatable {
    public static let filename = "project-copy.json"

    public var schemaVersion: Int = 1
    public let copiedAt: Date
    public let sourceItemPath: String
    public let sourceProjectPath: String?
    public let targetProjectPath: String
    public let links: [ProjectItemCopyLink]

    public init(
        copiedAt: Date,
        sourceItemPath: String,
        sourceProjectPath: String?,
        targetProjectPath: String,
        links: [ProjectItemCopyLink]
    ) {
        self.copiedAt = copiedAt
        self.sourceItemPath = sourceItemPath
        self.sourceProjectPath = sourceProjectPath
        self.targetProjectPath = targetProjectPath
        self.links = links
    }

    /// Unresolved links, one per distinct original path.
    public var unresolvedLinks: [ProjectItemCopyLink] {
        var seen = Set<String>()
        return links.filter { link in
            guard !link.isResolved else { return false }
            return seen.insert(link.originalPath).inserted
        }
    }

    public var hasMissingSources: Bool { !unresolvedLinks.isEmpty }

    /// True when the reads the result was computed from are not in this
    /// project, which is what read-level actions (extract, BLAST) need.
    public var missingSourceReads: Bool {
        unresolvedLinks.contains { $0.pointsIntoReadBundle || $0.role == ProjectItemLinkRewriter.Role.inputReads }
    }

    /// Display name of the project the item came from, or nil for a Finder copy.
    public var sourceProjectName: String? {
        guard let sourceProjectPath else { return nil }
        return URL(fileURLWithPath: sourceProjectPath).deletingPathExtension().lastPathComponent
    }

    /// One line per missing source, in the form the Inspector shows.
    public var missingSourceSummaryLines: [String] {
        unresolvedLinks.map { "Source data not in this project: \($0.displayName) (was \(ProjectItemLinkRewriter.plainPath(from: $0.originalPath)))" }
    }

    /// The reason given to a disabled read-level action.
    public var missingSourceReadsReason: String? {
        guard missingSourceReads else { return nil }
        let names = unresolvedLinks
            .filter { $0.pointsIntoReadBundle || $0.role == ProjectItemLinkRewriter.Role.inputReads }
            .map(\.displayName)
        let joined = names.prefix(3).joined(separator: ", ")
        return "Source reads are not in this project (\(joined))"
    }

    // MARK: Persistence

    public static func load(from itemURL: URL) -> ProjectItemCopyRecord? {
        let fileURL = itemURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ProjectItemCopyRecord.self, from: data)
        } catch {
            copyRecordLogger.warning("Could not decode \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func save(to itemURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try data.write(to: itemURL.appendingPathComponent(Self.filename), options: .atomic)
    }
}

// MARK: - Rewriter

/// Rewrites source-project paths inside a copied item's JSON sidecars.
///
/// Three kinds of stored path are handled:
/// - paths inside the copied item itself always move with it,
/// - absolute paths inside the source project move when the same
///   project-relative path exists in the new project,
/// - `@/` project-relative paths keep their text and are checked against the
///   new project.
/// Anything that cannot be resolved is left untouched and reported.
public enum ProjectItemLinkRewriter {

    public enum Role {
        public static let inputReads = "Input reads"
        public static let database = "Classifier database"
        public static let referenceBundle = "Reference bundle"
        public static let originBundle = "Origin bundle"
        public static let viewerBundle = "Viewer bundle"
        public static let sourceData = "Source data"
        public static let linkedFile = "Linked file"
    }

    public struct Context: Sendable {
        public let sourceItemURL: URL
        public let destinationItemURL: URL
        public let sourceProjectURL: URL?
        public let targetProjectURL: URL

        public init(sourceItemURL: URL, destinationItemURL: URL, sourceProjectURL: URL?, targetProjectURL: URL) {
            self.sourceItemURL = sourceItemURL
            self.destinationItemURL = destinationItemURL
            self.sourceProjectURL = sourceProjectURL
            self.targetProjectURL = targetProjectURL
        }
    }

    /// Sidecars larger than this are left alone. Real sidecars are a few KB.
    static let maximumSidecarSize = 16 * 1024 * 1024

    /// Rewrites the sidecars under `context.destinationItemURL` in place and
    /// returns every source-project link that was found.
    public static func rewrite(context: Context, fileManager: FileManager = .default) throws -> [ProjectItemCopyLink] {
        let root = context.destinationItemURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        let resolver = PathResolver(context: context, fileManager: fileManager)
        var links: [ProjectItemCopyLink] = []

        for fileURL in sidecarURLs(under: root, fileManager: fileManager) {
            let relativeFile = relativePath(of: fileURL, under: root)
            guard let data = fileManager.contents(atPath: fileURL.path),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            var changed = false
            let rewritten = rewriteValue(
                json,
                keyPath: "",
                lastKey: nil,
                file: relativeFile,
                resolver: resolver,
                links: &links,
                changed: &changed
            )
            guard changed, JSONSerialization.isValidJSONObject(rewritten) else { continue }
            let output = try JSONSerialization.data(
                withJSONObject: rewritten,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try output.write(to: fileURL, options: .atomic)
        }
        return links
    }

    // MARK: Path forms

    /// Strips a `file://` prefix so a stored URL string reads as a plain path.
    public static func plainPath(from stored: String) -> String {
        if stored.hasPrefix("file://"), let url = URL(string: stored) {
            return url.path
        }
        return stored
    }

    private enum PathForm {
        case absolute
        case fileURL
        case projectRelative
    }

    private static func form(of string: String) -> (form: PathForm, path: String)? {
        if string.hasPrefix("file://") {
            guard let url = URL(string: string), url.isFileURL else { return nil }
            return (.fileURL, url.path)
        }
        if string.hasPrefix("@/") {
            return (.projectRelative, String(string.dropFirst(2)))
        }
        if string.hasPrefix("/"), string.count > 1 {
            return (.absolute, string)
        }
        return nil
    }

    private static func encode(_ path: String, as form: PathForm) -> String {
        switch form {
        case .absolute: return path
        case .fileURL: return URL(fileURLWithPath: path).absoluteString
        case .projectRelative: return "@/" + path
        }
    }

    // MARK: Resolution

    private struct PathResolver {
        let sourceItemPrefixes: [String]
        let destinationItemPath: String
        let sourceProjectPrefixes: [String]
        let targetProjectPath: String
        let destinationItemRelativePath: String?
        let sourceItemRelativePath: String?
        let fileManager: FileManager

        init(context: Context, fileManager: FileManager) {
            self.fileManager = fileManager
            sourceItemPrefixes = ProjectItemLinkRewriter.pathVariants(of: context.sourceItemURL)
            destinationItemPath = context.destinationItemURL.standardizedFileURL.path
            sourceProjectPrefixes = context.sourceProjectURL.map(ProjectItemLinkRewriter.pathVariants) ?? []
            targetProjectPath = context.targetProjectURL.standardizedFileURL.path
            destinationItemRelativePath = ProjectItemLinkRewriter.relative(
                path: destinationItemPath,
                toAny: ProjectItemLinkRewriter.pathVariants(of: context.targetProjectURL)
            )
            sourceItemRelativePath = sourceProjectPrefixes.isEmpty
                ? nil
                : ProjectItemLinkRewriter.relative(path: sourceItemPrefixes[0], toAny: sourceProjectPrefixes)
        }

        enum Outcome {
            case unchanged
            case movedWithItem(String)
            case resolved(newPath: String, absolute: String)
            case unresolved
        }

        func resolve(absolutePath path: String) -> Outcome {
            if let inside = ProjectItemLinkRewriter.relative(path: path, toAny: sourceItemPrefixes) {
                return .movedWithItem(inside.isEmpty ? destinationItemPath : destinationItemPath + "/" + inside)
            }
            guard let relative = ProjectItemLinkRewriter.relative(path: path, toAny: sourceProjectPrefixes) else {
                return .unchanged
            }
            let candidate = relative.isEmpty ? targetProjectPath : targetProjectPath + "/" + relative
            if fileManager.fileExists(atPath: candidate) {
                return .resolved(newPath: candidate, absolute: candidate)
            }
            return .unresolved
        }

        func resolve(projectRelativePath rest: String) -> Outcome {
            if let sourceItemRelativePath, let destinationItemRelativePath,
               let inside = ProjectItemLinkRewriter.relative(path: rest, toAny: [sourceItemRelativePath]) {
                let moved = inside.isEmpty ? destinationItemRelativePath : destinationItemRelativePath + "/" + inside
                return .movedWithItem(moved)
            }
            let candidate = rest.isEmpty ? targetProjectPath : targetProjectPath + "/" + rest
            if fileManager.fileExists(atPath: candidate) {
                return .resolved(newPath: rest, absolute: candidate)
            }
            return .unresolved
        }
    }

    /// Both the standardized and the symlink-resolved spelling of a location,
    /// so `/var` and `/private/var` sidecars match either way.
    public static func pathVariants(of url: URL) -> [String] {
        let standardized = url.standardizedFileURL.path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        return standardized == resolved ? [standardized] : [standardized, resolved]
    }

    /// The remainder of `path` below one of `prefixes`, "" when equal, nil when outside.
    public static func relative(path: String, toAny prefixes: [String]) -> String? {
        for prefix in prefixes {
            if path == prefix { return "" }
            let slashed = prefix.hasSuffix("/") ? prefix : prefix + "/"
            if path.hasPrefix(slashed) {
                return String(path.dropFirst(slashed.count))
            }
        }
        return nil
    }

    // MARK: JSON walk

    private static func rewriteValue(
        _ value: Any,
        keyPath: String,
        lastKey: String?,
        file: String,
        resolver: PathResolver,
        links: inout [ProjectItemCopyLink],
        changed: inout Bool
    ) -> Any {
        if let string = value as? String {
            guard let (form, path) = form(of: string) else { return string }
            let outcome: PathResolver.Outcome
            switch form {
            case .absolute, .fileURL:
                outcome = resolver.resolve(absolutePath: path)
            case .projectRelative:
                outcome = resolver.resolve(projectRelativePath: path)
            }
            switch outcome {
            case .unchanged:
                return string
            case .movedWithItem(let moved):
                let encoded = encode(moved, as: form)
                if encoded != string { changed = true }
                return encoded
            case .resolved(let newPath, let absolute):
                links.append(ProjectItemCopyLink(
                    file: file,
                    keyPath: keyPath,
                    originalPath: string,
                    resolvedPath: absolute,
                    role: role(forKey: lastKey)
                ))
                let encoded = encode(newPath, as: form)
                if encoded != string { changed = true }
                return encoded
            case .unresolved:
                links.append(ProjectItemCopyLink(
                    file: file,
                    keyPath: keyPath,
                    originalPath: string,
                    resolvedPath: nil,
                    role: role(forKey: lastKey)
                ))
                return string
            }
        }
        if let dictionary = value as? [String: Any] {
            var rewritten: [String: Any] = [:]
            for (key, child) in dictionary {
                if preservesExactInvocationValue(forKey: key) {
                    rewritten[key] = child
                    continue
                }
                let childPath = keyPath.isEmpty ? key : "\(keyPath).\(key)"
                rewritten[key] = rewriteValue(
                    child,
                    keyPath: childPath,
                    lastKey: key,
                    file: file,
                    resolver: resolver,
                    links: &links,
                    changed: &changed
                )
            }
            return rewritten
        }
        if let array = value as? [Any] {
            return array.enumerated().map { index, child in
                rewriteValue(
                    child,
                    keyPath: "\(keyPath)[\(index)]",
                    lastKey: lastKey,
                    file: file,
                    resolver: resolver,
                    links: &links,
                    changed: &changed
                )
            }
        }
        return value
    }

    /// Command lines are a historical record and are never rewritten.
    private static func preservesExactInvocationValue(forKey key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return [
            "argv", "args", "arguments", "command", "commandline",
            "executedcommand", "reproduciblecommand", "shellcommand", "durablereplayargv",
        ].contains(normalized)
    }

    static func role(forKey key: String?) -> String {
        let normalized = (key ?? "").lowercased()
        if normalized.contains("input") || normalized.contains("fastq") || normalized.contains("reads") {
            return Role.inputReads
        }
        if normalized.contains("database") || normalized.contains("db") {
            return Role.database
        }
        if normalized.contains("origin") { return Role.originBundle }
        if normalized.contains("viewer") { return Role.viewerBundle }
        if normalized.contains("reference") { return Role.referenceBundle }
        if normalized.contains("source") { return Role.sourceData }
        return Role.linkedFile
    }

    // MARK: File enumeration

    /// JSON sidecars under the item, skipping provenance records (they are a
    /// historical record and have their own rehydration) and this record.
    private static func sidecarURLs(under root: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if url.lastPathComponent == "provenance",
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "json",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !name.lowercased().contains("provenance"),
                  name != ProjectItemCopyRecord.filename else {
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maximumSidecarSize else { continue }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func relativePath(of file: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComponents = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.starts(with: rootComponents) else { return file.lastPathComponent }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
