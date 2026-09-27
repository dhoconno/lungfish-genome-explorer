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
            if let resolved = existing.withCString({ realpath($0, nil) }) {
                defer { free(resolved) }
                let root = String(cString: resolved)
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
