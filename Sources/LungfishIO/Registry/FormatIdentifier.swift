// FormatIdentifier.swift - Unique identifier for file formats
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Part of the Format Registry system (DESIGN-003)

import Foundation

/// Identifies a file format in the registry.
///
/// FormatIdentifier provides a type-safe way to reference file formats throughout
/// the application. Each format has a unique string identifier that is case-insensitive.
///
/// ## Usage
/// ```swift
/// let format = FormatIdentifier.fasta
/// let customFormat = FormatIdentifier("myformat")
/// ```
///
/// ## Built-in Formats
/// The following standard genomic formats are predefined:
/// - Sequence: `.fasta`, `.fastq`, `.genbank`, `.embl`, `.twoBit`
/// - Alignment: `.sam`, `.bam`, `.cram`
/// - Annotation: `.gff3`, `.gtf`, `.bed`
/// - Variant: `.vcf`, `.bcf`
/// - Coverage: `.bigwig`, `.bigbed`, `.bedgraph`
/// - Index: `.fai`, `.bai`, `.csi`, `.tbi`
public struct FormatIdentifier: Hashable, Sendable, Codable, ExpressibleByStringLiteral {

    // MARK: - Properties

    /// The unique identifier string (lowercase)
    public let id: String

    /// File extensions associated with this format
    public let extensions: Set<String>

    /// MIME types for this format
    public let mimeTypes: Set<String>

    // MARK: - Initialization

    /// Creates a format identifier with the given ID.
    ///
    /// - Parameter id: The unique identifier string (will be lowercased)
    public init(_ id: String) {
        self.id = id.lowercased()
        self.extensions = []
        self.mimeTypes = []
    }

    /// Creates a format identifier with ID, extensions, and MIME types.
    ///
    /// - Parameters:
    ///   - id: The unique identifier string (will be lowercased)
    ///   - extensions: File extensions for this format (without leading dot)
    ///   - mimeTypes: MIME types for this format
    public init(_ id: String, extensions: Set<String>, mimeTypes: Set<String> = []) {
        self.id = id.lowercased()
        self.extensions = Set(extensions.map { $0.lowercased() })
        self.mimeTypes = mimeTypes
    }

    /// Creates a format identifier from a string literal.
    public init(stringLiteral value: String) {
        self.id = value.lowercased()
        self.extensions = []
        self.mimeTypes = []
    }

    // MARK: - Hashable & Equatable

    /// Format identifiers are equal if their IDs match (case-insensitive)
    public static func == (lhs: FormatIdentifier, rhs: FormatIdentifier) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.id = rawValue.lowercased()
        self.extensions = []
        self.mimeTypes = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

// MARK: - Standard Format Identifiers

extension FormatIdentifier {

    // MARK: Sequence Formats

    /// FASTA sequence format (.fa, .fasta, .fna, .faa, .ffn, .frn)
    public static let fasta = FormatIdentifier(
        "fasta",
        extensions: ["fa", "fasta", "fna", "faa", "ffn", "frn"],
        mimeTypes: ["text/x-fasta"]
    )

    /// FASTQ sequence format with quality scores (.fq, .fastq)
    public static let fastq = FormatIdentifier(
        "fastq",
        extensions: ["fq", "fastq"],
        mimeTypes: ["text/x-fastq"]
    )

    /// GenBank annotated sequence format (.gb, .gbk, .genbank, .gbff)
    public static let genbank = FormatIdentifier(
        "genbank",
        extensions: ["gb", "gbk", "genbank", "gbff"],
        mimeTypes: ["text/x-genbank"]
    )

    /// EMBL annotated sequence format (.embl)
    public static let embl = FormatIdentifier(
        "embl",
        extensions: ["embl"],
        mimeTypes: ["text/x-embl"]
    )

    /// 2bit compressed sequence format (.2bit)
    public static let twoBit = FormatIdentifier(
        "2bit",
        extensions: ["2bit"],
        mimeTypes: ["application/x-2bit"]
    )

    // MARK: Alignment Formats

    /// SAM text alignment format (.sam)
    public static let sam = FormatIdentifier(
        "sam",
        extensions: ["sam"],
        mimeTypes: ["text/x-sam"]
    )

    /// BAM binary alignment format (.bam)
    public static let bam = FormatIdentifier(
        "bam",
        extensions: ["bam"],
        mimeTypes: ["application/x-bam"]
    )

    /// CRAM compressed alignment format (.cram)
    public static let cram = FormatIdentifier(
        "cram",
        extensions: ["cram"],
        mimeTypes: ["application/x-cram"]
    )

    // MARK: Annotation Formats

    /// GFF3 annotation format (.gff, .gff3)
    public static let gff3 = FormatIdentifier(
        "gff3",
        extensions: ["gff", "gff3"],
        mimeTypes: ["text/x-gff3"]
    )

    /// GTF annotation format (.gtf)
    public static let gtf = FormatIdentifier(
        "gtf",
        extensions: ["gtf"],
        mimeTypes: ["text/x-gtf"]
    )

