// DatabaseRegistry+LockCheck.swift - A managed install checks the staged index against the lock's pin
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension DatabaseRegistry {
    /// Finds a database's entry in the bundled lock. A registry uses it unless it is handed another lookup.
    static let bundledLockLookup: ManagedDatabaseLockLookup = { ManagedToolLock.bundled.database(id: $0) }

    /// Reports the install's check step and, when the lock pins the database's bytes with `sha256` and
    /// `sizeBytes`, refuses a staged index that does not match them, before it replaces the installed file. An
    /// entry without `sha256`, such as `deacon-ribokmers`, which each install builds on its host, is not checked
    /// (CHTC lane L5-RECORDS M2). `lock` finds the entry, in the bundled lock unless a test hands the registry
    /// a lookup that pins its own fixture.
    nonisolated static func checkStagedIndexAgainstLock(
        _ stagedURL: URL,
        manifest: BundledDatabase,
        lock: ManagedDatabaseLockLookup = DatabaseRegistry.bundledLockLookup,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        progress?(0.88, "Checking \(manifest.displayName)…")
        guard let spec = lock(manifest.id),
              let pinnedSHA256 = spec.sha256?.lowercased() else {
            return
        }
        func refusal(_ reason: String) -> HumanScrubberDatabaseError {
            .installationFailed(databaseID: manifest.id, displayName: manifest.displayName, reason: reason)
        }
        let size = try ProvenanceFileHasher.fileSize(of: stagedURL)
        if let pinnedSize = spec.sizeBytes, UInt64(clamping: pinnedSize) != size {
            throw refusal("The index is \(size) bytes, and the bundled lock pins \(pinnedSize) bytes.")
        }
        let digest = try ProvenanceFileHasher.sha256(of: stagedURL)
        guard digest == pinnedSHA256 else {
            throw refusal("The index's SHA-256 is \(digest), and the bundled lock pins \(pinnedSHA256).")
        }
    }
}
