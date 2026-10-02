// GFF3Reader.swift - GFF3 annotation file parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)
// Reference: https://github.com/The-Sequence-Ontology/Specifications/blob/master/gff3.md

import Foundation
import LungfishCore

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

                    for try await line in url.linesAutoDecompressing() {
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
        let score = try parseScore(fields[5], lineNumber: lineNumber)

        // Strand
        let strand = parseStrand(fields[6])

        // Phase (may be ".")
        let phase = try parsePhase(fields[7], lineNumber: lineNumber)

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

    private func parseScore(_ value: String, lineNumber: Int) throws -> Double? {
        guard value != "." else { return nil }
        guard let score = Double(value), score.isFinite else {
            throw GFF3Error.invalidScore(line: lineNumber, value: value)
        }
        return score
    }

    private func parsePhase(_ value: String, lineNumber: Int) throws -> Int? {
        guard value != "." else { return nil }
        guard let phase = Int(value), (0...2).contains(phase) else {
            throw GFF3Error.invalidPhase(line: lineNumber, value: value)
        }
        return phase
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

        // Split by ";" and parse key=value or GTF/GFF2-style key "value" pairs.
        let pairs = value.split(separator: ";")
        for pair in pairs {
            let entry = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            if let equalsIndex = entry.firstIndex(of: "=") {
                let key = String(entry[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
                let rawValue = String(entry[entry.index(after: equalsIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    attributes[key] = urlDecode(stripQuotes(rawValue))
                }
                continue
            }

            guard let spaceIndex = entry.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }

            let key = String(entry[..<spaceIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(entry[entry.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                attributes[key] = urlDecode(stripQuotes(rawValue))
            }
        }

        return attributes
    }

    private func stripQuotes(_ value: String) -> String {
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func urlDecode(_ value: String) -> String {
        if let decoded = value.removingPercentEncoding {
            return decoded
        }
        return value
            .replacingOccurrences(of: "%3B", with: ";")
            .replacingOccurrences(of: "%3D", with: "=")
            .replacingOccurrences(of: "%26", with: "&")
            .replacingOccurrences(of: "%2C", with: ",")
            .replacingOccurrences(of: "%09", with: "\t")
            .replacingOccurrences(of: "%0A", with: "\n")
            .replacingOccurrences(of: "%25", with: "%")
    }
}
