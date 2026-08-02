// MHCReferenceRecordCatalog.swift - MHC reference allele metadata resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

public enum MHCReferenceMoleculeClass: String, Codable, Equatable, Sendable {
    case genomicDNA
    case cDNA
}

public enum MHCReferenceClassEvidence: String, Codable, Equatable, Sendable {
    case annotatedMetadata
    case lengthThresholdFallback
}

public struct MHCReferenceRecord: Codable, Equatable, Sendable {
    public let sequenceID: String
    public let alleleName: String
    public let locus: String
    public let moleculeClass: MHCReferenceMoleculeClass
    public let classEvidence: MHCReferenceClassEvidence
    public let sequenceLength: Int

    public init(
        sequenceID: String,
        alleleName: String,
        locus: String,
        moleculeClass: MHCReferenceMoleculeClass,
        classEvidence: MHCReferenceClassEvidence,
        sequenceLength: Int
    ) {
        self.sequenceID = sequenceID
        self.alleleName = alleleName
        self.locus = locus
        self.moleculeClass = moleculeClass
        self.classEvidence = classEvidence
        self.sequenceLength = sequenceLength
    }
}

public enum MHCReferenceRecordCatalogError: Error, LocalizedError, Equatable, Sendable {
    case invalidCDNAThreshold(Int)
    case manifestReadFailed(path: String, reason: String)
    case manifestMissingGenomePath(path: String)
    case unsafeBundlePath(field: String, path: String)
    case recordStoreOpenFailed(path: String, reason: String)
    case recordStoreQueryFailed(path: String, reason: String)
    case duplicateSequenceID(String)
    case conflictingMoleculeClasses(sequenceID: String, values: [String])
    case unsupportedMoleculeTypeValues(sequenceID: String, values: [String])
    case conflictingAlleles(sequenceID: String, values: [String])
    case invalidAlleleAnnotations(sequenceID: String, values: [String])
    case ambiguousFASTAAlleles(sequenceID: String, candidates: [String])
    case conflictingLoci(sequenceID: String, alleleLocus: String, annotatedGenes: [String])
    case unresolvedAlleleOrLocus(sequenceID: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCDNAThreshold(let value):
            return "The MHC cDNA length threshold must be greater than zero; received \(value)."
        case .manifestReadFailed(let path, let reason):
            return "Could not read the MHC reference manifest at \(path): \(reason)"
        case .manifestMissingGenomePath(let path):
            return "The MHC reference manifest at \(path) does not declare genome.path."
        case .unsafeBundlePath(let field, let path):
            return "The MHC reference manifest field \(field) must name a file inside the bundle; received '\(path)'."
        case .recordStoreOpenFailed(let path, let reason):
            return "Could not open the MHC reference record store read-only at \(path): \(reason)"
        case .recordStoreQueryFailed(let path, let reason):
            return "Could not query MHC allele metadata from \(path): \(reason)"
        case .duplicateSequenceID(let sequenceID):
            return "The MHC reference FASTA contains duplicate sequence ID '\(sequenceID)', so metadata cannot be joined unambiguously."
        case .conflictingMoleculeClasses(let sequenceID, let values):
            return "Reference sequence '\(sequenceID)' has conflicting molecule-class annotations: \(values.joined(separator: ", "))."
        case .unsupportedMoleculeTypeValues(let sequenceID, let values):
            return "Reference sequence '\(sequenceID)' has unsupported nonempty molecule-class annotations: \(values.joined(separator: ", ")). Use a recognized genomic DNA, mRNA, or cDNA value."
        case .conflictingAlleles(let sequenceID, let values):
            return "Reference sequence '\(sequenceID)' has conflicting allele annotations: \(values.joined(separator: ", "))."
        case .invalidAlleleAnnotations(let sequenceID, let values):
            return "Reference sequence '\(sequenceID)' has malformed nonempty MHC allele annotations: \(values.joined(separator: ", "))."
        case .ambiguousFASTAAlleles(let sequenceID, let candidates):
            return "Reference sequence '\(sequenceID)' has multiple valid MHC allele names in its FASTA description: \(candidates.joined(separator: ", "))."
        case .conflictingLoci(let sequenceID, let alleleLocus, let annotatedGenes):
            return "Reference sequence '\(sequenceID)' resolves to allele locus '\(alleleLocus)' but has conflicting gene annotations: \(annotatedGenes.joined(separator: ", "))."
        case .unresolvedAlleleOrLocus(let sequenceID):
            return "Reference sequence '\(sequenceID)' has no resolvable MHC allele name and locus in record metadata or its FASTA description."
        }
    }
}

