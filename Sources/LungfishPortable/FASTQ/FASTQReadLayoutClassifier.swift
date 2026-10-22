// FASTQReadLayoutClassifier.swift - The read-pair rule of the FASTQ layout classifier
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Classifies a FASTQ file as single-end, strictly interleaved, or mixed.
///
/// Two adjacent records are mates when LGE's existing read-pair rule
/// (``ReadPair/parse(from:)``: `/1` `/2` suffixes, or Illumina ` 1:N:` / ` 2:N:`
/// comments) gives the same pair ID with read 1 followed by read 2. Records
/// with no pair marker are mates when their read IDs are identical (the
/// BBTools and SRA convention). The scan is bounded by ``defaultRecordLimit``.
public enum FASTQReadLayoutClassifier {

    // MARK: Pairing rule

    /// Returns true when `second` is the read-2 mate of `first`.
    ///
    /// - Parameters:
    ///   - first: Full header line of the earlier record, without the leading `@`.
    ///   - second: Full header line of the next record, without the leading `@`.
    public static func areMates(_ first: String, _ second: String) -> Bool {
        let firstPair = pairInfo(first)
        let secondPair = pairInfo(second)
        if let firstPair, let secondPair {
            return firstPair.pairId == secondPair.pairId
                && firstPair.readNumber == 1
                && secondPair.readNumber == 2
        }
        if firstPair == nil, secondPair == nil {
            let firstID = readID(first)
            return !firstID.isEmpty && firstID == readID(second)
        }
        return false
    }

    /// `/1` `/2` on the read ID (even when a comment follows), else the
    /// Illumina ` 1:N:` / ` 2:N:` comment on the full header.
    private static func pairInfo(_ header: String) -> ReadPair? {
        ReadPair.parse(from: String(readID(header))) ?? ReadPair.parse(from: header)
    }

    private static func readID(_ header: String) -> Substring {
        let trimmed = header.drop(while: { $0 == "@" })
        if let end = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            return trimmed[..<end]
        }
        return trimmed
    }
}
