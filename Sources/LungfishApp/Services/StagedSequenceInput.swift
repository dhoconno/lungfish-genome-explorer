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
///   a failure to write starts no row and leaves no folder, since `writeFASTA` removes the folder it
///   made and rethrows.
/// - Each call writes one file into a folder of its own under `<project>/.tmp/`, made by
///   `ProjectTempDirectory.create(prefix:in:keepIntermediates:)`, through one `DurableReplace.replace`,
///   so the name holds the whole file or nothing, on APFS and ExFAT alike (2.11 C1, SWIFT inv 82).
/// - The folder stays after a run that published or was cancelled. Its marker keeps it, so no project
///   sweep removes it, the record that names the file as an input names a file that exists, and a copied
///   command replays (ARCH 5, BIO 6). With no project the folder is made under the system scratch root,
///   which the system may clear.
/// - A run that failed and published nothing writes no record, so nothing names the folder and the
///   marker keeps every sweep off it. The caller then removes it with `discard(_:unlessPublishedAt:)`
///   (2.12 review of lane 12.12, Fix 2).
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
        do {
            _ = try DurableReplace.replace(fastaData(records), named: fileName, in: folder)
        } catch {
            // The folder was made for this write and the marker keeps every sweep off it, so a write that failed
            // removes it. No row began and no record names it (M839 of 2.12, Phase 2.13).
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder.appendingPathComponent(fileName)
    }

    /// Removes the staged `folder` of a run that failed and published nothing, since no record names it
    /// and the marker keeps every project sweep off it. It removes nothing and returns false when
    /// `output` exists, because a bundle there means the run published and its record names the folder.
    /// Otherwise it removes `folder` as the bundle builder removes its own `extract-bundle-` stage, a
    /// removal that may fail without a word, and returns true. Call it for a failure only, never for a
    /// success or a cancel.
    @discardableResult
    static func discard(_ folder: URL, unlessPublishedAt output: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: output.path) else { return false }
        try? FileManager.default.removeItem(at: folder)
        return true
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
