import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import SQLite3

enum MHCReferenceVisualizationArtifactBuilderError: Error, Equatable, LocalizedError, Sendable {
    case missingRequestedRawReferenceID(String)
    case conflictingCandidateAlleleLabels(rawReferenceID: String, alleleNames: [String])
    case candidateAlleleLabelMismatch(
        rawReferenceID: String,
        candidateAlleleName: String,
        catalogAlleleName: String
    )

    var errorDescription: String? {
        switch self {
        case .missingRequestedRawReferenceID(let rawReferenceID):
            return "The requested MHC raw reference identity '\(rawReferenceID)' is absent from the complete reference bundle."
        case .conflictingCandidateAlleleLabels(let rawReferenceID, let alleleNames):
            return "Candidates selecting raw MHC reference '\(rawReferenceID)' disagree on its allele label: \(alleleNames.joined(separator: ", "))."
        case .candidateAlleleLabelMismatch(
            let rawReferenceID,
            let candidateAlleleName,
            let catalogAlleleName
        ):
            return "Candidate-selected raw MHC reference '\(rawReferenceID)' is labeled '\(candidateAlleleName)', but the reference bundle resolves it as '\(catalogAlleleName)'."
        }
    }
}

struct MHCReferenceVisualizationArtifactBuilder {
    struct Inputs {
        let referenceBundleURL: URL
        let exactKnownRawReferenceIDs: Set<String>
        let candidates: ONTMHCCandidateAllelesDocument?
    }

    struct Output {
        let document: ONTMHCReferenceVisualizationArtifact
        let genBankText: String
        let fastaText: String
    }

    func build(_ inputs: Inputs) throws -> Output {
        let catalog = try MHCReferenceRecordCatalog.load(from: inputs.referenceBundleURL)
        let manifest = try BundleManifest.load(from: inputs.referenceBundleURL)
        let bundle = ReferenceBundle(url: inputs.referenceBundleURL, manifest: manifest)
        let recordRows = try bundle.recordStoreDatabase()?.records() ?? []
        let recordFieldsByRawID = try loadRecordFields(
            manifest: manifest,
            bundleURL: inputs.referenceBundleURL
        )
        let recordRowsByRawID = Dictionary(uniqueKeysWithValues: recordRows.map {
            ($0.sequenceName, $0)
        })
        let catalogOrdinals = Dictionary(uniqueKeysWithValues: catalog.records.enumerated().map {
            ($0.element.sequenceID, $0.offset)
        })

        var requestedRawIDs = inputs.exactKnownRawReferenceIDs
        var candidateAlleleLabels: [String: Set<String>] = [:]
        var roleClusters: [String: [String: Set<String>]] = [:]
        for rawReferenceID in inputs.exactKnownRawReferenceIDs {
            roleClusters[rawReferenceID, default: [:]][
                ONTMHCReferenceVisualizationRole.exactKnownCall.rawValue,
                default: []
            ] = []
        }

        for candidate in inputs.candidates?.candidates ?? [] {
            let rawReferenceID = candidate.selectedEvidence.referenceName
            requestedRawIDs.insert(rawReferenceID)
            candidateAlleleLabels[rawReferenceID, default: []].insert(candidate.closestReferenceName)
            let role: ONTMHCReferenceVisualizationRole = candidate.classification == .novel
                ? .closestNovelReference
                : .closestExtensionReference
            roleClusters[rawReferenceID, default: [:]][role.rawValue, default: []]
                .insert(candidate.stableClusterID)
        }

        for rawReferenceID in requestedRawIDs.sorted() {
            guard catalog.record(sequenceID: rawReferenceID) != nil else {
                throw MHCReferenceVisualizationArtifactBuilderError
                    .missingRequestedRawReferenceID(rawReferenceID)
            }
        }

        var resolvedAlleleLabels: [String: String] = [:]
        for (rawReferenceID, labels) in candidateAlleleLabels {
            let sortedLabels = labels.sorted()
            guard sortedLabels.count == 1, let candidateAlleleName = sortedLabels.first else {
                throw MHCReferenceVisualizationArtifactBuilderError.conflictingCandidateAlleleLabels(
                    rawReferenceID: rawReferenceID,
                    alleleNames: sortedLabels
                )
            }
            let catalogAlleleName = catalog.record(sequenceID: rawReferenceID)!.alleleName
            guard candidateAlleleName == catalogAlleleName else {
                throw MHCReferenceVisualizationArtifactBuilderError.candidateAlleleLabelMismatch(
                    rawReferenceID: rawReferenceID,
                    candidateAlleleName: candidateAlleleName,
                    catalogAlleleName: catalogAlleleName
                )
            }
            resolvedAlleleLabels[rawReferenceID] = candidateAlleleName
        }

        let orderedRequests = requestedRawIDs.map { rawReferenceID in
            let ordinal = recordRowsByRawID[rawReferenceID]?.sourceOrdinal
                ?? catalogOrdinals[rawReferenceID]!
            return (rawReferenceID: rawReferenceID, sourceOrdinal: ordinal)
        }.sorted {
            if $0.sourceOrdinal != $1.sourceOrdinal {
                return $0.sourceOrdinal < $1.sourceOrdinal
            }
            return $0.rawReferenceID < $1.rawReferenceID
        }

        let formatter = GenBankWriter(url: URL(fileURLWithPath: "/dev/null"))
        var records: [ONTMHCReferenceVisualizationRecord] = []
        records.reserveCapacity(orderedRequests.count)

        for request in orderedRequests {
            let catalogRecord = catalog.record(sequenceID: request.rawReferenceID)!
            let alleleName = resolvedAlleleLabels[request.rawReferenceID] ?? catalogRecord.alleleName
            let recordFields = recordFieldsByRawID[request.rawReferenceID] ?? [:]
            let region = GenomicRegion(
                chromosome: request.rawReferenceID,
                start: 0,
                end: catalogRecord.sequenceLength
            )
            let sequence = try bundle.fetchSequenceSync(region: region).uppercased()
            let annotations = try annotations(in: bundle, region: region)
            let features = annotations.enumerated().flatMap { sourceOrdinal, annotation in
                annotation.intervals.map { interval in
                    makeVisualizationFeature(
                        annotation,
                        interval: interval,
                        sourceOrdinal: sourceOrdinal
                    )
                }
            }
            let canonicalAnnotations = annotations.map(sanitizedAnnotation)
            let genBankRecord = try makeGenBankRecord(
                rawReferenceID: request.rawReferenceID,
                sequence: sequence,
                annotations: canonicalAnnotations,
                recordFields: recordFields
            )
            let genBankText = formatter.format(genBankRecord)
            let fastaText = formatFASTA(
                rawReferenceID: request.rawReferenceID,
                alleleName: alleleName,
                sequence: sequence
            )
            let roles = makeRoles(roleClusters[request.rawReferenceID] ?? [:])

            records.append(ONTMHCReferenceVisualizationRecord(
                rawReferenceID: request.rawReferenceID,
                sourceOrdinal: request.sourceOrdinal,
                alleleName: alleleName,
                locus: catalogRecord.locus,
                sequence: sequence,
                sequenceSHA256: sha256(sequence),
                recordFields: recordFields,
                features: features,
                annotatedTranslation: annotations.lazy
                    .compactMap { $0.qualifier("translation") }
                    .first,
                genBankText: genBankText,
                fastaText: fastaText,
                roles: roles
            ))
        }

        let document = try ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: records
        ).validated()
        return Output(
            document: document,
            genBankText: records.map(\.genBankText).joined(),
            fastaText: records.map(\.fastaText).joined()
        )
    }
}

