import Foundation
import LungfishIO

enum FullLengthONTMHCWorkbookTintCategory: String, CaseIterable, Codable, Equatable, Sendable {
    case sharedNovel
    case singletonNovel
    case sharedExtension
    case singletonExtension
}

enum FullLengthONTMHCWorkbookCellValue: Codable, Equatable, Sendable {
    case text(String)
    case integer(Int)
    case decimal(Double)
    case blank
}

struct FullLengthONTMHCWorkbookCell: Codable, Equatable, Sendable {
    let value: FullLengthONTMHCWorkbookCellValue
    let tint: FullLengthONTMHCWorkbookTintCategory?

    init(_ text: String, tint: FullLengthONTMHCWorkbookTintCategory? = nil) {
        value = .text(text)
        self.tint = tint
    }

    init(_ integer: Int) {
        value = .integer(integer)
        tint = nil
    }

    init(_ decimal: Double) {
        value = .decimal(decimal)
        tint = nil
    }

    static let blank = FullLengthONTMHCWorkbookCell(value: .blank, tint: nil)

    private init(value: FullLengthONTMHCWorkbookCellValue, tint: FullLengthONTMHCWorkbookTintCategory?) {
        self.value = value
        self.tint = tint
    }
}

enum FullLengthONTMHCWorkbookProjectionError: Error, LocalizedError, Equatable, Sendable {
    case duplicateStableClusterID(String)
    case recordAppearsInBothDocuments(String)
    case observationWithoutRecord(String)
    case duplicateObservation(stableClusterID: String, sampleID: String, readGroupID: String)
    case observationSummaryMismatch(stableClusterID: String, field: String, expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .duplicateStableClusterID(let id):
            "Duplicate stable MHC cluster ID in workbook projection: \(id)."
        case .recordAppearsInBothDocuments(let id):
            "Stable MHC cluster ID appears in both candidate and un-nameable documents: \(id)."
        case .observationWithoutRecord(let id):
            "Workbook observation does not have a candidate or un-nameable record: \(id)."
        case .duplicateObservation(let id, let sample, let readGroup):
            "Duplicate MHC workbook observation for \(id), sample \(sample), read group \(readGroup)."
        case .observationSummaryMismatch(let id, let field, let expected, let actual):
            "MHC workbook projection summary mismatch for \(id) (\(field)): expected \(expected), found \(actual)."
        }
    }
}

struct FullLengthONTMHCCandidateWorkbookRow: Equatable, Sendable {
    let stableClusterID: String
    let provisionalName: String
    let locus: String
    let classification: String
    let supportClass: String
    let independentSampleCount: Int
    let occurrenceCount: Int
    let totalClusterReads: Int
    let supportingSampleIDs: [String]
    let readsBySample: [String: Int]
    let fastaRecordID: String
    let sequenceSHA256: String
    let bamPath: String
    let queryName: String
    let referenceName: String
    let readGroupID: String?
    let referenceStart: Int
    let cigar: String
    let closestReferenceName: String
    let closestReferenceClass: String
    let snpCount: Int
    let insertedBases: Int
    let deletedBases: Int
    let longGapBases: Int
    let comparableBases: Int
    let shorterCoverage: Double
    let identity: Double
    let mappingQuality: Int
    let alignmentScore: Int
    let tintCategory: FullLengthONTMHCWorkbookTintCategory
}

struct FullLengthONTMHCUnnameableWorkbookRow: Equatable, Sendable {
    let stableClusterID: String
    let reason: String
    let supportClass: String
    let independentSampleCount: Int
    let occurrenceCount: Int
    let totalClusterReads: Int
    let supportingSampleIDs: [String]
    let readsBySample: [String: Int]
    let fastaRecordID: String
    let sequenceSHA256: String
    let failedMetrics: [String: Double]
    let evidence: [ONTMHCEvidenceLocator]
}

struct FullLengthONTMHCWorkbookProjection: Equatable, Sendable {
    let sampleOrder: [String]
    let candidateRows: [FullLengthONTMHCCandidateWorkbookRow]
    let unnameableRows: [FullLengthONTMHCUnnameableWorkbookRow]

