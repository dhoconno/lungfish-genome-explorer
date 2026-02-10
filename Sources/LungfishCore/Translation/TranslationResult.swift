// TranslationResult.swift - Translation output types
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Translation Result

/// The result of translating a CDS annotation, including coordinate mapping.
public struct TranslationResult: Sendable {
    /// The translated protein sequence.
    public let protein: String

    /// The concatenated exon nucleotide sequence used for translation.
    public let codingSequence: String

    /// Per-amino-acid position and codon information with genomic coordinate mapping.
    public let aminoAcidPositions: [AminoAcidPosition]

    /// The codon table used for translation.
    public let codonTable: CodonTable

    /// The phase offset applied (0, 1, or 2 bases skipped at start).
    public let phaseOffset: Int

    public init(
        protein: String,
        codingSequence: String,
        aminoAcidPositions: [AminoAcidPosition],
        codonTable: CodonTable,
        phaseOffset: Int
    ) {
        self.protein = protein
        self.codingSequence = codingSequence
        self.aminoAcidPositions = aminoAcidPositions
        self.codonTable = codonTable
        self.phaseOffset = phaseOffset
    }
}

// MARK: - Amino Acid Position

/// Maps a single amino acid back to its codon and genomic coordinates.
public struct AminoAcidPosition: Sendable {
    /// 0-based index in the protein sequence.
    public let index: Int

    /// The amino acid character.
    public let aminoAcid: Character

    /// The three-letter codon (e.g., "ATG").
    public let codon: String

    /// Genomic coordinate ranges for this codon (usually 1 range; 2 if codon spans an intron).
    public let genomicRanges: [GenomicRange]

    /// Whether this codon is a start codon in the translation table used.
    public let isStart: Bool

    /// Whether this codon is a stop codon.
    public let isStop: Bool

    public init(
        index: Int,
        aminoAcid: Character,
        codon: String,
        genomicRanges: [GenomicRange],
        isStart: Bool,
        isStop: Bool
    ) {
        self.index = index
        self.aminoAcid = aminoAcid
        self.codon = codon
        self.genomicRanges = genomicRanges
        self.isStart = isStart
        self.isStop = isStop
    }
}

// MARK: - Genomic Range

/// A simple start/end range in genomic coordinates.
public struct GenomicRange: Sendable, Equatable {
    /// 0-based inclusive start.
    public let start: Int
    /// 0-based exclusive end.
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var length: Int { end - start }
}
