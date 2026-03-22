// BEDReader.swift - BED format parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)
// Reference: https://genome.ucsc.edu/FAQ/FAQformat.html#format1

import Foundation
import LungfishCore

/// A feature record from a BED file.
///
/// BED format supports 3-12 columns:
/// - BED3: chrom, chromStart, chromEnd
/// - BED4: + name
/// - BED5: + score
/// - BED6: + strand
/// - BED12: + thickStart, thickEnd, itemRgb, blockCount, blockSizes, blockStarts
public struct BEDFeature: Sendable, Identifiable {

    /// Unique identifier
    public var id: String { name ?? "\(chrom):\(chromStart)-\(chromEnd)" }

    /// Chromosome name
    public let chrom: String

    /// Start position (0-based)
    public let chromStart: Int

    /// End position (exclusive)
    public let chromEnd: Int

    /// Feature name (optional, column 4)
    public let name: String?

    /// Score 0-1000 (optional, column 5)
    public let score: Int?

    /// Strand (optional, column 6)
    public let strand: Strand

    /// Thick region start for display (optional, column 7)
    public let thickStart: Int?

    /// Thick region end for display (optional, column 8)
    public let thickEnd: Int?

    /// RGB color string (optional, column 9)
    public let itemRgb: String?

    /// Number of blocks/exons (optional, column 10)
    public let blockCount: Int?

    /// Block sizes (optional, column 11)
    public let blockSizes: [Int]?

    /// Block start positions relative to chromStart (optional, column 12)
    public let blockStarts: [Int]?

    /// Feature length in base pairs
    public var length: Int { chromEnd - chromStart }

    /// Creates a BED feature.
    public init(
        chrom: String,
        chromStart: Int,
        chromEnd: Int,
        name: String? = nil,
        score: Int? = nil,
        strand: Strand = .unknown,
        thickStart: Int? = nil,
        thickEnd: Int? = nil,
        itemRgb: String? = nil,
        blockCount: Int? = nil,
        blockSizes: [Int]? = nil,
        blockStarts: [Int]? = nil
    ) {
        self.chrom = chrom
        self.chromStart = chromStart
        self.chromEnd = chromEnd
        self.name = name
        self.score = score
        self.strand = strand
        self.thickStart = thickStart
        self.thickEnd = thickEnd
        self.itemRgb = itemRgb
        self.blockCount = blockCount
        self.blockSizes = blockSizes
        self.blockStarts = blockStarts
    }

    /// Converts to a SequenceAnnotation.
    public func toAnnotation() -> SequenceAnnotation {
        // Build intervals from blocks if present, otherwise single interval
        var intervals: [AnnotationInterval]

        if let blockCount = blockCount, blockCount > 0,
           let blockSizes = blockSizes,
           let blockStarts = blockStarts {
            intervals = (0..<blockCount).map { i in
                let start = chromStart + blockStarts[i]
                let end = start + blockSizes[i]
                return AnnotationInterval(start: start, end: end)
            }
        } else {
            intervals = [AnnotationInterval(start: chromStart, end: chromEnd)]
        }

        // Parse color if present
        var color: AnnotationColor?
        if let rgb = itemRgb, rgb != "0" && rgb != "." {
            color = parseColor(rgb)
        }

        var qualifiers: [String: AnnotationQualifier] = [:]
        if let score = score {
            qualifiers["score"] = AnnotationQualifier(String(score))
        }

        return SequenceAnnotation(
            type: .region,
            name: name ?? "\(chrom):\(chromStart)-\(chromEnd)",
            chromosome: chrom,
            intervals: intervals,
            strand: strand,
            qualifiers: qualifiers,
            color: color
        )
    }

    private func parseColor(_ rgb: String) -> AnnotationColor? {
        let components = rgb.split(separator: ",").compactMap { Int($0) }
        guard components.count == 3 else { return nil }

        return AnnotationColor(
            red: Double(components[0]) / 255.0,
            green: Double(components[1]) / 255.0,
            blue: Double(components[2]) / 255.0
        )
    }
}

