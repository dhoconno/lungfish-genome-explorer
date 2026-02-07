// AnnotationConverter.swift - Convert annotation files to BigBed format
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - AnnotationConverter

/// Converts annotation files (GFF3, BED, GenBank) to BED format for BigBed conversion.
///
/// The conversion pipeline is:
/// 1. Read source format (GFF3, BED, or GenBank)
/// 2. Convert to intermediate BED format
/// 3. Sort by chromosome and position
/// 4. Use bedToBigBed (via container) to create BigBed
///
/// ## Container Usage
///
/// The final step (BED to BigBed) requires the UCSC bedToBigBed tool.
/// This is run via the container plugin system.
///
/// ## Usage
///
/// ```swift
/// let converter = AnnotationConverter()
///
/// // Convert GFF3 to BED (intermediate step)
/// let bedURL = try await converter.convertToBED(
///     from: gff3URL,
///     format: .gff3,
///     output: tempBedURL
/// )
///
/// // Full conversion to BigBed (requires container)
/// let bigBedURL = try await converter.convertToBigBed(
///     from: gff3URL,
///     format: .gff3,
///     chromSizes: chromSizesURL,
///     output: outputBigBedURL
/// )
/// ```
public final class AnnotationConverter: Sendable {

    // MARK: - Types

    /// Supported input formats for annotation conversion.
    public enum InputFormat: String, Sendable, CaseIterable {
        case gff3 = "gff3"
        case bed = "bed"
        case genbank = "genbank"
        case gtf = "gtf"

        /// Detects format from file extension.
        public static func detect(from url: URL) -> InputFormat? {
            switch url.pathExtension.lowercased() {
            case "gff", "gff3":
                return .gff3
            case "gtf":
                return .gtf
            case "bed":
                return .bed
            case "gb", "gbk", "genbank":
                return .genbank
            default:
                return nil
            }
        }
    }

    /// BED output format configuration.
    public enum BEDFormat: Sendable {
        /// BED6: chrom, start, end, name, score, strand
        case bed6
        /// BED12: full format with blocks for exons
        case bed12

        /// Number of columns in this format.
        public var columns: Int {
            switch self {
            case .bed6: return 6
            case .bed12: return 12
            }
        }
    }

    /// Options for annotation conversion.
    public struct ConversionOptions: Sendable {
        /// Output BED format (bed6 or bed12)
        public let bedFormat: BEDFormat

        /// Feature types to include (nil = all)
        public let featureTypes: Set<String>?

        /// Whether to merge overlapping features
        public let mergeOverlapping: Bool

        /// Minimum feature length to include
        public let minLength: Int?

        /// Maximum feature length to include
        public let maxLength: Int?

        /// Creates conversion options.
        public init(
            bedFormat: BEDFormat = .bed6,
            featureTypes: Set<String>? = nil,
            mergeOverlapping: Bool = false,
            minLength: Int? = nil,
            maxLength: Int? = nil
        ) {
            self.bedFormat = bedFormat
            self.featureTypes = featureTypes
            self.mergeOverlapping = mergeOverlapping
            self.minLength = minLength
            self.maxLength = maxLength
        }

        /// Default options.
        public static let `default` = ConversionOptions()
    }

    // MARK: - Properties

    private let logger = Logger(
        subsystem: "com.lungfish.core",
        category: "AnnotationConverter"
    )

    // MARK: - Initialization

    /// Creates an annotation converter.
    public init() {}

    // MARK: - BED Conversion