private extension MHCReferenceVisualizationArtifactBuilder {
    static let excludedAnnotationQualifierKeys: Set<String> = [
        GenBankReader.rawFeatureTypeQualifierKey,
        GenBankReader.rawLocationQualifierKey,
        "annotation_db_row_id",
        "gene_name",
    ]

    func annotations(in bundle: ReferenceBundle, region: GenomicRegion) throws -> [SequenceAnnotation] {
        var annotations: [SequenceAnnotation] = []
        for trackID in bundle.annotationTrackIds {
            let queried = try bundle.getAnnotationsSync(trackId: trackID, region: region)
            let sourceOrdered = queried.enumerated().sorted { lhs, rhs in
                let lhsRowID = lhs.element.qualifier("annotation_db_row_id").flatMap(Int.init)
                let rhsRowID = rhs.element.qualifier("annotation_db_row_id").flatMap(Int.init)
                switch (lhsRowID, rhsRowID) {
                case let (.some(lhsRowID), .some(rhsRowID)) where lhsRowID != rhsRowID:
                    return lhsRowID < rhsRowID
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }.map(\.element)
            annotations.append(contentsOf: sourceOrdered)
        }
        return annotations
    }

    func loadRecordFields(
        manifest: BundleManifest,
        bundleURL: URL
    ) throws -> [String: [String: [String]]] {
        guard let store = manifest.recordStore else { return [:] }
        let databaseURL = try BundleManifest.validatedBundleMemberURL(
            for: store.databasePath,
            in: bundleURL,
            field: "record_store.database_path"
        )
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite did not return a connection"
            sqlite3_close(database)
            throw GenBankRecordDatabase.Error.openFailed(message)
        }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT r.sequence_name, fv.field_key, fv.value
            FROM records r
            JOIN field_values fv ON fv.record_id = r.id
            WHERE substr(fv.field_key, 1, 7) = 'record.'
            ORDER BY r.source_ordinal, r.id, fv.field_key COLLATE NOCASE, fv.value_ordinal
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GenBankRecordDatabase.Error.operationFailed(
                String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        var fieldsByRawID: [String: [String: [String]]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawReferenceIDText = sqlite3_column_text(statement, 0),
                  let fieldKeyText = sqlite3_column_text(statement, 1),
                  let valueText = sqlite3_column_text(statement, 2) else {
                continue
            }
            let rawReferenceID = String(cString: rawReferenceIDText)
            let storedKey = String(cString: fieldKeyText)
            let fieldKey = String(storedKey.dropFirst("record.".count))
            fieldsByRawID[rawReferenceID, default: [:]][fieldKey, default: []]
                .append(String(cString: valueText))
        }
        let result = sqlite3_errcode(database)
        guard result == SQLITE_OK || result == SQLITE_DONE else {
            throw GenBankRecordDatabase.Error.operationFailed(
                String(cString: sqlite3_errmsg(database))
            )
        }
        return fieldsByRawID
    }

    func makeVisualizationFeature(
        _ annotation: SequenceAnnotation,
        interval: AnnotationInterval,
        sourceOrdinal: Int
    ) -> ONTMHCReferenceVisualizationFeature {
        let rawFeatureType = annotation.qualifier(GenBankReader.rawFeatureTypeQualifierKey)
            ?? annotation.type.rawValue
        let rawLocation = annotation.qualifier(GenBankReader.rawLocationQualifierKey)
        let qualifiers = annotation.qualifiers.reduce(into: [String: [String]]()) { result, item in
            guard !Self.excludedAnnotationQualifierKeys.contains(item.key) else { return }
            result[item.key] = item.value.values
        }
        return ONTMHCReferenceVisualizationFeature(
            type: rawFeatureType,
            start: interval.start,
            end: interval.end,
            strand: annotation.strand.rawValue,
            sourceOrdinal: sourceOrdinal,
            rawGenBankLocation: rawLocation,
            qualifiers: qualifiers
        )
    }

    func sanitizedAnnotation(_ annotation: SequenceAnnotation) -> SequenceAnnotation {
        var annotation = annotation
        annotation.qualifiers = annotation.qualifiers.filter {
            !Self.excludedAnnotationQualifierKeys.contains($0.key)
        }
        return annotation
    }

    func makeGenBankRecord(
        rawReferenceID: String,
        sequence: String,
        annotations: [SequenceAnnotation],
        recordFields: [String: [String]]
    ) throws -> GenBankRecord {
        let moleculeType = recordFields["LOCUS.MOLECULE_TYPE"]?.first
            .flatMap(MoleculeType.init(rawValue:)) ?? .dna
        let topology = recordFields["LOCUS.TOPOLOGY"]?.first
            .flatMap(Topology.init(rawValue:)) ?? .linear
        let division = recordFields["LOCUS.DIVISION"]?.first
        let date = recordFields["LOCUS.DATE"]?.first
        return GenBankRecord(
            sequence: try Sequence(
                name: rawReferenceID,
                description: recordFields["DEFINITION"]?.first,
                alphabet: moleculeType.alphabet,
                bases: sequence
            ),
            annotations: annotations,
            locus: LocusInfo(
                name: rawReferenceID,
                length: sequence.count,
                moleculeType: moleculeType,
                topology: topology,
                division: division,
                date: date
            ),
            definition: recordFields["DEFINITION"]?.first,
            accession: recordFields["ACCESSION"]?.first,
            version: recordFields["VERSION"]?.first
        )
    }

    func makeRoles(
        _ roleClusters: [String: Set<String>]
    ) -> [ONTMHCReferenceVisualizationRoleAssignment] {
        let roleOrder: [ONTMHCReferenceVisualizationRole] = [
            .exactKnownCall,
            .closestNovelReference,
            .closestExtensionReference,
        ]
        return roleOrder.compactMap { role in
            guard let clusters = roleClusters[role.rawValue] else { return nil }
            return ONTMHCReferenceVisualizationRoleAssignment(
                role: role,
                candidateStableClusterIDs: clusters.sorted()
            )
        }
    }

    func formatFASTA(rawReferenceID: String, alleleName: String, sequence: String) -> String {
        var text = ">\(rawReferenceID) \(alleleName)\n"
        var offset = 0
        while offset < sequence.count {
            let start = sequence.index(sequence.startIndex, offsetBy: offset)
            let length = min(60, sequence.count - offset)
            let end = sequence.index(start, offsetBy: length)
            text += String(sequence[start..<end]) + "\n"
            offset += length
        }
        return text
    }

    func sha256(_ sequence: String) -> String {
        SHA256.hash(data: Data(sequence.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
