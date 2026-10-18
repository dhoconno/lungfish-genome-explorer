// StagedSequenceInput.swift - The durable FASTA input a viewer writes for a lungfish-cli leaf before its row begins
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Writes what a viewer shows as a FASTA file that a `lungfish-cli` leaf reads, for a run whose input
/// lives only in the viewer's memory or in a format the leaf does not read (Phase 2.12 lane 12.12,
/// A48-GAP, the region bundle of a viewer with no reference bundle).
///
/// The contract, which every caller keeps (lane 12.34 may reuse the writer).
/// - The caller writes before the row's `begin`, so the row records a command whose input exists, and
///   a failure to write starts no row.
/// - Each call writes one file into a folder of its own under `<project>/.tmp/`, made by
///   `ProjectTempDirectory.create(prefix:in:keepIntermediates:)`, through one `DurableReplace.replace`,
///   so the name holds the whole file or nothing, on APFS and ExFAT alike (2.11 C1, SWIFT inv 82).
/// - The folder stays after the run. Its marker keeps it, so no project sweep removes it, the record
///   that names the file as an input names a file that exists, and a copied command replays (ARCH 5,
///   BIO 6). With no project the folder is made under the system scratch root, which the system may clear.
/// - The FASTA holds one record per sequence. A header is the sequence's name alone and a line holds 70
///   bases, so the leaf finds each sequence by the name the viewer uses.
enum StagedSequenceInput {
    /// One sequence to write, under the name the viewer uses for it.
    struct Record: Sendable, Equatable {
        let name: String
        let bases: String
    }

    /// The bases a FASTA line holds.
    static let lineWidth = 70

    /// Writes `records` as `fileName` in a new folder named with `prefix` under the project's `.tmp/`,
    /// off the caller's actor, and returns the file.
    @concurrent
    static func writeFASTA(_ records: [Record], fileName: String, prefix: String, projectURL: URL?) async throws -> URL {
        let folder = try ProjectTempDirectory.create(prefix: prefix, in: projectURL, keepIntermediates: true)
        _ = try DurableReplace.replace(fastaData(records), named: fileName, in: folder)
        return folder.appendingPathComponent(fileName)
    }

    /// The FASTA text of `records`.
    static func fastaData(_ records: [Record]) -> Data {
        var text = ""
        for record in records {
            text += ">\(record.name)\n"
            var index = record.bases.startIndex
            while index < record.bases.endIndex {
                let end = record.bases.index(index, offsetBy: lineWidth, limitedBy: record.bases.endIndex) ?? record.bases.endIndex
                text += record.bases[index..<end] + "\n"
                index = end
            }
        }
        return Data(text.utf8)
    }
}
