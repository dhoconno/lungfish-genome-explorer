// GFF3Writer.swift - Writer for GFF3 format annotation files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - GFF3Writer

/// Writer for GFF3 format annotation files.
///
/// GFF3 format has 9 tab-separated columns:
/// 1. seqid - Sequence ID (chromosome or contig)
/// 2. source - Feature source (e.g., "ENSEMBL", "GenBank")
/// 3. type - Feature type (e.g., "gene", "mRNA", "CDS")
/// 4. start - Start position (1-based, inclusive)
/// 5. end - End position (1-based, inclusive)
/// 6. score - Score or "." for no score
/// 7. strand - +, -, or . for unknown
/// 8. phase - 0, 1, 2 for CDS features, or "." for others
/// 9. attributes - Key=Value pairs separated by ";"
///
/// ## Usage
/// ```swift
/// let writer = try GFF3Writer(url: outputURL)
/// try await writer.write(features)
/// writer.close()
/// ```
///
/// ## Converting from annotations
/// ```swift
/// let writer = try GFF3Writer(url: outputURL)
/// try await writer.write(annotations)
/// writer.close()
/// ```
public final class GFF3Writer {

    // MARK: - Properties

    /// Output file URL
    public let url: URL

    /// Source field to use when writing (default: "Lungfish")
    public let defaultSource: String

    /// Whether to write the GFF3 header
    public let includeHeader: Bool

    /// File handle for writing
    private var fileHandle: FileHandle?

    /// Whether the header has been written
    private var headerWritten: Bool = false

    // MARK: - Initialization

