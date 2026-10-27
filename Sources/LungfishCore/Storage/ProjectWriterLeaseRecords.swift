// ProjectWriterLeaseRecords.swift - The lock records this process's live writer leases hold
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Storage & Indexing Lead (Role 18)

import Foundation
import Synchronization

/// Every writer lease this process holds, by the lock record it wrote. A lock status
/// check asks it whether a record that names this process is still held here (3.0 WF-2).
///
/// The check runs while a project's lease lock is held, so this registry has its own
/// lock and takes no other lock while it holds that one. A lease leaves it when it is
/// freed, through the weak reference.
enum ProjectWriterLeaseRecords {
    private struct Entry {
        let record: ProjectLockRecord
        weak var lease: ProjectStoreWriterLease?
    }

    private static let entries = Mutex<[Entry]>([])

    /// Adds `lease` and returns it, so the caller keeps one line where it creates a lease.
    static func register(_ lease: ProjectStoreWriterLease) -> ProjectStoreWriterLease {
        entries.withLock { entries in
            entries.removeAll { $0.lease == nil }
            entries.append(Entry(record: lease.record, lease: lease))
        }
        return lease
    }

    static func containsLiveLease(holding record: ProjectLockRecord) -> Bool {
        entries.withLock { entries in
            entries.contains { $0.record == record && $0.lease != nil }
        }
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