    /// BED annotation format (.bed)
    public static let bed = FormatIdentifier(
        "bed",
        extensions: ["bed"],
        mimeTypes: ["text/x-bed"]
    )

    // MARK: Variant Formats

    /// VCF variant format (.vcf)
    public static let vcf = FormatIdentifier(
        "vcf",
        extensions: ["vcf"],
        mimeTypes: ["text/x-vcf"]
    )

    /// BCF binary variant format (.bcf)
    public static let bcf = FormatIdentifier(
        "bcf",
        extensions: ["bcf"],
        mimeTypes: ["application/x-bcf"]
    )

    // MARK: Coverage/Signal Formats

    /// BigWig coverage format (.bw, .bigwig, .bigWig)
    public static let bigwig = FormatIdentifier(
        "bigwig",
        extensions: ["bw", "bigwig"],
        mimeTypes: ["application/x-bigwig"]
    )

    /// BigBed annotation format (.bb, .bigbed, .bigBed)
    public static let bigbed = FormatIdentifier(
        "bigbed",
        extensions: ["bb", "bigbed"],
        mimeTypes: ["application/x-bigbed"]
    )

    /// bedGraph coverage format (.bedgraph, .bg)
    public static let bedgraph = FormatIdentifier(
        "bedgraph",
        extensions: ["bedgraph", "bg"],
        mimeTypes: ["text/x-bedgraph"]
    )

    // MARK: Index Formats

    /// FASTA index format (.fai)
    public static let fai = FormatIdentifier(
        "fai",
        extensions: ["fai"],
        mimeTypes: ["text/x-fai"]
    )

    /// BAM index format (.bai)
    public static let bai = FormatIdentifier(
        "bai",
        extensions: ["bai"],
        mimeTypes: ["application/x-bai"]
    )

    /// CSI index format (.csi)
    public static let csi = FormatIdentifier(
        "csi",
        extensions: ["csi"],
        mimeTypes: ["application/x-csi"]
    )

    /// Tabix index format (.tbi)
    public static let tbi = FormatIdentifier(
        "tbi",
        extensions: ["tbi"],
        mimeTypes: ["application/x-tbi"]
    )

    // MARK: Document Formats

    /// PDF document format (.pdf)
    public static let pdf = FormatIdentifier(
        "pdf",
        extensions: ["pdf"],
        mimeTypes: ["application/pdf"]
    )

    /// Plain text format (.txt, .text)
    public static let plainText = FormatIdentifier(
        "plaintext",
        extensions: ["txt", "text"],
        mimeTypes: ["text/plain"]
    )

    /// Markdown format (.md, .markdown)
    public static let markdown = FormatIdentifier(
        "markdown",
        extensions: ["md", "markdown"],
        mimeTypes: ["text/markdown"]
    )

    /// CSV format (.csv)
    public static let csv = FormatIdentifier(
        "csv",
        extensions: ["csv"],
        mimeTypes: ["text/csv"]
    )

    /// TSV format (.tsv)
    public static let tsv = FormatIdentifier(
        "tsv",
        extensions: ["tsv"],
        mimeTypes: ["text/tab-separated-values"]
    )

    // MARK: Image Formats

    /// PNG image format (.png)
    public static let png = FormatIdentifier(
        "png",
        extensions: ["png"],
        mimeTypes: ["image/png"]
    )

    /// JPEG image format (.jpg, .jpeg)
    public static let jpeg = FormatIdentifier(
        "jpeg",
        extensions: ["jpg", "jpeg"],
        mimeTypes: ["image/jpeg"]
    )

    /// TIFF image format (.tiff, .tif)
    public static let tiff = FormatIdentifier(
        "tiff",
        extensions: ["tiff", "tif"],
        mimeTypes: ["image/tiff"]
    )

    /// SVG image format (.svg)
    public static let svg = FormatIdentifier(
        "svg",
        extensions: ["svg"],
        mimeTypes: ["image/svg+xml"]
    )

    // MARK: Bundle Formats

    /// Lungfish reference bundle format (.lungfishref)
    public static let lungfishRef = FormatIdentifier(
        "lungfishref",
        extensions: ["lungfishref"],
        mimeTypes: ["application/x-lungfishref"]
    )

    /// Lungfish 12S amplicon reference bundle format (.lungfish12sref)
    public static let lungfish12SRef = FormatIdentifier(
        "lungfish12sref",
        extensions: ["lungfish12sref"],
        mimeTypes: ["application/x-lungfish12sref"]
    )

    /// Lungfish MHC amplicon reference bundle format (.lungfishmhcref)
    public static let lungfishMHCRef = FormatIdentifier(
        "lungfishmhcref",
        extensions: ["lungfishmhcref"],
        mimeTypes: ["application/x-lungfishmhcref"]
    )
}

// MARK: - CustomStringConvertible

extension FormatIdentifier: CustomStringConvertible {
    public var description: String {
        id
    }
}

// MARK: - CustomDebugStringConvertible

extension FormatIdentifier: CustomDebugStringConvertible {
    public var debugDescription: String {
        "FormatIdentifier(\(id))"
    }
}
