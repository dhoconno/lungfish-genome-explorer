// GenBankReader.swift - GenBank flat file parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// A parser for GenBank flat file format (.gb, .gbk, .genbank).
///
/// GenBankReader provides both streaming and batch access to GenBank files.
/// Each record in a GenBank file contains sequence data along with rich
/// annotations including genes, CDS features, and metadata.
///
/// ## File Format
///
/// GenBank files contain one or more records, each ending with `//`:
///
/// ```
/// LOCUS       NC_000001            1234567 bp    DNA     linear   PRI 01-JAN-2024
/// DEFINITION  Homo sapiens chromosome 1, complete sequence.
/// ACCESSION   NC_000001
/// VERSION     NC_000001.11
/// FEATURES             Location/Qualifiers
///      source          1..1234567
///                      /organism="Homo sapiens"
///      gene            1000..5000
///                      /gene="EXAMPLE"
/// ORIGIN
///         1 atgcatgcat gcatgcatgc
/// //
/// ```
///
/// ## Example
///
/// ```swift
/// let reader = try GenBankReader(url: genbankURL)
///
/// // Stream records
/// for try await record in reader.records() {
///     print("\(record.locus.name): \(record.sequence.length) bp")
///     print("Features: \(record.annotations.count)")
/// }
///
/// // Or read all at once
/// let allRecords = try await reader.readAll()
/// ```
public final class GenBankReader: Sendable {
    /// The file URL being read
    public let url: URL

    /// Supported file extensions
    public static let supportedExtensions: Set<String> = [
        "gb", "gbk", "genbank", "gbff"
    ]

