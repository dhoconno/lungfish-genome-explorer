// ProjectWriterLeaseRecords.swift - The lock records this process's live writer leases hold
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Storage & Indexing Lead (Role 18)

import Foundation
import Synchronization

/// The lock record of every writer lease this process holds, one entry per lease. A lock
/// status check asks it whether a record that names this process is still held here
/// (3.0 WF-2). An entry stays until the lease's `deinit` has removed its lock file, so a
/// record is never read as unheld while its file is on disk. The mutex guards plain
/// values and takes no other lock, and nothing that runs under it can free a lease.
enum ProjectWriterLeaseRecords {
    private static let held = Mutex<[ProjectLockRecord]>([])

    /// Adds the record of `lease` and returns `lease`, so the caller keeps one line where it creates a lease.
    static func register(_ lease: ProjectStoreWriterLease) -> ProjectStoreWriterLease {
        held.withLock { $0.append(lease.record) }
        return lease
    }

    /// Removes one entry for `record`. The lease's `deinit` calls it last, with its `leaseLock` held.
    static func remove(_ record: ProjectLockRecord) {
        held.withLock { records in
            if let index = records.firstIndex(of: record) { records.remove(at: index) }
        }
    }

    static func containsLiveLease(holding record: ProjectLockRecord) -> Bool {
        held.withLock { $0.contains(record) }
    }
}

extension ProjectStore {
    /// Whether a writer lease that this process still holds wrote `record`. Unlike
    /// `ownsWriterLease(at:)` it does not read the lock file, so it holds for a lease
    /// whose project folder moved while open.
    public static func hasLiveWriterLease(holding record: ProjectLockRecord) -> Bool {
        ProjectWriterLeaseRecords.containsLiveLease(holding: record)
    }
}
