// CanonicalFilePath.swift - One physical path for identity comparisons across symlinks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Canonical file paths for identity comparisons.
///
/// Two paths that name the same file must compare equal even when one goes
/// through a symlink (`/tmp` is `/private/tmp` on macOS, and a project may sit
/// behind a symlinked folder). Foundation's `resolvingSymlinksInPath()` and
/// `standardizedFileURL` are not stable for this: both drop a leading
/// `/private` only when the result exists, so an output about to be created
/// under `/private/tmp` reads back as `/private/tmp/...` while its existing
/// parent reads back as `/tmp/...`. Provenance publication compares the two
/// and reports a transaction-generation conflict.
///
/// This helper uses `realpath(3)` on the longest existing prefix and appends
/// the components that do not exist yet unchanged, so an artifact has the
/// same canonical path before and after it is written.
public enum CanonicalFilePath {
    /// The physical path of `url`, with any not-yet-existing tail appended verbatim.
    public static func path(for url: URL) -> String {
        let standardized = url.standardizedFileURL.path
        var existing = standardized
        var pending: [String] = []
        while true {
            if let root = resolve(existing) {
                guard !pending.isEmpty else { return root }
                let tail = pending.reversed().joined(separator: "/")
                return root == "/" ? "/" + tail : root + "/" + tail
            }
            let parentURL = URL(fileURLWithPath: existing).deletingLastPathComponent()
            let parent = parentURL.path
            guard parent != existing, !existing.isEmpty else { return standardized }
            pending.append(URL(fileURLWithPath: existing).lastPathComponent)
            existing = parent
        }
    }

    /// The `realpath(3)` probes of one call, such as one sanitize pass over a
    /// record (plan decision S2).
    ///
    /// Each prefix is probed at most once, and a prefix that does not resolve
    /// answers for its descendants, because `realpath(3)` resolves a path
    /// through its prefixes. Below `/home` every probe asks autofs, so a
    /// record that names 35 such paths now costs the probes of its deepest
    /// one instead of hundreds. Keep a cache local to one call and pass it
    /// `inout`. Never keep one in a static, because the file system changes.
    public struct Cache {
        private var resolved: [String: String] = [:]
        private var unresolved: Set<String> = []

        public init() {}

        mutating func physicalPath(of path: String) -> String? {
            if let known = resolved[path] { return known }
            if unresolved.contains(path) || hasUnresolvedAncestor(path) { return nil }
            guard let physical = CanonicalFilePath.resolve(path) else {
                unresolved.insert(path)
                return nil
            }
            resolved[path] = physical
            return physical
        }

        private func hasUnresolvedAncestor(_ path: String) -> Bool {
            guard !unresolved.isEmpty else { return false }
            var ancestor = Substring(path)
            while let slash = ancestor.lastIndex(of: "/"), slash != ancestor.startIndex {
                ancestor = ancestor[..<slash]
                if unresolved.contains(String(ancestor)) { return true }
            }
            return false
        }
    }

    /// ``path(for:)`` with every probe memoized in `cache`. The result is
    /// byte for byte the uncached one. Parents are split off with string
    /// operations, because `URL(fileURLWithPath:)` stats each one.
    public static func path(for url: URL, cache: inout Cache) -> String {
        let standardized = url.standardizedFileURL.path
        var existing = standardized
        var pending: [String] = []
        while true {
            if let root = cache.physicalPath(of: existing) {
                guard !pending.isEmpty else { return root }
                let tail = pending.reversed().joined(separator: "/")
                return root == "/" ? "/" + tail : root + "/" + tail
            }
            guard let (parent, last) = split(existing), parent != existing else { return standardized }
            pending.append(last)
            existing = parent
        }
    }

    /// The parent and the last component of `path` as `URL(fileURLWithPath:)`
    /// splits them, with string operations for the usual spelling.
    private static func split(_ path: String) -> (parent: String, last: String)? {
        guard !path.isEmpty, path != "/" else { return nil }
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("//"),
              let slash = path.lastIndex(of: "/") else {
            let url = URL(fileURLWithPath: path)
            return (url.deletingLastPathComponent().path, url.lastPathComponent)
        }
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        return (parent, String(path[path.index(after: slash)...]))
    }

    /// Replaces `realpath(3)` for the current task, so a test can count the
    /// probes a canonicalization makes without asking autofs.
    @TaskLocal package static var canonicalizerOverride: (@Sendable (String) -> String?)?

    /// The physical path of an existing `path`, or nil when `realpath(3)`
    /// cannot resolve it.
    static func resolve(_ path: String) -> String? {
        if let canonicalizerOverride {
            return canonicalizerOverride(path)
        }
        guard let resolved = path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path(for:)` as a file URL.
    public static func url(for url: URL) -> URL {
        URL(fileURLWithPath: path(for: url), isDirectory: url.hasDirectoryPath)
    }

    /// The path of `url` relative to `root`, comparing physical paths, or nil
    /// when `url` is not `root` or below it. `root` itself yields `""`.
    ///
    /// Use this instead of `dropFirst(root.path.count + 1)`: a directory
    /// enumerator started at `/tmp/x` yields `/private/tmp/x/...` URLs, and a
    /// string-length cut then returns garbage such as `p/x/file`.
    public static func relativePath(of url: URL, within root: URL) -> String? {
        let rootPath = path(for: root)
        let filePath = path(for: url)
        if filePath == rootPath { return "" }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    /// True when `url` is `root` or below it, comparing physical paths.
    public static func isPath(_ url: URL, within root: URL) -> Bool {
        relativePath(of: url, within: root) != nil
    }
}

extension URL {
    /// The physical path of this file URL; see `CanonicalFilePath`.
    public var canonicalFilePath: String { CanonicalFilePath.path(for: self) }

    /// This file URL on its physical path; see `CanonicalFilePath`.
    public var canonicalFileURL: URL { CanonicalFilePath.url(for: self) }
}
