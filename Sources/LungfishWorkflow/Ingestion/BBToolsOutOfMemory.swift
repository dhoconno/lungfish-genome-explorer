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
///
/// ### The BBTools launches on the import paths
///
/// The decision for each launch, by whether its memory grows with its input.
///
/// - Carry the flag: the storage `clumpify.sh` (`FASTQIngestionPipeline.clumpifyArguments`, for a single file, an
///   interleaved file, R1 plus R2, and the two launches of a split mixed file) and the two recipe dedupe launches
///   (`FASTQBatchImporter.pairedDedupeArguments` and `interleavedDedupeArguments`).
/// - Stream reads and do not carry it: `reformat.sh` in `FASTQIngestionPipeline` (`reformatQuantize` and
///   `interleavePairedFASTQ`), in `FASTQBatchImporter` (`interleavePairedInput` and `deinterleavePairedInput`) and in
///   `RecipeEngine` (the `format-conversion` interleave and deinterleave), and the recipe `bbmerge.sh` and `bbduk.sh`
///   steps, whose argvs build no k-mer table.
///
/// A launch added to these paths needs a row in this list. This search finds every BBTools launch again, and its
/// pattern avoids `\b`, which macOS `git grep -E` does not support.
///
/// ```
/// git grep -n -E "\.(clumpify|reformat|bbmerge|bbduk|repair|tadpole)([^A-Za-z]|$)" \
///     -- Sources/LungfishWorkflow Sources/LungfishApp/Services
/// ```
package enum BBToolsOutOfMemory {
    /// The BBTools shell flag that makes the JVM exit at once when it runs out of heap.
    package static let flag = "-eoom"

    /// The exit status HotSpot gives `-XX:+ExitOnOutOfMemoryError`.
    package static let exitStatus: Int32 = 3

    /// True when a launch that carried ``flag`` ended because its JVM ran out of heap.
    package static func isOutOfMemory(exitCode: Int32) -> Bool {
        exitCode == exitStatus
    }

    /// The heap in whole gigabytes that an `-Xmx<N>g` argument asked for, or nil when none was pinned.
    package static func heapGB(in arguments: [String]) -> Int? {
        for argument in arguments where argument.hasPrefix("-Xmx") && argument.hasSuffix("g") {
            if let gigabytes = Int(argument.dropFirst(4).dropLast()) { return gigabytes }
        }
        return nil
    }
}

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
