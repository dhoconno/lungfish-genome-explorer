// OpenFileProbe.swift - Whether a process holds a file open, read with libproc
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51. A command that runs no tool, such as `bam remove-track`, has no stand-in
// that writes a pid file when the command is at work. Its slow step is reading a file, here the
// hash of a large sparse BAM, so a SIGTERM check waits until the command holds that file open.

import Darwin
import Foundation
import LungfishCore

public enum OpenFileProbe {
    /// Whether process `pid` holds `path` open. A temporary folder may be spelled with or without
    /// its leading `/private`.
    public static func process(_ pid: Int32, holdsOpen path: String) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return false }
        let target = canonical(path)
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let open = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if canonical(open) == target { return true }
        }
        return false
    }

    /// Whether any process this test process started holds `path` open, such as the CLI a parity
    /// side runs through the app's transport.
    public static func anyDescendant(holdsOpen path: String) -> Bool {
        ProcessTreeTerminator.descendantProcessIDs(of: getpid()).contains { process($0, holdsOpen: path) }
    }

    private static func canonical(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return standard.hasPrefix("/private/") ? String(standard.dropFirst("/private".count)) : standard
    }
}