    init(
        candidateDocument: ONTMHCCandidateAllelesDocument,
        unnameableDocument: ONTMHCUnnameableClustersDocument,
        sampleOrder requestedSampleOrder: [String]
    ) throws {
        let candidateIDs = try Self.uniqueIDs(candidateDocument.candidates.map(\.stableClusterID))
        let unnameableIDs = try Self.uniqueIDs(unnameableDocument.clusters.map(\.stableClusterID))
        if let overlap = candidateIDs.intersection(unnameableIDs).sorted(by: Self.less).first {
            throw FullLengthONTMHCWorkbookProjectionError.recordAppearsInBothDocuments(overlap)
        }
        let allIDs = candidateIDs.union(unnameableIDs)
        let observations = candidateDocument.observations + unnameableDocument.observations
        if let orphan = observations.map(\.stableClusterID).first(where: { !allIDs.contains($0) }) {
            throw FullLengthONTMHCWorkbookProjectionError.observationWithoutRecord(orphan)
        }
        let observationsByID = try Self.observationsByStableID(observations)

        var seenSamples = Set<String>()
        var resolvedSampleOrder = requestedSampleOrder.filter { seenSamples.insert($0).inserted }
        let missingSamples = Set(observations.map(\.sampleID)).subtracting(seenSamples).sorted(by: Self.less)
        resolvedSampleOrder.append(contentsOf: missingSamples)
        sampleOrder = resolvedSampleOrder

        candidateRows = try candidateDocument.candidates.sorted { Self.less($0.stableClusterID, $1.stableClusterID) }.map { record in
            let grouped = observationsByID[record.stableClusterID] ?? []
            let reads = Self.readsBySample(grouped)
            try Self.validateSummary(
                stableClusterID: record.stableClusterID,
                independentSampleCount: record.independentSampleCount,
                occurrenceCount: record.occurrenceCount,
                totalClusterReads: record.totalClusterReads,
                observations: grouped,
                readsBySample: reads
            )
            return FullLengthONTMHCCandidateWorkbookRow(
                stableClusterID: record.stableClusterID,
                provisionalName: record.provisionalName,
                locus: record.locus,
                classification: record.classification.rawValue,
                supportClass: record.supportClass.rawValue,
                independentSampleCount: record.independentSampleCount,
                occurrenceCount: record.occurrenceCount,
                totalClusterReads: record.totalClusterReads,
                supportingSampleIDs: record.supportingSampleIDs,
                readsBySample: reads,
                fastaRecordID: record.fastaRecordID,
                sequenceSHA256: record.sequenceSHA256,
                bamPath: record.selectedEvidence.bamPath,
                queryName: record.selectedEvidence.queryName,
                referenceName: record.selectedEvidence.referenceName,
                readGroupID: record.selectedEvidence.readGroupID,
                referenceStart: record.selectedEvidence.referenceStart,
                cigar: record.selectedEvidence.cigar,
                closestReferenceName: record.closestReferenceName,
                closestReferenceClass: record.closestReferenceClass.rawValue,
                snpCount: record.snpCount,
                insertedBases: record.insertedBases,
                deletedBases: record.deletedBases,
                longGapBases: record.longGapBases,
                comparableBases: record.comparableBases,
                shorterCoverage: record.shorterCoverage,
                identity: record.identity,
                mappingQuality: record.mappingQuality,
                alignmentScore: record.alignmentScore,
                tintCategory: Self.tint(classification: record.classification, support: record.supportClass)
            )
        }
        unnameableRows = try unnameableDocument.clusters.sorted { Self.less($0.stableClusterID, $1.stableClusterID) }.map { record in
            let grouped = observationsByID[record.stableClusterID] ?? []
            let reads = Self.readsBySample(grouped)
            try Self.validateSummary(
                stableClusterID: record.stableClusterID,
                independentSampleCount: record.independentSampleCount,
                occurrenceCount: record.occurrenceCount,
                totalClusterReads: record.totalClusterReads,
                observations: grouped,
                readsBySample: reads
            )
            return FullLengthONTMHCUnnameableWorkbookRow(
                stableClusterID: record.stableClusterID,
                reason: record.reason.rawValue,
                supportClass: record.supportClass.rawValue,
                independentSampleCount: record.independentSampleCount,
                occurrenceCount: record.occurrenceCount,
                totalClusterReads: record.totalClusterReads,
                supportingSampleIDs: record.supportingSampleIDs,
                readsBySample: reads,
                fastaRecordID: record.fastaRecordID,
                sequenceSHA256: record.sequenceSHA256,
                failedMetrics: record.failedMetrics,
                evidence: record.evidence.sorted(by: Self.evidenceLess)
            )
        }
    }

