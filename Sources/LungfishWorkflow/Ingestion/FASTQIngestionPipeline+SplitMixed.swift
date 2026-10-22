// FASTQIngestionPipeline+SplitMixed.swift - The clumped halves of a mixed file join without a third copy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

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

/// A mixed file split by mate name into one file of whole pairs and one of unpaired reads, in a scratch folder the
/// caller removes.
struct MixedFileHalves: Sendable {
    let scratch: URL
    let pairs: URL
    let unpaired: URL
}

extension FASTQIngestionPipeline {

    /// Splits `input`, which the scan found to mix pairs with unpaired reads, into the two halves of a new scratch
    /// folder under `parent` and checks the split against the scan. The bbtools route and the Trim Galore route both
    /// split here, so a pair is a pair by the same rule in each (``FASTQPairInterleaver/partitionMixed(interleaved:pairs:unpaired:)``).
    /// A failed split removes its scratch folder.
    static func splitMixedByMate(
        _ input: URL,
        counts: FASTQPairInterleaver.MixedCounts,
        in parent: URL,
        scratchPrefix: String
    ) async throws -> MixedFileHalves {
        let fm = FileManager.default
        let scratch = parent.appendingPathComponent("\(scratchPrefix)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let halves = MixedFileHalves(
            scratch: scratch,
            pairs: scratch.appendingPathComponent("pairs.fastq"),
            unpaired: scratch.appendingPathComponent("unpaired.fastq")
        )
        do {
            try await detachedWork {
                FileManager.default.createFile(atPath: halves.pairs.path, contents: nil)
                FileManager.default.createFile(atPath: halves.unpaired.path, contents: nil)
                let pairsHandle = try FileHandle(forWritingTo: halves.pairs)
                defer { try? pairsHandle.close() }
                let unpairedHandle = try FileHandle(forWritingTo: halves.unpaired)
                defer { try? unpairedHandle.close() }
                let split = try FASTQPairInterleaver.partitionMixed(
                    interleaved: input,
                    pairs: pairsHandle,
                    unpaired: unpairedHandle
                )
                guard split == counts else {
                    throw FASTQIngestionError.clumpifyFailed(
                        "the pair scan found \(counts.pairs) pairs and \(counts.unpaired) unpaired reads, but the split wrote \(split.pairs) and \(split.unpaired)"
                    )
                }
            }
        } catch {
            try? fm.removeItem(at: scratch)
            throw error
        }
        return halves
    }

    /// Counts the stored output against the reads the storage tool kept and removes the output when the count is
    /// wrong, so the originals stay the only copy. Clumpify keeps every read the scan found. Trim Galore keeps the
    /// reads its trimming reports say it wrote, which the route checks against the scan. Both counts are exact.
    static func verifyStoredRecordCount(
        in output: URL,
        expected: Int,
        tool: String
    ) async throws {
        let records = try await detachedWork { try FASTQPairInterleaver.countRecords(in: output) }
        guard records == expected else {
            try? FileManager.default.removeItem(at: output)
            throw FASTQIngestionError.clumpifyFailed(
                "expected \(expected) reads after \(tool) but \(output.lastPathComponent) holds \(records); originals were kept"
            )
        }
    }
}
