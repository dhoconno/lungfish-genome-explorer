// SequenceExtractor.swift - Sequence extraction from annotations and regions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Extraction Request

/// Describes what sequence to extract and how.
public struct ExtractionRequest: Sendable {

    /// The source of the extraction.
    public enum Source: Sendable {
        /// A genomic region defined by coordinates.
        case region(chromosome: String, start: Int, end: Int)
        /// An annotation (may be discontiguous).
        case annotation(SequenceAnnotation)
    }

    /// Where to extract from.
    public let source: Source

    /// Bases of 5' flanking sequence to include.
    public let flank5Prime: Int

    /// Bases of 3' flanking sequence to include.
    public let flank3Prime: Int

    /// Whether to reverse-complement the extracted sequence.
    public let reverseComplement: Bool

    /// For discontiguous annotations: if true, concatenate exons (remove introns).
    public let concatenateExons: Bool

    public init(
        source: Source,
        flank5Prime: Int = 0,
        flank3Prime: Int = 0,
        reverseComplement: Bool = false,
        concatenateExons: Bool = false
    ) {
        self.source = source
        self.flank5Prime = max(0, flank5Prime)
        self.flank3Prime = max(0, flank3Prime)
        self.reverseComplement = reverseComplement
        self.concatenateExons = concatenateExons
    }

    /// Builds the default extraction request for an annotation, in feature
    /// (5'->3') orientation (SCI-06): reverse-complements a minus-strand
    /// feature and concatenates exons for spliced types, matching every other
    /// genome tool (UCSC, gffread, SnapGene, Geneious). Callers that need the
    /// raw plus-strand genomic span with introns intact — an explicit
    /// "genomic span as-is" — should construct `ExtractionRequest` directly
    /// with `reverseComplement: false, concatenateExons: false` instead.
    public static func defaultAnnotationRequest(
        for annotation: SequenceAnnotation,
        flank5Prime: Int = 0,
        flank3Prime: Int = 0
    ) -> ExtractionRequest {
        let splicedTypes: Set<AnnotationType> = [.cds, .mRNA, .transcript]
        return ExtractionRequest(
            source: .annotation(annotation),
            flank5Prime: flank5Prime,
            flank3Prime: flank3Prime,
            reverseComplement: annotation.strand == .reverse,
            concatenateExons: annotation.isDiscontinuous && splicedTypes.contains(annotation.type)
        )
    }
}

// MARK: - Extraction Result

/// The result of a sequence extraction.
public struct ExtractionResult: Sendable {

    /// FASTA header line (without the leading ">").
    public let fastaHeader: String

    /// The extracted nucleotide sequence.
    public let nucleotideSequence: String

    /// The translated protein sequence (CDS annotations only).
    public let proteinSequence: String?

    /// Name of the source (annotation name or region description).
    public let sourceName: String

    /// Chromosome the extraction came from.
    public let chromosome: String

    /// Effective start coordinate (including flanking, clamped).
    public let effectiveStart: Int

    /// Effective end coordinate (including flanking, clamped).
    public let effectiveEnd: Int

    /// Whether the sequence was reverse-complemented.
    public let isReverseComplement: Bool

    public init(
        fastaHeader: String,
        nucleotideSequence: String,
        proteinSequence: String?,
        sourceName: String,
        chromosome: String,
        effectiveStart: Int,
        effectiveEnd: Int,
        isReverseComplement: Bool
    ) {
        self.fastaHeader = fastaHeader
        self.nucleotideSequence = nucleotideSequence
        self.proteinSequence = proteinSequence
        self.sourceName = sourceName
        self.chromosome = chromosome
        self.effectiveStart = effectiveStart
        self.effectiveEnd = effectiveEnd
        self.isReverseComplement = isReverseComplement
    }
}

// MARK: - Extraction Errors

