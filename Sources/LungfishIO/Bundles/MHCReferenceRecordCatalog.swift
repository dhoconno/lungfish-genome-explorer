// MHCReferenceRecordCatalog.swift - MHC reference allele metadata resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

/// Deterministic MHC-specific projection of a `.lungfishref` bundle.
///
/// The FASTA establishes the authoritative sequence IDs, order, and lengths. When
/// present, the GenBank record store supplies allele, gene, and molecule-class
/// annotations. Missing annotations fall back to the FASTA description, a
/// recognized legacy IPD-MHC sequence identifier, and the configured cDNA
/// length threshold.
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

        let annotationFeatureTracks = try (manifest.annotations ?? []).compactMap { annotation -> AnnotationFeatureTrack? in
            guard let databasePath = annotation.databasePath, !databasePath.isEmpty else { return nil }
            let databaseURL = try bundleMemberURL(
                bundleURL: referenceBundleURL,
                relativePath: databasePath,
                field: "annotations[\(annotation.id)].database_path"
            )
            return AnnotationFeatureTrack(
                id: annotation.id,
                featuresBySequenceID: try readReferenceFeatures(from: databaseURL)
            )
        }

        var seenSequenceIDs = Set<String>()
        var resolvedRecords: [MHCReferenceRecord] = []
        resolvedRecords.reserveCapacity(sequences.count)

        for sequence in sequences {
            guard seenSequenceIDs.insert(sequence.name).inserted else {
                throw MHCReferenceRecordCatalogError.duplicateSequenceID(sequence.name)
            }

            let metadata = (metadataBySequenceID[sequence.name] ?? RecordMetadata())
                .fillingMissingValues(
                    from: annotationMetadata(
                        tracks: annotationFeatureTracks,
                        sequenceID: sequence.name
                    )
                )
            let legacyLocus = legacyIPDMHCLocus(from: sequence.name)
            let alleleName = try resolveAlleleName(
                sequenceID: sequence.name,
                description: sequence.description,
                annotatedValues: metadata.alleles,
                legacySequenceID: legacyLocus == nil ? nil : sequence.name
            )
            guard let locus = locus(from: alleleName) ?? legacyLocus else {
                throw MHCReferenceRecordCatalogError.unresolvedAlleleOrLocus(sequenceID: sequence.name)
            }
            try validateAnnotatedGenes(metadata.genes, alleleLocus: locus, sequenceID: sequence.name)

            let classResolution = try resolveMoleculeClass(
                sequenceID: sequence.name,
                sequenceLength: sequence.length,
                annotatedValues: metadata.moleculeTypes,
                cdnaThreshold: cdnaThreshold
            )
            let completeness = assessCompletenessAcrossTracks(
                moleculeClass: classResolution.moleculeClass,
                locus: locus,
                sequenceLength: sequence.length,
                tracks: annotationFeatureTracks,
                sequenceID: sequence.name
            )
            resolvedRecords.append(
                MHCReferenceRecord(
                    sequenceID: sequence.name,
                    alleleName: alleleName,
                    locus: locus,
                    moleculeClass: classResolution.moleculeClass,
                    classEvidence: classResolution.evidence,
                    sequenceLength: sequence.length,
                    completeness: completeness
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
        let annotations: [AnnotationProjection]?

        enum CodingKeys: String, CodingKey {
            case genome
            case recordStore = "record_store"
            case annotations
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

    struct AnnotationProjection: Decodable {
        let id: String
        let databasePath: String?

        enum CodingKeys: String, CodingKey {
            case id
            case databasePath = "database_path"
        }
    }

    struct ReferenceFeature {
        let type: String
        let start: Int
        let end: Int
        let attributes: String

        var number: Int? {
            attribute(named: "number").flatMap(Int.init)
        }

        func attribute(named key: String) -> String? {
            for pair in attributes.split(separator: ";", omittingEmptySubsequences: true) {
                let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2, fields[0] == Substring(key) else { continue }
                let encoded = String(fields[1])
                return encoded.removingPercentEncoding ?? encoded
            }
            return nil
        }
    }

    struct AnnotationFeatureTrack {
        let id: String
        let featuresBySequenceID: [String: [ReferenceFeature]]
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

        func fillingMissingValues(from fallback: RecordMetadata) -> RecordMetadata {
            RecordMetadata(
                alleles: alleles.isEmpty ? fallback.alleles : alleles,
                genes: genes.isEmpty ? fallback.genes : genes,
                moleculeTypes: moleculeTypes.isEmpty ? fallback.moleculeTypes : moleculeTypes
            )
        }
    }

    static func annotationMetadata(
        tracks: [AnnotationFeatureTrack],
        sequenceID: String
    ) -> RecordMetadata {
        var metadata = RecordMetadata()
        for feature in tracks.compactMap({ $0.featuresBySequenceID[sequenceID] }).flatMap({ $0 }) {
            if let allele = feature.attribute(named: "allele") {
                metadata.append(fieldKey: "feature.allele", value: allele)
            }
            if let gene = feature.attribute(named: "gene") {
                metadata.append(fieldKey: "feature.gene", value: gene)
            }
            if let moleculeType = feature.attribute(named: "mol_type") {
                metadata.append(fieldKey: "feature.mol_type", value: moleculeType)
            }
        }
        return metadata
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

    static func readReferenceFeatures(from databaseURL: URL) throws -> [String: [ReferenceFeature]] {
        var database: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, openFlags, nil) == SQLITE_OK,
              let database else {
            let reason = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite did not return a connection"
            if let database { sqlite3_close(database) }
            throw MHCReferenceRecordCatalogError.annotationStoreOpenFailed(
                path: databaseURL.path,
                reason: reason
            )
        }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT chromosome, type, start, end, COALESCE(attributes, '')
            FROM annotations
            WHERE lower(type) IN ('exon', 'intron', 'cds')
            ORDER BY chromosome, start, end, type
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MHCReferenceRecordCatalogError.annotationStoreQueryFailed(
                path: databaseURL.path,
                reason: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: [ReferenceFeature]] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  let sequenceText = sqlite3_column_text(statement, 0),
                  let typeText = sqlite3_column_text(statement, 1),
                  let attributesText = sqlite3_column_text(statement, 4) else {
                throw MHCReferenceRecordCatalogError.annotationStoreQueryFailed(
                    path: databaseURL.path,
                    reason: step == SQLITE_ROW
                        ? "annotations returned an unexpected NULL value"
                        : String(cString: sqlite3_errmsg(database))
                )
            }
            let sequenceID = String(cString: sequenceText)
            result[sequenceID, default: []].append(
                ReferenceFeature(
                    type: String(cString: typeText),
                    start: Int(sqlite3_column_int64(statement, 2)),
                    end: Int(sqlite3_column_int64(statement, 3)),
                    attributes: String(cString: attributesText)
                )
            )
        }
        return result
    }

    static func assessCompleteness(
        moleculeClass: MHCReferenceMoleculeClass,
        locus: String,
        sequenceLength: Int,
        annotationDatabaseAvailable: Bool,
        features: [ReferenceFeature],
        annotationTrackIDs: [String] = []
    ) -> MHCReferenceCompletenessAssessment {
        let acceptedTerminalExons = acceptedTerminalExons(for: locus) ?? []
        let exons = features.filter { $0.type.caseInsensitiveCompare("exon") == .orderedSame }
        let introns = features.filter { $0.type.caseInsensitiveCompare("intron") == .orderedSame }
        let observedExons = Array(Set(exons.compactMap(\.number))).sorted()
        let observedIntrons = Array(Set(introns.compactMap(\.number))).sorted()
        func assessment(
            _ status: MHCReferenceCompletenessStatus,
            _ reason: MHCReferenceCompletenessReason
        ) -> MHCReferenceCompletenessAssessment {
            MHCReferenceCompletenessAssessment(
                status: status,
                reason: reason,
                observedExons: observedExons,
                observedIntrons: observedIntrons,
                acceptedTerminalExons: acceptedTerminalExons,
                annotationTrackIDs: annotationTrackIDs.sorted()
            )
        }

        guard moleculeClass == .genomicDNA else {
            return assessment(.incomplete, .nonGenomicReference)
        }
        guard annotationDatabaseAvailable else {
            return assessment(.unknown, .missingAnnotationDatabase)
        }
        guard !features.isEmpty else {
            return assessment(.unknown, .missingAnnotationFeatures)
        }
        guard !acceptedTerminalExons.isEmpty else {
            return assessment(.unknown, .unsupportedLocusTopology)
        }

        let numberedExons = Dictionary(grouping: exons.compactMap { feature in
            feature.number.map { ($0, feature) }
        }, by: \.0)
        let numberedIntrons = Dictionary(grouping: introns.compactMap { feature in
            feature.number.map { ($0, feature) }
        }, by: \.0)
        guard numberedExons.values.allSatisfy({ $0.count == 1 }),
              numberedIntrons.values.allSatisfy({ $0.count == 1 }) else {
            return assessment(.unknown, .ambiguousAnnotationEvidence)
        }
        guard let terminalExon = observedExons.last,
              observedExons == Array(1...terminalExon) else {
            return assessment(.incomplete, .missingOrNoncontinuousExons)
        }
        guard acceptedTerminalExons.contains(terminalExon) else {
            return assessment(.incomplete, .unsupportedTerminalExon)
        }

        let exonByNumber = Dictionary(uniqueKeysWithValues: numberedExons.map { ($0.key, $0.value[0].1) })
        let intronByNumber = Dictionary(uniqueKeysWithValues: numberedIntrons.map { ($0.key, $0.value[0].1) })
        guard exonByNumber[1]?.start == 0,
              exonByNumber[terminalExon]?.end == sequenceLength else {
            return assessment(.incomplete, .missingBoundaryCoverage)
        }
        for number in 1..<terminalExon {
            guard let exon = exonByNumber[number],
                  let nextExon = exonByNumber[number + 1],
                  let intron = intronByNumber[number],
                  intron.start == exon.end,
                  intron.end == nextExon.start else {
                return assessment(.incomplete, .missingInterveningIntrons)
            }
        }

        let hasCompleteCDS = features.contains { feature in
            guard feature.type.caseInsensitiveCompare("CDS") == .orderedSame,
                  feature.start == 0,
                  feature.end == sequenceLength,
                  let rawLocation = feature.attribute(named: "_lf_raw_genbank_location") else {
                return false
            }
            return !rawLocation.contains("<") && !rawLocation.contains(">")
        }
        guard hasCompleteCDS else {
            return assessment(.incomplete, .fuzzyOrIncompleteCDS)
        }
        return assessment(.complete, .annotationTopology)
    }

    static func assessCompletenessAcrossTracks(
        moleculeClass: MHCReferenceMoleculeClass,
        locus: String,
        sequenceLength: Int,
        tracks: [AnnotationFeatureTrack],
        sequenceID: String
    ) -> MHCReferenceCompletenessAssessment {
        guard !tracks.isEmpty else {
            return assessCompleteness(
                moleculeClass: moleculeClass,
                locus: locus,
                sequenceLength: sequenceLength,
                annotationDatabaseAvailable: false,
                features: []
            )
        }
        let contributingTracks = tracks.compactMap { track -> (String, [ReferenceFeature])? in
            guard let features = track.featuresBySequenceID[sequenceID], !features.isEmpty else { return nil }
            return (track.id, features)
        }
        guard !contributingTracks.isEmpty else {
            return assessCompleteness(
                moleculeClass: moleculeClass,
                locus: locus,
                sequenceLength: sequenceLength,
                annotationDatabaseAvailable: true,
                features: [],
                annotationTrackIDs: tracks.map(\.id)
            )
        }
        let assessments = contributingTracks.map { trackID, features in
            assessCompleteness(
                moleculeClass: moleculeClass,
                locus: locus,
                sequenceLength: sequenceLength,
                annotationDatabaseAvailable: true,
                features: features,
                annotationTrackIDs: [trackID]
            )
        }
        let first = assessments[0]
        let decisionsAgree = assessments.dropFirst().allSatisfy {
            $0.status == first.status
                && $0.reason == first.reason
                && $0.observedExons == first.observedExons
                && $0.observedIntrons == first.observedIntrons
                && $0.acceptedTerminalExons == first.acceptedTerminalExons
        }
        let contributingTrackIDs = contributingTracks.map(\.0).sorted()
        guard decisionsAgree else {
            return MHCReferenceCompletenessAssessment(
                status: .unknown,
                reason: .ambiguousAnnotationEvidence,
                observedExons: Array(Set(assessments.flatMap(\.observedExons))).sorted(),
                observedIntrons: Array(Set(assessments.flatMap(\.observedIntrons))).sorted(),
                acceptedTerminalExons: acceptedTerminalExons(for: locus) ?? [],
                annotationTrackIDs: contributingTrackIDs
            )
        }
        return MHCReferenceCompletenessAssessment(
            status: first.status,
            reason: first.reason,
            observedExons: first.observedExons,
            observedIntrons: first.observedIntrons,
            acceptedTerminalExons: first.acceptedTerminalExons,
            annotationTrackIDs: contributingTrackIDs
        )
    }

    static func acceptedTerminalExons(for locus: String) -> [Int]? {
        guard let gene = locus.split(separator: "-", maxSplits: 1).last?
            .uppercased(), !gene.isEmpty else { return nil }
        if matchesLocusFamily(gene, family: "DRA") { return [5] }
        if ["DRB", "DPA", "DPB", "DQA", "DQB"].contains(where: {
            matchesLocusFamily(gene, family: $0)
        }) {
            return [6]
        }
        if ["A", "B", "C", "E", "F", "G", "I"].contains(where: {
            matchesLocusFamily(gene, family: $0)
        }) {
            return [7, 8]
        }
        return nil
    }

    static func matchesLocusFamily(_ gene: String, family: String) -> Bool {
        guard gene.hasPrefix(family) else { return false }
        return gene.dropFirst(family.count).allSatisfy(\.isNumber)
    }

    static func resolveAlleleName(
        sequenceID: String,
        description: String?,
        annotatedValues: [String],
        legacySequenceID: String?
    ) throws -> String {
        let distinctAnnotated = uniqueSortedValues(annotatedValues)
        let invalidAnnotated = distinctAnnotated.filter { !isValidMHCReferenceAlleleLabel($0) }
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
        if let fallback = fallbackCandidates.first {
            return fallback
        }
        if let legacySequenceID {
            return legacySequenceID
        }
        throw MHCReferenceRecordCatalogError.unresolvedAlleleOrLocus(sequenceID: sequenceID)
    }

    static func legacyIPDMHCLocus(from sequenceID: String) -> String? {
        let identifierParts = sequenceID.split(
            separator: "_",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard identifierParts.count == 3,
              identifierParts[0].count == 2,
              identifierParts[0].allSatisfy(isASCIIDigit) else {
            return nil
        }
        let locus = String(identifierParts[1])
        guard isValidMHCAlleleName("\(locus)*001"),
              isValidLegacyIPDMHCDesignation(identifierParts[2], locus: locus) else {
            return nil
        }
        return locus
    }

    static func isValidLegacyIPDMHCDesignation(
        _ designation: Substring,
        locus: String
    ) -> Bool {
        let labelAndAliases = designation.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard (1...2).contains(labelAndAliases.count) else {
            return false
        }
        guard labelAndAliases.count == 2 else {
            return isValidLegacyIPDMHCAlleleDesignation(labelAndAliases[0], locus: locus)
        }

        let aliases = labelAndAliases[1].split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        let aliasLoci = aliases.compactMap {
            legacyIPDMHCAliasLocus(from: $0, referenceLocus: locus)
        }
        guard !aliases.isEmpty, aliasLoci.count == aliases.count else { return false }
        return isValidLegacyIPDMHCGroupLabel(
            labelAndAliases[0],
            locus: locus,
            aliasLoci: Set(aliasLoci)
        )
    }

    static func isValidLegacyIPDMHCAlleleDesignation(
        _ designation: Substring,
        locus: String
    ) -> Bool {
        let colonDesignation = designation.split(
            separator: "_",
            omittingEmptySubsequences: false
        ).joined(separator: ":")
        return isValidMHCAlleleName("\(locus)*\(colonDesignation)")
    }

    static func legacyIPDMHCAliasLocus(
        from alias: Substring,
        referenceLocus: String
    ) -> String? {
        let fields = alias.split(separator: "_", omittingEmptySubsequences: false)
        let referenceLocusParts = referenceLocus.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard fields.count >= 2, referenceLocusParts.count == 2 else { return nil }
        let aliasGene = String(fields[0])
        let aliasLocus = "\(referenceLocusParts[0])-\(aliasGene)"
        let designation = fields.dropFirst().joined(separator: ":")
        guard isValidMHCAlleleName("\(aliasLocus)*\(designation)") else { return nil }
        return aliasGene
    }

    static func isValidLegacyIPDMHCGroupLabel(
        _ label: Substring,
        locus: String,
        aliasLoci: Set<String>
    ) -> Bool {
        let locusParts = locus.split(separator: "-", omittingEmptySubsequences: false)
        let fields = label.split(separator: "_", omittingEmptySubsequences: false)
        guard locusParts.count == 2,
              let firstCode = fields.first,
              aliasLoci.contains(String(locusParts[1])),
              isValidLegacyIPDMHCGroupCode(firstCode, gene: locusParts[1]) else {
            return false
        }
        if fields.count == 1 {
            return true
        }

        var index = 1
        while index < fields.count {
            let field = fields[index]
            if aliasLoci.contains(String(field)),
               index + 1 < fields.count,
               isValidLegacyIPDMHCGroupCode(fields[index + 1], gene: field) {
                index += 2
                continue
            }

            let joinedMatches = aliasLoci.filter { aliasLocus in
                guard field.hasPrefix(aliasLocus) else { return false }
                let groupCode = field.dropFirst(aliasLocus.count)
                return isValidLegacyIPDMHCGroupCode(groupCode, gene: Substring(aliasLocus))
            }
            guard joinedMatches.count == 1 else { return false }
            index += 1
        }
        return true
    }

    static func isValidLegacyIPDMHCGroupCode(
        _ code: Substring,
        gene: Substring
    ) -> Bool {
        let numericAndGroup: Substring
        if code.first == "W" {
            guard gene.hasPrefix("DRB") else { return false }
            numericAndGroup = code.dropFirst()
        } else {
            numericAndGroup = code
        }
        let numericIdentifier = numericAndGroup.prefix(while: isASCIIDigit)
        guard !numericIdentifier.isEmpty else { return false }
        let groupSuffix = numericAndGroup.dropFirst(numericIdentifier.count)
        guard !groupSuffix.isEmpty else { return true }
        guard groupSuffix.first == "g" else { return false }
        return groupSuffix.dropFirst().allSatisfy(isASCIIDigit)
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
        guard isValidMHCReferenceAlleleLabel(alleleName),
              let star = alleleName.firstIndex(of: "*") else { return nil }
        return String(alleleName[..<star])
    }

    static func isValidMHCReferenceAlleleLabel(_ value: String) -> Bool {
        if isValidMHCAlleleName(value) { return true }
        for marker in ["_ext", "_nov"] {
            guard let range = value.range(of: marker, options: .backwards),
                  range.upperBound == value.endIndex
                    || value[range.upperBound...].allSatisfy(isASCIIDigit) else {
                continue
            }
            let baseAllele = String(value[..<range.lowerBound])
            if isValidMHCAlleleName(baseAllele) { return true }
        }
        return false
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
