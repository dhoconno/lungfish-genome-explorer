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
/// BBTools and SRA convention), or when they end `.1` and `.2`, their stems are
/// equal and the stem itself ends in `.` and digits (`SRR1.7.1`, `SRR1.7.2`, as
/// `fastq-dump --readids` names them). `SRR1.1` and `SRR1.2` are spots of single
/// reads and stay single reads. Every default scan reads the whole file
/// (``defaultRecordLimit``), and only a scan of the whole file can call a file
/// strictly interleaved.
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
            let secondID = readID(second)
            return (!firstID.isEmpty && firstID == secondID) || areDottedMates(firstID, secondID)
        }
        return false
    }

    /// The stem and the mate number of a read ID in the dotted form, whose stem ends in `.` and digits with text before
    /// the dot. A name that could be read either way stays a single read, since pairing unrelated reads is the worse
    /// error.
    private static func dottedMate(_ id: Substring) -> (stem: Substring, mate: Int)? {
        let mate: Int
        if id.hasSuffix(".1") {
            mate = 1
        } else if id.hasSuffix(".2") {
            mate = 2
        } else {
            return nil
        }
        let stem = id.dropLast(2)
        guard let dot = stem.lastIndex(of: "."), dot > stem.startIndex else { return nil }
        let digits = stem[stem.index(after: dot)...].utf8
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return (stem, mate)
    }

    private static func areDottedMates(_ first: Substring, _ second: Substring) -> Bool {
        guard let first = dottedMate(first), first.mate == 1,
              let second = dottedMate(second), second.mate == 2 else { return false }
        return first.stem == second.stem
    }

    /// Whether the read ID of `header` has the dotted mate form. A mapper that pairs only records of one name reads a
    /// file in this form through ``sharedMateName(_:)``.
    public static func holdsDottedMateName(_ header: String) -> Bool {
        pairInfo(header) == nil && dottedMate(readID(header)) != nil
    }

    /// The header with the read ID's `.1` or `.2` written `/1` or `/2`, so the two mates share a fragment name to a tool
    /// that strips only those. Nil when the read ID does not have the dotted form.
    public static func sharedMateName(_ header: String) -> String? {
        guard holdsDottedMateName(header) else { return nil }
        let id = readID(header)
        let dot = header.index(id.endIndex, offsetBy: -2)
        return String(header[..<dot]) + "/" + String(header[header.index(after: dot)...])
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
