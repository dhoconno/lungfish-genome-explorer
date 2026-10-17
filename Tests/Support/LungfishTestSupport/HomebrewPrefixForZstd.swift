// HomebrewPrefixForZstd.swift - Let a test find the Homebrew zstd as a shell that ran `brew shellenv` does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The zstd lookup of `SequenceExportCompressor` takes the Homebrew prefix from the `HOMEBREW_PREFIX` variable,
/// because no source file names that prefix (Phase 2.11, Q66 fix a). A shell that ran `brew shellenv` carries the
/// variable, and a test process under a plain launch does not. A test that needs the zstd of Homebrew calls this
/// first, and the variable then holds what `brew shellenv` would set.
public enum HomebrewPrefixForZstd {
    /// Sets `HOMEBREW_PREFIX` to the Apple silicon prefix when the variable is unset and a zstd sits in that
    /// prefix. A Mac whose environment already names a prefix keeps it, and a Mac with no such zstd is left alone.
    public static func exposeIfNeeded() {
        guard getenv("HOMEBREW_PREFIX") == nil else { return }
        let prefix = "/opt/homebrew"
        guard FileManager.default.isExecutableFile(atPath: prefix + "/bin/zstd") else { return }
        setenv("HOMEBREW_PREFIX", prefix, 1)
    }
}
