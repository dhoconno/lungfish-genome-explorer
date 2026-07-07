// AnnotationDatabaseRecord.swift - SQLite-backed annotation metadata database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

// MARK: - AnnotationDatabaseRecord

/// A single annotation record from the SQLite database.
public struct AnnotationDatabaseRecord: Sendable {
    public let rowID: Int64?
    public let name: String
    public let type: String
    public let chromosome: String
    public let start: Int
    public let end: Int
    public let strand: String
    /// GFF3 attributes string (semicolon-delimited key=value pairs), if available.
    public let attributes: String?
    /// Number of blocks (BED12 column 9). Nil for single-interval features.
    public let blockCount: Int?
    /// Comma-separated block sizes (BED12 column 10), e.g. "120,300,200".
    public let blockSizes: String?
    /// Comma-separated block starts relative to `start` (BED12 column 11), e.g. "0,500,2000".
    public let blockStarts: String?
    /// Gene name extracted from the GFF3 `gene` attribute, for cross-feature search.
    public let geneName: String?

    public init(rowID: Int64? = nil, name: String, type: String, chromosome: String, start: Int, end: Int, strand: String, attributes: String? = nil, blockCount: Int? = nil, blockSizes: String? = nil, blockStarts: String? = nil, geneName: String? = nil) {
        self.rowID = rowID
        self.name = name
        self.type = type
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.strand = strand
        self.attributes = attributes
        self.blockCount = blockCount
        self.blockSizes = blockSizes
        self.blockStarts = blockStarts
        self.geneName = geneName
    }
}

// MARK: - AnnotationDatabaseRecord → SequenceAnnotation

extension AnnotationDatabaseRecord {
    /// Converts this database record to a `SequenceAnnotation` for rendering.
    ///
    /// Block data (blockCount/blockSizes/blockStarts) is used to create multi-interval
    /// annotations for discontinuous features (e.g., mRNA with exons). When block data
    /// is absent (v2 schema or single-interval features), a single interval is created.
    public func toAnnotation() -> SequenceAnnotation {
        let annotationType = AnnotationType.from(rawString: type) ?? .gene

        let strandValue: Strand
        switch strand {
        case "+": strandValue = .forward
        case "-": strandValue = .reverse
        default: strandValue = .unknown
        }

        // Build intervals from BED12 block data if available
        var intervals: [AnnotationInterval]
        if let bc = blockCount, bc > 1,
           let sizes = blockSizes, let starts = blockStarts {
            let sizeArr = sizes.split(separator: ",").compactMap { Int($0) }
            let startArr = starts.split(separator: ",").compactMap { Int($0) }
            if sizeArr.count >= bc && startArr.count >= bc {
                intervals = (0..<bc).map { i in
                    AnnotationInterval(
                        start: start + startArr[i],
                        end: start + startArr[i] + sizeArr[i]
                    )
                }
            } else {
                intervals = [AnnotationInterval(start: start, end: end)]
            }
        } else {
            intervals = [AnnotationInterval(start: start, end: end)]
        }

        // Parse qualifiers from GFF3-style attributes
        var qualifiers: [String: AnnotationQualifier] = [:]
        if let attrs = attributes {
            for pair in attrs.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0])
                    let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    qualifiers[key] = AnnotationQualifier(value)
                }
            }
        }
        if let rowID {
            qualifiers["annotation_db_row_id"] = AnnotationQualifier(String(rowID))
        }
        if let geneName, qualifiers["gene_name"] == nil {
            qualifiers["gene_name"] = AnnotationQualifier(geneName)
        }

        return SequenceAnnotation(
            type: annotationType,
            name: name,
            chromosome: chromosome,
            intervals: intervals,
            strand: strandValue,
            qualifiers: qualifiers
        )
    }
}

// MARK: - Coordinate Transformation for Extraction

extension AnnotationDatabaseRecord {