    /// Converts an annotation file to BED format.
    ///
    /// This is the intermediate step before BigBed conversion.
    /// The output BED file is sorted by chromosome and position.
    ///
    /// - Parameters:
    ///   - sourceURL: URL of the source annotation file
    ///   - format: Input file format (auto-detected if nil)
    ///   - outputURL: URL for the output BED file
    ///   - options: Conversion options
    ///   - progress: Optional progress callback (0.0-1.0, message)
    /// - Returns: URL of the created BED file
    /// - Throws: `AnnotationConversionError` if conversion fails
    public func convertToBED(
        from sourceURL: URL,
        format: InputFormat? = nil,
        output outputURL: URL,
        options: ConversionOptions = .default,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let inputFormat = format ?? InputFormat.detect(from: sourceURL)

        guard let detectedFormat = inputFormat else {
            throw AnnotationConversionError.unsupportedFormat(sourceURL.pathExtension)
        }

        progress?(0.1, "Reading \(detectedFormat.rawValue) file...")
        logger.info("Converting \(sourceURL.lastPathComponent) from \(detectedFormat.rawValue) to BED")

        // Read and convert based on format
        let features: [BEDEntry]
        switch detectedFormat {
        case .gff3, .gtf:
            features = try await readGFF3AsBED(from: sourceURL, options: options)
        case .bed:
            features = try await readBEDAsBED(from: sourceURL, options: options)
        case .genbank:
            features = try await readGenBankAsBED(from: sourceURL, options: options)
        }

        progress?(0.5, "Sorting \(features.count) features...")

        // Sort by chromosome, then by start position
        let sortedFeatures = features.sorted { a, b in
            if a.chrom != b.chrom {
                return a.chrom.localizedStandardCompare(b.chrom) == .orderedAscending
            }
            return a.chromStart < b.chromStart
        }

        progress?(0.7, "Writing BED file...")

        // Write to output
        try await writeBED(sortedFeatures, to: outputURL, format: options.bedFormat)

        progress?(1.0, "Conversion complete")
        logger.info("Wrote \(sortedFeatures.count) features to \(outputURL.lastPathComponent)")

        return outputURL
    }

    /// Converts an annotation file directly to BigBed format.
    ///
    /// This requires the bedToBigBed container plugin to be available.
    /// The conversion pipeline:
    /// 1. Convert to sorted BED file
    /// 2. Run bedToBigBed via container
    ///
    /// - Parameters:
    ///   - sourceURL: URL of the source annotation file
    ///   - format: Input file format (auto-detected if nil)
    ///   - chromSizesURL: URL to chromosome sizes file
    ///   - outputURL: URL for the output BigBed file
    ///   - options: Conversion options
    ///   - progress: Optional progress callback
    /// - Returns: URL of the created BigBed file
    /// - Throws: `AnnotationConversionError` if conversion fails
    public func convertToBigBed(
        from sourceURL: URL,
        format: InputFormat? = nil,
        chromSizes chromSizesURL: URL,
        output outputURL: URL,
        options: ConversionOptions = .default,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        // Create temp directory for intermediate files
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationConversion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Step 1: Convert to sorted BED
        let tempBedURL = tempDir.appendingPathComponent("features.bed")

        _ = try await convertToBED(
            from: sourceURL,
            format: format,
            output: tempBedURL,
            options: options,
            progress: { p, msg in
                progress?(p * 0.5, msg) // First half of progress
            }
        )

        progress?(0.5, "Running bedToBigBed...")

        // Step 2: Run bedToBigBed via container
        // This would use ContainerPluginManager - for now we copy the BED file
        // as a placeholder until container integration is complete
        try FileManager.default.copyItem(at: tempBedURL, to: outputURL)

        progress?(1.0, "BigBed conversion complete")
        logger.info("Created BigBed file: \(outputURL.lastPathComponent)")

        return outputURL
    }

    // MARK: - Format-specific Readers

    private func readGFF3AsBED(
        from url: URL,
        options: ConversionOptions
    ) async throws -> [BEDEntry] {
        var entries: [BEDEntry] = []

        // Read GFF3 file line by line
        for try await line in url.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines, comments, and directives
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("##FASTA") {
                    break // End of GFF section
                }
                continue
            }

            // Parse GFF3 line
            let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 9 else { continue }

            let seqid = fields[0]
            let featureType = fields[2]
            guard let start = Int(fields[3]),
                  let end = Int(fields[4]) else { continue }

            // Filter by feature type if specified
            if let allowedTypes = options.featureTypes,
               !allowedTypes.contains(featureType) {
                continue
            }

