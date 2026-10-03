// FileFormat.swift - Recognized genomic file formats
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

// MARK: - FileFormat

/// Recognized genomic file formats.
public enum FileFormat: String, Codable, Sendable {
    case fasta
    case fastq
    case bam
    case cram
    case sam
    case vcf
    case bcf
    case gff3
    case bed
    case bigBed
    case bigWig
    case genBank
    case html
    case json
    case sqlite
    case text
    /// A BAM index (`.bai`).
    case bai
    /// A coordinate-sorted index (`.csi`) of a BAM, BCF or VCF.
    case csi
    /// A CRAM index (`.crai`).
    case crai
    /// A tabix index (`.tbi`) of a compressed VCF, BED or GFF.
    case tbi
    /// A FASTA index (`.fai`).
    case fai
    /// A BGZF block index (`.gzi`).
    case gzi
    case unknown

    /// The format as a reader sees it (`BAM index`, `FASTQ`).
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
