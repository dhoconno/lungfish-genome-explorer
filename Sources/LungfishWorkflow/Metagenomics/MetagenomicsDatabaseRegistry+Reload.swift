// MetagenomicsDatabaseRegistry+Reload.swift - Reading the manifest again after another process changed it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

extension MetagenomicsDatabaseRegistry {
    /// Drops the rows held in memory and reads the manifest again, for a caller whose manifest
    /// another process changed. The Plugin Manager's database update runs `lungfish-cli conda db
    /// update` (Phase 2.10 lane A52), which replaces the folder and saves the manifest, and the
    /// app's registry would otherwise keep showing the version it loaded. The registry's file
    /// keeps its size baseline, so the method lives here and `databases` is module-internal.
    public func reloadFromDisk() throws {
        databases.removeAll()
        try loadIfNeeded()
    }
}