    /// Transforms this record's coordinates from source chromosome space to
    /// extracted sequence space.
    ///
    /// Handles single-interval and multi-block (BED12) annotations. Clips intervals
    /// to the extraction region boundaries. Returns nil if the annotation is fully
    /// outside the extraction region after clipping.
    ///
    /// - Parameters:
    ///   - extractionStart: Effective start of the extraction region (0-based inclusive)
    ///   - extractionEnd: Effective end of the extraction region (0-based exclusive)
    ///   - isReverseComplement: Whether the extracted sequence was reverse-complemented
    ///   - newChromosome: Chromosome name in the new bundle (from .fai)
    /// - Returns: A new record with transformed coordinates, or nil if fully clipped away
    public func transformed(
        extractionStart: Int,
        extractionEnd: Int,
        isReverseComplement: Bool,
        newChromosome: String
    ) -> AnnotationDatabaseRecord? {
        // Parse blocks into absolute intervals
        var absoluteBlocks: [(start: Int, end: Int)]
        if let bc = blockCount, bc > 1,
           let sizes = blockSizes, let starts = blockStarts {
            let sizeArr = sizes.split(separator: ",").compactMap { Int($0) }
            let startArr = starts.split(separator: ",").compactMap { Int($0) }
            let count = min(bc, min(sizeArr.count, startArr.count))
            absoluteBlocks = (0..<count).map { i in
                (start: start + startArr[i], end: start + startArr[i] + sizeArr[i])
            }
        } else {
            absoluteBlocks = [(start: start, end: end)]
        }

        // Clip blocks to extraction region
        var clippedBlocks: [(start: Int, end: Int)] = []
        for block in absoluteBlocks {
            let clippedStart = max(block.start, extractionStart)
            let clippedEnd = min(block.end, extractionEnd)
            if clippedEnd > clippedStart {
                clippedBlocks.append((start: clippedStart, end: clippedEnd))
            }
        }

        guard !clippedBlocks.isEmpty else { return nil }

        // Transform to new coordinate system
        var transformedBlocks: [(start: Int, end: Int)]
        let newStrand: String

        if isReverseComplement {
            transformedBlocks = clippedBlocks.map { block in
                (start: extractionEnd - block.end, end: extractionEnd - block.start)
            }
            transformedBlocks.reverse()
            switch strand {
            case "+": newStrand = "-"
            case "-": newStrand = "+"
            default: newStrand = strand
            }
        } else {
            transformedBlocks = clippedBlocks.map { block in
                (start: block.start - extractionStart, end: block.end - extractionStart)
            }
            newStrand = strand
        }

        let newStart = transformedBlocks.map(\.start).min()!
        let newEnd = transformedBlocks.map(\.end).max()!

        // Recompute BED12 block fields relative to newStart
        let newBlockCount: Int?
        let newBlockSizes: String?
        let newBlockStarts: String?

        if transformedBlocks.count > 1 {
            newBlockCount = transformedBlocks.count
            newBlockSizes = transformedBlocks.map { "\($0.end - $0.start)" }.joined(separator: ",") + ","
            newBlockStarts = transformedBlocks.map { "\($0.start - newStart)" }.joined(separator: ",") + ","
        } else {
            newBlockCount = nil
            newBlockSizes = nil
            newBlockStarts = nil
        }

        return AnnotationDatabaseRecord(
            name: name,
            type: type,
            chromosome: newChromosome,
            start: newStart,
            end: newEnd,
            strand: newStrand,
            attributes: attributes,
            blockCount: newBlockCount,
            blockSizes: newBlockSizes,
            blockStarts: newBlockStarts,
            geneName: geneName
        )
    }

    /// Serializes this record as a BED12+ tab-separated line compatible with
    /// `AnnotationDatabase.createFromBED()`.
    ///
    /// Format: chrom, start, end, name, score, strand, thickStart, thickEnd, rgb,
    /// blockCount, blockSizes, blockStarts, type, attributes
    public func toBED12PlusLine() -> String {
        let bc = blockCount ?? 1
        let bs = blockSizes ?? "\(end - start),"
        let bst = blockStarts ?? "0,"

        let fields: [String] = [
            chromosome,
            "\(start)",
            "\(end)",
            name,
            "0",
            strand,
            "\(start)",
            "\(end)",
            "0,0,0",
            "\(bc)",
            bs,
            bst,
            type,
            attributes ?? ""
        ]
        return fields.joined(separator: "\t")
    }
}

// MARK: - Errors

public enum AnnotationDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case invalidSchema(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open annotation database: \(msg)"
        case .createFailed(let msg): return "Failed to create annotation database: \(msg)"
        case .invalidSchema(let msg): return "Invalid annotation database schema: \(msg)"
        }
    }
}
