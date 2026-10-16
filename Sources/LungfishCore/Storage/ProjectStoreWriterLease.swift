// ProjectStoreWriterLease.swift - The writer lock a writable project store holds
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Storage & Indexing Lead (Role 18)

import Foundation

final class ProjectStoreWriterLease: @unchecked Sendable {
    let lockURL: URL
    let record: ProjectLockRecord
    private let synchronization: ProjectStoreSynchronization
    init(lockURL: URL, record: ProjectLockRecord, synchronization: ProjectStoreSynchronization) {
        self.lockURL = lockURL
        self.record = record
        self.synchronization = synchronization
    }
    deinit {
        synchronization.leaseLock.lock()
        defer { synchronization.leaseLock.unlock() }
        let manager = ProjectLockManager()
        if (try? manager.readLock(at: lockURL)) == record {
            try? manager.removeLockIfPresent(at: lockURL)
        }
    }
}
