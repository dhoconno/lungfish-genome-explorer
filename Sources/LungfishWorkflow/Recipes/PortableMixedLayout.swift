// PortableMixedLayout.swift - The mixed file of a merged layout, written with Foundation and a launcher
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Writes the one file a merge recipe stores, the merged reads first and then each unmerged pair with R1 next to
/// its R2, so the Mac import and a portable executor write the same bytes.
public enum PortableMixedLayout {

    /// Writes the mixed file of a merged layout and returns what
    /// ``FASTQPairInterleaver/writeMergedThenPairs(merged:unmergedR1:unmergedR2:to:launcher:)`` wrote. With no
    /// unmerged files the merged reads are copied on their own. `launcher` starts the decompressor of a gzip input.
    ///
    /// Runs the byte copy off the calling executor; the output is plain FASTQ
    /// because the storage step that follows reads, reorders, and compresses
    /// it anyway.
    package static func writeMixedLayout(
        merged: URL,
        unmergedR1: URL?,
        unmergedR2: URL?,
        to output: URL,
        launcher: any PortableChildLauncher
    ) async throws -> FASTQPairInterleaver.MergedThenPairsCounts {
        try await Task.detached(priority: .utility) {
            try Self.openSink(at: output) { sink in
                try FASTQPairInterleaver.writeMergedThenPairs(
                    merged: merged,
                    unmergedR1: unmergedR1,
                    unmergedR2: unmergedR2,
                    to: sink,
                    launcher: launcher
                )
            }
        }.value
    }

    private static func openSink<T>(at output: URL, _ body: (FileHandle) throws -> T) throws -> T {
        try? FileManager.default.removeItem(at: output)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        do {
            let result = try body(handle)
            try handle.close()
            return result
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
