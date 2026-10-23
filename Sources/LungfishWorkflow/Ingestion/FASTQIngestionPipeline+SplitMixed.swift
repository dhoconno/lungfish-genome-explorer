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
/// caller removes (``PortableMixedFileHalves``).
typealias MixedFileHalves = PortableMixedFileHalves

extension FASTQIngestionPipeline {

    /// ``PortableStorageChecks/splitMixedByMate(_:counts:in:scratchPrefix:launcher:)`` with the launcher that starts
    /// `gzip -dc` through `ToolProcess`. The bbtools route and the Trim Galore route both split here, so a pair is a
    /// pair by the same rule in each. A failed split removes its scratch folder.
    static func splitMixedByMate(
        _ input: URL,
        counts: FASTQPairInterleaver.MixedCounts,
        in parent: URL,
        scratchPrefix: String
    ) async throws -> MixedFileHalves {
        try await mappingStorageErrors {
            try await PortableStorageChecks.splitMixedByMate(
                input, counts: counts, in: parent, scratchPrefix: scratchPrefix, launcher: ToolProcessChildLauncher()
            )
        }
    }

    /// Counts the stored output against the reads the storage tool kept and removes the output when the count is
    /// wrong, so the originals stay the only copy. Clumpify keeps every read the scan found. Trim Galore keeps the
    /// reads its trimming reports say it wrote, which the route checks against the scan. Both counts are exact.
    static func verifyStoredRecordCount(
        in output: URL,
        expected: Int,
        tool: String
    ) async throws {
        try await mappingStorageErrors {
            try await PortableStorageChecks.verifyStoredRecordCount(
                in: output, expected: expected, tool: tool, launcher: ToolProcessChildLauncher()
            )
        }
    }
}
