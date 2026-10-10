// ManagedToolLockIdentity.swift - The identity of the bundled managed tool lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Which lock is in force: its version, its dependency set and the SHA-256 of its exact bytes.
///
/// `fileSHA256` is the lowercase hex digest of the lock file as read, so a whitespace edit
/// changes it while `manifestHash`, which hashes the decoded model, stays equal.
public struct ManagedToolLockIdentity: Sendable, Hashable {
    public let lockVersion: String
    public let dependencySet: String
    public let fileSHA256: String

    /// `lock` must have been decoded from `lockData`.
    public init(lock: ManagedToolLock, lockData: Data) {
        self.lockVersion = lock.version
        self.dependencySet = lock.resolvedDependencySet
        self.fileSHA256 = SHA256.hash(data: lockData).map { String(format: "%02x", $0) }.joined()
    }

    /// The identity of the lock file at `url`, nil when it cannot be read or decoded.
    static func read(at url: URL?) -> ManagedToolLockIdentity? {
        ManagedToolLock.readResource(at: url).map { ManagedToolLockIdentity(lock: $0.lock, lockData: $0.data) }
    }
}