    /// Creates a GFF3 writer for the specified file.
    ///
    /// - Parameters:
    ///   - url: Output file URL
    ///   - defaultSource: Source field for features without explicit source (default: "Lungfish")
    ///   - includeHeader: Whether to write the ##gff-version 3 header (default: true)
    /// - Throws: If the file cannot be created
    public init(url: URL, defaultSource: String = "Lungfish", includeHeader: Bool = true) throws {
        self.url = url
        self.defaultSource = defaultSource
        self.includeHeader = includeHeader

        // Create the file
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)
    }

    // MARK: - Writing Features

    /// Writes GFF3 features to the file.
    ///
    /// - Parameter features: Array of GFF3Feature to write
    /// - Throws: GFF3WriterError if the file is not open or writing fails
    public func write(_ features: [GFF3Feature]) async throws {
        guard let handle = fileHandle else {
            throw GFF3WriterError.fileNotOpen
        }

        // Write header if needed
        if includeHeader && !headerWritten {
            try writeHeader(to: handle)
        }

        // Write each feature
        for feature in features {
            let line = formatFeature(feature)
            try handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// Writes SequenceAnnotations to the file as GFF3 features.
    ///
    /// This is a convenience method that converts annotations to GFF3 features
    /// before writing. Each interval in a discontinuous annotation is written
    /// as a separate feature line.
    ///
    /// - Parameter annotations: Array of SequenceAnnotation to write
    /// - Throws: GFF3WriterError if the file is not open or writing fails
    public func write(_ annotations: [SequenceAnnotation]) async throws {
        guard let handle = fileHandle else {
            throw GFF3WriterError.fileNotOpen
        }

        // Write header if needed
        if includeHeader && !headerWritten {
            try writeHeader(to: handle)
        }

        // Convert and write each annotation
        for annotation in annotations {
            let features = annotationToFeatures(annotation)
            for feature in features {
                let line = formatFeature(feature)
                try handle.write(contentsOf: Data(line.utf8))
            }
        }
    }

    /// Writes a single GFF3 feature to the file.
    ///
    /// - Parameter feature: The GFF3Feature to write
    /// - Throws: GFF3WriterError if the file is not open or writing fails
    public func write(_ feature: GFF3Feature) async throws {
        guard let handle = fileHandle else {
            throw GFF3WriterError.fileNotOpen
        }

        // Write header if needed
        if includeHeader && !headerWritten {
            try writeHeader(to: handle)
        }

        let line = formatFeature(feature)
        try handle.write(contentsOf: Data(line.utf8))
    }

    /// Closes the file handle.
    public func close() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    // MARK: - Static Convenience Methods

    /// Writes features to a file.
    ///
    /// - Parameters:
    ///   - features: Array of GFF3Feature to write
    ///   - url: Output file URL
    ///   - source: Default source field (default: "Lungfish")
    /// - Throws: If writing fails
    public static func write(_ features: [GFF3Feature], to url: URL, source: String = "Lungfish") async throws {
        let writer = try GFF3Writer(url: url, defaultSource: source)
        defer { writer.close() }
        try await writer.write(features)
    }

    /// Writes annotations to a file as GFF3 format.
    ///
    /// - Parameters:
    ///   - annotations: Array of SequenceAnnotation to write
    ///   - url: Output file URL
    ///   - source: Default source field (default: "Lungfish")
    /// - Throws: If writing fails
    public static func write(_ annotations: [SequenceAnnotation], to url: URL, source: String = "Lungfish") async throws {
        let writer = try GFF3Writer(url: url, defaultSource: source)
        defer { writer.close() }
        try await writer.write(annotations)
    }

    // MARK: - Private Helpers

    private func writeHeader(to handle: FileHandle) throws {
        let header = "##gff-version 3\n"
        try handle.write(contentsOf: Data(header.utf8))
        headerWritten = true
    }

    private func formatFeature(_ feature: GFF3Feature) -> String {
        var fields: [String] = []

        // Column 1: seqid
        fields.append(feature.seqid)

        // Column 2: source
        fields.append(feature.source)

        // Column 3: type
        fields.append(feature.type)

        // Column 4: start (1-based)
        fields.append(String(feature.start))

        // Column 5: end (1-based)
        fields.append(String(feature.end))

        // Column 6: score
        if let score = feature.score {
            fields.append(String(format: "%.6g", score))
        } else {
            fields.append(".")
        }

        // Column 7: strand
        fields.append(strandString(feature.strand))

        // Column 8: phase
        if let phase = feature.phase {
            fields.append(String(phase))
        } else {
            fields.append(".")
        }

        // Column 9: attributes
        fields.append(formatAttributes(feature.attributes))

        return fields.joined(separator: "\t") + "\n"
    }

    private func strandString(_ strand: Strand) -> String {
        switch strand {
        case .forward: return "+"
        case .reverse: return "-"
        case .unknown: return "."
        }
    }

    private func formatAttributes(_ attributes: [String: String]) -> String {
        if attributes.isEmpty {
            return "."
        }

        // Sort attributes with ID and Name first for readability
        var sortedKeys = attributes.keys.sorted()

        // Move ID to front if present
        if let idIndex = sortedKeys.firstIndex(of: "ID") {
            sortedKeys.remove(at: idIndex)
            sortedKeys.insert("ID", at: 0)
        }

        // Move Name after ID if present
        if let nameIndex = sortedKeys.firstIndex(of: "Name") {
            sortedKeys.remove(at: nameIndex)
            let insertIndex = sortedKeys.first == "ID" ? 1 : 0
            sortedKeys.insert("Name", at: insertIndex)
        }

        // Move Parent after Name if present
        if let parentIndex = sortedKeys.firstIndex(of: "Parent") {
            sortedKeys.remove(at: parentIndex)
            var insertIndex = 0
            if sortedKeys.first == "ID" { insertIndex += 1 }
            if sortedKeys.count > insertIndex && sortedKeys[insertIndex] == "Name" { insertIndex += 1 }
            sortedKeys.insert("Parent", at: insertIndex)
        }

        let pairs = sortedKeys.compactMap { key -> String? in
            guard let value = attributes[key] else { return nil }
            let encodedValue = urlEncode(value)
            return "\(key)=\(encodedValue)"
        }

        return pairs.joined(separator: ";")
    }

    private func urlEncode(_ value: String) -> String {
        // Encode special characters that have meaning in GFF3 attributes
        // Order matters: encode % first to avoid double-encoding
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: ";", with: "%3B")
            .replacingOccurrences(of: "=", with: "%3D")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: ",", with: "%2C")
            .replacingOccurrences(of: "\t", with: "%09")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    private func annotationToFeatures(_ annotation: SequenceAnnotation) -> [GFF3Feature] {
        var features: [GFF3Feature] = []

        // Build base attributes
        var attributes: [String: String] = [:]
        attributes["ID"] = annotation.id.uuidString
        attributes["Name"] = annotation.name

        // Add note if present
        if let note = annotation.note {
            attributes["Note"] = note
        }

        // Add qualifiers
        for (key, qualifier) in annotation.qualifiers {
            // Skip if already set by standard fields
            if key == "ID" || key == "Name" || key == "Note" {
                continue
            }
            attributes[key] = qualifier.values.joined(separator: ",")
        }

        // Map annotation type to GFF3 type string
        let gff3Type = annotationTypeToGFF3Type(annotation.type)

        // Determine seqid
        let seqid = annotation.chromosome ?? "unknown"

        // Determine phase for CDS features. Per-segment phase is
        // computed from the shared helper (also used by the iVar GFF exporter),
        // which accounts for cumulative CDS length in transcription
        // order rather than writing phase 0 on every segment.
        let isCDS = annotation.type == .cds
        let phaseBySegmentStart: [Int: Int]
        if isCDS {
            let intervals = annotation.intervals.map {
                CDSSegmentPhases.Interval(start: $0.start, end: $0.end)
            }
            let computed = CDSSegmentPhases.compute(intervals: intervals, strand: annotation.strand.rawValue)
            phaseBySegmentStart = Dictionary(uniqueKeysWithValues: computed.map { ($0.interval.start, $0.phase) })
        } else {
            phaseBySegmentStart = [:]
        }

        // Create a feature for each interval. Multi-interval features
        // (spliced CDS/mRNA) share the SAME ID across every line, which is the
        // standard GFF3 idiom for a single multi-line feature and needs no
        // `Parent` attribute (previously each segment got a distinct
        // `_N`-suffixed ID and a `Parent` pointing at an ID that this writer
        // never emits, producing a dangling reference and splitting one CDS
        // into unrelated features on re-import).
        for interval in annotation.intervals {
            let intervalAttributes = attributes

            // Convert from 0-based to 1-based coordinates
            let start = interval.start + 1
            let end = interval.end

            // Get phase for CDS features; fall back to the interval's own
            // stored phase (e.g. read from an imported GFF3/GenBank record)
            // only if the shared computation has no entry for it.
            let phase: Int? = isCDS ? (phaseBySegmentStart[interval.start] ?? interval.phase ?? 0) : nil

            let feature = GFF3Feature(
                seqid: seqid,
                source: defaultSource,
                type: gff3Type,
                start: start,
                end: end,
                score: nil,
                strand: annotation.strand,
                phase: phase,
                attributes: intervalAttributes
            )

            features.append(feature)
        }

        return features
    }

    private func annotationTypeToGFF3Type(_ type: AnnotationType) -> String {
        switch type {
        case .gene: return "gene"
        case .mRNA: return "mRNA"
        case .transcript: return "transcript"
        case .exon: return "exon"
        case .intron: return "intron"
        case .cds: return "CDS"
        case .orf: return "ORF"
        case .translation: return "translation"
        case .utr5: return "five_prime_UTR"
        case .utr3: return "three_prime_UTR"
        case .promoter: return "promoter"
        case .enhancer: return "enhancer"
        case .silencer: return "silencer"
        case .terminator: return "terminator"
        case .polyASignal: return "polyA_signal"
        case .regulatory: return "regulatory"
        case .ncRNA: return "ncRNA"
        case .tRNA: return "tRNA"
        case .rRNA: return "rRNA"
        case .primer: return "primer"
        case .primerPair: return "primer_pair"
        case .amplicon: return "amplicon"
        case .restrictionSite: return "restriction_site"
        case .snp: return "SNP"
        case .variation: return "variation"
        case .insertion: return "insertion"
        case .deletion: return "deletion"
        case .repeatRegion: return "repeat_region"
        case .stem_loop: return "stem_loop"
        case .misc_feature: return "misc_feature"
        case .pseudogene: return "pseudogene"
        case .mobileElement: return "mobile_element"
        case .mat_peptide: return "mat_peptide"
        case .sig_peptide: return "sig_peptide"
        case .transit_peptide: return "transit_peptide"
        case .misc_binding: return "misc_binding"
        case .protein_bind: return "protein_bind"
        case .contig: return "contig"
        case .gap: return "gap"
        case .scaffold: return "scaffold"
        case .region: return "region"
        case .source: return "source"
        case .custom: return "region"
        // FASTQ read-level annotations use their rawValue as GFF3 type
        case .barcode5p: return "barcode_5p"
        case .barcode3p: return "barcode_3p"
        case .adapter5p: return "adapter_5p"
        case .adapter3p: return "adapter_3p"
        case .primer5p: return "primer_5p"
        case .primer3p: return "primer_3p"
        case .trimQuality: return "trim_quality"
        case .trimFixed: return "trim_fixed"
        case .orientMarker: return "orient_marker"
        case .umiRegion: return "umi_region"
        case .contaminantMatch: return "contaminant_match"
        }
    }
}
