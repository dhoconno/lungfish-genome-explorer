// FASTASelectionDetailFormatter.swift - Formats selected FASTA records for display
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

enum FASTASelectionDetailFormatter {
    static let lineWidth = 80

    static func text(for sequences: [Sequence]) -> String {
        sequences.map(record(for:)).joined(separator: "\n")
    }

    static func record(for sequence: Sequence) -> String {
        let description = sequence.description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let header: String
        if let description, !description.isEmpty {
            header = "\(sequence.name) \(description)"
        } else {
            header = sequence.name
        }

        let bases = sequence.asString()
        var lines = [String]()
        lines.reserveCapacity((bases.count + lineWidth - 1) / lineWidth)
        var start = bases.startIndex
        while start < bases.endIndex {
            let end = bases.index(
                start,
                offsetBy: lineWidth,
                limitedBy: bases.endIndex
            ) ?? bases.endIndex
            lines.append(String(bases[start..<end]))
            start = end
        }

        return ([">\(header)"] + lines).joined(separator: "\n") + "\n"
    }
}
