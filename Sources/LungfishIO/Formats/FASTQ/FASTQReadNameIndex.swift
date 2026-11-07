// FASTQReadNameIndex.swift - The mate and the index a Casava read name carries in its comment
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The mate number and the sample index of one read name, as bcl2fastq and BCL Convert write them.
///
/// A Casava 1.8 name is `<read ID> <mate>:<filter>:<control>:<index>`, where the index is `i7` or `i7+i5`, as in
/// `@A00123:8:H5:1:1101:1000:2000 1:N:0:ATTACTCG+TCTACTCT`. Only the comment after the first space is read for the
/// index, so a UMI that BCL Convert appends to the read ID (`...:2000:ACGTACGT 1:N:0:GATCAG+CTGATC`) is never taken
/// for it. An index field that is missing, empty, a number (a sample number, as `1:N:0:2`) or all `N` is no index,
/// and so is any field that holds a letter other than A, C, G, T or N. This is the one parser of the read name
/// (ARCH pin 2 of the 3.3 meeting). The demultiplexing pipeline takes the mate from it, and the route owner takes
/// the index.
public struct FASTQReadNameIndex: Sendable, Equatable {
    /// The read ID: the name before the first space, without a `/1` or `/2` suffix that gave the mate.
    public let readID: String
    /// 1 or 2 when the name gives the mate, by a `/1` or `/2` suffix or a comment that starts `1:` or `2:`, else 0.
    public let mate: Int
    /// The first index of a Casava comment, upper case, or nil when the comment carries no index.
    public let i7: String?
    /// The second index, after `+`, upper case, or nil when the comment carries none.
    public let i5: String?

    /// Whether the comment carries a first index.
    public var hasIndex: Bool { i7 != nil }

    /// Parses one read name, the text after a FASTQ record's `@`.
    public init(rawName: some StringProtocol) {
        let name = Substring(rawName)
        let parts = name.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let identifier = parts.first.map(String.init) ?? String(name)
        let comment = parts.count > 1 ? parts[1] : nil
        if identifier.hasSuffix("/1") || identifier.hasSuffix("/2") {
            readID = String(identifier.dropLast(2))
            mate = identifier.hasSuffix("/1") ? 1 : 2
        } else {
            readID = identifier
            mate = comment.map { $0.hasPrefix("1:") ? 1 : ($0.hasPrefix("2:") ? 2 : 0) } ?? 0
        }
        let index = comment.flatMap(Self.casavaIndexField)
        let indexParts = index?.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false) ?? []
        let first = indexParts.first.flatMap(Self.indexSequence)
        i7 = first
        i5 = first != nil && indexParts.count > 1 ? Self.indexSequence(indexParts[1]) : nil
    }

    /// The index field of a Casava comment, `<mate>:<Y|N>:<control>:<index>`, or nil when the comment has
    /// another shape. Only the comment's first word is read, so a tab or a later word is not part of the index.
    static func casavaIndexField(_ comment: Substring) -> Substring? {
        let word = comment.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
        let fields = word.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count >= 4,
              !fields[0].isEmpty, fields[0].allSatisfy(\.isNumber),
              fields[1] == "Y" || fields[1] == "N",
              !fields[2].isEmpty, fields[2].allSatisfy(\.isNumber) else { return nil }
        return fields[3]
    }

    /// One index of the field, upper case, or nil when it is empty, a number, all `N` or holds another letter.
    static func indexSequence(_ text: Substring) -> String? {
        let upper = text.uppercased()
        guard !upper.isEmpty,
              upper.allSatisfy({ "ACGTN".contains($0) }),
              upper.contains(where: { $0 != "N" }) else { return nil }
        return upper
    }
}
