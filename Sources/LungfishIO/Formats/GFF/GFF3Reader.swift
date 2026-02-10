// GFF3Reader.swift - GFF3 annotation file parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)
// Reference: https://github.com/The-Sequence-Ontology/Specifications/blob/master/gff3.md

import Foundation
import LungfishCore

/// A feature record from a GFF3 file.
public struct GFF3Feature: Sendable, Identifiable {

    /// Unique identifier (from ID attribute)
    public var id: String { attributes["ID"] ?? "\(seqid):\(start)-\(end)" }

    /// Sequence ID (chromosome or contig name)
    public let seqid: String

    /// Source of the feature (e.g., "ENSEMBL", "GenBank")
    public let source: String

    /// Feature type (e.g., "gene", "mRNA", "CDS", "exon")
    public let type: String

    /// Start position (1-based, inclusive)
    public let start: Int

    /// End position (1-based, inclusive)
    public let end: Int

    /// Score (or nil if ".")
    public let score: Double?

    /// Strand (+, -, ., or ?)
    public let strand: Strand

    /// Phase for CDS features (0, 1, 2, or nil)
    public let phase: Int?

    /// Key-value attributes
    public let attributes: [String: String]

    /// Parent feature ID (from Parent attribute)
    public var parentID: String? {
        attributes["Parent"]
    }

    /// Feature name (from Name attribute or ID)
    public var name: String {
        attributes["Name"] ?? attributes["ID"] ?? type
    }

    /// Creates a GFF3 feature from parsed fields.
    public init(
        seqid: String,
        source: String,
        type: String,
        start: Int,
        end: Int,
        score: Double?,
        strand: Strand,
        phase: Int?,
        attributes: [String: String]
    ) {
        self.seqid = seqid
        self.source = source
        self.type = type
        self.start = start
        self.end = end
        self.score = score
        self.strand = strand
        self.phase = phase
        self.attributes = attributes
    }

    /// Converts to a SequenceAnnotation.
    public func toAnnotation() -> SequenceAnnotation {
        let annotationType = AnnotationType.from(rawString: type) ?? .region

        // Convert qualifiers
        var qualifiers: [String: AnnotationQualifier] = [:]
        for (key, value) in attributes {
            qualifiers[key] = AnnotationQualifier(value)
        }

        return SequenceAnnotation(
            type: annotationType,
            name: name,
            chromosome: seqid,  // Associate annotation with its source sequence
            intervals: [AnnotationInterval(start: start - 1, end: end)], // Convert to 0-based
            strand: strand,
            qualifiers: qualifiers
        )
    }
}

/// Async streaming reader for GFF3 files.
///
/// GFF3 format has 9 tab-separated columns:
/// 1. seqid - Sequence ID
/// 2. source - Feature source
/// 3. type - Feature type
/// 4. start - Start position (1-based)
/// 5. end - End position (1-based)
/// 6. score - Score or "."
/// 7. strand - +, -, ., or ?
/// 8. phase - 0, 1, 2, or "."
/// 9. attributes - Key=Value pairs separated by ";"
///
/// ## Usage
/// ```swift
/// let reader = GFF3Reader()
/// for try await feature in reader.features(from: url) {
///     print("\(feature.type): \(feature.name) at \(feature.start)-\(feature.end)")
/// }
/// ```
public final class GFF3Reader: Sendable {

    // MARK: - Configuration

    /// Whether to validate feature coordinates
    public let validateCoordinates: Bool

    /// Whether to resolve parent-child relationships
    public let resolveParents: Bool

    // MARK: - Initialization

    /// Creates a GFF3 reader.
    ///
    /// - Parameters:
    ///   - validateCoordinates: Validate start <= end (default: true)
    ///   - resolveParents: Build parent-child hierarchy (default: false)
    public init(validateCoordinates: Bool = true, resolveParents: Bool = false) {
        self.validateCoordinates = validateCoordinates
        self.resolveParents = resolveParents
    }

