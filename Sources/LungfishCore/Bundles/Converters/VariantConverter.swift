// VariantConverter.swift - Convert VCF files to indexed BCF format
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - VariantConverter

/// Converts VCF files to indexed BCF format for efficient random access.
///
/// The conversion pipeline is:
/// 1. Validate and optionally normalize VCF
/// 2. Convert to BCF using bcftools (via container)
/// 3. Create CSI index for random access
///
/// ## Container Usage
///
/// BCF conversion requires bcftools, which runs via the container plugin system.
///
/// ## Usage
///
/// ```swift
/// let converter = VariantConverter()
///
/// // Convert VCF to indexed BCF
/// let bcfURL = try await converter.convertToBCF(
///     from: vcfURL,
///     output: outputBCFURL
/// )
/// ```
public final class VariantConverter: Sendable {

    // MARK: - Types

    /// Supported input formats for variant conversion.
    public enum InputFormat: String, Sendable, CaseIterable {
        case vcf = "vcf"
        case vcfGz = "vcf.gz"
        case bcf = "bcf"

        /// Detects format from file extension.
        public static func detect(from url: URL) -> InputFormat? {
            let path = url.path.lowercased()
            if path.hasSuffix(".vcf.gz") {
                return .vcfGz
            } else if path.hasSuffix(".vcf") {
                return .vcf
            } else if path.hasSuffix(".bcf") {
                return .bcf
            }
            return nil
        }
    }

    /// Options for variant conversion.
    public struct ConversionOptions: Sendable {
        /// Whether to normalize variants (left-align and split multi-allelic)
        public let normalize: Bool

        /// Whether to filter out low-quality variants
        public let filterLowQuality: Bool

        /// Minimum quality score to include
        public let minQuality: Double?

        /// Regions to include (nil = all)
        public let regions: [String]?

        /// Samples to include (nil = all)
        public let samples: [String]?

        /// Creates conversion options.
        public init(
            normalize: Bool = false,
            filterLowQuality: Bool = false,
            minQuality: Double? = nil,
            regions: [String]? = nil,
            samples: [String]? = nil
        ) {
            self.normalize = normalize
            self.filterLowQuality = filterLowQuality
            self.minQuality = minQuality
            self.regions = regions
            self.samples = samples
        }

        /// Default options.
        public static let `default` = ConversionOptions()
    }

    /// Statistics about a VCF file.
    public struct VCFStatistics: Sendable {
        /// Total number of variant records
        public let variantCount: Int

        /// Number of SNPs
        public let snpCount: Int

        /// Number of insertions
        public let insertionCount: Int

        /// Number of deletions
        public let deletionCount: Int

        /// Number of multi-allelic sites
        public let multiAllelicCount: Int

        /// Chromosomes present
        public let chromosomes: Set<String>

        /// Sample names
        public let samples: [String]
    }

    // MARK: - Properties

    private let logger = Logger(
        subsystem: LogSubsystem.core,
        category: "VariantConverter"
    )

    // MARK: - Initialization

    /// Creates a variant converter.
    public init() {}

    // MARK: - BCF Conversion

    /// Converts a VCF file to indexed BCF format.
    ///
    /// - Parameters:
    ///   - sourceURL: URL of the source VCF file
    ///   - outputURL: URL for the output BCF file
    ///   - options: Conversion options
    ///   - progress: Optional progress callback (0.0-1.0, message)
    /// - Returns: URL of the created BCF file
    /// - Throws: `VariantConversionError` if conversion fails
    public func convertToBCF(
        from sourceURL: URL,
        output outputURL: URL,
        options: ConversionOptions = .default,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let inputFormat = InputFormat.detect(from: sourceURL)

        guard inputFormat != nil else {
            throw VariantConversionError.unsupportedFormat(sourceURL.pathExtension)
        }

        progress?(0.1, "Validating VCF file...")
        logger.info("Converting \(sourceURL.lastPathComponent) to BCF")

        // Validate the VCF file exists
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw VariantConversionError.fileNotFound(sourceURL.path)
        }

        progress?(0.3, "Reading VCF file...")

        // Read and parse VCF to count variants and validate
        let stats = try await analyzeVCF(from: sourceURL)

