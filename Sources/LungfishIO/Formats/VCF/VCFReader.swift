// VCFReader.swift - VCF variant file parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)
// Reference: VCF 4.3 specification

import Foundation
import LungfishCore

/// A variant record from a VCF file.
public struct VCFVariant: Sendable, Identifiable, Equatable {

    /// Unique identifier (from ID field or auto-generated)
    public let id: String

    /// Chromosome name
    public let chromosome: String

    /// Position (1-based)
    public let position: Int

    /// Reference allele
    public let ref: String

    /// Alternate allele(s)
    public let alt: [String]

    /// Quality score (PHRED-scaled)
    public let quality: Double?

    /// Filter status (PASS or filter name)
    public let filter: String?

    /// INFO field key-value pairs
    public let info: [String: String]

    /// FORMAT field
    public let format: String?

    /// Sample genotypes keyed by sample name
    public let genotypes: [String: VCFGenotype]

    /// Creates a VCF variant.
    public init(
        id: String,
        chromosome: String,
        position: Int,
        ref: String,
        alt: [String],
        quality: Double?,
        filter: String?,
        info: [String: String],
        format: String? = nil,
        genotypes: [String: VCFGenotype] = [:]
    ) {
        self.id = id
        self.chromosome = chromosome
        self.position = position
        self.ref = ref
        self.alt = alt
        self.quality = quality
        self.filter = filter
        self.info = info
        self.format = format
        self.genotypes = genotypes
    }

    // MARK: - Derived Properties

    /// Whether this variant passed all filters
    public var isPassing: Bool {
        filter == nil || filter == "PASS" || filter == "."
    }

    /// Whether this is a SNP (single nucleotide polymorphism)
    public var isSNP: Bool {
        ref.count == 1 && alt.allSatisfy { $0.count == 1 }
    }

    /// Whether this is an indel
    public var isIndel: Bool {
        ref.count != 1 || alt.contains { $0.count != 1 }
    }

    /// Whether this has multiple alternate alleles
    public var isMultiAllelic: Bool {
        alt.count > 1
    }

    /// The end position (for indels/SVs)
    public var end: Int {
        if let endStr = info["END"], let endVal = Int(endStr) {
            return endVal
        }
        return position + ref.count - 1
    }

    /// Converts to a SequenceAnnotation.
    public func toAnnotation() -> SequenceAnnotation {
        let annotationType: AnnotationType = isSNP ? .snp : .variation

        var qualifiers: [String: AnnotationQualifier] = [:]
        qualifiers["ref"] = AnnotationQualifier(ref)
        qualifiers["alt"] = AnnotationQualifier(alt.joined(separator: ","))
        if let qual = quality {
            qualifiers["quality"] = AnnotationQualifier(String(qual))
        }
        if let filt = filter {
            qualifiers["filter"] = AnnotationQualifier(filt)
        }
        for (key, value) in info {
            qualifiers[key] = AnnotationQualifier(value)
        }

        return SequenceAnnotation(
            type: annotationType,
            name: id,
            start: position - 1,  // Convert to 0-based
            end: end,
            strand: .unknown,
            qualifiers: qualifiers
        )
    }
}

// MARK: - VCFGenotype

/// Genotype information for a sample.
public struct VCFGenotype: Sendable, Equatable {

    /// Raw genotype string (e.g., "0/1", "1|1")
    public let rawGenotype: String

    /// All field values keyed by FORMAT field name
    public let fields: [String: String]

    /// Parses the allele indices from the genotype.
    public var alleleIndices: [Int] {
        let separators = CharacterSet(charactersIn: "/|")
        return rawGenotype
            .components(separatedBy: separators)
            .compactMap { Int($0) }
    }

    /// Whether this genotype is phased (uses | separator)
    public var isPhased: Bool {
        rawGenotype.contains("|")
    }

    /// Whether this is homozygous reference (0/0)
    public var isHomRef: Bool {
        alleleIndices.allSatisfy { $0 == 0 }
    }

    /// Whether this is homozygous alternate
    public var isHomAlt: Bool {
        let indices = alleleIndices
        return !indices.isEmpty && indices.allSatisfy { $0 > 0 && $0 == indices[0] }
    }

    /// Whether this is heterozygous
    public var isHet: Bool {
        let indices = Set(alleleIndices)
        return indices.count > 1
    }

    /// Depth of coverage (DP field)
    public var depth: Int? {
        fields["DP"].flatMap { Int($0) }
    }