public enum ExtractionError: Error, LocalizedError {
    case emptyRegion
    case sequenceNotAvailable(String)
    case chromosomeLengthUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRegion:
            return "The extraction region is empty."
        case .sequenceNotAvailable(let detail):
            return "Sequence not available: \(detail)"
        case .chromosomeLengthUnknown(let chrom):
            return "Chromosome length unknown for '\(chrom)'."
        }
    }
}

// MARK: - Sequence Extractor

/// Pure extraction logic — no AppKit, testable, reusable by CLI.
public enum SequenceExtractor {

    /// A closure that provides nucleotide sequence for a genomic region.
    /// Parameters: chromosome, start (0-based inclusive), end (0-based exclusive).
    /// Returns the sequence string or nil if unavailable.
    public typealias SequenceProvider = (String, Int, Int) -> String?

    /// Extracts sequence according to the request.
    ///
    /// - Parameters:
    ///   - request: What to extract and how.
    ///   - sequenceProvider: Provides raw nucleotide sequence for a region.
    ///   - chromosomeLength: Length of the chromosome (for clamping flanking).
    /// - Returns: The extraction result.
    /// - Throws: `ExtractionError` if extraction fails.
    public static func extract(
        request: ExtractionRequest,
        sequenceProvider: SequenceProvider,
        chromosomeLength: Int
    ) throws -> ExtractionResult {
        switch request.source {
        case .region(let chromosome, let start, let end):
            return try extractRegion(
                chromosome: chromosome,
                start: start,
                end: end,
                flank5Prime: request.flank5Prime,
                flank3Prime: request.flank3Prime,
                reverseComplement: request.reverseComplement,
                sequenceProvider: sequenceProvider,
                chromosomeLength: chromosomeLength,
                sourceName: "\(chromosome):\(start)-\(end)"
            )

        case .annotation(let annotation):
            return try extractAnnotation(
                annotation: annotation,
                flank5Prime: request.flank5Prime,
                flank3Prime: request.flank3Prime,
                reverseComplement: request.reverseComplement,
                concatenateExons: request.concatenateExons,
                sequenceProvider: sequenceProvider,
                chromosomeLength: chromosomeLength
            )
        }
    }

    /// Formats an extraction result as a FASTA string (nucleotide).
    public static func formatFASTA(_ result: ExtractionResult, lineWidth: Int = 70) -> String {
        var fasta = ">\(result.fastaHeader)\n"
        fasta += wrapSequence(result.nucleotideSequence, lineWidth: lineWidth)
        return fasta
    }

    /// Formats an extraction result as a protein FASTA string.
    /// Returns nil if no protein sequence is available.
    public static func formatProteinFASTA(_ result: ExtractionResult, lineWidth: Int = 70) -> String? {
        guard let protein = result.proteinSequence else { return nil }
        var fasta = ">\(result.fastaHeader) [protein]\n"
        fasta += wrapSequence(protein, lineWidth: lineWidth)
        return fasta
    }

    // MARK: - Private Helpers

    private static func extractRegion(
        chromosome: String,
        start: Int,
        end: Int,
        flank5Prime: Int,
        flank3Prime: Int,
        reverseComplement: Bool,
        sequenceProvider: SequenceProvider,
        chromosomeLength: Int,
        sourceName: String
    ) throws -> ExtractionResult {
        guard end > start else { throw ExtractionError.emptyRegion }

        // Apply flanking, clamped to chromosome bounds
        let effectiveStart = max(0, start - flank5Prime)
        let effectiveEnd = min(chromosomeLength, end + flank3Prime)

        guard let rawSequence = sequenceProvider(chromosome, effectiveStart, effectiveEnd) else {
            throw ExtractionError.sequenceNotAvailable(
                "\(chromosome):\(effectiveStart)-\(effectiveEnd)"
            )
        }

        let nucleotideSequence: String
        if reverseComplement {
            nucleotideSequence = TranslationEngine.reverseComplement(rawSequence)
        } else {
            nucleotideSequence = rawSequence
        }

        let header = buildHeader(
            name: sourceName,
            chromosome: chromosome,
            start: effectiveStart,
            end: effectiveEnd,
            length: nucleotideSequence.count,
            reverseComplement: reverseComplement,
            concatenated: false
        )

        return ExtractionResult(
            fastaHeader: header,
            nucleotideSequence: nucleotideSequence,
            proteinSequence: nil,
            sourceName: sourceName,
            chromosome: chromosome,
            effectiveStart: effectiveStart,
            effectiveEnd: effectiveEnd,
            isReverseComplement: reverseComplement
        )
    }

