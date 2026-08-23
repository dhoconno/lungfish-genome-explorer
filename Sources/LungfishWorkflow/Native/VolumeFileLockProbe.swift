// VolumeFileLockProbe.swift - Does this volume support the file locks Nextflow needs?
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin

/// Probes whether a volume supports POSIX advisory file locks.
///
/// Nextflow's LevelDB cache requires working `fcntl` locks; exFAT (via FSKit
/// on macOS 26) and some network filesystems refuse them, which aborts every
/// run with "Can't open cache DB". Rather than allowlisting filesystem names,
/// this takes out a real lock on a probe file. The answer decides where the
/// Nextflow launch scratch lives: on the project volume when locks work
/// (external SSDs are usually far larger than the boot volume), on local
/// storage only when they do not.
public enum VolumeFileLockProbe {
    private static let cache = LockedCache()

    final class LockedCache: @unchecked Sendable {
        private let lock = NSLock()
        private var byVolume: [String: Bool] = [:]
        func value(_ key: String) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            return byVolume[key]
        }
        func set(_ key: String, _ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            byVolume[key] = value
        }
    }

    /// True when the volume containing `url` accepts an `fcntl` write lock.
    ///
    /// Errors (missing directory, permissions) return false so callers fall
    /// back to local scratch, which always works. Results are cached per
    /// volume for the process lifetime.
    public static func volumeSupportsFileLocks(at url: URL) -> Bool {
        let directory = nearestExistingDirectory(for: url)
        let volumeKey = (try? directory.resourceValues(forKeys: [.volumeURLKey]).volume?.path) ?? directory.path
        let key = volumeKey ?? directory.path
        if let cached = cache.value(key) { return cached }
        let result = probe(in: directory)
        cache.set(key, result)
        return result
    }

    static func probe(in directory: URL) -> Bool {
        let probeURL = directory.appendingPathComponent(".lungfish-lockprobe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probeURL) }
        let fd = open(probeURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return fcntl(fd, F_SETLK, &lock) == 0
    }

    private static func nearestExistingDirectory(for url: URL) -> URL {
        var candidate = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        while !(FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return candidate
    }
}
