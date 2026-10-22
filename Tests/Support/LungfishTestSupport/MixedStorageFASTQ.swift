// MixedStorageFASTQ.swift - A merging recipe's mixed output and the checks of how a storage step laid it out
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Small FASTQ files with merged reads and read pairs, as a merging recipe leaves them, and a reader that says how a
/// storage step laid its output out. The storage step of a file that mixes the two keeps each pair adjacent and writes
/// the pairs before the unpaired reads, whichever tool clumps the halves.
public enum MixedStorageFASTQ {

    /// What a stored FASTQ holds, read from its records.
    public struct Layout: Equatable, Sendable {
        /// Adjacent mate pairs, by the importer's by-name rule.
        public let pairs: Int
        /// Records without an adjacent mate.
        public let unpaired: Int
        /// Whether every pair comes before every unpaired read.
        public let pairsBeforeUnpaired: Bool
        /// Each record's name without its description or mate suffix, sorted.
        public let names: [String]
    }

    private static func record(_ name: String, _ bases: String) -> String {
        "@\(name)\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n"
    }

    private static func reverseComplement(_ bases: String) -> String {
        let complement: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A"]
        return String(bases.reversed().map { complement[$0] ?? $0 })
    }

    /// The file a merging recipe ends with: the merged reads first, then each R1 before its R2. `shortMerged` adds
    /// merged reads of 12 bases, which Trim Galore's length cutoff removes.
    public static func writeMixed(to url: URL, pairs: Int, merged: Int, shortMerged: Int = 0) throws {
        var text = ""
        for index in 0..<merged {
            text += record("merged\(index + 1)", InterleavedFASTQFixture.deterministicSequence(seed: UInt64(3_000 + index), length: 130))
        }
        for index in 0..<shortMerged {
            text += record("short\(index + 1)", InterleavedFASTQFixture.deterministicSequence(seed: UInt64(4_000 + index), length: 12))
        }
        for index in 0..<pairs {
            text += record("frag\(index + 1)/1", InterleavedFASTQFixture.deterministicSequence(seed: UInt64(5_000 + index), length: 100))
            text += record("frag\(index + 1)/2", InterleavedFASTQFixture.deterministicSequence(seed: UInt64(6_000 + index), length: 100))
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// R1 and R2 files of `apart` pairs whose reads do not overlap, so a merge leaves them as pairs, and `overlapping`
    /// pairs whose reads overlap by 50 bases, so a merge joins them into one read each.
    public static func writeReadPairs(r1: URL, r2: URL, apart: Int, overlapping: Int) throws {
        var first = "", second = ""
        for index in 0..<apart {
            let fragment = InterleavedFASTQFixture.deterministicSequence(seed: UInt64(1_000 + index), length: 400)
            first += record("apart\(index + 1)/1", String(fragment.prefix(100)))
            second += record("apart\(index + 1)/2", reverseComplement(String(fragment.suffix(100))))
        }
        for index in 0..<overlapping {
            let fragment = InterleavedFASTQFixture.deterministicSequence(seed: UInt64(2_000 + index), length: 150)
            first += record("overlap\(index + 1)/1", String(fragment.prefix(100)))
            second += record("overlap\(index + 1)/2", reverseComplement(String(fragment.suffix(100))))
        }
        try first.write(to: r1, atomically: true, encoding: .utf8)
        try second.write(to: r2, atomically: true, encoding: .utf8)
    }

    /// Each four-line record of a plain or gzip FASTQ, in file order, with its newlines.
    public static func records(of url: URL) throws -> [String] {
        let text: String
        if url.pathExtension == "gz" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "MixedStorageFASTQ", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "gzip could not read \(url.lastPathComponent)"])
            }
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return stride(from: 0, to: lines.count - lines.count % 4, by: 4).map {
            lines[$0..<$0 + 4].joined(separator: "\n") + "\n"
        }
    }

    /// The layout of a stored FASTQ: how many pairs and unpaired reads it holds, whether the pairs come first, and
    /// the names of its records.
    public static func layout(of url: URL) throws -> Layout {
        let all = try records(of: url)
        let counts = try FASTQPairInterleaver.countMixed(interleaved: url)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let head = scratch.appendingPathComponent("head.fastq")
        let tail = scratch.appendingPathComponent("tail.fastq")
        let split = min(all.count, counts.pairs * 2)
        try all.prefix(split).joined().write(to: head, atomically: true, encoding: .utf8)
        try all.dropFirst(split).joined().write(to: tail, atomically: true, encoding: .utf8)
        let headCounts = try FASTQPairInterleaver.countMixed(interleaved: head)
        let tailCounts = try FASTQPairInterleaver.countMixed(interleaved: tail)
        let names = all.map { record -> String in
            let header = record.split(separator: "\n").first.map { String($0.dropFirst()) } ?? ""
            let name = header.split(separator: " ").first.map(String.init) ?? header
            return name.hasSuffix("/1") || name.hasSuffix("/2") ? String(name.dropLast(2)) : name
        }.sorted()
        return Layout(
            pairs: counts.pairs,
            unpaired: counts.unpaired,
            pairsBeforeUnpaired: headCounts == .init(pairs: counts.pairs, unpaired: 0)
                && tailCounts == .init(pairs: 0, unpaired: counts.unpaired),
            names: names
        )
    }
}