    private static func extractAnnotation(
        annotation: SequenceAnnotation,
        flank5Prime: Int,
        flank3Prime: Int,
        reverseComplement: Bool,
        concatenateExons: Bool,
        sequenceProvider: SequenceProvider,
        chromosomeLength: Int
    ) throws -> ExtractionResult {
        let chromosome = annotation.chromosome ?? ""
        guard !annotation.intervals.isEmpty else { throw ExtractionError.emptyRegion }

        let genomicOrderIntervals = annotation.intervals.sorted { $0.start < $1.start }
        let boundingStart = genomicOrderIntervals.first!.start
        let boundingEnd = genomicOrderIntervals.last!.end

        // Transcription order: ascending genomic order on '+', descending on
        // '-' for an ordinary linear feature — matching `TranslationEngine.
        // translateCDS` and the app-level rendering convention. For an
        // origin-spanning feature on a circular molecule, the annotation's
        // stored interval order already IS transcription order (SCI-15) and
        // must not be re-sorted in either genomic direction.
        let transcriptionOrderIntervals: [AnnotationInterval] = annotation.isOriginSpanning
            ? annotation.intervals
            : (annotation.strand == .reverse ? genomicOrderIntervals.reversed() : genomicOrderIntervals)

        // SCI-06: flanks are specified in feature orientation (5' flank is
        // upstream of the gene, 3' flank is downstream), not by coordinate. For
        // a minus-strand feature, "upstream" is the higher genomic coordinate,
        // so the flank amounts are swapped before being applied to the genomic
        // bounding box.
        let isReverseStrand = annotation.strand == .reverse
        let genomicFlank5 = isReverseStrand ? flank3Prime : flank5Prime
        let genomicFlank3 = isReverseStrand ? flank5Prime : flank3Prime

        let finalSequence: String
        let effectiveStart: Int
        let effectiveEnd: Int
        let isConcatenated: Bool

        if annotation.isDiscontinuous && concatenateExons {
            // Concatenate exon sequences, add flanking to outer bounds
            let flankStart = max(0, boundingStart - genomicFlank5)
            let flankEnd = min(chromosomeLength, boundingEnd + genomicFlank3)
            effectiveStart = flankStart
            effectiveEnd = flankEnd

            // Fetch the two flanking segments once, in genomic order.
            let lowFlankSeq: String? = flankStart < boundingStart
                ? sequenceProvider(chromosome, flankStart, boundingStart)
                : nil
            let highFlankSeq: String? = boundingEnd < flankEnd
                ? sequenceProvider(chromosome, boundingEnd, flankEnd)
                : nil

            // Exon sequences, individually reverse-complemented when requested
            // and assembled in transcription order — matching
            // `TranslationEngine.translateCDS` (SCI-06/SCI-15). Whole-string RC
            // of a single ascending-order concatenation is only equivalent to
            // this for a linear feature; it is NOT equivalent for an
            // origin-spanning circular feature, whose stored interval order is
            // already transcription order rather than genomic-ascending.
            var exonParts: [String] = []
            for interval in transcriptionOrderIntervals {
                guard let exonSeq = sequenceProvider(chromosome, interval.start, interval.end) else {
                    throw ExtractionError.sequenceNotAvailable(
                        "\(chromosome):\(interval.start)-\(interval.end)"
                    )
                }
                exonParts.append(reverseComplement ? TranslationEngine.reverseComplement(exonSeq) : exonSeq)
            }
            let exonsInOrder = exonParts.joined()

            if reverseComplement {
                // Feature 5' end is the genomic-high-coordinate side on the
                // reverse strand, so the (already individually RC'd) high-side
                // flank comes first, then the exons, then the low-side flank.
                let rcHighFlank = highFlankSeq.map { TranslationEngine.reverseComplement($0) } ?? ""
                let rcLowFlank = lowFlankSeq.map { TranslationEngine.reverseComplement($0) } ?? ""
                finalSequence = rcHighFlank + exonsInOrder + rcLowFlank
            } else {
                finalSequence = (lowFlankSeq ?? "") + exonsInOrder + (highFlankSeq ?? "")
            }
            isConcatenated = true
        } else {
            // Contiguous: fetch full bounding region + flanking
            effectiveStart = max(0, boundingStart - genomicFlank5)
            effectiveEnd = min(chromosomeLength, boundingEnd + genomicFlank3)

            guard let rawSequence = sequenceProvider(chromosome, effectiveStart, effectiveEnd) else {
                throw ExtractionError.sequenceNotAvailable(
                    "\(chromosome):\(effectiveStart)-\(effectiveEnd)"
                )
            }
            finalSequence = reverseComplement ? TranslationEngine.reverseComplement(rawSequence) : rawSequence
            isConcatenated = false
        }

        // CDS translation
        let proteinSequence: String?
        if annotation.type == .cds {
            let result = TranslationEngine.translateCDS(
                annotation: annotation,
                sequenceProvider: { start, end in
                    sequenceProvider(chromosome, start, end)
                }
            )
            proteinSequence = result?.protein
        } else {
            proteinSequence = nil
        }

        let header = buildHeader(
            name: annotation.name,
            chromosome: chromosome,
            start: effectiveStart,
            end: effectiveEnd,
            length: finalSequence.count,
            reverseComplement: reverseComplement,
            concatenated: isConcatenated,
            strand: annotation.strand,
            annotationType: annotation.type,
            featureOrientation: reverseComplement || isConcatenated
        )

        return ExtractionResult(
            fastaHeader: header,
            nucleotideSequence: finalSequence,
            proteinSequence: proteinSequence,
            sourceName: annotation.name,
            chromosome: chromosome,
            effectiveStart: effectiveStart,
            effectiveEnd: effectiveEnd,
            isReverseComplement: reverseComplement
        )
    }

