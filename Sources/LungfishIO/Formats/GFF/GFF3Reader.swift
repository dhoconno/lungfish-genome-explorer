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
        let annotationType: AnnotationType
        switch type.lowercased() {
        case "gene":
            annotationType = .gene
        case "cds", "coding_sequence":
            annotationType = .cds
        case "exon":
            annotationType = .exon
        case "mrna", "transcript":
            annotationType = .mRNA
        case "intron":
            annotationType = .intron
        case "5'utr", "five_prime_utr":
            annotationType = .utr5
        case "3'utr", "three_prime_utr":
            annotationType = .utr3
        case "promoter":
            annotationType = .promoter
        default:
            annotationType = .region
        }

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
