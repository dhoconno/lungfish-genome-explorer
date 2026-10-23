// BBToolsOutOfMemory.swift - How an import ends when a BBTools JVM runs out of heap
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What a Mac import shows when a BBTools launch ran out of heap. The sentence speaks of this Mac's memory and of
/// `import fastq --clumpify-heap-gb`, so it stays with the Mac import and a run off the Mac words its own failure.
extension BBToolsOutOfMemory {
    /// The error an import fails with when a launch that carried ``flag`` ended because its JVM ran out of heap, or
    /// nil for any other end. Every such launch asks this one function, so the status check and the sentence stay
    /// together.
    static func error(
        exitCode: Int32, tool: String, arguments: [String], optionPinsHeap: Bool
    ) -> FASTQIngestionError? {
        guard isOutOfMemory(exitCode: exitCode) else { return nil }
        return .outOfMemory(message(tool: tool, arguments: arguments, optionPinsHeap: optionPinsHeap))
    }

    /// The sentence an import fails with.
    ///
    /// - Parameters:
    ///   - tool: The script that ran, such as `clumpify.sh`.
    ///   - arguments: The argv it ran with, which names the heap that ran.
    ///   - optionPinsHeap: True when `--clumpify-heap-gb` sets this launch's heap. The recipe steps size their own.
    ///     Only `import fastq` has the option, so the sentence names that command.
    static func message(tool: String, arguments: [String], optionPinsHeap: Bool) -> String {
        let kept = "so this sample was not imported and its original files were kept."
        guard let heap = heapGB(in: arguments) else {
            return "\(tool) ran out of memory with the heap BBTools sized from this Mac's free memory, \(kept) "
                + "Close other apps or import fewer samples at a time, then import again."
        }
        guard optionPinsHeap else {
            return "\(tool) ran out of memory with a \(heap) GB heap, \(kept) "
                + "Close other apps or import fewer samples at a time, then import again."
        }
        return "\(tool) ran out of memory with a \(heap) GB heap, \(kept) "
            + "Import again with a larger heap, for example using import fastq --clumpify-heap-gb \(heap * 2)."
    }
}