    private static func buildHeader(
        name: String,
        chromosome: String,
        start: Int,
        end: Int,
        length: Int,
        reverseComplement: Bool,
        concatenated: Bool,
        strand: Strand? = nil,
        annotationType: AnnotationType? = nil,
        featureOrientation: Bool = false
    ) -> String {
        var parts = [name]
        parts.append("[\(chromosome):\(start)-\(end)]")

        if let type = annotationType {
            parts.append("[\(type.rawValue)]")
        }

        if let strand = strand, strand != .unknown {
            parts.append("[strand: \(strand.rawValue)]")
        }

        if reverseComplement {
            parts.append("[reverse complement]")
        }

        if concatenated {
            parts.append("[exons concatenated]")
        }

        // SCI-06: label output that has been reoriented to feature (5'->3')
        // orientation, as distinct from the raw plus-strand genomic span, so a
        // reader is not misled about which convention the header coordinates
        // and sequence follow.
        if featureOrientation {
            parts.append("[feature orientation]")
        }

        parts.append("[\(length) bp]")

        return parts.joined(separator: " ")
    }

    private static func wrapSequence(_ sequence: String, lineWidth: Int) -> String {
        guard lineWidth > 0 else { return sequence + "\n" }
        var result = ""
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let end = sequence.index(index, offsetBy: lineWidth, limitedBy: sequence.endIndex) ?? sequence.endIndex
            result += sequence[index..<end]
            result += "\n"
            index = end
        }
        return result
    }
}
