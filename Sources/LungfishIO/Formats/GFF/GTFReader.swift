// GTFReader.swift - GTF (Gene Transfer Format) annotation file parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)
// Reference: https://www.ensembl.org/info/website/upload/gff.html

import Foundation
import LungfishCore

/// A feature record from a GTF file.
///
/// GTF (Gene Transfer Format, also known as GFF2.5) shares the same nine-column
/// tab-separated layout as GFF3 but uses a different attribute syntax:
/// - GFF3: `key1=value1;key2=value2`
/// - GTF:  `key1 "value1"; key2 "value2";`
///
/// GTF files do not use explicit `ID` / `Parent` attributes. Instead, hierarchy
/// is inferred from `gene_id` and `transcript_id` attributes present on every
/// feature line.
public struct GTFFeature: Sendable, Identifiable {

    /// Stable identifier derived from GTF attributes.
    ///
    /// Uses `gene_id` for gene features, `transcript_id` for transcript features,
    /// and a composite key for sub-features (exon, CDS, etc.).
    public var id: String {
        switch type {
        case "gene":
            return attributes["gene_id"] ?? "\(seqid):\(start)-\(end)"
        case "transcript":
            return attributes["transcript_id"] ?? attributes["gene_id"] ?? "\(seqid):\(start)-\(end)"
        default:
            // Sub-features: compose from transcript + type + coordinates for uniqueness
            let transcriptID = attributes["transcript_id"] ?? ""
            return "\(transcriptID):\(type):\(start)-\(end)"
        }
    }

    /// Sequence ID (chromosome or contig name)
    public let seqid: String

    /// Source of the feature (e.g., "GENCODE", "Ensembl")
    public let source: String

    /// Feature type (e.g., "gene", "transcript", "exon", "CDS")
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

    /// Key-value attributes parsed from the GTF attribute column
    public let attributes: [String: String]

    /// Gene ID from attributes (present on all GTF feature lines)
    public var geneID: String? {
        attributes["gene_id"]
    }

    /// Transcript ID from attributes (present on transcript and sub-features)
    public var transcriptID: String? {
        attributes["transcript_id"]
    }

    /// Feature name, preferring `gene_name` then `gene_id` then the feature type.
    public var name: String {
        attributes["gene_name"] ?? attributes["gene_id"] ?? type
    }

    /// Creates a GTF feature from parsed fields.
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
    ///
    /// GTF coordinates are 1-based, closed (both start and end inclusive).
    /// Internal coordinates are 0-based, half-open [start, end).
    /// Conversion: internal_start = gtf_start - 1, internal_end = gtf_end
    public func toAnnotation() -> SequenceAnnotation {
        let annotationType = AnnotationType.from(rawString: type) ?? .region

        // Build qualifiers from all GTF attributes
        var qualifiers: [String: AnnotationQualifier] = [:]
        for (key, value) in attributes {
            qualifiers[key] = AnnotationQualifier(value)
        }

        // Use gene_name as the annotation name if available, otherwise gene_id
        let annotationName = attributes["gene_name"] ?? attributes["gene_id"] ?? type

        return SequenceAnnotation(
            type: annotationType,
            name: annotationName,
            chromosome: seqid,
            intervals: [AnnotationInterval(start: start - 1, end: end)],
            strand: strand,
            qualifiers: qualifiers
        )
    }
}

/// Async reader for GTF (Gene Transfer Format) files.
///
/// GTF format uses the same nine tab-separated columns as GFF3:
/// 1. seqname   - Sequence name (chromosome)
/// 2. source    - Feature source (e.g., "GENCODE", "Ensembl")
/// 3. feature   - Feature type (e.g., "gene", "transcript", "exon", "CDS")
/// 4. start     - Start position (1-based, inclusive)
/// 5. end       - End position (1-based, inclusive)
/// 6. score     - Score or "."
/// 7. strand    - +, -, or .
/// 8. frame     - 0, 1, 2, or "." (reading frame for CDS)
/// 9. attribute - Semicolon-separated key-value pairs with quoted values
///
/// The attribute column differs from GFF3:
/// ```
/// gene_id "ENSG00000223972"; gene_name "DDX11L1"; gene_type "pseudogene";
/// ```
///
/// ## Usage
/// ```swift
/// let reader = GTFReader(url: gtfFileURL)
/// let annotations = try await reader.readAll()
/// ```
public final class GTFReader: Sendable {