    var candidateWorksheetRows: [[FullLengthONTMHCWorkbookCell]] {
        let header = [
            "Stable Cluster ID", "Provisional Name", "Locus", "Classification", "Support Class",
            "Independent Sample Count", "Occurrence Count", "Total Cluster Reads", "Supporting Sample IDs",
            "FASTA Record ID", "Sequence SHA-256", "BAM Path", "Query Name", "Reference Name",
            "Read Group ID", "Reference Start", "CIGAR", "Closest Reference Name", "Closest Reference Class",
            "SNP Count", "Inserted Bases", "Deleted Bases", "Long Gap Bases", "Comparable Bases",
            "Shorter Coverage", "Identity", "Mapping Quality", "Alignment Score",
        ] + sampleOrder.map { "Sample Reads: \($0)" }
        var result = [header.map { FullLengthONTMHCWorkbookCell($0) }]
        for row in candidateRows {
            var cells: [FullLengthONTMHCWorkbookCell] = [
                .init(row.stableClusterID), .init(row.provisionalName, tint: row.tintCategory), .init(row.locus),
                .init(row.classification), .init(row.supportClass), .init(row.independentSampleCount),
                .init(row.occurrenceCount), .init(row.totalClusterReads), .init(row.supportingSampleIDs.joined(separator: ";")),
                .init(row.fastaRecordID), .init(row.sequenceSHA256), .init(row.bamPath), .init(row.queryName),
                .init(row.referenceName), row.readGroupID.map { FullLengthONTMHCWorkbookCell($0) } ?? .blank,
                .init(row.referenceStart), .init(row.cigar), .init(row.closestReferenceName),
                .init(row.closestReferenceClass), .init(row.snpCount), .init(row.insertedBases),
                .init(row.deletedBases), .init(row.longGapBases), .init(row.comparableBases),
                .init(row.shorterCoverage), .init(row.identity), .init(row.mappingQuality), .init(row.alignmentScore),
            ]
            cells.append(contentsOf: sampleOrder.map { sample in
                row.readsBySample[sample].map { FullLengthONTMHCWorkbookCell($0) } ?? .blank
            })
            result.append(cells)
        }
        return result
    }

    var unnameableWorksheetRows: [[FullLengthONTMHCWorkbookCell]] {
        let header = [
            "Stable Cluster ID", "Reason", "Support Class", "Independent Sample Count", "Occurrence Count",
            "Total Cluster Reads", "Supporting Sample IDs", "FASTA Record ID", "Sequence SHA-256", "Failed Metrics",
            "Evidence Ordinal", "Evidence Count", "Evidence BAM Path", "Evidence Query Name", "Evidence Reference Name",
            "Evidence Read Group ID", "Evidence Reference Start", "Evidence CIGAR",
        ] + sampleOrder.map { "Sample Reads: \($0)" }
        var result = [header.map { FullLengthONTMHCWorkbookCell($0) }]
        for row in unnameableRows {
            let evidenceRows: [(ordinal: Int?, locator: ONTMHCEvidenceLocator?)] = row.evidence.isEmpty
                ? [(nil, nil)]
                : row.evidence.enumerated().map { ($0.offset + 1, $0.element) }
            for evidenceRow in evidenceRows {
                let locator = evidenceRow.locator
                var cells: [FullLengthONTMHCWorkbookCell] = [
                    .init(row.stableClusterID), .init(row.reason), .init(row.supportClass),
                    .init(row.independentSampleCount), .init(row.occurrenceCount), .init(row.totalClusterReads),
                    .init(row.supportingSampleIDs.joined(separator: ";")), .init(row.fastaRecordID),
                    .init(row.sequenceSHA256), .init(Self.metricText(row.failedMetrics)),
                    evidenceRow.ordinal.map { FullLengthONTMHCWorkbookCell($0) } ?? .blank,
                    .init(row.evidence.count),
                    locator.map { .init($0.bamPath) } ?? .blank,
                    locator.map { .init($0.queryName) } ?? .blank,
                    locator.map { .init($0.referenceName) } ?? .blank,
                    locator?.readGroupID.map { FullLengthONTMHCWorkbookCell($0) } ?? .blank,
                    locator.map { .init($0.referenceStart) } ?? .blank,
                    locator.map { .init($0.cigar) } ?? .blank,
                ]
                cells.append(contentsOf: sampleOrder.map { sample in
                    row.readsBySample[sample].map { FullLengthONTMHCWorkbookCell($0) } ?? .blank
                })
                result.append(cells)
            }
        }
        return result
    }

