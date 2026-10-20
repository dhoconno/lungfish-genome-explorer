// ExecutablePathSearch.swift - Finds a program in the directories of a PATH string, with no process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Finds a program by name in the directories of a `PATH` string, the way `which` does, without
/// starting a process (Phase 2.13 lane 13.11).
///
/// Three callers used to run `/usr/bin/which` for this and wait for it with no limit: the CLI locator,
/// `lungfish-cli debug env` and the Docker check of the container factory. The search reads the file
/// system only, so it cannot hang and it costs microseconds.
public enum ExecutablePathSearch {
    /// Returns the first directory entry of `path` that holds a regular file called `name` with an
    /// execute permission, or nil.
    ///
    /// A directory of that name, a file without an execute permission and an empty `PATH` entry are
    /// skipped. `which` reads an empty entry as the current directory, and a search that does would let
    /// a file in the working folder stand in for a tool. A name with a slash is not searched, since
    /// `which` treats it as a path.
    ///
    /// - Parameters:
    ///   - name: A bare program name such as `docker`.
    ///   - path: The colon-separated directories, normally `ProcessInfo.processInfo.environment["PATH"]`.
    ///   - fileManager: The file system to read.
    public static func find(
        _ name: String,
        inPath path: String?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !name.isEmpty, !name.contains("/"), let path, !path.isEmpty else { return nil }
        for entry in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path)
            else { continue }
            return candidate
        }
        return nil
    }
}