    /// Creates a GenBank reader for the specified file.
    ///
    /// - Parameter url: The file URL to read
    /// - Throws: `GenBankError.fileNotFound` if the file doesn't exist
    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GenBankError.fileNotFound(url)
        }
        self.url = url
    }

    /// Reads all records from the file.
    ///
    /// - Returns: Array of GenBank records
    /// - Throws: `GenBankError` if parsing fails
    public func readAll() async throws -> [GenBankRecord] {
        var records: [GenBankRecord] = []
        try await parseFile { record in
            records.append(record)
        }
        return records
    }

    /// Returns an async stream of GenBank records.
    ///
    /// This is memory-efficient for large files as it yields records
    /// one at a time.
    ///
    /// - Returns: An async stream of records
    public func records() -> AsyncThrowingStream<GenBankRecord, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.parseFile { record in
                        continuation.yield(record)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Implementation

    private func parseFile(
        onRecord: @escaping (GenBankRecord) -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let data = try handle.readToEnd() else {
            return
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw GenBankError.invalidEncoding
        }

        let lines = content.components(separatedBy: .newlines)
        var lineIndex = 0

        while lineIndex < lines.count {
            // Skip empty lines between records
            while lineIndex < lines.count && lines[lineIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                lineIndex += 1
            }

            if lineIndex >= lines.count {
                break
            }

            // Parse a single record
            let (record, nextIndex) = try parseRecord(lines: lines, startIndex: lineIndex)
            if let record = record {
                onRecord(record)
            }
            lineIndex = nextIndex
        }
    }

    private func parseRecord(lines: [String], startIndex: Int) throws -> (GenBankRecord?, Int) {
        var lineIndex = startIndex
        var locus: LocusInfo?
        var definition: String?
        var accession: String?
        var version: String?
        var features: [SequenceAnnotation] = []
        var sequenceBases = ""

        // Track current section
        enum Section {
            case header
            case features
            case origin
        }
        var currentSection: Section = .header

        // For multi-line values
        var currentDefinition = ""

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // End of record marker
            if trimmedLine == "//" {
                lineIndex += 1
                break
            }

            // Check for section transitions and keywords
            if line.hasPrefix("LOCUS") {
                locus = try parseLocus(line: line, lineNumber: lineIndex + 1)
                currentSection = .header
            } else if line.hasPrefix("DEFINITION") {
                currentDefinition = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("            ") && currentSection == .header && !currentDefinition.isEmpty && definition == nil {
                // Continuation of DEFINITION
                currentDefinition += " " + trimmedLine
            } else if line.hasPrefix("ACCESSION") {
                // Finalize definition if we were building it
                if !currentDefinition.isEmpty && definition == nil {
                    definition = currentDefinition
                }
                accession = parseSimpleField(line: line, keyword: "ACCESSION")
            } else if line.hasPrefix("VERSION") {
                version = parseSimpleField(line: line, keyword: "VERSION")
            } else if line.hasPrefix("FEATURES") {
                // Finalize definition if we were building it
                if !currentDefinition.isEmpty && definition == nil {
                    definition = currentDefinition
                }
                currentSection = .features
                // Parse the features table, passing locus name for per-sequence annotation filtering
                let (parsedFeatures, nextIndex) = try parseFeatures(lines: lines, startIndex: lineIndex + 1, locusName: locus?.name)
                features = parsedFeatures
                lineIndex = nextIndex
                continue
            } else if line.hasPrefix("ORIGIN") {
                currentSection = .origin
            } else if currentSection == .origin {
                // Parse sequence line: "        1 atgcatgcat gcatgcatgc ..."
                sequenceBases += parseOriginLine(line: line)
            }

            lineIndex += 1
        }

        // Finalize definition if we were building it
        if !currentDefinition.isEmpty && definition == nil {
            definition = currentDefinition
        }

        // Build the record if we have minimum required data
        guard let locusInfo = locus else {
            // No valid LOCUS line found - might be empty space between records
            if startIndex == lineIndex - 1 {
                return (nil, lineIndex)
            }
            throw GenBankError.invalidFormat("Missing LOCUS line", line: startIndex + 1)
        }

        // Create the sequence
        let sequence: Sequence
        if sequenceBases.isEmpty {
            // Some GenBank files might not have sequence data
            sequence = try Sequence(
                name: locusInfo.name,
                description: definition,
                alphabet: locusInfo.moleculeType.alphabet,
                bases: String(repeating: "N", count: locusInfo.length)
            )
        } else {
            do {
                sequence = try Sequence(
                    name: locusInfo.name,
                    description: definition,
                    alphabet: locusInfo.moleculeType.alphabet,
                    bases: sequenceBases.uppercased()
                )
            } catch let error as SequenceError {
                throw GenBankError.invalidSequence(name: locusInfo.name, underlying: error)
            }
        }

        let record = GenBankRecord(
            sequence: sequence,
            annotations: features,
            locus: locusInfo,
            definition: definition,
            accession: accession,
            version: version
        )

        return (record, lineIndex)
    }

    // MARK: - LOCUS Parsing

    private func parseLocus(line: String, lineNumber: Int) throws -> LocusInfo {
        // LOCUS format:
        // LOCUS       NC_000001            1234567 bp    DNA     linear   PRI 01-JAN-2024
        // Columns are roughly: LOCUS, name, length, unit, moltype, topology, division, date

        let content = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        let parts = content.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        guard parts.count >= 4 else {
            throw GenBankError.invalidFormat("Invalid LOCUS line format", line: lineNumber)
        }

        let name = parts[0]

        // Find the length (a number followed by "bp" or "aa")
        var length = 0
        var moleculeType: MoleculeType = .dna
        var topology: Topology = .linear
        var division: String?
        var date: String?

        var index = 1
        while index < parts.count {
            let part = parts[index]

            if let parsedLength = Int(part) {
                length = parsedLength
            } else if part == "bp" || part == "aa" {
                // Unit indicator, length should have been parsed already
            } else if let molType = MoleculeType(rawValue: part.uppercased()) {
                moleculeType = molType
            } else if let molType = MoleculeType(rawValue: part) {
                moleculeType = molType
            } else if part.lowercased() == "circular" {
                topology = .circular
            } else if part.lowercased() == "linear" {
                topology = .linear
            } else if part.count == 3 && part.uppercased() == part {
                // Division code (PRI, ROD, MAM, etc.)
                division = part
            } else if part.contains("-") && part.count > 8 {
                // Date like "01-JAN-2024"
                date = part
            }

            index += 1
        }

        return LocusInfo(
            name: name,
            length: length,
            moleculeType: moleculeType,
            topology: topology,
            division: division,
            date: date
        )
    }

    // MARK: - Simple Field Parsing

    private func parseSimpleField(line: String, keyword: String) -> String? {
        let startIndex = line.index(line.startIndex, offsetBy: min(12, line.count))
        guard startIndex < line.endIndex else { return nil }
        let value = String(line[startIndex...]).trimmingCharacters(in: .whitespaces)
        // Take only the first word for ACCESSION/VERSION
        return value.split(separator: " ").first.map(String.init) ?? value
    }

    // MARK: - Features Parsing

    private func parseFeatures(lines: [String], startIndex: Int, locusName: String?) throws -> ([SequenceAnnotation], Int) {
        var features: [SequenceAnnotation] = []
        var lineIndex = startIndex

        // State for building current feature
        var currentFeatureType: String?
        var currentLocation: String?
        var currentQualifiers: [(String, String?)] = []
        var currentQualifierKey: String?
        var currentQualifierValue: String?

        func finalizeCurrentFeature() throws {
            guard let featureType = currentFeatureType,
                  let locationStr = currentLocation else {
                return
            }

            // Finalize any pending qualifier
            if let key = currentQualifierKey {
                currentQualifiers.append((key, currentQualifierValue))
            }

            // Parse the location
            let (intervals, strand) = try parseLocation(locationStr, lineNumber: lineIndex)

            // Convert qualifiers to dictionary
            var qualifierDict: [String: AnnotationQualifier] = [:]
            for (key, value) in currentQualifiers {
                if let existingQualifier = qualifierDict[key] {
                    // Append to existing qualifier
                    var values = existingQualifier.values
                    if let v = value {
                        values.append(v)
                    }
                    qualifierDict[key] = AnnotationQualifier(values)
                } else {
                    qualifierDict[key] = AnnotationQualifier(value ?? "")
                }
            }

            // Determine feature name from qualifiers
            let name = qualifierDict["gene"]?.firstValue
                ?? qualifierDict["locus_tag"]?.firstValue
                ?? qualifierDict["product"]?.firstValue
                ?? qualifierDict["label"]?.firstValue
                ?? featureType

            // Map feature type string to AnnotationType
            let annotationType = mapFeatureType(featureType)

            // Create annotation with chromosome set to locus name for per-sequence filtering
            let annotation = SequenceAnnotation(
                type: annotationType,
                name: name,
                chromosome: locusName,
                intervals: intervals,
                strand: strand,
                qualifiers: qualifierDict,
                note: qualifierDict["note"]?.firstValue
            )
            features.append(annotation)

            // Reset state
            currentFeatureType = nil
            currentLocation = nil
            currentQualifiers = []
            currentQualifierKey = nil
            currentQualifierValue = nil
        }

        while lineIndex < lines.count {
            let line = lines[lineIndex]

            // Check for section end (ORIGIN, CONTIG, or end of file marker)
            if line.hasPrefix("ORIGIN") || line.hasPrefix("CONTIG") || line.hasPrefix("//") {
                try finalizeCurrentFeature()
                break
            }

            // Skip empty lines
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                lineIndex += 1
                continue
            }

            // Check for new feature (feature key starts at column 5, location at column 21)
            // Feature lines have format: "     feature_key     location"
            // Feature keys can start with letters (gene, CDS) or digits (5'UTR, 3'UTR)
            if line.count >= 6 && line.prefix(5) == "     " && !line.hasPrefix("                     /") {
                let featureContent = String(line.dropFirst(5))
                // Check if this looks like a new feature line:
                // - Starts with letter (gene, CDS, exon, etc.)
                // - Starts with digit followed by ' (5'UTR, 3'UTR)
                let firstChar = featureContent.first
                let isNewFeature = firstChar?.isLetter == true ||
                                   (firstChar?.isNumber == true && featureContent.contains("'"))
                if isNewFeature {
                    // This is a new feature
                    try finalizeCurrentFeature()

                    let parts = featureContent.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    if parts.count >= 1 {
                        currentFeatureType = String(parts[0])
                        currentLocation = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                    }
                    lineIndex += 1
                    continue
                }
            }

            // Check for qualifier line (starts with 21 spaces and /)
            if line.hasPrefix("                     /") {
                // Finalize previous qualifier if any
                if let key = currentQualifierKey {
                    currentQualifiers.append((key, currentQualifierValue))
                    currentQualifierKey = nil
                    currentQualifierValue = nil
                }

                let qualifierContent = String(line.dropFirst(22)) // Remove leading spaces and /
                if let equalsIndex = qualifierContent.firstIndex(of: "=") {
                    currentQualifierKey = String(qualifierContent[..<equalsIndex])
                    var value = String(qualifierContent[qualifierContent.index(after: equalsIndex)...])
                    // Remove quotes if present
                    if value.hasPrefix("\"") {
                        value = String(value.dropFirst())
                        if value.hasSuffix("\"") {
                            value = String(value.dropLast())
                        }
                    }
                    currentQualifierValue = value
                } else {
                    // Qualifier without value (e.g., /pseudo)
                    currentQualifierKey = qualifierContent
                    currentQualifierValue = nil
                }
                lineIndex += 1
                continue
            }

            // Check for continuation line (21 spaces, no /)
            if line.hasPrefix("                     ") && !line.hasPrefix("                     /") {
                let continuation = line.trimmingCharacters(in: .whitespaces)

                if currentQualifierKey != nil {
                    // Continuation of qualifier value
                    if var value = currentQualifierValue {
                        var contValue = continuation
                        // Handle quoted continuation
                        if contValue.hasSuffix("\"") {
                            contValue = String(contValue.dropLast())
                        }
                        value += contValue
                        currentQualifierValue = value
                    }
                } else if currentLocation != nil {
                    // Continuation of location
                    currentLocation! += continuation
                }
                lineIndex += 1
                continue
            }

            lineIndex += 1
        }

        return (features, lineIndex)
    }

    // MARK: - Location Parsing

    private func parseLocation(_ locationStr: String, lineNumber: Int) throws -> ([AnnotationInterval], Strand) {
        let location = locationStr.trimmingCharacters(in: .whitespaces)

        // Parse the location and determine strand
        let (intervals, isComplement) = try parseLocationExpression(location, lineNumber: lineNumber)

        let strand: Strand = isComplement ? .reverse : .forward
        return (intervals, strand)
    }

    private func parseLocationExpression(_ expr: String, lineNumber: Int) throws -> ([AnnotationInterval], Bool) {
        var expression = expr.trimmingCharacters(in: .whitespaces)
        var isComplement = false

        // Handle complement()
        if expression.hasPrefix("complement(") && expression.hasSuffix(")") {
            isComplement = true
            expression = String(expression.dropFirst(11).dropLast(1))
        }

        // Handle join()
        if expression.hasPrefix("join(") && expression.hasSuffix(")") {
            let inner = String(expression.dropFirst(5).dropLast(1))
            let parts = splitLocationParts(inner)
            var intervals: [AnnotationInterval] = []
            for part in parts {
                let (partIntervals, _) = try parseLocationExpression(part, lineNumber: lineNumber)
                intervals.append(contentsOf: partIntervals)
            }
            return (intervals, isComplement)
        }

        // Handle order()
        if expression.hasPrefix("order(") && expression.hasSuffix(")") {
            let inner = String(expression.dropFirst(6).dropLast(1))
            let parts = splitLocationParts(inner)
            var intervals: [AnnotationInterval] = []
            for part in parts {
                let (partIntervals, _) = try parseLocationExpression(part, lineNumber: lineNumber)
                intervals.append(contentsOf: partIntervals)
            }
            return (intervals, isComplement)
        }

        // Parse simple range: start..end or start^end or single position
        let interval = try parseSimpleLocation(expression, lineNumber: lineNumber)
        return ([interval], isComplement)
    }

    private func splitLocationParts(_ inner: String) -> [String] {
        // Split on commas, but respect nested parentheses
        var parts: [String] = []
        var current = ""
        var depth = 0

        for char in inner {
            if char == "(" {
                depth += 1
                current.append(char)
            } else if char == ")" {
                depth -= 1
                current.append(char)
            } else if char == "," && depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            parts.append(current.trimmingCharacters(in: .whitespaces))
        }
        return parts
    }

    private func parseSimpleLocation(_ expr: String, lineNumber: Int) throws -> AnnotationInterval {
        var expression = expr

        // Handle complement() if still present (nested complement)
        if expression.hasPrefix("complement(") && expression.hasSuffix(")") {
            expression = String(expression.dropFirst(11).dropLast(1))
        }

        // Remove position modifiers like < and >
        expression = expression.replacingOccurrences(of: "<", with: "")
        expression = expression.replacingOccurrences(of: ">", with: "")

        // Handle range: start..end
        if expression.contains("..") {
            let parts = expression.components(separatedBy: "..")
            guard parts.count == 2,
                  let start = parsePosition(parts[0]),
                  let end = parsePosition(parts[1]) else {
                throw GenBankError.invalidLocation(expression)
            }
            // GenBank uses 1-based coordinates, convert to 0-based
            return AnnotationInterval(start: start - 1, end: end)
        }

        // Handle insertion point: start^end
        if expression.contains("^") {
            let parts = expression.components(separatedBy: "^")
            guard parts.count == 2,
                  let start = parsePosition(parts[0]),
                  let end = parsePosition(parts[1]) else {
                throw GenBankError.invalidLocation(expression)
            }
            // For insertion points, the feature is between the two positions
            return AnnotationInterval(start: start - 1, end: end)
        }

        // Single position
        if let pos = parsePosition(expression) {
            // Single position becomes a 1-bp interval
            return AnnotationInterval(start: pos - 1, end: pos)
        }

        throw GenBankError.invalidLocation(expression)
    }

    private func parsePosition(_ str: String) -> Int? {
        // Handle positions that might have accession prefix like "NC_000001.11:1000"
        let cleanStr: String
        if let colonIndex = str.lastIndex(of: ":") {
            cleanStr = String(str[str.index(after: colonIndex)...])
        } else {
            cleanStr = str
        }
        return Int(cleanStr.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Origin Parsing

    private func parseOriginLine(line: String) -> String {
        // ORIGIN lines look like: "        1 atgcatgcat gcatgcatgc ..."
        // We need to extract just the sequence characters
        var sequence = ""
        for char in line {
            if char.isLetter {
                sequence.append(char)
            }
        }
        return sequence
    }

    // MARK: - Feature Type Mapping

    private func mapFeatureType(_ typeString: String) -> AnnotationType {
        switch typeString.lowercased() {
        case "gene": return .gene
        case "mrna": return .mRNA
        case "cds": return .cds
        case "exon": return .exon
        case "intron": return .intron
        case "5'utr", "five_prime_utr": return .utr5
        case "3'utr", "three_prime_utr": return .utr3
        case "promoter": return .promoter
        case "enhancer": return .enhancer
        case "terminator": return .terminator
        case "polya_signal": return .polyASignal
        case "primer_bind": return .primer
        case "repeat_region": return .repeatRegion
        case "stem_loop": return .stem_loop
        case "source": return .source
        case "misc_feature": return .misc_feature
        case "variation": return .variation
        case "gap": return .gap
        case "region": return .region
        default: return .misc_feature
        }
    }
}

// MARK: - GenBankRecord

/// A complete GenBank record containing sequence data and annotations.
public struct GenBankRecord: Sendable {
    /// The biological sequence
    public let sequence: Sequence

    /// Feature annotations from the FEATURES table
    public let annotations: [SequenceAnnotation]

    /// LOCUS line information
    public let locus: LocusInfo

    /// DEFINITION line (sequence description)
    public let definition: String?

    /// ACCESSION number
    public let accession: String?

    /// VERSION string (accession.version format)
    public let version: String?

    public init(
        sequence: Sequence,
        annotations: [SequenceAnnotation],
        locus: LocusInfo,
        definition: String? = nil,
        accession: String? = nil,
        version: String? = nil
    ) {
        self.sequence = sequence
        self.annotations = annotations
        self.locus = locus
        self.definition = definition
        self.accession = accession
        self.version = version
    }
}

// MARK: - LocusInfo

/// Information from the GenBank LOCUS line.
public struct LocusInfo: Sendable {
    /// Sequence name/identifier
    public let name: String

    /// Sequence length in base pairs (or amino acids for protein)
    public let length: Int

    /// Molecule type (DNA, RNA, mRNA, etc.)
    public let moleculeType: MoleculeType

    /// Topology (linear or circular)
    public let topology: Topology

    /// GenBank division code (PRI, ROD, VRT, etc.)
    public let division: String?

    /// Modification date
    public let date: String?

    public init(
        name: String,
        length: Int,
        moleculeType: MoleculeType,
        topology: Topology,
        division: String? = nil,
        date: String? = nil
    ) {
        self.name = name
        self.length = length
        self.moleculeType = moleculeType
        self.topology = topology
        self.division = division
        self.date = date
    }
}

// MARK: - MoleculeType

/// GenBank molecule types
public enum MoleculeType: String, Sendable, CaseIterable {
    case dna = "DNA"
    case rna = "RNA"
    case mrna = "mRNA"
    case trna = "tRNA"
    case rrna = "rRNA"
    case genomicDNA = "genomic DNA"
    case genomicRNA = "genomic RNA"
    case protein = "AA"

    /// Maps to SequenceAlphabet
    public var alphabet: SequenceAlphabet {
        switch self {
        case .protein:
            return .protein
        case .rna, .mrna, .trna, .rrna, .genomicRNA:
            return .rna
        default:
            return .dna
        }
    }

    /// Initialize from various string formats found in GenBank files
    public init?(rawValue: String) {
        switch rawValue.uppercased() {
        case "DNA", "DS-DNA", "SS-DNA": self = .dna
        case "RNA", "DS-RNA", "SS-RNA": self = .rna
        case "MRNA": self = .mrna
        case "TRNA": self = .trna
        case "RRNA": self = .rrna
        case "AA": self = .protein
        default:
            if rawValue.lowercased().contains("dna") {
                self = .dna
            } else if rawValue.lowercased().contains("rna") {
                self = .rna
            } else {
                return nil
            }
        }
    }
}

// MARK: - Topology

/// Sequence topology
public enum Topology: String, Sendable {
    case linear
    case circular
}

// MARK: - GenBankError

/// Errors that can occur during GenBank parsing.
public enum GenBankError: Error, LocalizedError {
    case fileNotFound(URL)
    case invalidEncoding
    case invalidFormat(String, line: Int)
    case invalidLocation(String)
    case invalidSequence(name: String, underlying: SequenceError)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "GenBank file not found: \(url.path)"
        case .invalidEncoding:
            return "GenBank file has invalid encoding (expected UTF-8)"
        case .invalidFormat(let message, let line):
            return "Invalid GenBank format at line \(line): \(message)"
        case .invalidLocation(let location):
            return "Invalid GenBank location: \(location)"
        case .invalidSequence(let name, let underlying):
            return "Invalid sequence '\(name)': \(underlying.localizedDescription)"
        }
    }
}

