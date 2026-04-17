// SamtoolsLocator.swift - Shared samtools discovery helper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Centralized samtools discovery used by import, materialization, and viewer code.
public enum SamtoolsLocator {

    /// Returns the first executable samtools path that can be found.
    ///
    /// Search order:
    /// 1. Managed `~/.lungfish/conda/envs/samtools/bin/samtools`
    /// 2. Directories from an explicitly provided `searchPath`, when a caller
    ///    intentionally opts into an extra fallback (for example in tests).
    public static func locate(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPath: String? = nil
    ) -> String? {
        let fm = FileManager.default

        let managedSamtools = homeDirectory
            .appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("conda", isDirectory: true)
            .appendingPathComponent("envs", isDirectory: true)
            .appendingPathComponent("samtools", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("samtools")
        if fm.isExecutableFile(atPath: managedSamtools.path) {
            return managedSamtools.path
        }

        if let searchPath, !searchPath.isEmpty {
            for dir in searchPath.split(separator: ":") {
                let candidate = String(dir) + "/samtools"
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        return nil
    }
}
