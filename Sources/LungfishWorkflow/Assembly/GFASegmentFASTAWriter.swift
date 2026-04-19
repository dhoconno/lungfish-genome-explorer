// GFASegmentFASTAWriter.swift - Convert GFA segments into FASTA
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum GFASegmentFASTAWriter {
    public static func writePrimaryContigs(from gfaURL: URL, to fastaURL: URL) throws {
        let gfa = try String(contentsOf: gfaURL, encoding: .utf8)
        var records: [String] = []

        for line in gfa.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("S\t") else { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            let name = String(columns[1])
            let sequence = String(columns[2])
            guard !name.isEmpty, !sequence.isEmpty, sequence != "*" else { continue }
            records.append(">\(name)\n\(sequence)")
        }

        let output = records.joined(separator: "\n") + (records.isEmpty ? "" : "\n")
        try output.write(to: fastaURL, atomically: true, encoding: .utf8)
    }
}