    // MARK: - Reading

    /// Returns an async stream of GFF3 features.
    ///
    /// - Parameter url: URL of the GFF3 file
    /// - Returns: AsyncThrowingStream of features
    public func features(from url: URL) -> AsyncThrowingStream<GFF3Feature, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var lineNumber = 0

                    for try await line in url.lines {
                        lineNumber += 1

                        // Skip empty lines and comments
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty || trimmed.hasPrefix("#") {
                            // Check for directives
                            if trimmed.hasPrefix("##FASTA") {
                                // End of GFF section
                                break
                            }
                            continue
                        }

                        // Parse feature line
                        do {
                            let feature = try self.parseLine(trimmed, lineNumber: lineNumber)
                            continuation.yield(feature)
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Reads all features into memory.
    ///
    /// - Parameter url: URL of the GFF3 file
    /// - Returns: Array of features
    public func readAll(from url: URL) async throws -> [GFF3Feature] {
        var results: [GFF3Feature] = []
        for try await feature in features(from: url) {
            results.append(feature)
        }
        return results
    }

    /// Reads features and converts to annotations.
    ///
    /// - Parameter url: URL of the GFF3 file
    /// - Returns: Array of SequenceAnnotation
    public func readAsAnnotations(from url: URL) async throws -> [SequenceAnnotation] {
        let features = try await readAll(from: url)
        return features.map { $0.toAnnotation() }
    }

    /// Reads features grouped by sequence ID.
    ///
    /// - Parameter url: URL of the GFF3 file
    /// - Returns: Dictionary mapping seqid to features
    public func readGroupedBySequence(from url: URL) async throws -> [String: [GFF3Feature]] {
        var grouped: [String: [GFF3Feature]] = [:]
        for try await feature in features(from: url) {
            grouped[feature.seqid, default: []].append(feature)
        }
        return grouped
    }

    // MARK: - Parsing

    private func parseLine(_ line: String, lineNumber: Int) throws -> GFF3Feature {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)

        guard fields.count >= 9 else {
            throw GFF3Error.invalidLineFormat(line: lineNumber, expected: 9, got: fields.count)
        }

        // Parse each field
        let seqid = fields[0]
        let source = fields[1]
        let type = fields[2]

        guard let start = Int(fields[3]) else {
            throw GFF3Error.invalidCoordinate(line: lineNumber, field: "start", value: fields[3])
        }

        guard let end = Int(fields[4]) else {
            throw GFF3Error.invalidCoordinate(line: lineNumber, field: "end", value: fields[4])
        }

        // Validate coordinates
        if validateCoordinates && start > end {
            throw GFF3Error.invalidCoordinateRange(line: lineNumber, start: start, end: end)
        }

        // Score (may be ".")
        let score: Double? = fields[5] == "." ? nil : Double(fields[5])

        // Strand
        let strand = parseStrand(fields[6])

        // Phase (may be ".")
        let phase: Int? = fields[7] == "." ? nil : Int(fields[7])

        // Attributes
        let attributes = parseAttributes(fields[8])

        return GFF3Feature(
            seqid: seqid,
            source: source,
            type: type,
            start: start,
            end: end,
            score: score,
            strand: strand,
            phase: phase,
            attributes: attributes
        )
    }

    private func parseStrand(_ value: String) -> Strand {
        switch value {
        case "+":
            return .forward
        case "-":
            return .reverse
        default:
            return .unknown
        }
    }

    private func parseAttributes(_ value: String) -> [String: String] {
        var attributes: [String: String] = [:]

        // Split by ";" and parse key=value pairs
        let pairs = value.split(separator: ";")
        for pair in pairs {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            if keyValue.count == 2 {
                let key = String(keyValue[0]).trimmingCharacters(in: .whitespaces)
                var rawValue = String(keyValue[1])

                // URL decode the value
                rawValue = urlDecode(rawValue)

                // Handle multiple values (comma-separated)
                attributes[key] = rawValue
            }
        }

        return attributes
    }

    private func urlDecode(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%3B", with: ";")
            .replacingOccurrences(of: "%3D", with: "=")
            .replacingOccurrences(of: "%26", with: "&")
            .replacingOccurrences(of: "%2C", with: ",")
            .replacingOccurrences(of: "%09", with: "\t")
            .replacingOccurrences(of: "%0A", with: "\n")
            .replacingOccurrences(of: "%25", with: "%")
    }
}

// MARK: - GFF3Error

/// Errors that can occur when parsing GFF3 files.
public enum GFF3Error: Error, LocalizedError, Sendable {

