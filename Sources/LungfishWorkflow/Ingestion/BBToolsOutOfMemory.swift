// BBToolsOutOfMemory.swift - How an import ends when a BBTools JVM runs out of heap
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The out-of-memory contract of the BBTools launches on the import paths.
///
/// BBTools 40.02 `clumpify.sh` started without `-eoom` and given a heap too small for its input ended one of two
/// ways in the C3 fact-check. It exited 1 in 20 of 27 runs, and it hung idle in 7 until something killed it. With
/// `-eoom` the BBTools shell script passes `-XX:+ExitOnOutOfMemoryError` to the JVM, which then exits with status 3
/// in under a second. An import adds the flag to every launch whose memory grows with its input, and turns that
/// status into one plain sentence so the user sees what ran out and which option raises it.
enum BBToolsOutOfMemory {
    /// The BBTools shell flag that makes the JVM exit at once when it runs out of heap.
    static let flag = "-eoom"

    /// The exit status HotSpot gives `-XX:+ExitOnOutOfMemoryError`.
    static let exitStatus: Int32 = 3

    /// True when a launch that carried ``flag`` ended because its JVM ran out of heap.
    static func isOutOfMemory(exitCode: Int32) -> Bool {
        exitCode == exitStatus
    }

    /// The heap in whole gigabytes that an `-Xmx<N>g` argument asked for, or nil when none was pinned.
    static func heapGB(in arguments: [String]) -> Int? {
        for argument in arguments where argument.hasPrefix("-Xmx") && argument.hasSuffix("g") {
            if let gigabytes = Int(argument.dropFirst(4).dropLast()) { return gigabytes }
        }
        return nil
    }

    /// The sentence an import fails with.
    ///
    /// - Parameters:
    ///   - tool: The script that ran, such as `clumpify.sh`.
    ///   - arguments: The argv it ran with, which names the heap that ran.
    ///   - optionPinsHeap: True when `--clumpify-heap-gb` sets this launch's heap. The recipe steps size their own.
    static func message(tool: String, arguments: [String], optionPinsHeap: Bool) -> String {
        let kept = "so nothing was imported and the original files were kept."
        guard let heap = heapGB(in: arguments) else {
            return "\(tool) ran out of memory with the heap BBTools sized from this Mac's free memory, \(kept) "
                + "Close other apps or import fewer samples at a time, then import again."
        }
        guard optionPinsHeap else {
            return "\(tool) ran out of memory with a \(heap) GB heap, \(kept) "
                + "Close other apps or import fewer samples at a time, then import again."
        }
        return "\(tool) ran out of memory with a \(heap) GB heap, \(kept) "
            + "Import again with a larger heap, for example --clumpify-heap-gb \(heap * 2)."
    }
}