/// Async streaming reader for BED files.
///
/// Supports BED3 through BED12 formats. Automatically detects
/// the number of columns from the first data line.
///
/// ## Usage
/// ```swift
/// let reader = BEDReader()
/// for try await feature in reader.features(from: url) {
///     print("\(feature.chrom):\(feature.chromStart)-\(feature.chromEnd)")
/// }
/// ```
public final class BEDReader: Sendable {

    // MARK: - Configuration

    /// Whether to validate coordinates
    public let validateCoordinates: Bool

    /// Separator character (tab by default)
    public let separator: Character

    // MARK: - Initialization

    /// Creates a BED reader.
    ///
    /// - Parameters:
    ///   - validateCoordinates: Validate start < end (default: true)
    ///   - separator: Field separator (default: tab)
    public init(validateCoordinates: Bool = true, separator: Character = "\t") {
        self.validateCoordinates = validateCoordinates
        self.separator = separator
    }

    // MARK: - Reading

    /// Returns an async stream of BED features.
    ///
    /// - Parameter url: URL of the BED file
    /// - Returns: AsyncThrowingStream of features
    public func features(from url: URL) -> AsyncThrowingStream<BEDFeature, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var lineNumber = 0

                    for try await line in url.lines {
                        lineNumber += 1

                        // Skip empty lines, comments, and track/browser lines
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty ||
                           trimmed.hasPrefix("#") ||
                           trimmed.hasPrefix("track") ||
                           trimmed.hasPrefix("browser") {
                            continue
                        }

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
    /// - Parameter url: URL of the BED file
    /// - Returns: Array of features
    public func readAll(from url: URL) async throws -> [BEDFeature] {
        var results: [BEDFeature] = []
        for try await feature in features(from: url) {
            results.append(feature)
        }
        return results
    }

    /// Reads features and converts to annotations.
    ///
    /// - Parameter url: URL of the BED file
    /// - Returns: Array of SequenceAnnotation
    public func readAsAnnotations(from url: URL) async throws -> [SequenceAnnotation] {
        let features = try await readAll(from: url)
        return features.map { $0.toAnnotation() }
    }

    // MARK: - Parsing

    private func parseLine(_ line: String, lineNumber: Int) throws -> BEDFeature {
        let fields = line.split(separator: separator, omittingEmptySubsequences: false).map(String.init)

        guard fields.count >= 3 else {
            throw BEDError.invalidLineFormat(line: lineNumber, minFields: 3, got: fields.count)
        }

        // Required fields (BED3)
        let chrom = fields[0]

        guard let chromStart = Int(fields[1]) else {
            throw BEDError.invalidCoordinate(line: lineNumber, field: "chromStart", value: fields[1])
        }

        guard let chromEnd = Int(fields[2]) else {
            throw BEDError.invalidCoordinate(line: lineNumber, field: "chromEnd", value: fields[2])
        }

        if validateCoordinates && chromStart >= chromEnd {
            throw BEDError.invalidCoordinateRange(line: lineNumber, start: chromStart, end: chromEnd)
        }

        // Optional fields
        let name = fields.count > 3 ? (fields[3] == "." ? nil : fields[3]) : nil
        let score = fields.count > 4 ? Int(fields[4]) : nil
        let strand = fields.count > 5 ? parseStrand(fields[5]) : .unknown
        let thickStart = fields.count > 6 ? Int(fields[6]) : nil
        let thickEnd = fields.count > 7 ? Int(fields[7]) : nil
        let itemRgb = fields.count > 8 ? (fields[8] == "." ? nil : fields[8]) : nil
        let blockCount = fields.count > 9 ? Int(fields[9]) : nil

        // Block data
        var blockSizes: [Int]?
        var blockStarts: [Int]?

        if fields.count > 10 && blockCount != nil && blockCount! > 0 {
            blockSizes = parseIntList(fields[10])
            if fields.count > 11 {
                blockStarts = parseIntList(fields[11])
            }
        }

        return BEDFeature(
            chrom: chrom,
            chromStart: chromStart,
            chromEnd: chromEnd,
            name: name,
            score: score,
            strand: strand,
            thickStart: thickStart,
            thickEnd: thickEnd,
            itemRgb: itemRgb,
            blockCount: blockCount,
            blockSizes: blockSizes,
            blockStarts: blockStarts
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

    private func parseIntList(_ value: String) -> [Int] {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .split(separator: ",")
            .compactMap { Int($0) }
    }
}

// MARK: - BEDError

/// Errors that can occur when parsing BED files.
public enum BEDError: Error, LocalizedError, Sendable {

    /// Line has too few fields
    case invalidLineFormat(line: Int, minFields: Int, got: Int)

    /// Coordinate field is not a valid integer
    case invalidCoordinate(line: Int, field: String, value: String)

    /// Start coordinate is >= end
    case invalidCoordinateRange(line: Int, start: Int, end: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidLineFormat(let line, let minFields, let got):
            return "BED line \(line): expected at least \(minFields) fields, got \(got)"
        case .invalidCoordinate(let line, let field, let value):
            return "BED line \(line): invalid \(field) coordinate '\(value)'"
        case .invalidCoordinateRange(let line, let start, let end):
            return "BED line \(line): start (\(start)) >= end (\(end))"
        }
    }
}

// MARK: - BEDWriter

/// Writer for BED format files.
public final class BEDWriter {

    /// Output URL
    public let url: URL

    /// Number of columns to write (3-12)
    public let columns: Int

    private var fileHandle: FileHandle?

    /// Creates a BED writer.
    ///
    /// - Parameters:
    ///   - url: Output file URL
    ///   - columns: Number of columns (3-12, default: 6)
    public init(url: URL, columns: Int = 6) {
        self.url = url
        self.columns = min(12, max(3, columns))
    }

    /// Opens the file for writing.
    public func open() throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
    }

    /// Closes the file.
    public func close() throws {
        try fileHandle?.close()
        fileHandle = nil
    }

    /// Writes a BED feature.
    public func write(_ feature: BEDFeature) throws {
        guard let handle = fileHandle else {
            throw BEDWriterError.fileNotOpen
        }

        var fields = [
            feature.chrom,
            String(feature.chromStart),
            String(feature.chromEnd)
        ]

        if columns >= 4 {
            fields.append(feature.name ?? ".")
        }
        if columns >= 5 {
            fields.append(feature.score.map(String.init) ?? "0")
        }
        if columns >= 6 {
            fields.append(strandString(feature.strand))
        }
        if columns >= 7 {
            fields.append(feature.thickStart.map(String.init) ?? String(feature.chromStart))
        }
        if columns >= 8 {
            fields.append(feature.thickEnd.map(String.init) ?? String(feature.chromEnd))
        }
        if columns >= 9 {
            fields.append(feature.itemRgb ?? "0")
        }
        if columns >= 10 {
            fields.append(feature.blockCount.map(String.init) ?? "1")
        }
        if columns >= 11 {
            let sizes = feature.blockSizes ?? [feature.chromEnd - feature.chromStart]
            fields.append(sizes.map(String.init).joined(separator: ",") + ",")
        }
        if columns >= 12 {
            let starts = feature.blockStarts ?? [0]
            fields.append(starts.map(String.init).joined(separator: ",") + ",")
        }

        let line = fields.joined(separator: "\t") + "\n"
        try handle.write(contentsOf: Data(line.utf8))
    }

    private func strandString(_ strand: Strand) -> String {
        switch strand {
        case .forward: return "+"
        case .reverse: return "-"
        case .unknown: return "."
        }
    }

    /// Writes features to a file.
    public static func write(_ features: [BEDFeature], to url: URL, columns: Int = 6) throws {
        let writer = BEDWriter(url: url, columns: columns)
        try writer.open()
        defer { try? writer.close() }
        for feature in features {
            try writer.write(feature)
        }
    }
}

/// Errors for BED writer.
public enum BEDWriterError: Error, LocalizedError, Sendable {
    case fileNotOpen

    public var errorDescription: String? {
        switch self {
        case .fileNotOpen:
            return "BED file not open for writing"
        }
    }
}