    /// Line has wrong number of fields
    case invalidLineFormat(line: Int, expected: Int, got: Int)

    /// Coordinate field is not a valid integer
    case invalidCoordinate(line: Int, field: String, value: String)

    /// Start coordinate is greater than end
    case invalidCoordinateRange(line: Int, start: Int, end: Int)

    /// Parent feature not found
    case parentNotFound(line: Int, parentID: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLineFormat(let line, let expected, let got):
            return "GFF3 line \(line): expected \(expected) fields, got \(got)"
        case .invalidCoordinate(let line, let field, let value):
            return "GFF3 line \(line): invalid \(field) coordinate '\(value)'"
        case .invalidCoordinateRange(let line, let start, let end):
            return "GFF3 line \(line): start (\(start)) > end (\(end))"
        case .parentNotFound(let line, let parentID):
            return "GFF3 line \(line): parent '\(parentID)' not found"
        }
    }
}

// MARK: - GFF3 Statistics

/// Statistics about a GFF3 file.
public struct GFF3Statistics: Sendable {

    /// Total number of features
    public let featureCount: Int

    /// Features by type
    public let featuresByType: [String: Int]

    /// Features by sequence
    public let featuresBySequence: [String: Int]

    /// Unique sequence IDs
    public var sequenceCount: Int { featuresBySequence.count }

    /// Computes statistics from features.
    public init(features: [GFF3Feature]) {
        self.featureCount = features.count

        var byType: [String: Int] = [:]
        var bySeq: [String: Int] = [:]

        for feature in features {
            byType[feature.type, default: 0] += 1
            bySeq[feature.seqid, default: 0] += 1
        }

        self.featuresByType = byType
        self.featuresBySequence = bySeq
    }
}

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

        // Determine phase for CDS features
        let isCDS = annotation.type == .cds

        // Create a feature for each interval
        for (index, interval) in annotation.intervals.enumerated() {
            var intervalAttributes = attributes

            // For multi-interval features, add part number
            if annotation.intervals.count > 1 {
                intervalAttributes["ID"] = "\(annotation.id.uuidString)_\(index + 1)"
                intervalAttributes["Parent"] = annotation.id.uuidString
            }

            // Convert from 0-based to 1-based coordinates
            let start = interval.start + 1
            let end = interval.end

            // Get phase for CDS features
            let phase: Int? = isCDS ? (interval.phase ?? 0) : nil

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
        case .utr5: return "five_prime_UTR"
        case .utr3: return "three_prime_UTR"
        case .promoter: return "promoter"
        case .enhancer: return "enhancer"
        case .silencer: return "silencer"
        case .terminator: return "terminator"
        case .polyASignal: return "polyA_signal"
        case .regulatory: return "regulatory"
        case .ncRNA: return "ncRNA"
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
        }
    }
}

// MARK: - GFF3WriterError

/// Errors that can occur when writing GFF3 files.
public enum GFF3WriterError: Error, LocalizedError, Sendable {

    /// File is not open for writing
    case fileNotOpen

    /// Failed to write to file
    case writeFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .fileNotOpen:
            return "GFF3 file not open for writing"
        case .writeFailed(let error):
            return "Failed to write GFF3 file: \(error.localizedDescription)"
        }
    }
}