/// Deterministic MHC-specific projection of a `.lungfishref` bundle.
///
/// The FASTA establishes the authoritative sequence IDs, order, and lengths. When
/// present, the GenBank record store supplies allele, gene, and molecule-class
/// annotations. Missing annotations fall back to the FASTA description and the
/// configured cDNA length threshold.
public struct MHCReferenceRecordCatalog: Equatable, Sendable {
    public let records: [MHCReferenceRecord]
    private let recordsBySequenceID: [String: MHCReferenceRecord]

    private init(records: [MHCReferenceRecord]) {
        self.records = records
        self.recordsBySequenceID = Dictionary(uniqueKeysWithValues: records.map { ($0.sequenceID, $0) })
    }

    public func record(sequenceID: String) -> MHCReferenceRecord? {
        recordsBySequenceID[sequenceID]
    }

    public static func load(
        from referenceBundleURL: URL,
        cdnaThreshold: Int = 2_000
    ) throws -> MHCReferenceRecordCatalog {
        guard cdnaThreshold > 0 else {
            throw MHCReferenceRecordCatalogError.invalidCDNAThreshold(cdnaThreshold)
        }

        let manifestURL = referenceBundleURL.appendingPathComponent("manifest.json", isDirectory: false)
        let manifest: ManifestProjection
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(ManifestProjection.self, from: data)
        } catch {
            throw MHCReferenceRecordCatalogError.manifestReadFailed(
                path: manifestURL.path,
                reason: error.localizedDescription
            )
        }

        guard let genomePath = manifest.genome?.path, !genomePath.isEmpty else {
            throw MHCReferenceRecordCatalogError.manifestMissingGenomePath(path: manifestURL.path)
        }
        let fastaURL = try bundleMemberURL(
            bundleURL: referenceBundleURL,
            relativePath: genomePath,
            field: "genome.path"
        )
        let sequences = try FASTAReader(url: fastaURL).readAllSync()

        let metadataBySequenceID: [String: RecordMetadata]
        if let databasePath = manifest.recordStore?.databasePath, !databasePath.isEmpty {
            let databaseURL = try bundleMemberURL(
                bundleURL: referenceBundleURL,
                relativePath: databasePath,
                field: "record_store.database_path"
            )
            metadataBySequenceID = try readMetadata(from: databaseURL)
        } else {
            metadataBySequenceID = [:]
        }

        var seenSequenceIDs = Set<String>()
        var resolvedRecords: [MHCReferenceRecord] = []
        resolvedRecords.reserveCapacity(sequences.count)

        for sequence in sequences {
            guard seenSequenceIDs.insert(sequence.name).inserted else {
                throw MHCReferenceRecordCatalogError.duplicateSequenceID(sequence.name)
            }

            let metadata = metadataBySequenceID[sequence.name] ?? RecordMetadata()
            let alleleName = try resolveAlleleName(
                sequenceID: sequence.name,
                description: sequence.description,
                annotatedValues: metadata.alleles
            )
            guard let locus = locus(from: alleleName) else {
                throw MHCReferenceRecordCatalogError.unresolvedAlleleOrLocus(sequenceID: sequence.name)
            }
            try validateAnnotatedGenes(metadata.genes, alleleLocus: locus, sequenceID: sequence.name)

            let classResolution = try resolveMoleculeClass(
                sequenceID: sequence.name,
                sequenceLength: sequence.length,
                annotatedValues: metadata.moleculeTypes,
                cdnaThreshold: cdnaThreshold
            )
            resolvedRecords.append(
                MHCReferenceRecord(
                    sequenceID: sequence.name,
                    alleleName: alleleName,
                    locus: locus,
                    moleculeClass: classResolution.moleculeClass,
                    classEvidence: classResolution.evidence,
                    sequenceLength: sequence.length
                )
            )
        }

        return MHCReferenceRecordCatalog(records: resolvedRecords)
    }
}

private extension MHCReferenceRecordCatalog {
    struct ManifestProjection: Decodable {
        let genome: GenomeProjection?
        let recordStore: RecordStoreProjection?

        enum CodingKeys: String, CodingKey {
            case genome
            case recordStore = "record_store"
        }
    }

    struct GenomeProjection: Decodable {
        let path: String
    }

    struct RecordStoreProjection: Decodable {
        let databasePath: String

        enum CodingKeys: String, CodingKey {
            case databasePath = "database_path"
        }
    }

