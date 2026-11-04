// FASTQLayoutRecordFixtures.swift - FASTQ files of a known read layout at real record counts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Writes a FASTQ file from runs of mate pairs and single reads, so a test can hold more pairs than a bounded scan
/// reads and say exactly what the file holds.
///
/// Mates are named `p<n>/1` and `p<n>/2`, and a single read `m<n>`, the name of a merged read.
public enum FASTQLayoutRecordFixtures {

    /// One run of records.
    public enum Run: Sendable {
        /// `count` adjacent mate pairs, numbered from `first`.
        case pairs(Int, first: Int = 0)
        /// `count` single reads, numbered from `first`.
        case singles(Int, first: Int = 0)
    }

    /// Writes `runs` in order to `url`.
    public static func write(_ runs: [Run], to url: URL) throws {
        var text = ""
        text.reserveCapacity(runs.reduce(0) { total, run in
            switch run {
            case .pairs(let count, _): return total + count * 64
            case .singles(let count, _): return total + count * 40
            }
        })
        for run in runs {
            switch run {
            case .pairs(let count, let first):
                for index in first..<(first + count) {
                    text += "@p\(index)/1\nACGTACGT\n+\nIIIIIIII\n@p\(index)/2\nTTGGCCAA\n+\nIIIIIIII\n"
                }
            case .singles(let count, let first):
                for index in first..<(first + count) {
                    text += "@m\(index)\nGATTACAGATTACA\n+\nIIIIIIIIIIIIII\n"
                }
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
