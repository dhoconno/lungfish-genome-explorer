// FileFormat.swift - The format of a file a provenance record names
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

// MARK: - FileFormat

/// The format of a file a provenance record names, by its raw value (`fastq`, `bai`).
///
/// It is string-backed like `BundleKindID`, so a value this build does not know, such as a later
/// writer's `csv`, decodes and encodes again unchanged inside a record of schema version 2 or later.
/// In a version 1 record such a value fails to decode as it always did, so the record still falls to
/// the primitive adapter and a released record keeps its shape and signing payload. The static
/// members are the values this build knows.
public struct FileFormat: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The format with this raw value when this build knows it, else nil, for a site that maps an
    /// unknown name to a fallback.
    public init?(knownRawValue rawValue: String) {
        guard Self.known.contains(FileFormat(rawValue: rawValue)) else { return nil }
        self.init(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let format = FileFormat(rawValue: try container.decode(String.self))
        guard format.isKnown || ProvenanceFileValueDecoding.acceptsUnknownValues else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot initialize FileFormat from invalid String value \(format.rawValue)"
            )
        }
        self = format
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// True for a value this build knows.
    public var isKnown: Bool { Self.known.contains(self) }

    public static let fasta = FileFormat(rawValue: "fasta")
    public static let fastq = FileFormat(rawValue: "fastq")
    public static let bam = FileFormat(rawValue: "bam")
    public static let cram = FileFormat(rawValue: "cram")
    public static let sam = FileFormat(rawValue: "sam")
    public static let vcf = FileFormat(rawValue: "vcf")
    public static let bcf = FileFormat(rawValue: "bcf")
    public static let gff3 = FileFormat(rawValue: "gff3")
    public static let bed = FileFormat(rawValue: "bed")
    public static let bigBed = FileFormat(rawValue: "bigBed")
    public static let bigWig = FileFormat(rawValue: "bigWig")
    public static let genBank = FileFormat(rawValue: "genBank")
    public static let html = FileFormat(rawValue: "html")
    public static let json = FileFormat(rawValue: "json")
    public static let sqlite = FileFormat(rawValue: "sqlite")
    public static let text = FileFormat(rawValue: "text")
    /// A BAM index (`.bai`).
    public static let bai = FileFormat(rawValue: "bai")
    /// A coordinate-sorted index (`.csi`) of a BAM, BCF or VCF.
    public static let csi = FileFormat(rawValue: "csi")
    /// A CRAM index (`.crai`).
    public static let crai = FileFormat(rawValue: "crai")
    /// A tabix index (`.tbi`) of a compressed VCF, BED or GFF.
    public static let tbi = FileFormat(rawValue: "tbi")
    /// A FASTA index (`.fai`).
    public static let fai = FileFormat(rawValue: "fai")
    /// A BGZF block index (`.gzi`).
    public static let gzi = FileFormat(rawValue: "gzi")
    public static let unknown = FileFormat(rawValue: "unknown")

    /// The values this build knows, which a version 1 record may hold.
    public static let known: Set<FileFormat> = [
        .fasta, .fastq, .bam, .cram, .sam, .vcf, .bcf, .gff3, .bed, .bigBed, .bigWig, .genBank,
        .html, .json, .sqlite, .text, .bai, .csi, .crai, .tbi, .fai, .gzi, .unknown,
    ]

    /// The format as a reader sees it (`BAM index`, `FASTQ`), or the raw value of one this build does
    /// not know.
    public var displayName: String {
        switch self {
        case .fasta: return "FASTA"
        case .fastq: return "FASTQ"
        case .bam: return "BAM"
        case .cram: return "CRAM"
        case .sam: return "SAM"
        case .vcf: return "VCF"
        case .bcf: return "BCF"
        case .gff3: return "GFF3"
        case .bed: return "BED"
        case .bigBed: return "BigBed"
        case .bigWig: return "BigWig"
        case .genBank: return "GenBank"
        case .html: return "HTML"
        case .json: return "JSON"
        case .sqlite: return "SQLite"
        case .text: return "text"
        case .bai: return "BAM index"
        case .csi: return "CSI index"
        case .crai: return "CRAM index"
        case .tbi: return "Tabix index"
        case .fai: return "FASTA index"
        case .gzi: return "BGZF index"
        case .unknown: return "unknown"
        default: return rawValue
        }
    }

    /// The format a file name implies, looking through a `.gz` suffix for
    /// the data formats and at the index suffixes themselves.
    public static func inferred(fromPath path: String) -> FileFormat {
        let url = URL(fileURLWithPath: path)
        var ext = url.pathExtension.lowercased()
        if ext == "gz" {
            ext = url.deletingPathExtension().pathExtension.lowercased()
        }
        switch ext {
        case "fa", "fasta", "fna": return .fasta
        case "fq", "fastq": return .fastq
        case "bam": return .bam
        case "cram": return .cram
        case "sam": return .sam
        case "vcf": return .vcf
        case "bcf": return .bcf
        case "gff", "gff3": return .gff3
        case "bed": return .bed
        case "bb", "bigbed": return .bigBed
        case "bw", "bigwig": return .bigWig
        case "gb", "gbk", "genbank": return .genBank
        case "html": return .html
        case "json": return .json
        case "db", "sqlite", "sqlite3": return .sqlite
        case "txt", "tsv", "csv", "log": return .text
        case "bai": return .bai
        case "csi": return .csi
        case "crai": return .crai
        case "tbi": return .tbi
        case "fai": return .fai
        case "gzi": return .gzi
        default: return .unknown
        }
    }
}

// MARK: - ProvenanceFileValueDecoding

/// Whether a file format or role this build does not know decodes. Only a record of schema version 2
/// or later accepts one, so `ProvenanceEnvelope` sets this while it decodes such a record, and every
/// other decode, a version 1 record or a bare run among them, keeps refusing the value.
enum ProvenanceFileValueDecoding {
    @TaskLocal static var acceptsUnknownValues = false
}
