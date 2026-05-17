// BigBedReader.swift - BigBed detection-only marker types
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A feature decoded from a BigBed file.
///
/// BigBed files remain detectable in the format registry, but Lungfish does not
/// currently ship a supported in-process BigBed parser. Annotation bundles use
/// SQLite-backed stores instead.
public struct BigBedFeature: Sendable, Identifiable {
    public let id: UUID
    public let chromosome: String
    public let start: Int
    public let end: Int
    public let name: String?
    public let score: Int?
    public let strand: Character?
    public let thickStart: Int?
    public let thickEnd: Int?
    public let rgb: String?
    public let blockCount: Int?
    public let blockSizes: [Int]?
    public let blockStarts: [Int]?
    public let additionalFields: [String]

    public init(
        id: UUID = UUID(),
        chromosome: String,
        start: Int,
        end: Int,
        name: String? = nil,
        score: Int? = nil,
        strand: Character? = nil,
        thickStart: Int? = nil,
        thickEnd: Int? = nil,
        rgb: String? = nil,
        blockCount: Int? = nil,
        blockSizes: [Int]? = nil,
        blockStarts: [Int]? = nil,
        additionalFields: [String] = []
    ) {
        self.id = id
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.name = name
        self.score = score
        self.strand = strand
        self.thickStart = thickStart
        self.thickEnd = thickEnd
        self.rgb = rgb
        self.blockCount = blockCount
        self.blockSizes = blockSizes
        self.blockStarts = blockStarts
        self.additionalFields = additionalFields
    }
}

/// Header metadata for a BigBed file.
public struct BigBedHeader: Sendable {
    public let version: UInt16
    public let zoomLevels: UInt16
    public let chromosomeTreeOffset: UInt64
    public let fullDataOffset: UInt64
    public let fullIndexOffset: UInt64
    public let fieldCount: UInt16
    public let definedFieldCount: UInt16
    public let autoSqlOffset: UInt64
    public let totalSummaryOffset: UInt64
    public let uncompressBufSize: UInt32

    public init(
        version: UInt16,
        zoomLevels: UInt16,
        chromosomeTreeOffset: UInt64,
        fullDataOffset: UInt64,
        fullIndexOffset: UInt64,
        fieldCount: UInt16,
        definedFieldCount: UInt16,
        autoSqlOffset: UInt64,
        totalSummaryOffset: UInt64,
        uncompressBufSize: UInt32
    ) {
        self.version = version
        self.zoomLevels = zoomLevels
        self.chromosomeTreeOffset = chromosomeTreeOffset
        self.fullDataOffset = fullDataOffset
        self.fullIndexOffset = fullIndexOffset
        self.fieldCount = fieldCount
        self.definedFieldCount = definedFieldCount
        self.autoSqlOffset = autoSqlOffset
        self.totalSummaryOffset = totalSummaryOffset
        self.uncompressBufSize = uncompressBufSize
    }
}

/// Chromosome metadata from a BigBed file.
public struct BigBedChromosome: Sendable {
    public let name: String
    public let id: UInt32
    public let length: UInt32

    public init(name: String, id: UInt32, length: UInt32) {
        self.name = name
        self.id = id
        self.length = length
    }
}

/// Errors reserved for future BigBed support.
public enum BigBedError: Error, LocalizedError, Sendable {
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "BigBed reading is unavailable; use SQLite-backed annotations or BED/GFF/GTF import paths."
        }
    }
}

/// Unsupported actor-based reader for BigBed binary files.
///
/// BigBed files are detection-only until a complete UCSC/libBigWig-backed
/// implementation is available.
@available(*, unavailable, message: "BigBed reading is unavailable; use SQLite-backed annotations or BED/GFF/GTF import paths instead.")
public actor BigBedReader {}
