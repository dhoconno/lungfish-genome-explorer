// TranslationEngine.swift - Core translation logic
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Translation Engine

/// Pure translation functions. All methods are static and `Sendable`-safe.
public enum TranslationEngine {

    // MARK: - Basic Translation

    /// Translates a nucleotide string to a protein string.
    ///
    /// - Parameters:
    ///   - sequence: Nucleotide sequence (DNA or RNA).
    ///   - offset: Number of bases to skip before the first codon (0, 1, or 2).
    ///   - table: Codon table to use.
    ///   - showStopAsAsterisk: If true, stop codons appear as `*`; if false, they are omitted.
    ///   - trimToFirstStop: If true, translation stops at the first stop codon.
    /// - Returns: The translated protein string.
    public static func translate(
        _ sequence: String,
        offset: Int = 0,
        table: CodonTable = .standard,
        showStopAsAsterisk: Bool = true,
        trimToFirstStop: Bool = false
    ) -> String {
        let chars = Array(sequence.uppercased())
        var protein = ""
        var position = offset

        while position + 3 <= chars.count {
            let codon = String(chars[position..<(position + 3)])
            let aminoAcid = table.translate(codon)

            if aminoAcid == "*" {
                if trimToFirstStop {
                    break
                }
                if showStopAsAsterisk {
                    protein.append("*")
                }
            } else {
                protein.append(aminoAcid)
            }

            position += 3
        }

        return protein
    }

    // MARK: - Reverse Complement

    /// Returns the reverse complement of a nucleotide sequence.
    /// Handles IUPAC ambiguity codes and both DNA (T) and RNA (U) bases.
    public static func reverseComplement(_ sequence: String) -> String {
        let isRNA = sequence.contains { $0 == "U" || $0 == "u" } &&
            !sequence.contains { $0 == "T" || $0 == "t" }

        let adenineComplementUpper: Character = isRNA ? "U" : "T"
        let adenineComplementLower: Character = isRNA ? "u" : "t"
        let complementMap: [Character: Character] = [
            "A": adenineComplementUpper, "T": "A", "U": "A", "C": "G", "G": "C",
            "a": adenineComplementLower, "t": "a", "u": "a", "c": "g", "g": "c",
            "R": "Y", "Y": "R", "S": "S", "W": "W",
            "K": "M", "M": "K", "B": "V", "V": "B",
            "D": "H", "H": "D", "N": "N",
            "r": "y", "y": "r", "s": "s", "w": "w",
            "k": "m", "m": "k", "b": "v", "v": "b",
            "d": "h", "h": "d", "n": "n"
        ]
        return String(sequence.reversed().map { complementMap[$0] ?? $0 })
    }

    // MARK: - CDS Translation

    /// Translates a CDS (coding sequence) annotation, handling discontiguous exons,
    /// strand orientation, and phase offsets.
    ///
    /// - Parameters:
    ///   - annotation: The annotation to translate (should be a CDS or gene with exon intervals).
    ///   - sequenceProvider: A closure that extracts nucleotides for a given genomic range (0-based, half-open).
    ///   - table: Codon table to use.
    /// - Returns: A `TranslationResult` with the protein, coding sequence, and coordinate mapping,
    ///            or `nil` if the annotation has no intervals or the sequence is empty.
    public static func translateCDS(
        annotation: SequenceAnnotation,
        sequenceProvider: (Int, Int) -> String?,
        table: CodonTable = .standard
    ) -> TranslationResult? {
        guard !annotation.intervals.isEmpty else { return nil }

        // Always sort intervals ascending by genomic position.
        // For reverse strand, the concatenated sequence is then reverse-complemented
        // as a whole: rc(exon1+exon2+...+exonN) = rc(exonN)+...+rc(exon1), which
        // gives the correct 5'→3' mRNA order (highest genomic coord first).
        let sortedIntervals = annotation.intervals.sorted { $0.start < $1.start }

        // Extract nucleotides from each interval
        var exonSequences: [(sequence: String, interval: AnnotationInterval)] = []
        for interval in sortedIntervals {
            guard let seq = sequenceProvider(interval.start, interval.end), !seq.isEmpty else {
                continue
            }
            exonSequences.append((seq, interval))
        }

        guard !exonSequences.isEmpty else { return nil }

        // Concatenate all exon sequences
        let codingSequence: String
        if annotation.strand == .reverse {
            let concatenated = exonSequences.map(\.sequence).joined()
            codingSequence = reverseComplement(concatenated)
        } else {
            codingSequence = exonSequences.map(\.sequence).joined()
        }

        // Determine phase offset from first interval that yielded sequence.
        let phaseOffset = exonSequences.first?.interval.phase ?? 0

        // Build the genomic coordinate map for each nucleotide position in the coding sequence
        let genomicPositions = buildGenomicPositionMap(
            exonSequences: exonSequences,
            strand: annotation.strand
        )

        // Translate and build amino acid positions
        let upperCoding = codingSequence.uppercased()
        let chars = Array(upperCoding)
        var aminoAcidPositions: [AminoAcidPosition] = []
        var protein = ""
        var aaIndex = 0
        var position = phaseOffset

        while position + 3 <= chars.count {
            let codon = String(chars[position..<(position + 3)])
            let aminoAcid = table.translate(codon)

            // Map this codon's 3 nucleotide positions back to genomic coordinates
            let codonGenomicRanges = genomicRangesForCodon(
                codingPositions: position..<(position + 3),
                genomicPositions: genomicPositions
            )

            let aaPos = AminoAcidPosition(
                index: aaIndex,
                aminoAcid: aminoAcid,
                codon: codon,
                genomicRanges: codonGenomicRanges,
                isStart: table.isStartCodon(codon),
                isStop: aminoAcid == "*"
            )
            aminoAcidPositions.append(aaPos)
            protein.append(aminoAcid)

            aaIndex += 1
            position += 3
        }

        return TranslationResult(
            protein: protein,
            codingSequence: codingSequence,
            aminoAcidPositions: aminoAcidPositions,
            codonTable: table,
            phaseOffset: phaseOffset
        )
    }

