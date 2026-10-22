// FASTQIngestionPipeline+SplitMixed.swift - The clumped halves of a mixed file join without a third copy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension FASTQIngestionPipeline {

    /// ``PortableFileJoin/appendAndRename(_:to:as:)``, which joins the clumped
    /// halves of a mixed file with no third copy on disk.
    static func appendAndRename(_ tail: URL, to head: URL, as output: URL) throws {
        try PortableFileJoin.appendAndRename(tail, to: head, as: output)
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
