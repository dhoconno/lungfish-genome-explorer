// ReadIDMatching.swift - How seqkit grep reads a record's ID before it matches the read-ID list
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How `seqkit grep` reads a FASTQ record's ID before comparing it with the
/// read-ID list, the `matching` argument of
/// ``ReadExtractionService/extractByReadIDs(config:matching:progress:)``.
public enum ReadIDMatching: Sendable, Equatable {
    /// The first word of the header, seqkit's own rule.
    case firstWord
    /// The first word without a final `/1` or `/2`. kraken2 names both mates
    /// of a pair by that fragment name, so a header such as `@X/1` must match
    /// the ID `X` (D7c, Phase 1.5 lane A3). `@X/1`, `@X/2`, `@X` and
    /// `@X 1:N:0:A` all read as `X`, and `@X/12` stays `X/12`.
    case fragmentName

    /// The seqkit options for this rule. The first-word rule adds none, so
    /// every other caller's argv stays byte for byte.
    var seqkitArguments: [String] {
        switch self {
        case .firstWord: return []
        case .fragmentName: return ["--id-regexp", #"^(\S+?)(?:/[12])?(?:\s|$)"#]
        }
    }

    /// The ID this rule reads from a FASTQ header line, the text seqkit
    /// captures with ``seqkitArguments``. The first word ends at a space, a
    /// tab, a carriage return or a form feed. The fragment-name rule then
    /// drops one final `/1` or `/2` from a word longer than two characters,
    /// as kraken2 `--paired` names a pair, so `@X/1/1` reads as `X/1` and
    /// `@/1` as `/1`.
    public func readID(ofHeaderLine line: String) -> String {
        let header = line.hasPrefix("@") ? line.dropFirst() : Substring(line)
        let word = header.prefix { !" \t\r\u{0C}\n".contains($0) }
        switch self {
        case .firstWord:
            return String(word)
        case .fragmentName:
            guard word.count > 2, word.hasSuffix("/1") || word.hasSuffix("/2") else { return String(word) }
            return String(word.dropLast(2))
        }
    }
}
