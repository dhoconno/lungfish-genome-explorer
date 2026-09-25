// PhysicalPathContainment.swift - Path containment checks that agree across /tmp and /private/tmp
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Compares file locations by their physical path, so a directory named
/// through a symbolic link (`/tmp`, `/var`) and a file named through its
/// target (`/private/tmp`, `/private/var`) still nest.
///
/// `URL.standardizedFileURL` is not enough for this: it strips a leading
/// `/private` only when the shortened path exists on disk, so an existing
/// output directory `/private/tmp/run` standardizes to `/tmp/run` while a
/// not-yet-written file inside it keeps `/private/tmp/run/out.json`.
public enum PhysicalPathContainment {

    /// The physical path of `url`: symbolic links in its longest existing
    /// ancestor are resolved with `realpath(3)`, and the components that do
    /// not exist yet are appended unchanged (after `.` and `..` are removed).
    public static func physicalPath(of url: URL) -> String {
        let lexical = NSString(string: url.path).standardizingPath
        var existing = lexical
        var pending: [String] = []
        while existing != "/", !existing.isEmpty {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return pending.reversed().reduce(base) {
                    NSString(string: $0).appendingPathComponent($1)
                }
            }
            pending.append(NSString(string: existing).lastPathComponent)
            existing = NSString(string: existing).deletingLastPathComponent
        }
        return lexical
    }

    /// The path of `fileURL` relative to `directoryURL`, comparing physical
    /// paths, or `nil` when the file is not strictly inside the directory.
    public static func relativePath(of fileURL: URL, within directoryURL: URL) -> String? {
        let directory = physicalPath(of: directoryURL)
        let file = physicalPath(of: fileURL)
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        guard file.hasPrefix(prefix), file.count > prefix.count else { return nil }
        return String(file.dropFirst(prefix.count))
    }
}
