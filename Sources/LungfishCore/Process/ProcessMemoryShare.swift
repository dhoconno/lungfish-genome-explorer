// ProcessMemoryShare.swift - The share of the Mac's memory LGE's own process may use, and the watch that reads it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization

/// The share of this Mac's memory that LGE's own process, the app or `lungfish-cli`, may use before its memory guard
/// stops the work. It is read against the process's own `phys_footprint`, which leaves out the managed tools it runs,
/// since each runs as a child with memory of its own. Half of the Mac is 32 GB on a 64 GB Mac and 8 GB on a 16 GB
/// Mac, which leaves room for the tools (a Java tool's heap is capped at 35%, ``ManagedJavaHeapPolicy``) and macOS.
package struct ProcessMemoryShare: Sendable, Equatable {
    /// Half of the Mac's memory.
    package static let standardFraction = 0.5
    /// How often a guard reads the footprint.
    package static let pollInterval: Duration = .seconds(2)
    /// A guard that spoke arms again only once the footprint falls below this part of the share, so a footprint
    /// that stays high does not speak every poll.
    package static let rearmFraction = 0.9

    package let physicalMemoryBytes: UInt64
    package let fraction: Double

    package init(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        fraction: Double = Self.standardFraction
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.fraction = fraction
    }

    /// The footprint at which a guard stops the work.
    package var limitBytes: UInt64 {
        UInt64(Double(physicalMemoryBytes) * fraction)
    }

    /// The footprint below which a guard that spoke arms again.
    package var rearmBytes: UInt64 {
        UInt64(Double(limitBytes) * Self.rearmFraction)
    }

    /// The share in words, such as "half or more of the 64 GB on this Mac".
    package var shareWords: String {
        let part = fraction == 0.5 ? "half" : "\(Int((fraction * 100).rounded()))%"
        return "\(part) or more of the \(MemoryWords.bytes(physicalMemoryBytes)) on this Mac"
    }

    /// This process's own footprint, the `phys_footprint` of `task_info` `TASK_VM_INFO` that Activity Monitor shows
    /// as Memory, or nil when the kernel does not answer.
    package static func currentFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}

/// Reads a footprint and says once when it reaches the share. It arms again only after the footprint fell below
/// ``ProcessMemoryShare/rearmBytes``. The app and the CLI guard each hold one and act on what it says.
package final class ProcessMemoryWatch: Sendable {
    package let share: ProcessMemoryShare
    private let readFootprint: @Sendable () -> UInt64?
    private let armed = Mutex(true)
    private let timer = Mutex<DispatchSourceTimer?>(nil)

    package init(share: ProcessMemoryShare, readFootprint: @escaping @Sendable () -> UInt64?) {
        self.share = share
        self.readFootprint = readFootprint
    }

    /// Reads the footprint once. Returns it when it reached the share while the watch was armed, which disarms it,
    /// and nil otherwise.
    package func check() -> UInt64? {
        guard let footprint = readFootprint() else { return nil }
        return armed.withLock { armed -> UInt64? in
            if footprint >= share.limitBytes {
                guard armed else { return nil }
                armed = false
                return footprint
            }
            if footprint < share.rearmBytes {
                armed = true
            }
            return nil
        }
    }

    /// Calls `overShare` on `queue` with the footprint each time ``check()`` returns one, every
    /// ``ProcessMemoryShare/pollInterval``, until ``stop()``.
    package func start(queue: DispatchQueue, overShare: @escaping @Sendable (UInt64) -> Void) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        let seconds = Double(ProcessMemoryShare.pollInterval.components.seconds)
        source.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in
            guard let self, let footprint = self.check() else { return }
            overShare(footprint)
        }
        timer.withLock { current in
            current?.cancel()
            current = source
        }
        source.resume()
    }

    /// Stops the readings ``start(queue:overShare:)`` began.
    package func stop() {
        timer.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}