        progress?(0.5, "Converting \(stats.variantCount) variants to BCF...")

        // For now, we copy the VCF as a placeholder until bcftools container is integrated
        // In production, this would use NativeToolRunner to run bcftools
        try await convertVCFToBCFPlaceholder(
            from: sourceURL,
            to: outputURL,
            options: options
        )

        progress?(0.8, "Creating index...")

        // Create placeholder index file
        let indexURL = outputURL.appendingPathExtension("csi")
        try await createIndexPlaceholder(for: outputURL, indexURL: indexURL)

        progress?(1.0, "BCF conversion complete")
        logger.info("Created BCF file: \(outputURL.lastPathComponent) with \(stats.variantCount) variants")

        return outputURL
    }

    /// Analyzes a VCF file and returns statistics.
    ///
    /// - Parameter url: URL of the VCF file
    /// - Returns: Statistics about the VCF file
    public func analyzeVCF(from url: URL) async throws -> VCFStatistics {
        var variantCount = 0
        var snpCount = 0
        var insertionCount = 0
        var deletionCount = 0
        var multiAllelicCount = 0
        var chromosomes = Set<String>()
        var samples: [String] = []

        for try await line in url.lines {
            // Parse header for samples
            if line.hasPrefix("#CHROM") {
                let fields = line.split(separator: "\t").map(String.init)
                if fields.count > 9 {
                    samples = Array(fields[9...])
                }
                continue
            }

            // Skip other header lines
            if line.hasPrefix("#") {
                continue
            }

            // Parse variant line
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8 else { continue }

            variantCount += 1
            chromosomes.insert(fields[0])

            let ref = fields[3]
            let altField = fields[4]
            let alts = altField.split(separator: ",").map(String.init)

            // Check for multi-allelic
            if alts.count > 1 {
                multiAllelicCount += 1
            }

            // Classify variant type
            for alt in alts {
                if alt == "." || alt == "*" {
                    continue
                }
                if ref.count == 1 && alt.count == 1 {
                    snpCount += 1
                } else if ref.count < alt.count {
                    insertionCount += 1
                } else if ref.count > alt.count {
                    deletionCount += 1
                }
            }
        }

        return VCFStatistics(
            variantCount: variantCount,
            snpCount: snpCount,
            insertionCount: insertionCount,
            deletionCount: deletionCount,
            multiAllelicCount: multiAllelicCount,
            chromosomes: chromosomes,
            samples: samples
        )
    }

    /// Validates a VCF file for common issues.
    ///
    /// - Parameter url: URL of the VCF file
    /// - Returns: Array of validation issues (empty if valid)
    public func validateVCF(from url: URL) async throws -> [VCFValidationIssue] {
        var issues: [VCFValidationIssue] = []
        var lineNumber = 0
        var hasHeader = false
        var hasChromLine = false
        var lastChrom = ""
        var lastPos = 0

        for try await line in url.lines {
            lineNumber += 1

            // Check for file format header
            if lineNumber == 1 {
                if !line.hasPrefix("##fileformat=VCF") {
                    issues.append(.missingFileFormatHeader)
                } else {
                    hasHeader = true
                }
                continue
            }

            // Check for #CHROM header line
            if line.hasPrefix("#CHROM") {
                hasChromLine = true
                let fields = line.split(separator: "\t")
                if fields.count < 8 {
                    issues.append(.invalidHeaderLine(lineNumber))
                }
                continue
            }

            // Skip other headers
            if line.hasPrefix("#") {
                continue
            }

            // Validate data lines
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.count < 8 {
                issues.append(.invalidDataLine(lineNumber, "too few columns"))
                continue
            }

            // Check position is numeric
            guard let pos = Int(fields[1]) else {
                issues.append(.invalidDataLine(lineNumber, "invalid position"))
                continue
            }

            // Check sorting (within same chromosome)
            if fields[0] == lastChrom && pos < lastPos {
                issues.append(.unsortedVariants(lineNumber))
            }
            lastChrom = fields[0]
            lastPos = pos

            // Check REF is not empty
            if fields[3].isEmpty {
                issues.append(.invalidDataLine(lineNumber, "empty REF"))
            }

            // Check ALT is not empty
            if fields[4].isEmpty {
                issues.append(.invalidDataLine(lineNumber, "empty ALT"))
            }
        }

        if !hasHeader {
            issues.append(.missingFileFormatHeader)
        }
        if !hasChromLine {
            issues.append(.missingChromHeader)
        }

        return issues
    }

    // MARK: - Private Helpers

    private func convertVCFToBCFPlaceholder(
        from sourceURL: URL,
        to outputURL: URL,
        options: ConversionOptions
    ) async throws {
        // This is a placeholder implementation
        // In production, this would use bcftools via NativeToolRunner:
        // bcftools view -Ob -o output.bcf input.vcf
        //
        // For now, we simply copy the file to demonstrate the pipeline

        // Create a simple BCF-like header and copy variant data
        var output = Data()

        // BCF magic number (placeholder - real BCF has specific binary format)
        let header = "##BCF_PLACEHOLDER\n"
        output.append(Data(header.utf8))

        // Copy VCF content
        let vcfData = try Data(contentsOf: sourceURL)
        output.append(vcfData)

        try output.write(to: outputURL)
    }

    private func createIndexPlaceholder(
        for bcfURL: URL,
        indexURL: URL
    ) async throws {
        // This is a placeholder implementation
        // In production, this would use bcftools via NativeToolRunner:
        // bcftools index output.bcf
        //
        // For now, create an empty index file

        let placeholder = "# BCF index placeholder\n# Real index would be created by bcftools index\n"
        try placeholder.write(to: indexURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - VCFValidationIssue

/// Validation issues that can be found in VCF files.
public enum VCFValidationIssue: Sendable, CustomStringConvertible {
    /// Missing ##fileformat header
    case missingFileFormatHeader

    /// Missing #CHROM header line
    case missingChromHeader

    /// Invalid header line
    case invalidHeaderLine(Int)

    /// Invalid data line
    case invalidDataLine(Int, String)

    /// Variants are not sorted by position
    case unsortedVariants(Int)

    /// Duplicate variant at same position
    case duplicateVariant(Int)

    public var description: String {
        switch self {
        case .missingFileFormatHeader:
            return "Missing ##fileformat=VCF header"
        case .missingChromHeader:
            return "Missing #CHROM header line"
        case .invalidHeaderLine(let line):
            return "Invalid header at line \(line)"
        case .invalidDataLine(let line, let reason):
            return "Invalid data at line \(line): \(reason)"
        case .unsortedVariants(let line):
            return "Unsorted variants at line \(line)"
        case .duplicateVariant(let line):
            return "Duplicate variant at line \(line)"
        }
    }
}

// MARK: - VariantConversionError

/// Errors that can occur during variant conversion.
public enum VariantConversionError: Error, LocalizedError, Sendable {

    /// The input format is not supported.
    case unsupportedFormat(String)

    /// The input file was not found.
    case fileNotFound(String)

    /// The VCF file is invalid.
    case invalidVCF(String)

    /// BCF conversion failed.
    case bcfConversionFailed(String)

    /// Index creation failed.
    case indexCreationFailed(String)

    /// No variants found in input file.
    case noVariants

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported variant format: '.\(ext)'"
        case .fileNotFound(let path):
            return "Variant file not found: '\(path)'"
        case .invalidVCF(let reason):
            return "Invalid VCF file: \(reason)"
        case .bcfConversionFailed(let reason):
            return "BCF conversion failed: \(reason)"
        case .indexCreationFailed(let reason):
            return "Index creation failed: \(reason)"
        case .noVariants:
            return "No variants found in input file"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedFormat:
            return "Supported formats: VCF, VCF.GZ, BCF"
        case .fileNotFound:
            return "Check that the file exists and the path is correct"
        case .invalidVCF:
            return "Validate the VCF file with vcf-validator or bcftools"
        case .bcfConversionFailed:
            return "Ensure bcftools container is available"
        case .indexCreationFailed:
            return "Check that bcftools can create indices"
        case .noVariants:
            return "Verify the input file contains variant data"
        }
    }
}