    struct RecordMetadata {
        var alleles: [String] = []
        var genes: [String] = []
        var moleculeTypes: [String] = []

        mutating func append(fieldKey: String, value: String) {
            switch fieldKey {
            case "feature.allele":
                alleles.append(value)
            case "feature.gene":
                genes.append(value)
            case "feature.mol_type":
                moleculeTypes.append(value)
            default:
                break
            }
        }
    }

    static func bundleMemberURL(bundleURL: URL, relativePath: String, field: String) throws -> URL {
        do {
            return try BundleManifest.validatedBundleMemberURL(
                for: relativePath,
                in: bundleURL,
                field: field
            )
        } catch {
            throw MHCReferenceRecordCatalogError.unsafeBundlePath(field: field, path: relativePath)
        }
    }

    static func readMetadata(from databaseURL: URL) throws -> [String: RecordMetadata] {
        var database: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, openFlags, nil) == SQLITE_OK,
              let database else {
            let reason = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite did not return a connection"
            if let database {
                sqlite3_close(database)
            }
            throw MHCReferenceRecordCatalogError.recordStoreOpenFailed(path: databaseURL.path, reason: reason)
        }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT r.sequence_name, f.field_key, f.value
            FROM records AS r
            JOIN field_values AS f ON f.record_id = r.id
            WHERE f.field_key IN ('feature.allele', 'feature.gene', 'feature.mol_type')
            ORDER BY r.source_ordinal, r.sequence_name, f.field_key, f.value_ordinal
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MHCReferenceRecordCatalogError.recordStoreQueryFailed(
                path: databaseURL.path,
                reason: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: RecordMetadata] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw MHCReferenceRecordCatalogError.recordStoreQueryFailed(
                    path: databaseURL.path,
                    reason: String(cString: sqlite3_errmsg(database))
                )
            }
            guard let sequenceNameText = sqlite3_column_text(statement, 0),
                  let fieldKeyText = sqlite3_column_text(statement, 1),
                  let valueText = sqlite3_column_text(statement, 2) else {
                throw MHCReferenceRecordCatalogError.recordStoreQueryFailed(
                    path: databaseURL.path,
                    reason: "records/field_values returned an unexpected NULL value"
                )
            }
            let sequenceID = String(cString: sequenceNameText)
            let fieldKey = String(cString: fieldKeyText)
            let value = String(cString: valueText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                result[sequenceID, default: RecordMetadata()].append(fieldKey: fieldKey, value: value)
            }
        }
        return result
    }

    static func resolveAlleleName(
        sequenceID: String,
        description: String?,
        annotatedValues: [String]
    ) throws -> String {
        let distinctAnnotated = uniqueSortedValues(annotatedValues)
        let invalidAnnotated = distinctAnnotated.filter { !isValidMHCAlleleName($0) }
        if !invalidAnnotated.isEmpty {
            throw MHCReferenceRecordCatalogError.invalidAlleleAnnotations(
                sequenceID: sequenceID,
                values: invalidAnnotated
            )
        }
        if distinctAnnotated.count > 1 {
            throw MHCReferenceRecordCatalogError.conflictingAlleles(
                sequenceID: sequenceID,
                values: distinctAnnotated
            )
        }
        if let annotated = distinctAnnotated.first {
            return annotated
        }
        let fallbackCandidates = alleleNames(fromFASTAHeaderDescription: description)
        if fallbackCandidates.count > 1 {
            throw MHCReferenceRecordCatalogError.ambiguousFASTAAlleles(
                sequenceID: sequenceID,
                candidates: fallbackCandidates
            )
        }
        guard let fallback = fallbackCandidates.first else {
            throw MHCReferenceRecordCatalogError.unresolvedAlleleOrLocus(sequenceID: sequenceID)
        }
        return fallback
    }

    static func alleleNames(fromFASTAHeaderDescription description: String?) -> [String] {
        guard let description else { return [] }
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;"))
        var candidates = Set<String>()
        for rawToken in description.components(separatedBy: separators) where !rawToken.isEmpty {
            let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}.'\""))
            if isValidMHCAlleleName(token) {
                candidates.insert(token)
            }
        }
        return candidates.sorted()
    }

    static func locus(from alleleName: String) -> String? {
        guard isValidMHCAlleleName(alleleName),
              let star = alleleName.firstIndex(of: "*") else { return nil }
        return String(alleleName[..<star])
    }

    static func isValidMHCAlleleName(_ value: String) -> Bool {
        let starParts = value.split(separator: "*", omittingEmptySubsequences: false)
        guard starParts.count == 2 else { return false }

        let locusParts = starParts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard locusParts.count == 2,
              locusParts.allSatisfy({
                  guard let first = $0.first, isASCIIAlpha(first) else { return false }
                  return $0.allSatisfy(isASCIIAlphaNumeric)
              }) else {
            return false
        }

        let designation = starParts[1]
        let fields = designation.split(separator: ":", omittingEmptySubsequences: false)
        guard let firstField = fields.first else { return false }
        if firstField.first == "W" {
            guard locusParts[1].hasPrefix("DRB"), isPrimaryAlleleField(firstField) else {
                return false
            }
        } else if !isPrimaryAlleleField(firstField) {
            return false
        }
        return fields.dropFirst().allSatisfy {
            isNumericAlleleField($0) || isControlledProvisionalField($0)
        }
    }

    static func isPrimaryAlleleField(_ field: Substring) -> Bool {
        if isNumericAlleleField(field) {
            return true
        }

        guard field.first == "W" else { return false }
        let numericIdentifier = field.dropFirst()
        return !numericIdentifier.isEmpty
            && numericIdentifier.allSatisfy(isASCIIDigit)
    }

    static func isNumericAlleleField(_ field: Substring) -> Bool {
        guard !field.isEmpty else { return false }
        var reachedSuffix = false
        var digitCount = 0
        for character in field {
            if isASCIIDigit(character), !reachedSuffix {
                digitCount += 1
            } else if isASCIIAlpha(character) {
                reachedSuffix = true
            } else {
                return false
            }
        }
        return digitCount > 0
    }

    static func isControlledProvisionalField(_ field: Substring) -> Bool {
        let numericIdentifier: Substring
        if field.hasPrefix("ext") {
            numericIdentifier = field.dropFirst(3)
        } else if field.hasPrefix("new") {
            numericIdentifier = field.dropFirst(3)
        } else {
            return false
        }
        return !numericIdentifier.isEmpty
            && numericIdentifier.allSatisfy(isASCIIDigit)
    }

    static func validateAnnotatedGenes(
        _ annotatedValues: [String],
        alleleLocus: String,
        sequenceID: String
    ) throws {
        let genes = uniqueSortedValues(annotatedValues)
        guard !genes.isEmpty else { return }
        let matchingGenes = genes.filter {
            alleleLocus == $0 || alleleLocus.hasSuffix("-\($0)")
        }
        guard matchingGenes.count == genes.count else {
            throw MHCReferenceRecordCatalogError.conflictingLoci(
                sequenceID: sequenceID,
                alleleLocus: alleleLocus,
                annotatedGenes: genes
            )
        }
    }

    static func resolveMoleculeClass(
        sequenceID: String,
        sequenceLength: Int,
        annotatedValues: [String],
        cdnaThreshold: Int
    ) throws -> (moleculeClass: MHCReferenceMoleculeClass, evidence: MHCReferenceClassEvidence) {
        let sortedValues = uniqueSortedValues(annotatedValues)
        let unsupportedValues = sortedValues.filter { moleculeClass(fromAnnotatedValue: $0) == nil }
        if !unsupportedValues.isEmpty {
            throw MHCReferenceRecordCatalogError.unsupportedMoleculeTypeValues(
                sequenceID: sequenceID,
                values: unsupportedValues
            )
        }
        let recognized = Set(sortedValues.compactMap(moleculeClass(fromAnnotatedValue:)))
        if recognized.count > 1 {
            throw MHCReferenceRecordCatalogError.conflictingMoleculeClasses(
                sequenceID: sequenceID,
                values: sortedValues
            )
        }
        if let annotated = recognized.first {
            return (annotated, .annotatedMetadata)
        }
        return (
            sequenceLength < cdnaThreshold ? .cDNA : .genomicDNA,
            .lengthThresholdFallback
        )
    }

    static func moleculeClass(fromAnnotatedValue rawValue: String) -> MHCReferenceMoleculeClass? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        switch normalized {
        case "genomic dna", "genomic", "gdna":
            return .genomicDNA
        case "mrna", "cdna", "complementary dna", "transcript":
            return .cDNA
        default:
            return nil
        }
    }

    static func uniqueSortedValues(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted()
    }

    static func isASCIIAlphaNumeric(_ character: Character) -> Bool {
        isASCIIAlpha(character) || isASCIIDigit(character)
    }

    static func isASCIIAlpha(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (65...90).contains(value) || (97...122).contains(value)
    }

    static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (48...57).contains(value)
    }
}
