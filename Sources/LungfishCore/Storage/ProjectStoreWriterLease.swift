// ProjectStoreWriterLease.swift - The writer lock a writable project store holds
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Storage & Indexing Lead (Role 18)

import Foundation

/// The lock a writable project store holds. It keeps the project folder open
/// for events only, so a release finds the lock after the folder moves (2.11 S60).
/// O_EVTONLY never blocks an eject, and O_CLOEXEC keeps the descriptor out of tools.
final class ProjectStoreWriterLease: @unchecked Sendable {
    let lockURL: URL
    let record: ProjectLockRecord
    private let synchronization: ProjectStoreSynchronization
    private let folder: Int32
    init(lockURL: URL, projectURL: URL, record: ProjectLockRecord, synchronization: ProjectStoreSynchronization) {
        self.lockURL = lockURL
        self.record = record
        self.synchronization = synchronization
        self.folder = open(projectURL.path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
    }

    /// The lock where the folder is now, or where it was taken when the kernel
    /// cannot name the folder (deleted, or its volume is gone).
    private var currentLockURL: URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard folder >= 0, fcntl(folder, F_GETPATH, &buffer) != -1 else { return lockURL }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return ProjectLockManager.lockURL(for: URL(fileURLWithPath: path, isDirectory: true))
    }

    deinit {
        defer { if folder >= 0 { close(folder) } }
        synchronization.leaseLock.lock()
        defer { synchronization.leaseLock.unlock() }
        let manager = ProjectLockManager()
        let current = currentLockURL
        if (try? manager.readLock(at: current)) == record {
            try? manager.removeLockIfPresent(at: current)
        }
        ProjectWriterLeaseRecords.remove(record)
    }
}