    /// Genotype quality (GQ field)
    public var genotypeQuality: Int? {
        fields["GQ"].flatMap { Int($0) }
    }
}

// MARK: - VCFHeader

/// Parsed VCF header information.
public struct VCFHeader: Sendable {

    /// File format version (e.g., "VCFv4.3")
    public let fileFormat: String

    /// INFO field definitions
    public let infoFields: [String: VCFFieldDefinition]

    /// FORMAT field definitions
    public let formatFields: [String: VCFFieldDefinition]

    /// FILTER definitions
    public let filters: [String: String]

    /// Contig definitions with lengths
    public let contigs: [String: Int]

    /// Sample names
    public let sampleNames: [String]

    /// Other header lines
    public let otherHeaders: [String: String]

    public init(
        fileFormat: String = "VCFv4.3",
        infoFields: [String: VCFFieldDefinition] = [:],
        formatFields: [String: VCFFieldDefinition] = [:],
        filters: [String: String] = [:],
        contigs: [String: Int] = [:],
        sampleNames: [String] = [],
        otherHeaders: [String: String] = [:]
    ) {
        self.fileFormat = fileFormat
        self.infoFields = infoFields
        self.formatFields = formatFields
        self.filters = filters
        self.contigs = contigs
        self.sampleNames = sampleNames
        self.otherHeaders = otherHeaders
    }
}

/// Definition of a VCF INFO or FORMAT field.
public struct VCFFieldDefinition: Sendable {
    public let id: String
    public let number: String  // "1", "A", "G", "R", "."
    public let type: String    // "Integer", "Float", "String", "Flag", "Character"
    public let description: String

    public init(id: String, number: String, type: String, description: String) {
        self.id = id
        self.number = number
        self.type = type
        self.description = description
    }
}

// MARK: - VCFReader

/// Async streaming reader for VCF files.
///
/// Supports VCF 4.x format with full header parsing.
///
/// ## Usage
/// ```swift
/// let reader = VCFReader()
/// let header = try await reader.readHeader(from: url)
/// for try await variant in reader.variants(from: url) {
///     print("\(variant.chromosome):\(variant.position) \(variant.ref)>\(variant.alt)")
/// }
/// ```
public final class VCFReader: Sendable {

    // MARK: - Configuration

    /// Whether to validate variant records
    public let validateRecords: Bool

    /// Whether to parse genotype fields
    public let parseGenotypes: Bool

    // MARK: - Initialization

    /// Creates a VCF reader.
    ///
    /// - Parameters:
    ///   - validateRecords: Validate coordinates and alleles (default: true)
    ///   - parseGenotypes: Parse sample genotype fields (default: true)
    public init(validateRecords: Bool = true, parseGenotypes: Bool = true) {
        self.validateRecords = validateRecords
        self.parseGenotypes = parseGenotypes
    }

    // MARK: - Reading

    /// Returns an async stream of VCF variants.
    ///
    /// - Parameter url: URL of the VCF file
    /// - Returns: AsyncThrowingStream of variants
    public func variants(from url: URL) -> AsyncThrowingStream<VCFVariant, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var headerParsed = false
                    var sampleNames: [String] = []
                    var lineNumber = 0

                    for try await line in url.lines {
                        lineNumber += 1

                        // Skip empty lines
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }

                        // Skip meta-information lines
                        if trimmed.hasPrefix("##") { continue }

                        // Parse header line
                        if trimmed.hasPrefix("#CHROM") {
                            sampleNames = self.parseSampleNames(from: trimmed)
                            headerParsed = true
                            continue
                        }

                        // Parse variant record
                        guard headerParsed else {
                            continuation.finish(throwing: VCFError.missingHeader)
                            return
                        }

