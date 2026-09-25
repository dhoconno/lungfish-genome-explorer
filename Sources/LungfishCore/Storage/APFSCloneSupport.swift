// APFSCloneSupport.swift - Explicit APFS clone primitives for managed storage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Explicit copy-on-write cloning for managed storage.
///
/// `FileManager.copyItem` clones on APFS but silently falls back to a full
/// copy elsewhere. Managed storage sharing must never pay for a hidden full
/// copy, so every clone here goes through `clonefile(2)` and fails loudly when
/// the volume cannot clone.
public enum APFSCloneSupport {
    public enum CloneError: Error, LocalizedError, Equatable, Sendable {
        case differentVolumes(source: String, destination: String)
        case cloneFailed(source: String, destination: String, code: Int32)
        case sourceUnreadable(String)

        public var errorDescription: String? {
            switch self {
            case .differentVolumes(let source, let destination):
                return "\(source) and \(destination) are on different volumes, so they cannot share storage."
            case .cloneFailed(let source, let destination, let code):
                return "Could not clone \(source) to \(destination): \(String(cString: strerror(code)))"
            case .sourceUnreadable(let path):
                return "Could not read \(path)."
            }
        }
    }

    /// The device identifier of the volume holding `url`, without following a
    /// trailing symbolic link. Returns `nil` when the path does not exist.
    public static func volumeIdentifier(of url: URL) -> dev_t? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return nil }
        return metadata.st_dev
    }

    /// The volume identifier of the nearest existing ancestor, for paths that
    /// have not been created yet.
    public static func volumeIdentifierOfNearestExistingAncestor(of url: URL) -> dev_t? {
        var candidate = url.standardizedFileURL
        while true {
            if let device = volumeIdentifier(of: candidate) { return device }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    /// Whether two existing paths (or their nearest existing ancestors) live on
    /// the same volume. Cloning only ever makes sense within one volume.
    public static func onSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = volumeIdentifierOfNearestExistingAncestor(of: lhs),
              let right = volumeIdentifierOfNearestExistingAncestor(of: rhs) else { return false }
        return left == right
    }

    /// Whether the volume holding `url` (or its nearest existing ancestor) is APFS.
    public static func isAPFSVolume(_ url: URL) -> Bool {
        var candidate = url.standardizedFileURL
        while true {
            var info = statfs()
            if statfs(candidate.path, &info) == 0 {
                return withUnsafePointer(to: &info.f_fstypename) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                        String(cString: $0) == "apfs"
                    }
                }
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return false }
            candidate = parent
        }
    }

    /// Clones a file or directory tree with `clonefile(2)`.
    ///
    /// The destination must not exist. Symbolic links are cloned as links, never
    /// followed. There is no fallback: a volume that cannot clone throws
    /// ``CloneError/cloneFailed(source:destination:code:)`` so callers keep
    /// today's behaviour (a download or a copy) explicitly.
    public static func cloneItem(at source: URL, to destination: URL) throws {
        guard onSameVolume(source, destination.deletingLastPathComponent()) else {
            throw CloneError.differentVolumes(source: source.path, destination: destination.path)
        }
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw CloneError.cloneFailed(source: source.path, destination: destination.path, code: errno)
        }
    }

    /// The APFS clone family identifier of a file.
    ///
    /// Files created from one another by `clonefile(2)` share a clone identifier
    /// while their data blocks are still shared. Returns `nil` when the volume
    /// does not report one, in which case callers must not count a re-clone as
    /// reclaimed space.
    public static func cloneIdentifier(of url: URL) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        // The reply is packed: a UInt32 length followed immediately by the
        // UInt64 identifier at offset 4, so it is read from raw bytes rather
        // than a Swift struct, whose alignment padding would shift the field.
        let headerSize = MemoryLayout<UInt32>.size
        let payloadSize = MemoryLayout<UInt64>.size
        var buffer = [UInt8](repeating: 0, count: headerSize + payloadSize + 8)
        let result = buffer.withUnsafeMutableBytes { bytes in
            getattrlist(url.path, &list, bytes.baseAddress, bytes.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { bytes -> UInt64? in
            let length = bytes.loadUnaligned(as: UInt32.self)
            guard Int(length) >= headerSize + payloadSize else { return nil }
            let id = bytes.loadUnaligned(fromByteOffset: headerSize, as: UInt64.self)
            return id == 0 ? nil : id
        }
    }

    /// Every vnode any process holds open, captured in one pass over the
    /// process table so that checking a file is a set lookup.
    ///
    /// `processesHoldingOpen(_:)` walks the whole system per call, which is
    /// O(files x processes) when applied to hundreds of thousands of package
    /// files. A dedupe pass captures this once and asks it about each file it
    /// is about to replace. Processes the caller may not inspect are skipped.
    public struct OpenFileSnapshot: Sendable {
        private let identities: Set<FileIdentity>
        public let processesInspected: Int

        struct FileIdentity: Hashable, Sendable {
            let device: dev_t
            let inode: UInt64
        }

        init(identities: Set<FileIdentity>, processesInspected: Int) {
            self.identities = identities
            self.processesInspected = processesInspected
        }

        /// Whether the file at `url` (not followed if a link) is open anywhere.
        public func contains(_ url: URL) -> Bool {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { return false }
            return identities.contains(FileIdentity(device: metadata.st_dev, inode: UInt64(metadata.st_ino)))
        }

        public static func capture(excludingCurrentProcess: Bool = true) -> OpenFileSnapshot {
            let current = getpid()
            let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard needed > 0 else { return OpenFileSnapshot(identities: [], processesInspected: 0) }
            var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
            let used = pids.withUnsafeMutableBytes { buffer in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
            }
            guard used > 0 else { return OpenFileSnapshot(identities: [], processesInspected: 0) }
            var identities = Set<FileIdentity>()
            var inspected = 0
            for pid in pids.prefix(Int(used) / MemoryLayout<pid_t>.size) where pid > 0 {
                if excludingCurrentProcess, pid == current { continue }
                let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
                guard bytes > 0 else { continue }
                inspected += 1
                let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size + 16
                var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
                let filled = descriptors.withUnsafeMutableBytes { buffer in
                    proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
                }
                guard filled > 0 else { continue }
                for descriptor in descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
                where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                    var info = vnode_fdinfowithpath()
                    let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                    guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
                    identities.insert(FileIdentity(
                        device: dev_t(info.pvip.vip_vi.vi_stat.vst_dev),
                        inode: info.pvip.vip_vi.vi_stat.vst_ino
                    ))
                }
            }
            return OpenFileSnapshot(identities: identities, processesInspected: inspected)
        }
    }

    /// Process identifiers that currently hold `url` open, or an empty list when
    /// the kernel cannot answer. This walks every process, so call it for one
    /// file at a time, never per scanned file; use ``OpenFileSnapshot`` for bulk checks.
    public static func processesHoldingOpen(_ url: URL, excludingCurrentProcess: Bool = true) -> [pid_t] {
        let flags = UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY)
        let needed = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, url.path, flags, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 16)
        let used = pids.withUnsafeMutableBytes { buffer in
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, url.path, flags, buffer.baseAddress, Int32(buffer.count))
        }
        guard used > 0 else { return [] }
        let current = getpid()
        return Array(pids.prefix(Int(used) / MemoryLayout<pid_t>.size))
            .filter { $0 != 0 && (!excludingCurrentProcess || $0 != current) }
    }
}
