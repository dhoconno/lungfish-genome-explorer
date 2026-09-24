// TranslationEngine.swift - Core translation logic
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

// MARK: - Translation Engine

/// Pure translation functions. All methods are static and `Sendable`-safe.
public enum TranslationEngine {

    /// RNA-independent complement mappings shared by every `reverseComplement` call.
    /// Only the adenine entries (`A`/`a`) depend on whether the sequence is RNA (U) or DNA (T),
    /// so they are added per-call rather than stored here.
    private static let baseComplementMap: [Character: Character] = [
        "T": "A", "U": "A", "C": "G", "G": "C",
        "t": "a", "u": "a", "c": "g", "g": "c",
        "R": "Y", "Y": "R", "S": "S", "W": "W",
        "K": "M", "M": "K", "B": "V", "V": "B",
        "D": "H", "H": "D", "N": "N",
        "r": "y", "y": "r", "s": "s", "w": "w",
        "k": "m", "m": "k", "b": "v", "v": "b",
        "d": "h", "h": "d", "n": "n"
    ]

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
        var complementMap = baseComplementMap
        complementMap["A"] = adenineComplementUpper
        complementMap["a"] = adenineComplementLower
        return String(sequence.reversed().map { complementMap[$0] ?? $0 })
    }

    // MARK: - CDS Translation

    /// Translates a CDS (coding sequence) annotation, handling discontiguous exons,
    /// strand orientation, and phase offsets.
    ///
    /// - Parameters:
    ///   - annotation: The annotation to translate (should be a CDS or gene with exon intervals).
    ///   - sequenceProvider: A closure that extracts nucleotides for a given genomic range (0-based, half-open).
    ///   - table: Codon table to use. When `nil` (the default), the table is
    ///     derived from the annotation's `/transl_table` qualifier if present
    ///     (SCI-10), falling back to the standard genetic code (table 1). Pass
    ///     an explicit table to override per-annotation qualifiers, for example
    ///     a user-selected genetic code in the viewer.
    /// - Returns: A `TranslationResult` with the protein, coding sequence, and coordinate mapping,
    ///            or `nil` if the annotation has no intervals or the sequence is empty.
    public static func translateCDS(
        annotation: SequenceAnnotation,
        sequenceProvider: (Int, Int) -> String?,
        table: CodonTable? = nil
    ) -> TranslationResult? {
        guard !annotation.intervals.isEmpty else { return nil }

        let table = table ?? resolvedCodonTable(for: annotation)

        // Transcription order. For an ordinary linear feature this is
        // ascending genomic order on '+' and descending on '-', matching the
        // app-level rendering convention (`SequenceViewerView.
        // codingCoordinateOrder`). `SequenceAnnotation.intervals` is no longer
        // force-sorted ascending by `SequenceAnnotation.init` (SCI-15), so for
        // an origin-spanning feature on a circular molecule (GenBank
        // `join(4000..4200,1..100)`) the stored order already IS the correct
        // transcription order and sorting it — in either direction — would
        // scramble it, since no single genomic direction recovers order across
        // an origin wrap. `annotation.isOriginSpanning` distinguishes the two
        // cases from the interval coordinates alone.
        let transcriptionOrderIntervals: [AnnotationInterval]
        if annotation.isOriginSpanning {
            transcriptionOrderIntervals = annotation.intervals
        } else {
            let ascending = annotation.intervals.sorted { $0.start < $1.start }
            transcriptionOrderIntervals = annotation.strand == .reverse ? ascending.reversed() : ascending
        }

        // Extract nucleotides from each interval, in transcription order.
        var exonSequences: [(sequence: String, interval: AnnotationInterval)] = []
        for interval in transcriptionOrderIntervals {
            guard let seq = sequenceProvider(interval.start, interval.end), !seq.isEmpty else {
                continue
            }
            exonSequences.append((seq, interval))
        }

        guard !exonSequences.isEmpty else { return nil }

        // Concatenate exon sequences in transcription order. For the reverse
        // strand each exon's raw (plus-strand) sequence is reverse-complemented
        // individually and then joined in transcription order, which is
        // equivalent to rc(exonN)+...+rc(exon1) for a genomic-ascending '-'
        // feature but also correct for an origin-spanning feature whose stored
        // order already reflects 5'->3' transcription rather than genomic
        // ascent.
        let codingSequence: String
        if annotation.strand == .reverse {
            codingSequence = exonSequences.map { reverseComplement($0.sequence) }.joined()
        } else {
            codingSequence = exonSequences.map(\.sequence).joined()
        }

        // Determine phase offset from the 5'-most segment in transcription order,
        // i.e. the first element of `exonSequences` (SCI-10: previously this used
        // `exonSequences.first` after an ascending sort, which for the reverse
        // strand picked the 3'-most segment instead of the 5'-most one).
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

    /// Resolves the codon table for an annotation from its `/transl_table`
    /// qualifier (GenBank) or `transl_table`/`genetic_code` GFF3 attribute,
    /// falling back to the standard genetic code (SCI-10). This matters most
    /// for mitochondrial genes: without it, vertebrate mitochondrial CDS
    /// (`/transl_table=2`) translate AGA/AGG as Arg instead of a stop, and TGA
    /// as a stop instead of Trp.
    public static func resolvedCodonTable(for annotation: SequenceAnnotation) -> CodonTable {
        let rawID = annotation.qualifier("transl_table") ?? annotation.qualifier("genetic_code")
        guard let rawID, let tableID = Int(rawID.trimmingCharacters(in: .whitespaces)) else {
            return .standard
        }
        return CodonTable.table(id: tableID) ?? .standard
    }

    // MARK: - Private Helpers

    /// Builds a map from coding-sequence nucleotide index to genomic coordinate.
    ///
    /// `exonSequences` is in transcription order and, for the reverse strand, each
    /// exon's sequence has already been individually reverse-complemented before
    /// this is called (see `translateCDS`). So per exon, coding position 0 maps to
    /// that exon's highest genomic coordinate and counts down, and exons are
    /// concatenated in transcription order (not necessarily genomic-ascending, for
    /// an origin-spanning circular feature).
    private static func buildGenomicPositionMap(
        exonSequences: [(sequence: String, interval: AnnotationInterval)],
        strand: Strand
    ) -> [Int] {
        var positions: [Int] = []

        for (seq, interval) in exonSequences {
            if strand == .reverse {
                // This exon's own sequence was individually reverse-complemented,
                // so its first base corresponds to the exon's last genomic base.
                for i in 0..<seq.count {
                    positions.append(interval.end - 1 - i)
                }
            } else {
                for i in 0..<seq.count {
                    positions.append(interval.start + i)
                }
            }
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