                        do {
                            let variant = try self.parseVariantLine(trimmed, sampleNames: sampleNames, lineNumber: lineNumber)
                            continuation.yield(variant)
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

    /// Reads all variants into memory.
    ///
    /// - Parameter url: URL of the VCF file
    /// - Returns: Array of variants
    public func readAll(from url: URL) async throws -> [VCFVariant] {
        var results: [VCFVariant] = []
        for try await variant in variants(from: url) {
            results.append(variant)
        }
        return results
    }

    /// Reads and parses the VCF header.
    ///
    /// - Parameter url: URL of the VCF file
    /// - Returns: Parsed header
    public func readHeader(from url: URL) async throws -> VCFHeader {
        var fileFormat = "VCFv4.3"
        var infoFields: [String: VCFFieldDefinition] = [:]
        var formatFields: [String: VCFFieldDefinition] = [:]
        var filters: [String: String] = [:]
        var contigs: [String: Int] = [:]
        var sampleNames: [String] = []
        var otherHeaders: [String: String] = [:]

        for try await line in url.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("##fileformat=") {
                fileFormat = String(trimmed.dropFirst(13))
            } else if trimmed.hasPrefix("##INFO=") {
                if let def = parseFieldDefinition(trimmed.dropFirst(7)) {
                    infoFields[def.id] = def
                }
            } else if trimmed.hasPrefix("##FORMAT=") {
                if let def = parseFieldDefinition(trimmed.dropFirst(9)) {
                    formatFields[def.id] = def
                }
            } else if trimmed.hasPrefix("##FILTER=") {
                let (id, desc) = parseFilterLine(String(trimmed.dropFirst(9)))
                filters[id] = desc
            } else if trimmed.hasPrefix("##contig=") {
                let (id, length) = parseContigLine(String(trimmed.dropFirst(9)))
                if let len = length {
                    contigs[id] = len
                }
            } else if trimmed.hasPrefix("#CHROM") {
                sampleNames = parseSampleNames(from: trimmed)
                break  // End of header
            } else if trimmed.hasPrefix("##") {
                // Other header lines
                if let eqIdx = trimmed.firstIndex(of: "=") {
                    let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<eqIdx])
                    let value = String(trimmed[trimmed.index(after: eqIdx)...])
                    otherHeaders[key] = value
                }
            } else {
                break  // Reached data section
            }
        }

        return VCFHeader(
            fileFormat: fileFormat,
            infoFields: infoFields,
            formatFields: formatFields,
            filters: filters,
            contigs: contigs,
            sampleNames: sampleNames,
            otherHeaders: otherHeaders
        )
    }

    /// Converts variants to annotations.
    public func readAsAnnotations(from url: URL) async throws -> [SequenceAnnotation] {
        let variants = try await readAll(from: url)
        return variants.map { $0.toAnnotation() }
    }

    // MARK: - Parsing

    private func parseSampleNames(from line: String) -> [String] {
        let fields = line.split(separator: "\t").map(String.init)
        guard fields.count > 9 else { return [] }
        return Array(fields.dropFirst(9))
    }

    private func parseVariantLine(_ line: String, sampleNames: [String], lineNumber: Int) throws -> VCFVariant {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)

        guard fields.count >= 8 else {
            throw VCFError.invalidLineFormat(line: lineNumber, expected: 8, got: fields.count)
        }

        let chromosome = fields[0]

        guard let position = Int(fields[1]) else {
            throw VCFError.invalidPosition(line: lineNumber, value: fields[1])
        }

        let id = fields[2] == "." ? "\(chromosome)_\(position)" : fields[2]
        let ref = fields[3]
        let alt = fields[4].split(separator: ",").map(String.init)
        let quality = fields[5] == "." ? nil : Double(fields[5])
        let filter = fields[6] == "." ? nil : fields[6]
        let info = parseInfoField(fields[7])

        // Parse genotypes if present
        var format: String?
        var genotypes: [String: VCFGenotype] = [:]

        if parseGenotypes && fields.count > 9 {
            format = fields[8]
            let formatFields = fields[8].split(separator: ":").map(String.init)

            for (index, sampleName) in sampleNames.enumerated() {
                if fields.count > 9 + index {
                    let genotypeFields = fields[9 + index].split(separator: ":").map(String.init)
                    var fieldDict: [String: String] = [:]
                    for (i, name) in formatFields.enumerated() {
                        if i < genotypeFields.count {
                            fieldDict[name] = genotypeFields[i]
                        }
                    }
                    let rawGT = fieldDict["GT"] ?? "./."
                    genotypes[sampleName] = VCFGenotype(rawGenotype: rawGT, fields: fieldDict)
                }
            }
        }

        // Validation
        if validateRecords {
            guard position > 0 else {
                throw VCFError.invalidPosition(line: lineNumber, value: fields[1])
            }
            guard !ref.isEmpty else {
                throw VCFError.invalidAllele(line: lineNumber, field: "REF", value: ref)
            }
        }

        return VCFVariant(
            id: id,
            chromosome: chromosome,
            position: position,
            ref: ref,
            alt: alt,
            quality: quality,
            filter: filter,
            info: info,
            format: format,
            genotypes: genotypes
        )
    }

    private func parseInfoField(_ field: String) -> [String: String] {
        guard field != "." else { return [:] }

        var result: [String: String] = [:]
        let pairs = field.split(separator: ";")

        for pair in pairs {
            if let eqIdx = pair.firstIndex(of: "=") {
                let key = String(pair[..<eqIdx])
                let value = String(pair[pair.index(after: eqIdx)...])
                result[key] = value
            } else {
                // Flag field (no value)
                result[String(pair)] = "true"
            }
        }

        return result
    }

    private func parseFieldDefinition(_ str: Substring) -> VCFFieldDefinition? {
        // Format: <ID=X,Number=Y,Type=Z,Description="...">
        let content = str.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        var dict: [String: String] = [:]

        // Simple parser for key=value pairs
        var remaining = content[...]
        while !remaining.isEmpty {
            if let eqIdx = remaining.firstIndex(of: "=") {
                let key = String(remaining[..<eqIdx])
                remaining = remaining[remaining.index(after: eqIdx)...]

                if remaining.first == "\"" {
                    // Quoted value
                    remaining = remaining.dropFirst()
                    if let endQuote = remaining.firstIndex(of: "\"") {
                        dict[key] = String(remaining[..<endQuote])
                        remaining = remaining[remaining.index(after: endQuote)...]
                        if remaining.first == "," {
                            remaining = remaining.dropFirst()
                        }
                    }
                } else {
                    // Unquoted value
                    if let commaIdx = remaining.firstIndex(of: ",") {
                        dict[key] = String(remaining[..<commaIdx])
                        remaining = remaining[remaining.index(after: commaIdx)...]
                    } else {
                        dict[key] = String(remaining)
                        remaining = ""[...]
                    }
                }
            } else {
                break
            }
        }

        guard let id = dict["ID"],
              let number = dict["Number"],
              let type = dict["Type"],
              let description = dict["Description"] else {
            return nil
        }

        return VCFFieldDefinition(id: id, number: number, type: type, description: description)
    }

    private func parseFilterLine(_ str: String) -> (String, String) {
        // Format: <ID=X,Description="...">
        let content = str.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        var id = ""
        var description = ""

        if let idRange = content.range(of: "ID=") {
            let afterId = content[idRange.upperBound...]
            if let comma = afterId.firstIndex(of: ",") {
                id = String(afterId[..<comma])
            }
        }

        if let descRange = content.range(of: "Description=\"") {
            let afterDesc = content[descRange.upperBound...]
            if let endQuote = afterDesc.firstIndex(of: "\"") {
                description = String(afterDesc[..<endQuote])
            }
        }

        return (id, description)
    }

    private func parseContigLine(_ str: String) -> (String, Int?) {
        let content = str.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        var id = ""
        var length: Int?

        if let idRange = content.range(of: "ID=") {
            let afterId = content[idRange.upperBound...]
            if let comma = afterId.firstIndex(of: ",") {
                id = String(afterId[..<comma])
            } else {
                id = String(afterId)
            }
        }

        if let lenRange = content.range(of: "length=") {
            let afterLen = content[lenRange.upperBound...]
            if let comma = afterLen.firstIndex(of: ",") {
                length = Int(afterLen[..<comma])
            } else {
                length = Int(afterLen)
            }
        }

        return (id, length)
    }
}

// MARK: - VCFError

/// Errors that can occur when parsing VCF files.
public enum VCFError: Error, LocalizedError, Sendable {

    case missingHeader
    case invalidLineFormat(line: Int, expected: Int, got: Int)
    case invalidPosition(line: Int, value: String)
    case invalidAllele(line: Int, field: String, value: String)
    case invalidQuality(line: Int, value: String)

    public var errorDescription: String? {
        switch self {
        case .missingHeader:
            return "VCF file missing header line (#CHROM...)"
        case .invalidLineFormat(let line, let expected, let got):
            return "VCF line \(line): expected at least \(expected) fields, got \(got)"
        case .invalidPosition(let line, let value):
            return "VCF line \(line): invalid position '\(value)'"
        case .invalidAllele(let line, let field, let value):
            return "VCF line \(line): invalid \(field) allele '\(value)'"
        case .invalidQuality(let line, let value):
            return "VCF line \(line): invalid quality '\(value)'"
        }
    }
}