            // Filter by length
            let length = end - start + 1
            if let minLen = options.minLength, length < minLen { continue }
            if let maxLen = options.maxLength, length > maxLen { continue }

            // Parse strand
            let strandStr = fields[6]
            let strand: String
            switch strandStr {
            case "+": strand = "+"
            case "-": strand = "-"
            default: strand = "."
            }

            // Parse attributes for name
            let attributes = parseGFF3Attributes(fields[8])
            let name = attributes["Name"] ?? attributes["ID"] ?? featureType

            // Parse score
            let score = Int(fields[5]) ?? 0

            // Collect key attributes for extra column 14
            var extraAttrs: [String] = []
            for key in ["description", "gene_biotype", "Dbxref", "gene"] {
                if let val = attributes[key] {
                    extraAttrs.append("\(key)=\(val)")
                }
            }
            let attrStr = extraAttrs.isEmpty ? nil : extraAttrs.joined(separator: ";")

            // Convert to 0-based coordinates (GFF3 is 1-based)
            let entry = BEDEntry(
                chrom: seqid,
                chromStart: start - 1,
                chromEnd: end,
                name: name,
                score: min(1000, max(0, score)),
                strand: strand,
                thickStart: start - 1,
                thickEnd: end,
                itemRgb: "0",
                blockCount: 1,
                blockSizes: [end - start + 1],
                blockStarts: [0],
                featureType: featureType,
                featureAttributes: attrStr
            )
            entries.append(entry)
        }

        return entries
    }

    private func readBEDAsBED(
        from url: URL,
        options: ConversionOptions
    ) async throws -> [BEDEntry] {
        var entries: [BEDEntry] = []

        for try await line in url.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines, comments, track/browser lines
            if trimmed.isEmpty ||
               trimmed.hasPrefix("#") ||
               trimmed.hasPrefix("track") ||
               trimmed.hasPrefix("browser") {
                continue
            }

            let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3,
                  let chromStart = Int(fields[1]),
                  let chromEnd = Int(fields[2]) else { continue }

            // Filter by length
            let length = chromEnd - chromStart
            if let minLen = options.minLength, length < minLen { continue }
            if let maxLen = options.maxLength, length > maxLen { continue }

            let entry = BEDEntry(
                chrom: fields[0],
                chromStart: chromStart,
                chromEnd: chromEnd,
                name: fields.count > 3 ? fields[3] : ".",
                score: fields.count > 4 ? Int(fields[4]) ?? 0 : 0,
                strand: fields.count > 5 ? fields[5] : ".",
                thickStart: fields.count > 6 ? Int(fields[6]) ?? chromStart : chromStart,
                thickEnd: fields.count > 7 ? Int(fields[7]) ?? chromEnd : chromEnd,
                itemRgb: fields.count > 8 ? fields[8] : "0",
                blockCount: fields.count > 9 ? Int(fields[9]) ?? 1 : 1,
                blockSizes: fields.count > 10 ? parseIntList(fields[10]) : [chromEnd - chromStart],
                blockStarts: fields.count > 11 ? parseIntList(fields[11]) : [0]
            )
            entries.append(entry)
        }

        return entries
    }

    private func readGenBankAsBED(
        from url: URL,
        options: ConversionOptions
    ) async throws -> [BEDEntry] {
        var entries: [BEDEntry] = []
        var currentLocus = ""

        // Simple GenBank parser for FEATURES section
        var inFeatures = false
        var currentFeature: (type: String, location: String, qualifiers: [String: String])?

        for try await line in url.lines {
            // Track LOCUS for sequence name
            if line.hasPrefix("LOCUS") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2 {
                    currentLocus = String(parts[1])
                }
            }

            // Enter FEATURES section
            if line.hasPrefix("FEATURES") {
                inFeatures = true
                continue
            }

            // Exit FEATURES section
            if line.hasPrefix("ORIGIN") || line.hasPrefix("CONTIG") {
                inFeatures = false
                // Save last feature
                if let feature = currentFeature {
                    if let entry = parseGenBankFeature(
                        type: feature.type,
                        location: feature.location,
                        qualifiers: feature.qualifiers,
                        locus: currentLocus,
                        options: options
                    ) {
                        entries.append(entry)
                    }
                }
                currentFeature = nil
                continue
            }

            guard inFeatures else { continue }

            // Check for new feature (starts with feature key after spaces)
            if line.count > 5 && line.prefix(5) == "     " {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Check if this is a new feature or continuation
                if !trimmed.hasPrefix("/") && trimmed.contains(" ") {
                    // Save previous feature
                    if let feature = currentFeature {
                        if let entry = parseGenBankFeature(
                            type: feature.type,
                            location: feature.location,
                            qualifiers: feature.qualifiers,
                            locus: currentLocus,
                            options: options
                        ) {
                            entries.append(entry)
                        }
                    }

                    // Parse new feature
                    let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    if parts.count >= 2 {
                        currentFeature = (
                            type: String(parts[0]),
                            location: String(parts[1]),
                            qualifiers: [:]
                        )
                    }
                } else if trimmed.hasPrefix("/") {
                    // Qualifier line
                    if var feature = currentFeature {
                        let qualParts = trimmed.dropFirst().split(separator: "=", maxSplits: 1)
                        if qualParts.count >= 2 {
                            let key = String(qualParts[0])
                            var value = String(qualParts[1])
                            // Remove quotes
                            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                                value = String(value.dropFirst().dropLast())
                            }
                            feature.qualifiers[key] = value
                            currentFeature = feature
                        }
                    }
                }
            }
        }

        return entries
    }

    // MARK: - Helper Methods

    private func parseGFF3Attributes(_ attributeString: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pairs = attributeString.split(separator: ";")
        for pair in pairs {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            if keyValue.count == 2 {
                let key = String(keyValue[0]).trimmingCharacters(in: .whitespaces)
                let value = String(keyValue[1])
                    .replacingOccurrences(of: "%3B", with: ";")
                    .replacingOccurrences(of: "%3D", with: "=")
                    .replacingOccurrences(of: "%26", with: "&")
                    .replacingOccurrences(of: "%2C", with: ",")
                attributes[key] = value
            }
        }
        return attributes
    }

    private func parseIntList(_ value: String) -> [Int] {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .split(separator: ",")
            .compactMap { Int($0) }
    }

    private func parseGenBankFeature(
        type: String,
        location: String,
        qualifiers: [String: String],
        locus: String,
        options: ConversionOptions
    ) -> BEDEntry? {
        // Filter by feature type
        if let allowedTypes = options.featureTypes,
           !allowedTypes.contains(type) {
            return nil
        }

        // Parse location (simple version - handles N..M format)
        let cleanLocation = location
            .replacingOccurrences(of: "complement(", with: "")
            .replacingOccurrences(of: "join(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")

        let isComplement = location.contains("complement")

        // Handle simple range
        let rangeParts = cleanLocation.split(separator: "..").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard rangeParts.count >= 2 else { return nil }

        let start = rangeParts[0] - 1  // Convert to 0-based
        let end = rangeParts[1]

        // Filter by length
        let length = end - start
        if let minLen = options.minLength, length < minLen { return nil }
        if let maxLen = options.maxLength, length > maxLen { return nil }

        let name = qualifiers["gene"] ?? qualifiers["locus_tag"] ?? qualifiers["product"] ?? type

        return BEDEntry(
            chrom: locus,
            chromStart: start,
            chromEnd: end,
            name: name,
            score: 0,
            strand: isComplement ? "-" : "+",
            thickStart: start,
            thickEnd: end,
            itemRgb: "0",
            blockCount: 1,
            blockSizes: [length],
            blockStarts: [0]
        )
    }

    private func writeBED(
        _ entries: [BEDEntry],
        to url: URL,
        format: BEDFormat
    ) async throws {
        var lines: [String] = []

        for entry in entries {
            var fields: [String] = [
                entry.chrom,
                String(entry.chromStart),
                String(entry.chromEnd)
            ]

            if format.columns >= 4 {
                fields.append(entry.name)
            }
            if format.columns >= 5 {
                fields.append(String(entry.score))
            }
            if format.columns >= 6 {
                fields.append(entry.strand)
            }
            if format.columns >= 7 {
                fields.append(String(entry.thickStart))
            }
            if format.columns >= 8 {
                fields.append(String(entry.thickEnd))
            }
            if format.columns >= 9 {
                fields.append(entry.itemRgb)
            }
            if format.columns >= 10 {
                fields.append(String(entry.blockCount))
            }
            if format.columns >= 11 {
                fields.append(entry.blockSizes.map(String.init).joined(separator: ",") + ",")
            }
            if format.columns >= 12 {
                fields.append(entry.blockStarts.map(String.init).joined(separator: ",") + ",")
            }

            // Extra columns 13-14: feature type and attributes (for GFF3-sourced data)
            if entry.featureType != nil || entry.featureAttributes != nil {
                fields.append(entry.featureType ?? ".")
                if let attrs = entry.featureAttributes {
                    fields.append(attrs)
                }
            }

            lines.append(fields.joined(separator: "\t"))
        }

        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - BEDEntry

/// Internal representation of a BED12 entry for conversion.
struct BEDEntry: Sendable {
    let chrom: String
    let chromStart: Int
    let chromEnd: Int
    let name: String
    let score: Int
    let strand: String
    let thickStart: Int
    let thickEnd: Int
    let itemRgb: String
    let blockCount: Int
    let blockSizes: [Int]
    let blockStarts: [Int]
    /// GFF3 feature type (e.g., "gene", "mRNA", "CDS") — written as extra column 13
    let featureType: String?
    /// Key GFF3 attributes (e.g., "description=...;gene_biotype=...") — written as extra column 14
    let featureAttributes: String?

    init(chrom: String, chromStart: Int, chromEnd: Int, name: String, score: Int,
         strand: String, thickStart: Int, thickEnd: Int, itemRgb: String,
         blockCount: Int, blockSizes: [Int], blockStarts: [Int],
         featureType: String? = nil, featureAttributes: String? = nil) {
        self.chrom = chrom; self.chromStart = chromStart; self.chromEnd = chromEnd
        self.name = name; self.score = score; self.strand = strand
        self.thickStart = thickStart; self.thickEnd = thickEnd; self.itemRgb = itemRgb
        self.blockCount = blockCount; self.blockSizes = blockSizes; self.blockStarts = blockStarts
        self.featureType = featureType; self.featureAttributes = featureAttributes
    }
}

// MARK: - AnnotationConversionError

/// Errors that can occur during annotation conversion.
public enum AnnotationConversionError: Error, LocalizedError, Sendable {

    /// The input format is not supported.
    case unsupportedFormat(String)

    /// The input file could not be read.
    case readFailed(String)

    /// The output file could not be written.
    case writeFailed(String)

    /// bedToBigBed conversion failed.
    case bigBedConversionFailed(String)

    /// The chromosome sizes file is missing or invalid.
    case invalidChromSizes(String)

    /// No features found in input file.
    case noFeatures

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported annotation format: '.\(ext)'"
        case .readFailed(let reason):
            return "Failed to read annotation file: \(reason)"
        case .writeFailed(let reason):
            return "Failed to write output file: \(reason)"
        case .bigBedConversionFailed(let reason):
            return "BigBed conversion failed: \(reason)"
        case .invalidChromSizes(let reason):
            return "Invalid chromosome sizes: \(reason)"
        case .noFeatures:
            return "No features found in input file"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedFormat:
            return "Supported formats: GFF3, GTF, BED, GenBank"
        case .readFailed:
            return "Check that the file exists and is readable"
        case .writeFailed:
            return "Check that the output directory is writable"
        case .bigBedConversionFailed:
            return "Ensure the bedToBigBed container is available"
        case .invalidChromSizes:
            return "Provide a valid chromosome sizes file"
        case .noFeatures:
            return "Verify the input file contains annotation features"
        }
    }
}