    func enrichingLegacyUnmatchedRows(_ rows: [[String]]) -> [[String]] {
        guard !rows.isEmpty else { return rows }
        let metadataHeader = [
            "provisional_name", "candidate_locus", "candidate_classification", "candidate_support_class",
            "candidate_snp_count", "candidate_inserted_bases", "candidate_deleted_bases",
            "candidate_long_gap_bases", "candidate_closest_reference", "un_nameable_reason",
        ]
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidateRows.map { ($0.stableClusterID, $0) })
        let unnameableByID = Dictionary(uniqueKeysWithValues: unnameableRows.map { ($0.stableClusterID, $0) })
        let legacyHeader = rows[0]
        var result = [Self.inserting(metadataHeader, afterFirstCellOf: legacyHeader)]
        result.append(contentsOf: rows.dropFirst().map { row in
            let id = row.first ?? ""
            let metadata: [String]
            let authoritativeRow: [String]
            if let candidate = candidatesByID[id] {
                metadata = [
                    candidate.provisionalName, candidate.locus, candidate.classification, candidate.supportClass,
                    String(candidate.snpCount), String(candidate.insertedBases), String(candidate.deletedBases),
                    String(candidate.longGapBases), candidate.closestReferenceName, "",
                ]
                authoritativeRow = Self.authoritativeLegacyRow(
                    row,
                    header: legacyHeader,
                    candidate: candidate
                )
            } else if let unnameable = unnameableByID[id] {
                metadata = ["", "", "un-nameable", unnameable.supportClass, "", "", "", "", "", unnameable.reason]
                authoritativeRow = Self.authoritativeLegacyRow(
                    row,
                    header: legacyHeader,
                    unnameable: unnameable
                )
            } else {
                metadata = Array(repeating: "", count: metadataHeader.count)
                authoritativeRow = Self.normalizingLegacyLabels(row, header: legacyHeader)
            }
            return Self.inserting(metadata, afterFirstCellOf: authoritativeRow)
        })
        return result
    }

    private static func uniqueIDs(_ ids: [String]) throws -> Set<String> {
        var result = Set<String>()
        for id in ids where !result.insert(id).inserted {
            throw FullLengthONTMHCWorkbookProjectionError.duplicateStableClusterID(id)
        }
        return result
    }

    private static func observationsByStableID(
        _ observations: [ONTMHCCandidateObservation]
    ) throws -> [String: [ONTMHCCandidateObservation]] {
        var seen = Set<String>()
        for observation in observations {
            let key = [observation.stableClusterID, observation.sampleID, observation.readGroupID].joined(separator: "\0")
            guard seen.insert(key).inserted else {
                throw FullLengthONTMHCWorkbookProjectionError.duplicateObservation(
                    stableClusterID: observation.stableClusterID,
                    sampleID: observation.sampleID,
                    readGroupID: observation.readGroupID
                )
            }
        }
        return Dictionary(grouping: observations, by: \.stableClusterID)
    }

    private static func readsBySample(_ observations: [ONTMHCCandidateObservation]) -> [String: Int] {
        observations.reduce(into: [:]) { $0[$1.sampleID, default: 0] += $1.aggregatedSampleReadCount }
    }

    private static func validateSummary(
        stableClusterID: String,
        independentSampleCount: Int,
        occurrenceCount: Int,
        totalClusterReads: Int,
        observations: [ONTMHCCandidateObservation],
        readsBySample: [String: Int]
    ) throws {
        let checks = [
            ("independent_sample_count", independentSampleCount, readsBySample.values.filter { $0 > 0 }.count),
            ("occurrence_count", occurrenceCount, observations.reduce(0) { $0 + $1.sourceClusterIDs.count }),
            ("total_cluster_reads", totalClusterReads, readsBySample.values.reduce(0, +)),
        ]
        if let mismatch = checks.first(where: { $0.1 != $0.2 }) {
            throw FullLengthONTMHCWorkbookProjectionError.observationSummaryMismatch(
                stableClusterID: stableClusterID,
                field: mismatch.0,
                expected: mismatch.1,
                actual: mismatch.2
            )
        }
    }

    private static func tint(
        classification: ONTMHCCandidateClassification,
        support: ONTMHCCandidateSupportClass
    ) -> FullLengthONTMHCWorkbookTintCategory {
        switch (classification, support) {
        case (.novel, .shared): .sharedNovel
        case (.novel, .singleton): .singletonNovel
        case (.extension, .shared): .sharedExtension
        case (.extension, .singleton): .singletonExtension
        }
    }

    private static func metricText(_ metrics: [String: Double]) -> String {
        metrics.keys.sorted(by: less).map { key in "\(key)=\(metrics[key]!)" }.joined(separator: ";")
    }

    private static func inserting(_ values: [String], afterFirstCellOf row: [String]) -> [String] {
        guard let first = row.first else { return values }
        return [first] + values + row.dropFirst()
    }

    private static func authoritativeLegacyRow(
        _ row: [String],
        header: [String],
        candidate: FullLengthONTMHCCandidateWorkbookRow
    ) -> [String] {
        replacingLegacyFields(in: row, header: header) { field, original in
            switch field {
            case "match_source": "reciprocal-minimap2"
            case "closest_match_id": candidate.provisionalName
            case "closest_reference", "closest_reference_name": candidate.closestReferenceName
            case "match_class": candidate.classification
            case "nucleotides_different", "snp_differences": String(candidate.snpCount)
            case "indel_bases": String(candidate.insertedBases + candidate.deletedBases)
            case "aligned_bases": String(candidate.comparableBases)
            case "score": String(candidate.alignmentScore)
            case "percent_identity": decimalText(candidate.identity * 100)
            case "query_coverage": decimalText(candidate.shorterCoverage * 100)
            case "evalue", "bitscore": ""
            default: original
            }
        }
    }

    private static func authoritativeLegacyRow(
        _ row: [String],
        header: [String],
        unnameable: FullLengthONTMHCUnnameableWorkbookRow
    ) -> [String] {
        replacingLegacyFields(in: row, header: header) { field, original in
            switch field {
            case "match_source": "reciprocal-unnameable"
            case "match_class": "un-nameable"
            case "closest_match_id", "closest_reference", "closest_reference_name", "nucleotides_different", "snp_differences",
                 "indel_bases", "aligned_bases", "score", "percent_identity", "query_coverage", "evalue", "bitscore": ""
            default: original
            }
        }
    }

    private static func normalizingLegacyLabels(_ row: [String], header: [String]) -> [String] {
        let originalMatchID = header.firstIndex(of: "closest_match_id").flatMap { row.indices.contains($0) ? row[$0] : nil }
        return replacingLegacyFields(in: row, header: header) { field, original in
            if field == "match_class", let originalMatchID {
                if originalMatchID.range(of: #"_0SNP$"#, options: .regularExpression) != nil { return "exact" }
                if originalMatchID.range(of: #"_[1-9][0-9]*SNP$"#, options: .regularExpression) != nil { return "novel" }
                if originalMatchID.hasSuffix("_extension") { return "extension" }
            }
            switch field {
            case "closest_match_id", "closest_reference", "closest_reference_name":
                return normalizedLegacyLabel(original)
            default:
                return original
            }
        }
    }

    private static func replacingLegacyFields(
        in row: [String],
        header: [String],
        transform: (_ field: String, _ value: String) -> String
    ) -> [String] {
        row.enumerated().map { index, value in
            transform(header.indices.contains(index) ? header[index] : "", value)
        }
    }

    private static func normalizedLegacyLabel(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "_extension", with: "_ext")
        guard let regex = try? NSRegularExpression(pattern: #"_([0-9]+)SNP"#) else { return result }
        while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let fullRange = Range(match.range(at: 0), in: result),
              let countRange = Range(match.range(at: 1), in: result),
              let count = Int(result[countRange]) {
            result.replaceSubrange(fullRange, with: count == 0 ? "" : "_\(count)nt_nov")
        }
        return result
    }

    private static func decimalText(_ value: Double) -> String {
        String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func evidenceLess(_ lhs: ONTMHCEvidenceLocator, _ rhs: ONTMHCEvidenceLocator) -> Bool {
        let left = [lhs.bamPath, lhs.queryName, lhs.referenceName, lhs.readGroupID ?? "", String(lhs.referenceStart), lhs.cigar]
        let right = [rhs.bamPath, rhs.queryName, rhs.referenceName, rhs.readGroupID ?? "", String(rhs.referenceStart), rhs.cigar]
        for (a, b) in zip(left, right) where a != b { return less(a, b) }
        return false
    }

    private static func less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
