// ProcessProbes.swift - Three probe modes of lungfish-executor that the launcher's tests and the CHTC job start
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Probe modes that need no tool image, so the same tests run on macOS, in the Linux tier and on a CHTC node.
///
/// - `setsid-exec <absolute program> [<argument>...]` starts a new session and replaces itself with the program, as
///   util-linux `setsid` does. macOS ships no `setsid` command, and a tool image may lack one.
/// - `touch-memory <MiB>` allocates that many MiB and writes one byte in every 4 KiB, so its peak resident memory is the
///   allocation plus the runtime's own pages.
/// - `list-fds` prints the open descriptors from 0 to 4095, separated by spaces.
///
/// `main` unblocks the termination signals before a probe runs, so an exec'd program starts with an empty mask.
enum ProcessProbes {
    static let modes: Set<String> = ["setsid-exec", "touch-memory", "list-fds"]

    static func main(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "setsid-exec":
            return setsidExec(Array(arguments.dropFirst()))
        case "touch-memory":
            return touchMemory(arguments.dropFirst().first)
        case "list-fds":
            return listDescriptors()
        default:
            return fail("usage: lungfish-executor setsid-exec <program> [<argument>...] | touch-memory <MiB> | list-fds", 64)
        }
    }

    private static func fail(_ message: String, _ status: Int32) -> Int32 {
        FileHandle.standardError.write(Data("lungfish-executor: \(message)\n".utf8))
        return status
    }

    private static func setsidExec(_ arguments: [String]) -> Int32 {
        guard let program = arguments.first, program.hasPrefix("/") else {
            return fail("setsid-exec needs an absolute program path", 64)
        }
        guard setsid() != -1 else {
            return fail("setsid failed. \(String(cString: strerror(errno)))", 1)
        }
        let argv = arguments.map { strdup($0) } + [nil]
        execv(program, argv)
        return fail("cannot run \(program). \(String(cString: strerror(errno)))", 127)
    }

    private static func touchMemory(_ text: String?) -> Int32 {
        guard let text, let mebibytes = Int(text), (0...16_384).contains(mebibytes) else {
            return fail("touch-memory needs a size from 0 to 16384 MiB", 64)
        }
        let bytes = mebibytes << 20
        guard bytes > 0 else { return 0 }
        let block = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 4096)
        defer { block.deallocate() }
        var sum = 0
        for offset in stride(from: 0, to: bytes, by: 4096) {
            block.storeBytes(of: UInt8(truncatingIfNeeded: offset >> 12) | 1, toByteOffset: offset, as: UInt8.self)
        }
        for offset in stride(from: 0, to: bytes, by: 4096) {
            sum &+= Int(block.load(fromByteOffset: offset, as: UInt8.self))
        }
        print("touched \(mebibytes) MiB, checksum \(sum)")
        return 0
    }

    private static func listDescriptors() -> Int32 {
        let open = (Int32(0)..<4096).filter { fcntl($0, F_GETFD) != -1 }
        print(open.map(String.init).joined(separator: " "))
        return 0
    }
}
