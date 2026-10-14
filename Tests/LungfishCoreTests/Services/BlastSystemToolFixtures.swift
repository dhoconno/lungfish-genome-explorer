// BlastSystemToolFixtures.swift - Fixtures for the tests of BLAST's real gzip and unzip
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport

/// Inputs for the tests that run the real `/usr/bin` tools behind ``BlastService``.
/// The tools themselves are run through ``SystemToolProbe``.
enum BlastSystemToolFixtures {
    /// A Kraken 2 output of lines of varied length with what a scan of it must give.
    struct KrakenFixture {
        let text: String
        /// Column 5 of every line, keyed by read id.
        let hitStrings: [String: String]
        /// The number of lines that start with `C`.
        let classifiedCount: Int
        let idsByTaxon: [Int: Set<String>]

        /// The read ids of the classified lines whose taxon is in `taxIds`.
        func ids(taxIds: Set<Int>) -> Set<String> {
            taxIds.reduce(into: Set<String>()) { $0.formUnion(idsByTaxon[$1] ?? []) }
        }
    }

    /// `lines` lines of a Kraken 2 output. About one in seven is unclassified.
    static func krakenFixture(lines: Int) -> KrakenFixture {
        var text = ""
        var hitStrings: [String: String] = [:]
        var classified = 0
        var idsByTaxon: [Int: Set<String>] = [:]
        for index in 0..<lines {
            let id = "read_\(index)"
            let isClassified = index % 7 != 0
            let taxId = isClassified ? [562, 9606, 11676, 12814][index % 4] : 0
            let hit = (0...(index % 40)).map { "\(taxId):\($0 * 3 + index % 11)" }.joined(separator: " ")
            text += "\(isClassified ? "C" : "U")\t\(id)\t\(taxId)\t\(100 + index % 150)\t\(hit)\n"
            hitStrings[id] = hit
            if isClassified {
                classified += 1
                idsByTaxon[taxId, default: []].insert(id)
            }
        }
        return KrakenFixture(text: text, hitStrings: hitStrings, classifiedCount: classified, idsByTaxon: idsByTaxon)
    }

    /// `reads` FASTQ records of 100 bases, with the sequence of each.
    static func fastqFixture(reads: Int) -> (text: String, sequences: [String]) {
        let bases = Array("ACGT")
        let quality = String(repeating: "I", count: 100)
        var text = ""
        var sequences: [String] = []
        for index in 0..<reads {
            let sequence = String((0..<100).map { bases[(index &* 31 &+ $0 &* 7 &+ $0 / 3) & 3] })
            sequences.append(sequence)
            text += "@read_\(index)\n\(sequence)\n+\n\(quality)\n"
        }
        return (text, sequences)
    }

    /// One per-query file of a BLAST result archive.
    static func queryJSON(_ number: Int) -> Data {
        Data("""
        {"BlastOutput2": [{"report": {"program": "blastn", "version": "BLASTN 2.16.0+", \
        "results": {"search": {"query_title": "read_\(number)", "query_len": \(number * 10), "hits": []}}}}]}
        """.utf8)
    }

    /// A BLAST result archive made by the real zip. Its members are the manifest, the per-query
    /// files `RID_10`, `RID_2` and `RID_1` and a text file the service ignores.
    static func resultArchive(in directory: URL) async throws -> Data {
        let members = directory.appendingPathComponent("members", isDirectory: true)
        try FileManager.default.createDirectory(at: members, withIntermediateDirectories: true)
        for number in [10, 2, 1] {
            try queryJSON(number).write(to: members.appendingPathComponent("RID_\(number).json"))
        }
        try Data(#"{"BlastJSON": [{"File": "RID_1.json"}]}"#.utf8).write(to: members.appendingPathComponent("RID.json"))
        try Data("not json".utf8).write(to: members.appendingPathComponent("RID.txt"))
        let archive = directory.appendingPathComponent("results.zip")
        let names = ["RID_10.json", "RID_2.json", "RID_1.json", "RID.json", "RID.txt"]
        try await SystemToolProbe.run("zip", ["-q", "-j", archive.path] + names.map { members.appendingPathComponent($0).path })
        return try Data(contentsOf: archive)
    }
}
