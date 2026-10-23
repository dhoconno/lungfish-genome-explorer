// StepRecord.swift - The fields of one step's run record that the executor's launcher owns (lane K3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The exit codes live in Portable beside the run record (ARCH-r3 ruling 2). The alias keeps the name in this module,
/// so the executor's tests, which import only the executor, still reach them.
typealias ExecutorExitCode = LungfishPortable.ExecutorExitCode

/// The words a record carries. They become frozen strings when the lane lands (UX 1).
enum StepReason {
    /// SWIFT's sentence (SWIFT.md:68-69) followed by UX's (tally-r2 3.5, K3-8).
    static let lingeringProcess = "A process the tool started was still running after the tool exited. The executor stopped it."

    /// UX's refused-run words when the subreaper call fails (tally-r2 3.5).
    static func subreaperRefused(errnoName: String) -> String {
        "The executor could not register to adopt leftover processes (prctl failed with \(errnoName)). No tool ran."
    }
}

/// One step's record: its outcome, the tool's end and peak memory, what the sweep stopped and the outputs it hashed.
///
/// The run record's schema belongs to lane K4, which nests or renames these fields. The keys `orphanSweep` (values
/// `subreaper` and `parentWalkOnly`) and the subreaper state are UX's and QA's (tally-r2 K3-6, K3-8, XC-20).
struct StepRecord: Codable, Equatable, Sendable {
    /// The Portable types with the same keys, so `run --plan` and the Mac read the step mode's fields (ARCH-r3 ruling 2).
    typealias Subreaper = ExecutorStepRecord.Subreaper
    typealias Output = ExecutorStepRecord.Output

    var recordVersion = 1
    var executorVersion: String
    var executorPID: Int32
    /// `succeeded`, `failed`, `interrupted` or `refused`.
    var outcome: String
    var reason: String?
    /// The termination signal that interrupted the run.
    var signal: Int32?
    var signalName: String?
    var exitCode: Int32
    var orphanSweep: String
    var subreaper: Subreaper
    var argv: [String]
    /// The names of the variables the tool started with. The environment is built from nothing.
    var environmentNames: [String]
    var graceSeconds: Double
    var deadlineSeconds: Double?
    var toolPID: Int32?
    var toolExitCode: Int32?
    var toolSignal: Int32?
    var peakResidentBytes: UInt64?
    /// True when a process outlived the grace and was sent SIGKILL.
    var escalatedToSIGKILL: Bool
    /// The processes the executor signalled other than the tool, found under its own PID or in the tool's group.
    var stoppedProcesses: [Int32]
    /// Orphans re-parented to the executor and reaped by their own PID.
    var adoptedOrphansReaped: Int
    var wallSeconds: Double
    /// Each output's digest. Written only for a step that succeeded, after the sweep.
    var outputs: [Output]

    /// Writes the record by one rename of a fully written, synced temporary file in the same folder.
    func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self) + Data("\n".utf8)
        let temporary = "\(path).tmp-\(getpid())"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ExecutorSpawn.Failure(reason: "Could not create \(temporary). \(String(cString: strerror(errno)))") }
        let ok = writeAll(fd, data) && fsync(fd) == 0
        close(fd)
        guard ok, rename(temporary, path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw ExecutorSpawn.Failure(reason: "Could not write the record \(path). \(reason)")
        }
    }
}

/// Writes every byte of `data` to `fd`, retrying short writes and EINTR.
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var written = 0
        while written < raw.count {
            let count = write(fd, base + written, raw.count - written)
            if count > 0 {
                written += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
