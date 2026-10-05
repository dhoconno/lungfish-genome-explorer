// MultipleSequenceAlignmentDistanceMatrix.swift - Aligned FASTA records for MSA distance matrices
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The matrix itself lives in MSADistanceMatrix.swift, with its options in
// MSADistanceModels.swift and the UPGMA order in MSADistanceClustering.swift.

import Foundation

/// One aligned FASTA record: the header text after `>` and the gapped sequence.
public struct MSAAlignedRecord: Sendable, Equatable {
    public let name: String
    public let sequence: String

    public init(name: String, sequence: String) {
        self.name = name
        self.sequence = sequence
    }

    /// Parses aligned FASTA text. Whitespace inside sequence lines is dropped, as the GUI
    /// viewport does. A record with an empty header keeps the empty name. Returns an empty
    /// array for text without records.
    ///
    /// `keepingInteriorWhitespace` preserves the older CLI reading, which kept interior
    /// whitespace as sequence characters. Only the msa subcommands whose output predates
    /// finding S2 pass true, so their files stay byte-identical.
    public static func parseAlignedFASTA(
        _ text: String,
        keepingInteriorWhitespace: Bool = false
    ) -> [MSAAlignedRecord] {
        var records: [MSAAlignedRecord] = []
        var currentName: String?
        var currentSequence = ""

        func flush() {
            guard let currentName else { return }
            records.append(MSAAlignedRecord(name: currentName, sequence: currentSequence))
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { continue }
            if line.hasPrefix(">") {
                flush()
                currentName = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                currentSequence = ""
            } else {
                currentSequence += keepingInteriorWhitespace ? line : line.filter { !$0.isWhitespace }
            }
        }
        flush()
        return records
    }

    /// Loads the primary aligned FASTA of a `.lungfishmsa` bundle.
    public static func loadPrimaryAlignment(of bundleURL: URL) throws -> [MSAAlignedRecord] {
        let fastaURL = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
        let text = try String(contentsOf: fastaURL, encoding: .utf8)
        return parseAlignedFASTA(text)
    }
}