    // MARK: - Properties

    /// URL of the GTF file to read
    private let url: URL

    /// Whether to validate that start <= end
    public let validateCoordinates: Bool

    // MARK: - Initialization

    /// Creates a GTF reader for the specified file.
    ///
    /// - Parameters:
    ///   - url: URL of the GTF file
    ///   - validateCoordinates: Validate start <= end (default: true)
    public init(url: URL, validateCoordinates: Bool = true) {
        self.url = url
        self.validateCoordinates = validateCoordinates
    }

    // MARK: - Reading

    /// Returns an async stream of GTF features.
    ///
    /// - Returns: AsyncThrowingStream of GTFFeature
    public func features() -> AsyncThrowingStream<GTFFeature, Error> {
        let fileURL = url
        let validate = validateCoordinates

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var lineNumber = 0

                    for try await line in fileURL.linesAutoDecompressing() {
                        lineNumber += 1

                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty || trimmed.hasPrefix("#") {
                            continue
                        }

                        do {
                            let feature = try GTFReader.parseLine(
                                trimmed,
                                lineNumber: lineNumber,
                                validateCoordinates: validate
                            )
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

    /// Reads all features and converts to SequenceAnnotation objects.
    ///
    /// - Returns: Array of SequenceAnnotation
    /// - Throws: GTFError on parse failure
    public func readAll() async throws -> [SequenceAnnotation] {
        var annotations: [SequenceAnnotation] = []
        for try await feature in features() {
            annotations.append(feature.toAnnotation())
        }
        return annotations
    }

    /// Reads all GTF features into memory.
    ///
    /// - Returns: Array of GTFFeature
    /// - Throws: GTFError on parse failure
    public func readAllFeatures() async throws -> [GTFFeature] {
        var results: [GTFFeature] = []
        for try await feature in features() {
            results.append(feature)
        }
        return results
    }

    /// Synchronous variant for contexts that cannot use async/await.
    ///
    /// Reads the entire file line-by-line using Foundation string APIs.
    ///
    /// - Returns: Array of SequenceAnnotation
    /// - Throws: GTFError on parse failure or if the file cannot be read
    public func readAllSync() throws -> [SequenceAnnotation] {
        var annotations: [SequenceAnnotation] = []
        var lineNumber = 0

        func consume(_ line: String) throws {
            lineNumber += 1

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                return
            }

            let feature = try GTFReader.parseLine(
                trimmed,
                lineNumber: lineNumber,
                validateCoordinates: validateCoordinates
            )
            annotations.append(feature.toAnnotation())
        }

        if url.isGzipCompressed {
            let stream = try GzipInputStream(url: url)
            try stream.forEachLine(consume)
        } else {
            let content = try String(contentsOf: url, encoding: .utf8)
            for line in content.components(separatedBy: .newlines) {
                try consume(line)
            }
        }

        return annotations
    }

    /// Reads features grouped by sequence ID.
    ///
    /// - Returns: Dictionary mapping seqid to annotations
    /// - Throws: GTFError on parse failure
    public func readGroupedBySequence() async throws -> [String: [SequenceAnnotation]] {
        var grouped: [String: [SequenceAnnotation]] = [:]
        for try await feature in features() {
            let annotation = feature.toAnnotation()
            let chrom = annotation.chromosome ?? "unknown"
            grouped[chrom, default: []].append(annotation)
        }
        return grouped
    }

    // MARK: - Parsing (static for Sendable safety)

    /// Parses a single GTF line into a GTFFeature.
    ///
    /// - Parameters:
    ///   - line: The raw tab-separated line
    ///   - lineNumber: Line number for error reporting
    ///   - validateCoordinates: Whether to check start <= end
    /// - Returns: The parsed GTFFeature
    /// - Throws: GTFError on malformed input
    static func parseLine(
        _ line: String,
        lineNumber: Int,
        validateCoordinates: Bool
    ) throws -> GTFFeature {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)

        guard fields.count >= 9 else {
            throw GTFError.invalidLineFormat(line: lineNumber, expected: 9, got: fields.count)
        }

        let seqid = fields[0]
        let source = fields[1]
        let type = fields[2]

        guard let start = Int(fields[3]) else {
            throw GTFError.invalidCoordinate(line: lineNumber, field: "start", value: fields[3])
        }

        guard let end = Int(fields[4]) else {
            throw GTFError.invalidCoordinate(line: lineNumber, field: "end", value: fields[4])
        }

        if validateCoordinates && start > end {
            throw GTFError.invalidCoordinateRange(line: lineNumber, start: start, end: end)
        }

        let score: Double? = fields[5] == "." ? nil : Double(fields[5])
        let strand = parseStrand(fields[6])
        let phase: Int? = fields[7] == "." ? nil : Int(fields[7])
        let attributes = parseGTFAttributes(fields[8])

        return GTFFeature(
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

    /// Parses GTF-style attributes.
    ///
    /// GTF attribute format:
    /// ```
    /// gene_id "ENSG00000223972"; gene_name "DDX11L1"; gene_type "pseudogene";
    /// ```
    ///
    /// Rules:
    /// - Entries are separated by `"; "` (semicolon + space) or standalone `";"`
    /// - Each entry is `key "value"` or `key value` (unquoted integers like `level 2`)
    /// - Trailing semicolons are tolerated
    /// - Whitespace around values is trimmed
    ///
    /// - Parameter raw: The raw attribute string from column 9
    /// - Returns: Dictionary of key-value pairs
    static func parseGTFAttributes(_ raw: String) -> [String: String] {
        var attributes: [String: String] = [:]

        // Split on semicolons. GTF uses "; " but we also handle ";" alone.
        let entries = raw.split(separator: ";")

        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }

            // Find the first space that separates key from value
            guard let spaceIndex = trimmed.firstIndex(of: " ") else {
                // Key with no value (rare but tolerated)
                continue
            }

            let key = String(trimmed[trimmed.startIndex..<spaceIndex])
            var value = String(trimmed[trimmed.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)

            // Strip surrounding quotes if present
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            attributes[key] = value
        }

        return attributes
    }

    /// Parses a strand character to the Strand enum.
    private static func parseStrand(_ value: String) -> Strand {
        switch value {
        case "+": return .forward
        case "-": return .reverse
        default: return .unknown
        }
    }
}

// MARK: - GTFError

/// Errors that can occur when parsing GTF files.
public enum GTFError: Error, LocalizedError, Sendable {

    /// Line has wrong number of tab-separated fields
    case invalidLineFormat(line: Int, expected: Int, got: Int)

    /// A coordinate field is not a valid integer
    case invalidCoordinate(line: Int, field: String, value: String)

    /// Start coordinate is greater than end
    case invalidCoordinateRange(line: Int, start: Int, end: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidLineFormat(let line, let expected, let got):
            return "GTF line \(line): expected \(expected) fields, got \(got)"
        case .invalidCoordinate(let line, let field, let value):
            return "GTF line \(line): invalid \(field) coordinate '\(value)'"
        case .invalidCoordinateRange(let line, let start, let end):
            return "GTF line \(line): start (\(start)) > end (\(end))"
        }
    }
}

// MARK: - GTF Statistics

/// Statistics about a GTF file.
public struct GTFStatistics: Sendable {

    /// Total number of features
    public let featureCount: Int

    /// Features by type
    public let featuresByType: [String: Int]

    /// Features by sequence
    public let featuresBySequence: [String: Int]

    /// Unique gene IDs
    public let geneCount: Int

    /// Unique transcript IDs
    public let transcriptCount: Int

    /// Unique sequence IDs
    public var sequenceCount: Int { featuresBySequence.count }

    /// Computes statistics from features.
    public init(features: [GTFFeature]) {
        self.featureCount = features.count

        var byType: [String: Int] = [:]
        var bySeq: [String: Int] = [:]
        var geneIDs: Set<String> = []
        var transcriptIDs: Set<String> = []

        for feature in features {
            byType[feature.type, default: 0] += 1
            bySeq[feature.seqid, default: 0] += 1
            if let gid = feature.geneID {
                geneIDs.insert(gid)
            }
            if let tid = feature.transcriptID {
                transcriptIDs.insert(tid)
            }
        }

        self.featuresByType = byType
        self.featuresBySequence = bySeq
        self.geneCount = geneIDs.count
        self.transcriptCount = transcriptIDs.count
    }
}