// MARK: - GenBankWriter

/// A writer for GenBank format files.
public final class GenBankWriter: Sendable {
    /// The file URL to write to
    public let url: URL

    /// Creates a GenBank writer for the specified file.
    ///
    /// - Parameter url: The file URL to write
    public init(url: URL) {
        self.url = url
    }

    /// Writes records to the file.
    ///
    /// - Parameter records: The records to write
    /// - Throws: If writing fails
    public func write(_ records: [GenBankRecord]) throws {
        var content = ""

        for record in records {
            content += formatRecord(record)
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func formatRecord(_ record: GenBankRecord) -> String {
        var lines: [String] = []

        // LOCUS line
        let locusLine = formatLocusLine(record.locus)
        lines.append(locusLine)

        // DEFINITION
        if let definition = record.definition {
            lines.append("DEFINITION  \(definition)")
        }

        // ACCESSION
        if let accession = record.accession {
            lines.append("ACCESSION   \(accession)")
        }

        // VERSION
        if let version = record.version {
            lines.append("VERSION     \(version)")
        }

        // FEATURES
        if !record.annotations.isEmpty {
            lines.append("FEATURES             Location/Qualifiers")
            for annotation in record.annotations {
                lines.append(contentsOf: formatFeature(annotation))
            }
        }

        // ORIGIN
        lines.append("ORIGIN      ")
        lines.append(contentsOf: formatOrigin(record.sequence.asString()))

        // Record terminator
        lines.append("//")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private func formatLocusLine(_ locus: LocusInfo) -> String {
        let paddedName = locus.name.padding(toLength: 16, withPad: " ", startingAt: 0)
        var line = "LOCUS       \(paddedName)\(String(format: "%11d", locus.length)) bp    \(locus.moleculeType.rawValue)  \(locus.topology.rawValue)"
        if let division = locus.division {
            line += " \(division)"
        }
        if let date = locus.date {
            line += " \(date)"
        }
        return line
    }

    private func formatFeature(_ annotation: SequenceAnnotation) -> [String] {
        var lines: [String] = []

        // Feature key and location
        let featureType = annotation.type.rawValue.lowercased()
        let location = formatLocation(annotation)
        let paddedType = featureType.padding(toLength: 15, withPad: " ", startingAt: 0)
        lines.append("     \(paddedType) \(location)")

        // Qualifiers
        for (key, qualifier) in annotation.qualifiers.sorted(by: { $0.key < $1.key }) {
            for value in qualifier.values {
                if value.isEmpty {
                    lines.append("                     /\(key)")
                } else {
                    lines.append("                     /\(key)=\"\(value)\"")
                }
            }
        }

        return lines
    }

    private func formatLocation(_ annotation: SequenceAnnotation) -> String {
        let intervals = annotation.intervals

        // Format intervals (convert from 0-based to 1-based)
        let formatInterval: (AnnotationInterval) -> String = { interval in
            let start = interval.start + 1
            let end = interval.end
            if start == end {
                return "\(start)"
            }
            return "\(start)..\(end)"
        }

        var location: String
        if intervals.count == 1 {
            location = formatInterval(intervals[0])
        } else {
            let parts = intervals.map(formatInterval)
            location = "join(\(parts.joined(separator: ",")))"
        }

        if annotation.strand == .reverse {
            location = "complement(\(location))"
        }

        return location
    }

    private func formatOrigin(_ sequence: String) -> [String] {
        var lines: [String] = []
        var position = 0
        let lowercaseSeq = sequence.lowercased()

        while position < lowercaseSeq.count {
            let lineStart = position
            var lineParts: [String] = []

            // Position number (right-justified in 9 characters)
            let positionStr = String(format: "%9d", lineStart + 1)

            // Up to 6 groups of 10 bases per line
            for _ in 0..<6 {
                if position >= lowercaseSeq.count {
                    break
                }
                let endPos = min(position + 10, lowercaseSeq.count)
                let startIndex = lowercaseSeq.index(lowercaseSeq.startIndex, offsetBy: position)
                let endIndex = lowercaseSeq.index(lowercaseSeq.startIndex, offsetBy: endPos)
                lineParts.append(String(lowercaseSeq[startIndex..<endIndex]))
                position = endPos
            }

            lines.append(positionStr + " " + lineParts.joined(separator: " "))
        }

        return lines
    }
}
