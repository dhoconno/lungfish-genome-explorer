// ManagedJavaHeapPolicy.swift - One place that decides how big a bundled Java tool's heap may be
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin

/// Sizes the `-Xmx` heap handed to bundled Java tools (BBTools: clumpify,
/// reformat, bbduk, ...).
///
/// Why this exists: every import/derivative path used to size the heap at 60 to
/// 80 percent of physical RAM. On a 48 GB machine that is a 28 GB JVM, and a
/// FASTQ import running next to a Kraken2 Standard-16 classification (16 GB
/// resident) plus fseventsd pushed the whole machine out of memory on
/// 2026-08-22. BBTools does not need that much: clumpify/reformat stream
/// reads and only buffer the current group, and the JVM compressed-oops
/// ceiling is 31 GB anyway.
///
/// The policy is the minimum of:
/// * a share of physical memory (`physicalShare`, default 35 percent), so a
///   second managed tool can run alongside;
/// * what is actually free right now minus a reserve for the OS, the app, and
///   file cache (`reserveGB`), so a JVM started while another tool is resident
///   does not plan to swap;
/// * the 31 GB compressed-oops ceiling;
/// and never below `minimumGB` (BBTools' own default is 2 GB and large FASTQ
/// files need at least 4 GB).
public enum ManagedJavaHeapPolicy: Sendable {
    /// JVM compressed-oops ceiling; heaps above this lose the pointer compression win.
    public static let compressedOopsCeilingGB = 31
    /// Memory left for the OS, the app, the file cache, and concurrent tools.
    public static let reserveGB = 8
    /// Share of physical memory one bundled Java tool may claim.
    public static let physicalShare = 0.35

    /// Heap size in whole gigabytes for one bundled Java tool.
    ///
    /// - Parameters:
    ///   - physicalMemoryBytes: physical RAM; defaults to this machine's.
    ///   - availableMemoryBytes: memory currently free (free + inactive +
    ///     speculative pages); defaults to a live reading, `nil` when unknown.
    ///   - minimumGB: floor; 4 for ingestion of large files, 1 for small derivative steps.
    public static func heapGB(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        availableMemoryBytes: UInt64? = currentAvailableMemoryBytes(),
        minimumGB: Int = 4
    ) -> Int {
        let gb = 1024.0 * 1024.0 * 1024.0
        let physicalGB = Double(physicalMemoryBytes) / gb
        var candidate = physicalGB * physicalShare
        if let availableMemoryBytes {
            let availableGB = Double(availableMemoryBytes) / gb
            candidate = min(candidate, availableGB - Double(reserveGB))
        }
        let clamped = min(Double(compressedOopsCeilingGB), candidate)
        return max(minimumGB, Int(clamped.rounded(.down)))
    }

    /// Free + inactive + speculative pages right now, or `nil` if the host
    /// statistics call fails.
    public static func currentAvailableMemoryBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
        return pages * UInt64(pageSize)
    }
}
