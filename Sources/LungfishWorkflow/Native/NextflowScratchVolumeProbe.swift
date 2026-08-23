// NextflowScratchVolumeProbe.swift - Can this volume host Nextflow's launch scratch?
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin

/// Probes whether a volume can safely host Nextflow's `.nextflow/` cache and
/// `work/` tree.
///
/// Two independent capabilities matter:
///
/// 1. **POSIX advisory file locks** (`fcntl`): Nextflow takes them on its
///    cache DB and history file; some network filesystems refuse them.
/// 2. **Native extended attributes**: on volumes without them (exFAT via
///    FSKit on macOS 26), macOS shims every xattr into an AppleDouble
///    `._file` sidecar. Nextflow's LevelDB cache enumerates its directory
///    and parses file names as numbers, so a stray `._000003` aborts every
///    run with `NumberFormatException` — which Nextflow misreports as
///    "needs a shared file system that supports file locks". Observed on a
///    real FSKit exFAT volume where the lock probe alone passed.
///
/// Rather than allowlisting filesystem names, both capabilities are probed
/// with real files. The answer decides where the Nextflow launch scratch
/// lives: on the project volume when it qualifies (external SSDs are usually
/// far larger than the boot volume), on local storage only when it does not.
public enum NextflowScratchVolumeProbe {
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

    /// True when the volume containing `url` accepts `fcntl` write locks AND
    /// stores extended attributes natively (no AppleDouble sidecars).
    ///
    /// Errors (missing directory, permissions) return false so callers fall
    /// back to local scratch, which always works. Results are cached per
    /// volume for the process lifetime.
    public static func volumeSupportsNextflowScratch(at url: URL) -> Bool {
        let directory = nearestExistingDirectory(for: url)
        let volumeKey = (try? directory.resourceValues(forKeys: [.volumeURLKey]).volume?.path) ?? directory.path
        let key = volumeKey ?? directory.path
        if let cached = cache.value(key) { return cached }
        let result = probeFileLocks(in: directory) && probeNativeExtendedAttributes(in: directory)
        cache.set(key, result)
        return result
    }

    /// True when a real `fcntl` write lock succeeds on a probe file.
    static func probeFileLocks(in directory: URL) -> Bool {
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

    /// True when writing an xattr does NOT materialize an AppleDouble
    /// `._file` sidecar next to the probe file.
    static func probeNativeExtendedAttributes(in directory: URL, probeName: String? = nil) -> Bool {
        let name = probeName ?? ".lungfish-xattrprobe-\(UUID().uuidString)"
        let probeURL = directory.appendingPathComponent(name)
        let sidecarURL = directory.appendingPathComponent("._\(name)")
        defer {
            try? FileManager.default.removeItem(at: probeURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        guard FileManager.default.createFile(atPath: probeURL.path, contents: Data()) else { return false }
        var value: UInt8 = 1
        // An outright xattr failure leaves no sidecar behind, so it does not
        // trip the LevelDB file-name parser; only a materialized sidecar does.
        _ = setxattr(probeURL.path, "com.lungfish.volume-probe", &value, 1, 0, 0)
        return !FileManager.default.fileExists(atPath: sidecarURL.path)
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
