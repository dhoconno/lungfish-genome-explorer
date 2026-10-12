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

    /// The bases a provider returned for one CDS segment, and where they start.
    ///
    /// A provider that clamps a request to the sequence it holds returns fewer bases than the segment has.
    /// `start` says which end it kept. That lets the engine tell a clip at the 5' end of the CDS, which moves
    /// the reading frame, from a clip at the 3' end, which only shortens the protein.
    package struct SegmentRead: Sendable, Equatable {
        /// The 0-based plus-strand coordinate of the first base of `sequence`.
        package let start: Int

        /// The plus-strand bases that were read, as the sequence stores them.
        package let sequence: String

        package init(start: Int, sequence: String) {
            self.start = start
            self.sequence = sequence
        }
    }

    /// Translates a CDS (coding sequence) annotation, handling discontiguous exons,
    /// strand orientation, phase offsets and a sequence that ends inside the CDS.
    ///
    /// The provider reads one segment, a 0-based half-open range, and returns its plus-strand bases. It
    /// returns fewer bases than were asked for only when the range ran past the end of the sequence, and
    /// nil when no base of the range exists. The bases it returns start where the range starts. A provider
    /// that can also cut the start of the range, such as a window onto part of a chromosome, reports where
    /// its bases start through `translateCDS(annotation:segmentProvider:table:)` instead.
    ///
    /// A segment that comes back short, or not at all, lost bases to the end of the sequence. Bases lost at
    /// the 3' end of the CDS only shorten the protein, and a partial last codon is dropped. Bases lost at
    /// the 5' end move the frame. With p the phase of the 5'-most segment and r the coding bases lost before
    /// the first base that was read, whole segments included, the first codon starts at base ((p - r) mod 3)
    /// of the bases that were read. A phase recorded on a later segment is not used, so a clip never moves
    /// the frame of a base that is still read and the protein is the in-frame tail of the unclipped one. A
    /// GenBank import records the phase on the 5'-most segment only. A segment that fails between two that
    /// were read, or a clip that leaves a gap between two segments, gives no protein. The protein and the
    /// amino acid indexes start at the first whole codon that was read, and every codon maps to the bases it
    /// came from.
    ///
    /// - Parameters:
    ///   - annotation: The annotation to translate (should be a CDS or gene with exon intervals).
    ///   - sequenceProvider: A closure that extracts nucleotides for a given genomic range (0-based, half-open).
    ///   - table: Codon table to use. When `nil` (the default), the table is
    ///     derived from the annotation's `/transl_table` qualifier if present,
    ///     falling back to the standard genetic code (table 1). Pass
    ///     an explicit table to override per-annotation qualifiers, for example
    ///     a user-selected genetic code in the viewer.
    /// - Returns: A `TranslationResult` with the protein, coding sequence, and coordinate mapping,
    ///            or `nil` if the annotation has no intervals or the sequence is empty.
    public static func translateCDS(
        annotation: SequenceAnnotation,
        sequenceProvider: (Int, Int) -> String?,
        table: CodonTable? = nil
    ) -> TranslationResult? {
        translateCDS(
            annotation: annotation,
            segmentProvider: { start, end in
                sequenceProvider(start, end).map { SegmentRead(start: start, sequence: $0) }
            },
            table: table
        )
    }

    /// Translates a CDS annotation from a provider that reports where its bases start.
    ///
    /// The rule for a clipped CDS is the one `translateCDS(annotation:sequenceProvider:table:)` describes.
    /// Here the provider says which end of a segment it cut, so a window that starts inside the CDS moves
    /// the frame of a forward-strand CDS the way the end of a sequence moves the frame of a reverse-strand one.
    package static func translateCDS(
        annotation: SequenceAnnotation,
        segmentProvider: (Int, Int) -> SegmentRead?,
        table: CodonTable? = nil
    ) -> TranslationResult? {
        guard let layout = codingLayout(annotation: annotation, segmentProvider: segmentProvider) else {
            return nil
        }

        let table = table ?? resolvedCodonTable(for: annotation)

        // Translate and build amino acid positions
        let upperCoding = layout.codingSequence.uppercased()
        let chars = Array(upperCoding)
        var aminoAcidPositions: [AminoAcidPosition] = []
        var protein = ""
        var aaIndex = 0
        var position = layout.phaseOffset

        while position + 3 <= chars.count {
            let codon = String(chars[position..<(position + 3)])
            let aminoAcid = table.translate(codon)

            // Map this codon's 3 nucleotide positions back to genomic coordinates
            let codonGenomicRanges = genomicRangesForCodon(
                codingPositions: position..<(position + 3),
                genomicPositions: layout.genomicPositions
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
            codingSequence: layout.codingSequence,
            aminoAcidPositions: aminoAcidPositions,
            codonTable: table,
            phaseOffset: layout.phaseOffset
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
    /// falling back to the standard genetic code. This matters most
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

    // MARK: - Coding Layout

    /// A CDS read from its provider and ready to translate.
    package struct CodingLayout {
        /// The bases that were read, in transcription order and on the coding strand.
        package let codingSequence: String

        /// The genomic coordinate of each base of `codingSequence`.
        package let genomicPositions: [Int]

        /// Bases to skip before the first whole codon.
        package let phaseOffset: Int

        /// Whole codons of the full CDS before the first whole codon that was read. The first codon read is
        /// residue codonsBeforeFirstRead + 1 of the protein.
        package var codonsBeforeFirstRead: Int = 0
    }

    /// One segment of a CDS as its provider returned it.
    private struct ReadSegment {
        let interval: AnnotationInterval
        let read: SegmentRead
        let baseCount: Int

        /// Bases of the segment that the read left out at its 5' end.
        let fivePrimeLoss: Int

        /// Bases of the segment that the read left out at its 3' end.
        let threePrimeLoss: Int
    }

    /// The intervals of `annotation` in transcription order.
    ///
    /// For an ordinary linear feature this is ascending genomic order on '+' and descending on '-', matching the
    /// app-level rendering convention (`SequenceViewerView.codingCoordinateOrder`). `SequenceAnnotation.intervals`
    /// is no longer force-sorted ascending by `SequenceAnnotation.init`, so for an origin-spanning feature on a
    /// circular molecule (GenBank `join(4000..4200,1..100)`) the stored order already is the transcription
    /// order. Sorting it in either direction would scramble it, since no single genomic direction recovers the
    /// order across an origin wrap. `annotation.isOriginSpanning` tells the two cases apart from the interval
    /// coordinates alone.
    private static func transcriptionOrder(of annotation: SequenceAnnotation) -> [AnnotationInterval] {
        if annotation.isOriginSpanning {
            return annotation.intervals
        }
        let ascending = annotation.intervals.sorted { $0.start < $1.start }
        return annotation.strand == .reverse ? ascending.reversed() : ascending
    }

    /// Reads every segment of `annotation`, joins the bases in transcription order and finds the frame.
    ///
    /// Returns nil when no segment could be read, when a segment fails between two that were read, and when
    /// a clip leaves a gap between two segments. The rule for the frame is on `translateCDS`.
    package static func codingLayout(
        annotation: SequenceAnnotation,
        segmentProvider: (Int, Int) -> SegmentRead?
    ) -> CodingLayout? {
        guard !annotation.intervals.isEmpty else { return nil }

        let isReverse = annotation.strand == .reverse
        let ordered = transcriptionOrder(of: annotation)

        // Read each segment in transcription order. A segment that fails before the first one that reads
        // is lost at the 5' end of the CDS. One that fails after it and is followed by another that reads
        // leaves a hole.
        var segments: [ReadSegment] = []
        var droppedBeforeFirst = 0
        var failedSinceLastRead = false
        for interval in ordered where interval.length > 0 {
            guard let read = segmentProvider(interval.start, interval.end), !read.sequence.isEmpty else {
                if segments.isEmpty {
                    droppedBeforeFirst += interval.length
                } else {
                    failedSinceLastRead = true
                }
                continue
            }
            if failedSinceLastRead { return nil }

            // The part of the segment that the read left out at its low and at its high coordinate. The
            // 5' end of a segment is its high end on the reverse strand and its low end on the forward strand.
            let baseCount = read.sequence.count
            let lowLoss = max(0, read.start - interval.start)
            let highLoss = max(0, interval.end - (read.start + baseCount))
            segments.append(ReadSegment(
                interval: interval,
                read: read,
                baseCount: baseCount,
                fivePrimeLoss: isReverse ? highLoss : lowLoss,
                threePrimeLoss: isReverse ? lowLoss : highLoss
            ))
        }

        guard let first = segments.first else { return nil }

        // Only the 5' end of the first segment and the 3' end of the last may be short. A short end
        // anywhere else leaves a gap in the coding sequence.
        for (index, segment) in segments.enumerated() {
            if index > 0 && segment.fivePrimeLoss > 0 { return nil }
            if index < segments.count - 1 && segment.threePrimeLoss > 0 { return nil }
        }

        // Join the bases in transcription order. On the reverse strand each segment is reverse-complemented
        // on its own and then joined. That equals rc(exonN)+...+rc(exon1) for a genomic-ascending '-' feature
        // and is also right for an origin-spanning feature whose stored order already reflects 5'->3'
        // transcription. Per segment, coding position 0 maps to the highest genomic base that was read and
        // counts down on the reverse strand, and to the lowest and counts up on the forward strand.
        var codingSequence = ""
        var genomicPositions: [Int] = []
        for segment in segments {
            if isReverse {
                codingSequence += reverseComplement(segment.read.sequence)
                let top = min(segment.read.start + segment.baseCount, segment.interval.end)
                genomicPositions.append(contentsOf: (0..<segment.baseCount).map { top - 1 - $0 })
            } else {
                codingSequence += segment.read.sequence
                genomicPositions.append(contentsOf: (0..<segment.baseCount).map { segment.read.start + $0 })
            }
        }

        // p is the phase of the segment the read loop meets first, whether or not it could be read.
        let fivePrimePhase = ordered.first(where: { $0.length > 0 })?.phase
        let phaseOffset = frameOffset(
            first: first,
            fivePrimePhase: fivePrimePhase,
            basesDroppedBeforeFirst: droppedBeforeFirst
        )

        // The first whole codon of the full CDS starts at its base p. The first whole codon that was read starts at
        // base (r + offset) of the full CDS. Under the rule above the codons between the two are whole, so the
        // distance is a multiple of three, and it is 0 when nothing was lost.
        let codonsBeforeFirstRead = max(
            0, (droppedBeforeFirst + first.fivePrimeLoss + phaseOffset - (fivePrimePhase ?? 0)) / 3
        )

        return CodingLayout(
            codingSequence: codingSequence,
            genomicPositions: genomicPositions,
            phaseOffset: phaseOffset,
            codonsBeforeFirstRead: codonsBeforeFirstRead
        )
    }

    /// Bases to skip before the first whole codon of the bases that were read.
    ///
    /// With nothing lost at the 5' end this is the phase recorded on the first segment, as it has always been.
    /// Otherwise it is ((p - r) mod 3), with p the phase of the original 5'-most segment and r every coding base
    /// lost before the first base that was read, whole segments and the bases cut inside the first read segment
    /// alike (decision G1). A phase recorded on a later segment is not used, so a clip never moves the frame of
    /// a base that is still read.
    private static func frameOffset(
        first: ReadSegment,
        fivePrimePhase: Int?,
        basesDroppedBeforeFirst: Int
    ) -> Int {
        if basesDroppedBeforeFirst == 0 && first.fivePrimeLoss == 0 {
            return first.interval.phase ?? 0
        }
        return wrapToCodon((fivePrimePhase ?? 0) - basesDroppedBeforeFirst - first.fivePrimeLoss)
    }

    /// `value` taken to 0, 1 or 2, counting back from a multiple of three when it is negative.
    private static func wrapToCodon(_ value: Int) -> Int {
        ((value % 3) + 3) % 3
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
