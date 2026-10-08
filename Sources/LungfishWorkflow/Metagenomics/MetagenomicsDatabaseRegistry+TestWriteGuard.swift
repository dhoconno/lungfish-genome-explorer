// MetagenomicsDatabaseRegistry+TestWriteGuard.swift - Keeps test installs out of real managed storage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore

extension MetagenomicsDatabaseRegistry {
    /// Stops a test process before an install writes the manifest or downloads
    /// into the user's real managed storage.
    func checkTestProcessWrite(operation: String) {
        let base = storageConfigStore?.currentLocation().databaseRootURL ?? databasesBaseURL
        ManagedStorageTestWriteGuard.checkWrite(to: base, operation: operation)
    }
}
