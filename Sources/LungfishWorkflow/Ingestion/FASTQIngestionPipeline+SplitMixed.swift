// FASTQIngestionPipeline+SplitMixed.swift - The clumped halves of a mixed file join without a third copy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQIngestionPipeline {

    /// Appends `tail` to the end of `head` byte for byte, removes `tail` and
    /// renames `head` to `output`. The result is the file a concatenation of
    /// the two into `output` writes, with no third copy on disk.
    ///
    /// The storage step of a file that mixes pairs and single reads clumps
    /// the two halves apart and joins them before compression. It used to
    /// write the join as a new file while the split halves and both clumped
    /// halves were still on disk, so the import's scratch peaked near four
    /// uncompressed copies of the run (F9 re-review N4).
    static func appendAndRename(_ tail: URL, to head: URL, as output: URL) throws {
        let sink = try FileHandle(forWritingTo: head)
        do {
            try sink.seekToEnd()
            let source = try FileHandle(forReadingFrom: tail)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try sink.write(contentsOf: chunk)
            }
            try sink.close()
        } catch {
            try? sink.close()
            throw error
        }
        try FileManager.default.removeItem(at: tail)
        try FileManager.default.moveItem(at: head, to: output)
    }
}
