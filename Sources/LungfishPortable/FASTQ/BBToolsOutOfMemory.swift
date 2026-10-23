// BBToolsOutOfMemory.swift - The out-of-memory flag and exit status of a BBTools launch
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
/// - Stream reads and do not carry it: `reformat.sh` in `FASTQIngestionPipeline` (`reformatQuantize`), in
///   `PortableStorageStep` (the Trim Galore interleave, `trimGaloreInterleaveArguments`), in `FASTQBatchImporter`
///   (`interleavePairedInput` and `deinterleavePairedInput`) and in
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