    // MARK: - Multi-Frame Translation

    /// Translates a sequence in multiple reading frames.
    ///
    /// - Parameters:
    ///   - frames: Which reading frames to translate.
    ///   - sequence: The nucleotide sequence.
    ///   - table: Codon table to use.
    /// - Returns: An array of (frame, protein) pairs.
    public static func translateFrames(
        _ frames: [ReadingFrame],
        sequence: String,
        table: CodonTable = .standard
    ) -> [(ReadingFrame, String)] {
        frames.map { frame in
            let workingSequence: String
            if frame.isReverse {
                workingSequence = reverseComplement(sequence)
            } else {
                workingSequence = sequence
            }
            let protein = translate(workingSequence, offset: frame.offset, table: table)
            return (frame, protein)
        }
    }

    // MARK: - Private Helpers

    /// Builds a map from coding-sequence nucleotide index to genomic coordinate.
    private static func buildGenomicPositionMap(
        exonSequences: [(sequence: String, interval: AnnotationInterval)],
        strand: Strand
    ) -> [Int] {
        var positions: [Int] = []

        for (seq, interval) in exonSequences {
            for i in 0..<seq.count {
                // Always map forward: position j in the concatenated sequence
                // corresponds to genomic coordinate interval.start + j.
                positions.append(interval.start + i)
            }
        }

        if strand == .reverse {
            // rc() reverses the concatenated sequence, so coding position 0
            // maps to the last genomic position we collected, position 1 to
            // second-to-last, etc. Reversing the positions array achieves this.
            positions.reverse()
        }

        return positions
    }

    /// Converts coding-sequence positions to genomic ranges, merging consecutive positions.
    private static func genomicRangesForCodon(
        codingPositions: Range<Int>,
        genomicPositions: [Int]
    ) -> [GenomicRange] {
        guard codingPositions.upperBound <= genomicPositions.count else {
            return []
        }

        let positions = codingPositions.map { genomicPositions[$0] }

        // Group consecutive genomic positions into ranges
        var ranges: [GenomicRange] = []
        var rangeStart = positions[0]
        var rangeEnd = positions[0]

        for i in 1..<positions.count {
            let pos = positions[i]
            if pos == rangeEnd + 1 {
                // Consecutive — extend current range
                rangeEnd = pos
            } else if pos == rangeEnd - 1 {
                // Consecutive in reverse direction — extend
                rangeStart = pos
            } else {
                // Non-consecutive — start a new range
                let start = min(rangeStart, rangeEnd)
                let end = max(rangeStart, rangeEnd) + 1
                ranges.append(GenomicRange(start: start, end: end))
                rangeStart = pos
                rangeEnd = pos
            }
        }
        // Append last range
        let start = min(rangeStart, rangeEnd)
        let end = max(rangeStart, rangeEnd) + 1
        ranges.append(GenomicRange(start: start, end: end))

        return ranges.sorted { $0.start < $1.start }
    }
}
