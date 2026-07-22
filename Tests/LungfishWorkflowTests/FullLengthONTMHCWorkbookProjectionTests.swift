import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow
import XCTest

final class FullLengthONTMHCWorkbookProjectionTests: XCTestCase {
    func testNormalizedUnmatchedRowsJoinFASTAAndGenBankByStableIdentity() throws {
        let documents = makeDocuments()
        let projection = try singleCandidateProjection(from: documents)
        let candidateSequence = "ATGGCTTAA"
        let unnameableSequence = "ACGTACGT"
        let rows = try projection.normalizedUnmatchedRows(
            candidateFASTARecords: [
                .init(name: "cluster-1", sequence: candidateSequence, readCount: 10),
            ],
            unnameableFASTARecords: [
                .init(name: "cluster-u", sequence: unnameableSequence, readCount: 4),
            ],
            candidateGenBankRecords: [
                try normalizedGenBankRecord(
                    stableID: "cluster-1",
                    sequence: candidateSequence,
                    translation: "MA",
                    status: "full-length"
                ),
            ],
            unnameableGenBankRecords: [
                try normalizedGenBankRecord(
                    stableID: "cluster-u",
                    sequence: unnameableSequence,
                    translation: nil,
                    status: "full-length"
                ),
            ]
        )

        XCTAssertEqual(rows.map(\.stableClusterID), ["cluster-1", "cluster-u"])
        XCTAssertEqual(Set(rows.map(\.stableClusterID)).count, rows.count)
        XCTAssertEqual(rows[0].recordCategory, .candidate)
        XCTAssertEqual(rows[0].nucleotideSequence, candidateSequence)
        XCTAssertEqual(rows[0].putativeAminoAcidTranslation, "MA")
        XCTAssertEqual(rows[0].translationStatus, .fullLength)
        XCTAssertEqual(rows[0].readsBySample, ["sample-a": 7, "sample-b": 3])
        XCTAssertEqual(rows[1].recordCategory, .unnameable)
        XCTAssertEqual(rows[1].nucleotideSequence, unnameableSequence)
        XCTAssertNil(rows[1].putativeAminoAcidTranslation)
        XCTAssertEqual(rows[1].translationStatus, .incompleteUnresolved)

        let encoded = try JSONEncoder().encode(rows)
        XCTAssertEqual(
            try JSONDecoder().decode([FullLengthONTMHCNormalizedUnmatchedRow].self, from: encoded),
            rows
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(object.first).keys), [
            "record_category", "stable_cluster_id", "provisional_allele_name", "locus",
            "classification_or_reason", "closest_reference_allele", "closest_reference_raw_id",
            "snp_count", "inserted_bases", "deleted_bases", "long_gap_bases", "comparable_bases",
            "failed_metrics", "support_class", "independent_sample_count", "occurrence_count",
            "total_cluster_reads", "supporting_sample_ids", "reads_by_sample", "fasta_record_id",
            "sequence_sha256", "nucleotide_sequence", "putative_amino_acid_translation",
            "translation_status",
        ])
    }

    func testUnmatchedAllelesWorksheetCombinesCategoriesWithSeparateSequenceTranslationAndStatusColumns() throws {
        let documents = makeDocuments()
        let projection = try singleCandidateProjection(from: documents)
        let rows = try normalizedRows(projection: projection)

        let cells = FullLengthONTMHCUnmatchedWorksheetBuilder.buildCells(
            rows: rows,
            sampleOrder: ["sample-a", "sample-b"]
        )
        let headers = cells[0].map(\.value)
        let stableIDColumn = try XCTUnwrap(headers.firstIndex(of: .text("Stable Cluster ID")))
        let nucleotideColumn = try XCTUnwrap(headers.firstIndex(of: .text("Nucleotide Sequence")))
        let translationColumn = try XCTUnwrap(headers.firstIndex(of: .text("Putative Amino Acid Translation")))
        let statusColumn = try XCTUnwrap(headers.firstIndex(of: .text("Translation Status")))

        XCTAssertEqual(cells.count, 3, "Header plus exactly one row per stable unmatched sequence")
        XCTAssertEqual(cells.dropFirst().map { $0[stableIDColumn].value }, [.text("cluster-1"), .text("cluster-u")])
        XCTAssertEqual(cells[1][nucleotideColumn].value, .text("ATGGCTTAA"))
        XCTAssertEqual(cells[1][translationColumn].value, .text("MA"))
        XCTAssertEqual(cells[1][statusColumn].value, .text("full-length"))
        XCTAssertEqual(cells[2][nucleotideColumn].value, .text("ACGTACGT"))
        XCTAssertEqual(cells[2][translationColumn].value, .blank)
        XCTAssertEqual(cells[2][statusColumn].value, .text("incomplete/unresolved"))
    }

    func testUnmatchedAllelesWorksheetSortsAllCategoriesByProvisionalNameAndStableID() throws {
        let rows = [
            normalizedUnmatchedRow(category: .candidate, stableID: "blank-10", provisionalName: "   "),
            normalizedUnmatchedRow(category: .unnameable, stableID: "i-10", provisionalName: "Mamu-I*001"),
            normalizedUnmatchedRow(category: .candidate, stableID: "g-1", provisionalName: "Mamu-G*001"),
            normalizedUnmatchedRow(category: .unnameable, stableID: "a1-1", provisionalName: "Mamu-A1*010"),
            normalizedUnmatchedRow(category: .candidate, stableID: "b02-1", provisionalName: "Mamu-B02ps*001"),
            normalizedUnmatchedRow(category: .unnameable, stableID: "b-1", provisionalName: "Mamu-B*010"),
            normalizedUnmatchedRow(category: .candidate, stableID: "i-2", provisionalName: "Mamu-I*001"),
            normalizedUnmatchedRow(category: .candidate, stableID: "a2-1", provisionalName: "Mamu-A2*002"),
            normalizedUnmatchedRow(category: .unnameable, stableID: "blank-2", provisionalName: nil),
        ]

        let cells = FullLengthONTMHCUnmatchedWorksheetBuilder.buildCells(
            rows: rows,
            sampleOrder: []
        )
        let headers = cells[0].map(\.value)
        let stableIDColumn = try XCTUnwrap(headers.firstIndex(of: .text("Stable Cluster ID")))
        let nameColumn = try XCTUnwrap(headers.firstIndex(of: .text("Provisional Allele Name")))

        XCTAssertEqual(cells.dropFirst().map { $0[stableIDColumn].value }, [
            .text("a1-1"),
            .text("a2-1"),
            .text("b-1"),
            .text("b02-1"),
            .text("i-2"),
            .text("i-10"),
            .text("g-1"),
            .text("blank-2"),
            .text("blank-10"),
        ])
        XCTAssertEqual(cells.dropFirst().map { $0[nameColumn].value }, [
            .text("Mamu-A1*010"),
            .text("Mamu-A2*002"),
            .text("Mamu-B*010"),
            .text("Mamu-B02ps*001"),
            .text("Mamu-I*001"),
            .text("Mamu-I*001"),
            .text("Mamu-G*001"),
            .blank,
            .text("   "),
        ])
    }

    func testUnnameableClosestReferenceSeparatesMappedAlleleLabelFromRawIdentityAndDoesNotInventFallback() throws {
        let documents = makeDocuments()
        let original = try XCTUnwrap(documents.unnameable.clusters.first)
        let selectedEvidence = try XCTUnwrap(original.evidence.first { $0.referenceName == "ref-a" })
        let summary = try ONTMHCReciprocalQueryHitSummary(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: original.stableClusterID,
            alignmentCount: 1,
            targetAlignmentCounts: ["ref-a": 1],
            exactMatchTargetNames: [],
            closestMatchTargetNames: ["ref-a"]
        )
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 2,
            createdAt: documents.unnameable.createdAt,
            thresholds: documents.unnameable.thresholds,
            sequenceFASTA: documents.unnameable.sequenceFASTA,
            clusters: [
                ONTMHCUnnameableRecord(
                    stableClusterID: original.stableClusterID,
                    reason: original.reason,
                    failedMetrics: original.failedMetrics,
                    supportClass: original.supportClass,
                    independentSampleCount: original.independentSampleCount,
                    occurrenceCount: original.occurrenceCount,
                    totalClusterReads: original.totalClusterReads,
                    supportingSampleIDs: original.supportingSampleIDs,
                    fastaRecordID: original.fastaRecordID,
                    sequenceSHA256: original.sequenceSHA256,
                    reciprocalHitSummary: summary,
                    selectedEvidence: selectedEvidence
                ),
            ],
            observations: documents.unnameable.observations
        )
        let projection = try singleCandidateProjection(from: (
            candidates: documents.candidates,
            unnameable: unnameableDocument
        ))
        let mapped = try normalizedRows(
            projection: projection,
            knownAlleleDisplayNames: ["ref-a": "Mafa-A1*001:01:01:01"]
        )
        let mappedUnnameable = try XCTUnwrap(mapped.first { $0.recordCategory == .unnameable })
        XCTAssertEqual(mappedUnnameable.closestReferenceRawID, "ref-a")
        XCTAssertEqual(mappedUnnameable.closestReferenceAllele, "Mafa-A1*001:01:01:01")

        let missingMetadata = try normalizedRows(projection: projection)
        let unresolvedUnnameable = try XCTUnwrap(missingMetadata.first { $0.recordCategory == .unnameable })
        XCTAssertEqual(unresolvedUnnameable.closestReferenceRawID, "ref-a")
        XCTAssertNil(
            unresolvedUnnameable.closestReferenceAllele,
            "Missing reference metadata must not copy a raw ID into the allele-label field"
        )

        let legacyProjection = try singleCandidateProjection(from: documents)
        let legacyUnnameable = try XCTUnwrap(
            normalizedRows(projection: legacyProjection).first { $0.recordCategory == .unnameable }
        )
        XCTAssertNil(
            legacyUnnameable.closestReferenceRawID,
            "Legacy evidence order is not a scientific closest-match ranking"
        )
    }

    func testReciprocalKnownRowsKeepDistinctRawCallIDsWhenDisplayAlleleLabelsCollide() throws {
        let genotypeRows = [
            FullLengthONTMHCClusterGenotypeRow(
                sample: "sample-a", cluster: "cluster-0", clusterReads: 7,
                allele: "AAA_RAW_1", alleleLength: 1_200,
                alignedBases: 1_200, score: 1_200
            ),
            FullLengthONTMHCClusterGenotypeRow(
                sample: "sample-a", cluster: "cluster-0", clusterReads: 7,
                allele: "AAA_RAW_1", alleleLength: 1_200,
                alignedBases: 1_200, score: 1_200, referenceSequenceID: "AAA_RAW_1"
            ),
            FullLengthONTMHCClusterGenotypeRow(
                sample: "sample-a", cluster: "cluster-0", clusterReads: 7,
                allele: "Mafa-A1*001:01:01:01", alleleLength: 1_200,
                alignedBases: 1_200, score: 1_200, referenceSequenceID: "AAA_RAW_1"
            ),
            FullLengthONTMHCClusterGenotypeRow(
                sample: "sample-a", cluster: "cluster-0", clusterReads: 7,
                allele: "Mafa-A1*001:01:01:01", alleleLength: 1_200,
                alignedBases: 1_200, score: 1_200, referenceSequenceID: "AAA_RAW_2"
            ),
        ]
        let reportRows = FullLengthONTMHCClusterReportBuilder.reportRows(
            genotypeRows: genotypeRows,
            sampleReadCounts: ["sample-a": 20]
        )
        XCTAssertEqual(reportRows.map(\.genotype), ["AAA_RAW_1", "AAA_RAW_2"])
        XCTAssertEqual(reportRows.map(\.passedUniqueReads), [7, 7])

        let projection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: makeDocuments().candidates,
            unnameableDocument: makeDocuments().unnameable,
            sampleOrder: ["sample-a"]
        )
        let unifiedRows = FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildRows(
            reportRows: reportRows,
            projection: projection,
            sampleOrder: ["sample-a"],
            knownAlleleDisplayNames: [
                "AAA_RAW_1": "Mafa-A1*001:01:01:01",
                "AAA_RAW_2": "Mafa-A1*001:01:01:01",
            ]
        ).filter { $0.first == "known-allele" }
        XCTAssertEqual(unifiedRows.map { $0[1] }, ["AAA_RAW_1", "AAA_RAW_2"])
        XCTAssertEqual(unifiedRows.map { $0[2] }, [
            "Mafa-A1*001:01:01:01",
            "Mafa-A1*001:01:01:01",
        ])
    }

    func testUnifiedWorkbookCellsPrependAnalystHeaderAndMapKnownDisplayNamesWithoutConflation() throws {
        let documents = makeDocuments()
        let projection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: documents.candidates,
            unnameableDocument: documents.unnameable,
            sampleOrder: ["sample-a"]
        )
        let knownRows = [
            reportRow(sample: "sample-a", genotype: "NHP00001", reads: 9),
            reportRow(sample: "sample-a", genotype: "NHP00002", reads: 5),
            reportRow(sample: "sample-a", genotype: "NHP00003", reads: 3),
        ]
        let samples = [
            FullLengthONTMHCPivotSample(
                sample: "sample-a",
                mappedReadCount: 17,
                totalReadCount: 20,
                retainedPercent: 85
            ),
        ]

        let cells = FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildWorkbookCells(
            reportRows: knownRows,
            projection: projection,
            samples: samples,
            haplotypeAnalysis: nil,
            knownAlleleDisplayNames: [
                "NHP00001": "Mafa-A1*001:01:01:01",
                "NHP00002": "Mafa-A1*001:01:01:01",
            ]
        )
        let textRows = cells.map { row in
            row.map { cell -> String in
                if case .text(let value) = cell.value { return value }
                return ""
            }
        }
        XCTAssertEqual(textRows[0].first, "Client ID")
        let mappedReadRow = try XCTUnwrap(textRows.firstIndex { $0.first == "Mapped Read Count" })
        XCTAssertEqual(cells[mappedReadRow].last?.value, .integer(17))
        XCTAssertTrue(textRows.contains { $0.first == "MHC-A Haplotype 1" })
        XCTAssertTrue(textRows.contains { $0.first == "Comments" })

        let tableHeaderIndex = try XCTUnwrap(textRows.firstIndex { $0.first == "call_type" })
        XCTAssertTrue(cells[tableHeaderIndex - 1].allSatisfy { $0.value == .blank }, "A separator row must precede the unified table")
        XCTAssertEqual(
            textRows[0].firstIndex(of: "sample-a"),
            textRows[tableHeaderIndex].firstIndex(of: "sample-a"),
            "Analyst-header and unified-table sample columns must align"
        )
        let tableRows = textRows.dropFirst(tableHeaderIndex + 1)
        let known = tableRows.filter { $0.first == "known-allele" }
        XCTAssertEqual(known.map { $0[1] }, ["NHP00001", "NHP00002", "NHP00003"])
        XCTAssertEqual(known.map { $0[2] }, [
            "Mafa-A1*001:01:01:01",
            "Mafa-A1*001:01:01:01",
            "NHP00003",
        ])
        XCTAssertEqual(known.count, 3, "Distinct raw references must not be merged when display labels collide")
    }

    func testUnifiedWorkbookAnalystSummaryUsesTypedNumbersWithoutParsingIdentifiers() throws {
        let documents = makeDocuments()
        let projection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: documents.candidates,
            unnameableDocument: documents.unnameable,
            sampleOrder: ["00123"]
        )
        let samples = [
            FullLengthONTMHCPivotSample(
                sample: "00123",
                mappedReadCount: 17,
                totalReadCount: 20,
                retainedPercent: 85
            ),
        ]

        let cells = FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildWorkbookCells(
            reportRows: [],
            projection: projection,
            samples: samples,
            haplotypeAnalysis: nil,
            knownAlleleDisplayNames: [:]
        )

        XCTAssertEqual(cells[0][12].value, .text("00123"), "Numeric-looking sample identifiers must remain text")
        XCTAssertEqual(cells[2][1].value, .integer(17))
        XCTAssertEqual(cells[2][2].value, .decimal(17))
        XCTAssertEqual(cells[2][12].value, .integer(17))
        XCTAssertEqual(cells[3][12].value, .integer(20))
        XCTAssertEqual(cells[4][12].value, .decimal(15))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typed-unified-summary-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try FullLengthONTMHCXLSXPackageWriter.write(
            sheets: [.init(name: "Unified Genotype Pivot", cells: cells)],
            to: url
        )

        let sheet = try unzip("xl/worksheets/sheet1.xml", from: url)
        XCTAssertTrue(sheet.contains("<c r=\"M1\" s=\"1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">00123</t></is></c>"), sheet)
        XCTAssertTrue(sheet.contains("<c r=\"B3\"><v>17</v></c>"), sheet)
        XCTAssertTrue(sheet.contains("<c r=\"C3\"><v>17</v></c>"), sheet)
        XCTAssertTrue(sheet.contains("<c r=\"M3\"><v>17</v></c>"), sheet)
        XCTAssertTrue(sheet.contains("<c r=\"M4\"><v>20</v></c>"), sheet)
        XCTAssertTrue(sheet.contains("<c r=\"M5\"><v>15</v></c>"), sheet)
        XCTAssertFalse(sheet.contains("<c r=\"M3\" t=\"inlineStr\">"), sheet)
        XCTAssertFalse(sheet.contains("<c r=\"M4\" t=\"inlineStr\">"), sheet)
        XCTAssertFalse(sheet.contains("<c r=\"M5\" t=\"inlineStr\">"), sheet)
    }

    func testNormalizedUnmatchedRowsRejectDocumentSequenceChecksumMismatch() throws {
        let documents = makeDocuments(candidateSequenceSHA256Overrides: [
            "cluster-1": String(repeating: "0", count: 64),
        ])
        let projection = try singleCandidateProjection(from: documents)

        XCTAssertThrowsError(try normalizedRows(projection: projection)) { error in
            guard case FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                stableClusterID: "cluster-1",
                detail: let detail
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("document sequence SHA-256"), detail)
        }
    }

    func testNormalizedUnmatchedRowsHashLowercaseFASTAAsNormalizedUppercaseSequence() throws {
        let projection = try singleCandidateProjection(from: makeDocuments())
        let candidateSequence = "ATGGCTTAA"
        let unnameableSequence = "ACGTACGT"

        let rows: [FullLengthONTMHCNormalizedUnmatchedRow]
        do {
            rows = try projection.normalizedUnmatchedRows(
                candidateFASTARecords: [
                    .init(name: "cluster-1", sequence: candidateSequence.lowercased(), readCount: 10),
                ],
                unnameableFASTARecords: [
                    .init(name: "cluster-u", sequence: unnameableSequence.lowercased(), readCount: 4),
                ],
                candidateGenBankRecords: [
                    try normalizedGenBankRecord(
                        stableID: "cluster-1",
                        sequence: candidateSequence,
                        translation: "MA",
                        status: "full-length"
                    ),
                ],
                unnameableGenBankRecords: [
                    try normalizedGenBankRecord(
                        stableID: "cluster-u",
                        sequence: unnameableSequence,
                        translation: nil,
                        status: "incomplete/unresolved"
                    ),
                ]
            )
        } catch {
            return XCTFail("Lowercase FASTA should share normalized scientific identity: \(error)")
        }

        XCTAssertEqual(rows.map(\.stableClusterID), ["cluster-1", "cluster-u"])
        XCTAssertEqual(rows.map(\.nucleotideSequence), [
            candidateSequence.lowercased(),
            unnameableSequence.lowercased(),
        ])
    }

    func testNormalizedUnmatchedRowsRejectGenBankChecksumAccessionAndLocusIdentityMismatches() throws {
        let projection = try singleCandidateProjection(from: makeDocuments())
        let sequence = "ATGGCTTAA"
        let mismatches: [(String, GenBankRecord)] = [
            (
                "source sequence SHA-256",
                try normalizedGenBankRecord(
                    stableID: "cluster-1",
                    sequence: sequence,
                    translation: "MA",
                    status: "full-length",
                    sourceSequenceSHA256: String(repeating: "f", count: 64)
                )
            ),
            (
                "accession",
                try normalizedGenBankRecord(
                    stableID: "cluster-1", sequence: sequence, translation: "MA",
                    status: "full-length", accession: "different-id"
                )
            ),
            (
                "locus",
                try normalizedGenBankRecord(
                    stableID: "cluster-1", sequence: sequence, translation: "MA",
                    status: "full-length", locusName: "different-id"
                )
            ),
        ]

        for (expectedDetail, genBankRecord) in mismatches {
            XCTAssertThrowsError(try normalizedRows(
                projection: projection,
                candidateGenBankRecord: genBankRecord
            )) { error in
                guard case FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: "cluster-1",
                    detail: let detail
                ) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(detail.contains(expectedDetail), detail)
            }
        }
    }

    func testProjectionRetainsEveryCandidateAndUnnameableWithStableIdentityAndSampleReads() throws {
        let documents = makeDocuments()

        let projection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: documents.candidates,
            unnameableDocument: documents.unnameable,
            sampleOrder: ["sample-b", "sample-a"]
        )

        XCTAssertEqual(projection.sampleOrder, ["sample-b", "sample-a"])
        XCTAssertEqual(projection.candidateRows.map(\.stableClusterID), ["cluster-1", "cluster-2", "cluster-3", "cluster-4"])
        XCTAssertEqual(projection.candidateRows.map(\.provisionalName), [
            "Mafa-A1*018:01:01:01_5nt_nov",
            "Mafa-A1*018:01:01:01_5nt_nov",
            "Mafa-B*001:01_ext",
            "Mafa-B*002:01_ext",
        ])
        XCTAssertEqual(projection.candidateRows[0].readsBySample, ["sample-a": 7, "sample-b": 3])
        XCTAssertEqual(projection.candidateRows[0].tintCategory, .sharedNovel)
        XCTAssertEqual(projection.candidateRows[1].tintCategory, .singletonNovel)
        XCTAssertEqual(projection.candidateRows[2].tintCategory, .sharedExtension)
        XCTAssertEqual(projection.candidateRows[3].tintCategory, .singletonExtension)
        XCTAssertEqual(projection.unnameableRows.map(\.stableClusterID), ["cluster-u"])
        XCTAssertEqual(projection.unnameableRows.first?.reason, "unresolved-locus")
        XCTAssertEqual(projection.unnameableRows.first?.readsBySample, ["sample-a": 4])
        XCTAssertEqual(projection.unnameableRows.first?.evidence.map(\.queryName), ["cluster-u-a", "cluster-u-z"])
        XCTAssertEqual(projection.unnameableWorksheetRows.count, 3, "Header plus one row for each evidence locator")
        let queryColumn = try XCTUnwrap(
            projection.unnameableWorksheetRows[0].firstIndex { $0.value == .text("Evidence Query Name") }
        )
        XCTAssertEqual(projection.unnameableWorksheetRows[1][queryColumn].value, .text("cluster-u-a"))
        XCTAssertEqual(projection.unnameableWorksheetRows[2][queryColumn].value, .text("cluster-u-z"))
    }

    func testSchemaVersionTwoUsesOneCompactRowPerStableSequenceWithReciprocalSummary() throws {
        let documents = try makeVersionTwoDocuments()

        let projection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: documents.candidates,
            unnameableDocument: documents.unnameable,
            sampleOrder: ["sample-a", "sample-b"]
        )

        XCTAssertEqual(projection.candidateRows.count, 4, "Workbook projection must never filter candidates")
        XCTAssertEqual(projection.unnameableWorksheetRows.count, 2, "Header plus one compact stable-sequence row")

        let candidateHeaders = projection.candidateWorksheetRows[0].map(\.value)
        let candidateAlignmentColumn = try XCTUnwrap(candidateHeaders.firstIndex(of: .text("Reciprocal Alignment Count")))
        let candidateClosestColumn = try XCTUnwrap(candidateHeaders.firstIndex(of: .text("Closest Match Target Names")))
        XCTAssertEqual(projection.candidateWorksheetRows.count, 5)
        XCTAssertEqual(projection.candidateWorksheetRows[1][candidateAlignmentColumn].value, .integer(1))
        XCTAssertEqual(projection.candidateWorksheetRows[1][candidateClosestColumn].value, .text("ref-1"))

        let headers = projection.unnameableWorksheetRows[0].map(\.value)
        func value(_ header: String) throws -> FullLengthONTMHCWorkbookCellValue {
            let column = try XCTUnwrap(headers.firstIndex(of: .text(header)))
            return projection.unnameableWorksheetRows[1][column].value
        }

        XCTAssertEqual(try value("Reciprocal Alignment Count"), .integer(3))
        XCTAssertEqual(try value("Reciprocal Target Count"), .integer(2))
        XCTAssertEqual(try value("Reciprocal Target Alignment Counts"), .text("ref-a=2;ref-b=1"))
        XCTAssertEqual(try value("Exact Match Target Names"), .text("ref-a"))
        XCTAssertEqual(try value("Closest Match Target Names"), .text("ref-a;ref-b"))
        XCTAssertEqual(try value("Selected Evidence Query Name"), .text("cluster-u"))
        XCTAssertFalse(headers.contains(.text("Evidence Ordinal")))
    }

    func testWorkbookWritesFourTintStylesOnlyOnCandidateNameCellsAndUsesTypedNumbers() throws {
        let documents = makeDocuments()
        let projection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: documents.candidates,
            unnameableDocument: documents.unnameable,
            sampleOrder: ["sample-a", "sample-b"]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("candidate-workbook-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }

        try FullLengthONTMHCXLSXPackageWriter.write(
            sheets: [
                .init(name: "Candidate Alleles", cells: projection.candidateWorksheetRows),
                .init(name: "Un-nameable Clusters", cells: projection.unnameableWorksheetRows),
                .init(
                    name: "Unified Genotype Pivot",
                    cells: FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildCells(
                        reportRows: [],
                        projection: projection,
                        sampleOrder: projection.sampleOrder
                    )
                ),
            ],
            to: url
        )
        let styles = try unzip("xl/styles.xml", from: url)
        for rgb in ["FFF5D78E", "FFF5B97A", "FFA8D8D0", "FFAFCBF2"] {
            XCTAssertTrue(styles.contains("rgb=\"\(rgb)\""), "Missing fill \(rgb)")
        }
        let sheet = try unzip("xl/worksheets/sheet1.xml", from: url)
        XCTAssertTrue(sheet.contains("<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"))
        XCTAssertTrue(sheet.contains("<autoFilter ref="))
        XCTAssertTrue(sheet.contains("<cols>"))
        XCTAssertTrue(sheet.contains("<c r=\"B2\" s=\"2\" t=\"inlineStr\">"))
        XCTAssertTrue(sheet.contains("<c r=\"B3\" s=\"3\" t=\"inlineStr\">"))
        XCTAssertTrue(sheet.contains("<c r=\"B4\" s=\"4\" t=\"inlineStr\">"))
        XCTAssertTrue(sheet.contains("<c r=\"B5\" s=\"5\" t=\"inlineStr\">"))
        for styleID in 2...5 {
            XCTAssertEqual(sheet.components(separatedBy: " s=\"\(styleID)\"").count - 1, 1)
        }
        XCTAssertEqual(sheet.components(separatedBy: "Mafa-A1*018:01:01:01_5nt_nov").count - 1, 2)
        for clusterID in ["cluster-1", "cluster-2", "cluster-3", "cluster-4"] {
            XCTAssertTrue(sheet.contains(clusterID))
        }
        XCTAssertTrue(sheet.contains("<c r=\"G2\"><v>2</v></c>"), "Counts must be numeric OOXML cells")
        XCTAssertFalse(sheet.contains("_extension"))
        XCTAssertFalse(sheet.contains(" SNP"))
        XCTAssertFalse(sheet.contains("_0nt_nov"))
        let unnameableSheet = try unzip("xl/worksheets/sheet2.xml", from: url)
        XCTAssertTrue(unnameableSheet.contains("cluster-u"))
        XCTAssertTrue(unnameableSheet.contains("unresolved-locus"))
        XCTAssertTrue(unnameableSheet.contains("cluster-u-a"))
        XCTAssertTrue(unnameableSheet.contains("cluster-u-z"))
        XCTAssertFalse(unnameableSheet.contains(" s=\"2\""))
        XCTAssertFalse(unnameableSheet.contains(" s=\"3\""))
        XCTAssertFalse(unnameableSheet.contains(" s=\"4\""))
        XCTAssertFalse(unnameableSheet.contains(" s=\"5\""))
        let unifiedSheet = try unzip("xl/worksheets/sheet3.xml", from: url)
        XCTAssertTrue(unifiedSheet.contains("<c r=\"J2\"><v>2</v></c>"))
        XCTAssertTrue(unifiedSheet.contains("<c r=\"K2\"><v>2</v></c>"))
        XCTAssertTrue(unifiedSheet.contains("<c r=\"L2\"><v>10</v></c>"))
        XCTAssertFalse(unifiedSheet.contains("<c r=\"J2\" t=\"inlineStr\">"))
        XCTAssertTrue(unifiedSheet.contains("<c r=\"C2\" s=\"2\" t=\"inlineStr\">"))
    }

    func testUnifiedPivotPreservesKnownCallsAndSeparateCandidateRowsWhenLabelsCollide() throws {
        let documents = makeDocuments()
        let projection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: documents.candidates,
            unnameableDocument: documents.unnameable,
            sampleOrder: ["sample-a", "sample-b"]
        )
        let known = FullLengthONTMHCReportRow(
            sample: "sample-a",
            genotype: "Mafa-A1*001:01",
            passedAlignments: 9,
            passedUniqueReads: 9,
            sampleTotalReads: 20,
            sampleUniqueRetainedReads: 9,
            sampleUniqueRetainedPercent: 45,
            overallInputReads: 20,
            overallUniqueRetainedReads: 9,
            overallUniqueRetainedPercent: 45
        )

        let rows = FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildRows(
            reportRows: [known],
            projection: projection,
            sampleOrder: ["sample-a", "sample-b"]
        )

        XCTAssertEqual(rows.filter { $0.contains("Mafa-A1*018:01:01:01_5nt_nov") }.count, 2)
        XCTAssertTrue(rows.contains { $0.contains("cluster-1") })
        XCTAssertTrue(rows.contains { $0.contains("cluster-2") })
        XCTAssertTrue(rows.contains { $0.contains("Mafa-A1*001:01") })
        XCTAssertFalse(rows.joined().contains("Novel:"))
        XCTAssertFalse(rows.joined().contains("_extension"))

        let cells = FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildCells(
            reportRows: [known],
            projection: projection,
            sampleOrder: ["sample-a", "sample-b"]
        )
        XCTAssertNil(cells[1][2].tint)
        XCTAssertEqual(cells[2][2].tint, FullLengthONTMHCWorkbookTintCategory.sharedNovel)
        XCTAssertEqual(cells[3][2].tint, FullLengthONTMHCWorkbookTintCategory.singletonNovel)
        for row in cells.dropFirst() {
            for (column, cell) in row.enumerated() where column != 2 {
                XCTAssertNil(cell.tint)
            }
        }
    }

    func testUnifiedPivotInterleavesKnownAndCandidateCallsInBiologicalDisplayOrder() throws {
        let projection = try orderingProjection(candidateSpecs: [
            (stableID: "tie-10", name: "Mamu-B*010", locus: "Mamu-B"),
            (stableID: "g-1", name: "Mamu-G*001", locus: "Mamu-G"),
            (stableID: "a2-1", name: "Mamu-A2*002", locus: "Mamu-A2"),
            (stableID: "b02-1", name: "Mamu-B02ps*001", locus: "Mamu-B02ps"),
            (stableID: "tie-2", name: "Mamu-B*010", locus: "Mamu-B"),
        ])
        let reportRows = [
            reportRow(sample: "sample-a", genotype: "raw-i", reads: 1),
            reportRow(sample: "sample-a", genotype: "tie-1", reads: 2),
            reportRow(sample: "sample-a", genotype: "raw-a1", reads: 3),
        ]

        let rows = FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildRows(
            reportRows: reportRows,
            projection: projection,
            sampleOrder: ["sample-a"],
            knownAlleleDisplayNames: [
                "raw-i": "Mamu-I*001",
                "tie-1": "Mamu-B*010",
                "raw-a1": "Mamu-A1*010",
            ]
        )

        XCTAssertEqual(rows[0][0], "call_type", "The header must remain fixed")
        XCTAssertEqual(rows.dropFirst().map { "\($0[2])|\($0[3].isEmpty ? $0[1] : $0[3])" }, [
            "Mamu-A1*010|raw-a1",
            "Mamu-A2*002|a2-1",
            "Mamu-B*010|tie-1",
            "Mamu-B*010|tie-2",
            "Mamu-B*010|tie-10",
            "Mamu-B02ps*001|b02-1",
            "Mamu-I*001|raw-i",
            "Mamu-G*001|g-1",
        ])
        XCTAssertEqual(rows.filter { $0[2] == "Mamu-B*010" }.count, 3)
    }

    func testLegacyUnmatchedSheetsRetainRowsButUseCandidateNamesAndMetrics() throws {
        let documents = makeDocuments()
        let projection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: documents.candidates,
            unnameableDocument: documents.unnameable,
            sampleOrder: ["sample-a", "sample-b"]
        )

        let legacy = [
            ["unmatched_sequence_id", "closest_match_id", "closest_reference", "match_class", "nucleotides_different", "snp_differences", "indel_bases", "aligned_bases", "score", "sequence"],
            ["cluster-1", "Mafa-A1*018:01:01:01_5SNP", "legacy-ref", "snp-different", "9", "9", "9", "9", "9", "ACGT"],
            ["cluster-3", "Mafa-B*001:01_extension", "legacy-cdna", "extension", "0", "0", "200", "800", "-1200", "CCCC"],
            ["cluster-u", "Unresolved_2SNP", "legacy-unresolved", "snp-different", "2", "2", "0", "700", "500", "TGCA"],
        ]
        let rows = projection.enrichingLegacyUnmatchedRows(legacy)

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0][1], "provisional_name")
        XCTAssertEqual(rows[1][1], "Mafa-A1*018:01:01:01_5nt_nov")
        XCTAssertEqual(rows[1][3], "novel")
        XCTAssertEqual(rows[1][5], "5")
        XCTAssertEqual(rows[3][3], "un-nameable")
        XCTAssertEqual(rows[3][10], "unresolved-locus")
        XCTAssertEqual(rows[1].last, "ACGT")
        XCTAssertEqual(rows[3].last, "TGCA")
        let allValues = rows.flatMap { $0 }.joined(separator: "\t")
        XCTAssertFalse(allValues.contains("_extension"), allValues)
        XCTAssertNil(allValues.range(of: #"_[0-9]+SNP"#, options: .regularExpression), allValues)
        let closestMatchIndex = try XCTUnwrap(rows[0].firstIndex(of: "closest_match_id"))
        let matchClassIndex = try XCTUnwrap(rows[0].firstIndex(of: "match_class"))
        let snpIndex = try XCTUnwrap(rows[0].firstIndex(of: "snp_differences"))
        XCTAssertEqual(rows[1][closestMatchIndex], "Mafa-A1*018:01:01:01_5nt_nov")
        XCTAssertEqual(rows[1][matchClassIndex], "novel")
        XCTAssertEqual(rows[1][snpIndex], "5")
        XCTAssertEqual(rows[2][closestMatchIndex], "Mafa-B*001:01_ext")
        XCTAssertEqual(rows[2][matchClassIndex], "extension")
        XCTAssertEqual(rows[3][closestMatchIndex], "")
        XCTAssertEqual(rows[3][matchClassIndex], "un-nameable")
    }

    func testLegacyNormalizationPreservesRawIdentifiersAcrossAllRetainedSheetShapes() throws {
        let documents = makeDocuments()
        let projection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: documents.candidates,
            unnameableDocument: documents.unnameable,
            sampleOrder: ["donor_extension"]
        )
        let sheets = [
            [
                ["unmatched_sequence_id", "sample", "cluster", "closest_match_id", "closest_reference", "match_class"],
                ["cluster-1", "donor_extension", "cluster_5SNP", "Old_5SNP", "Reference_extension", "snp-different"],
            ],
            [
                ["unmatched_sequence_id", "closest_match_id", "match_class", "donor_extension"],
                ["cluster_5SNP", "Old_5SNP", "snp-different", "7"],
            ],
            [
                ["unmatched_sequence_id", "sample", "cluster", "closest_match_id", "closest_reference", "match_class"],
                ["cluster-u", "donor_extension", "cluster_5SNP", "Old_5SNP", "Reference_extension", "snp-different"],
            ],
            [
                ["unmatched_sequence_id", "closest_match_id", "closest_reference_name", "match_class", "donor_extension"],
                ["cluster_5SNP", "Old_5SNP", "Reference_extension", "snp-different", "7"],
            ],
        ]

        for (index, input) in sheets.enumerated() {
            let output = projection.enrichingLegacyUnmatchedRows(input)
            let flattened = output.flatMap { $0 }
            XCTAssertTrue(flattened.contains("donor_extension"), "Sheet shape \(index) changed a sample identifier")
            XCTAssertTrue(flattened.contains("cluster_5SNP"), "Sheet shape \(index) changed a cluster/stable identifier")
            let closestIndex = try XCTUnwrap(output[0].firstIndex(of: "closest_match_id"))
            XCTAssertFalse(output[1][closestIndex].contains("_5SNP"), "Allele-derived label was not normalized")
            if let referenceIndex = output[0].firstIndex(where: {
                $0 == "closest_reference" || $0 == "closest_reference_name"
            }) {
                XCTAssertFalse(output[1][referenceIndex].contains("_extension"))
            }
        }
    }

    func testOOXMLTextEncoderHandlesControlsLiteralEscapeTokensEntitiesAndUnicode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ooxml-text-encoding-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = "control:\u{000B} literal:_x000B_ entities:&< unicode:β🧬"

        try FullLengthONTMHCXLSXPackageWriter.write(
            sheets: [.init(name: "Name &_x000B_ β🧬", rows: [["Value"], [payload]])],
            to: url
        )

        let workbook = try unzip("xl/workbook.xml", from: url)
        let sheet = try unzip("xl/worksheets/sheet1.xml", from: url)
        XCTAssertTrue(workbook.contains("Name &amp;_x005F_x000B_ β🧬"), workbook)
        XCTAssertTrue(sheet.contains("control:_x000B_"), sheet)
        XCTAssertTrue(sheet.contains("literal:_x005F_x000B_"), sheet)
        XCTAssertTrue(sheet.contains("entities:&amp;&lt;"), sheet)
        XCTAssertTrue(sheet.contains("unicode:β🧬"), sheet)
        XCTAssertFalse(sheet.contains("\u{000B}"))
        try assertXMLWellFormed(workbook)
        try assertXMLWellFormed(sheet)
    }

    private func makeDocuments(
        candidateSequenceSHA256Overrides: [String: String] = [:]
    ) -> (
        candidates: ONTMHCCandidateAllelesDocument,
        unnameable: ONTMHCUnnameableClustersDocument
    ) {
        let fasta = ONTMHCArtifactReference(path: "candidate_alleles.fasta", sha256: String(repeating: "a", count: 64), sizeBytes: 400)
        let evidence = ONTMHCEvidenceLocator(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "cluster-1",
            referenceName: "ref-1",
            readGroupID: nil,
            referenceStart: 17,
            cigar: "1000M"
        )
        let specs: [(String, String, ONTMHCCandidateClassification, ONTMHCCandidateSupportClass, Int)] = [
            ("cluster-1", "Mafa-A1*018:01:01:01_5nt_nov", .novel, .shared, 5),
            ("cluster-2", "Mafa-A1*018:01:01:01_5nt_nov", .novel, .singleton, 5),
            ("cluster-3", "Mafa-B*001:01_ext", .extension, .shared, 0),
            ("cluster-4", "Mafa-B*002:01_ext", .extension, .singleton, 0),
        ]
        let candidates = specs.map { id, name, classification, support, snps in
            ONTMHCCandidateRecord(
                stableClusterID: id,
                provisionalName: name,
                locus: name.hasPrefix("Mafa-A") ? "Mafa-A1" : "Mafa-B",
                classification: classification,
                supportClass: support,
                closestReferenceName: classification == .novel ? "Mafa-A1*018:01:01:01" : String(name.dropLast(4)),
                closestReferenceClass: classification == .novel ? .genomicDNA : .cDNA,
                snpCount: snps,
                insertedBases: 0,
                deletedBases: classification == .extension ? 200 : 0,
                longGapBases: classification == .extension ? 200 : 0,
                comparableBases: 1_000,
                shorterCoverage: 1,
                identity: 1,
                mappingQuality: 60,
                alignmentScore: 1_000,
                independentSampleCount: support == .shared ? 2 : 1,
                occurrenceCount: support == .shared ? 2 : 1,
                totalClusterReads: id == "cluster-1" ? 10 : (support == .shared ? 6 : 4),
                supportingSampleIDs: support == .shared ? ["sample-a", "sample-b"] : ["sample-a"],
                fastaRecordID: id,
                sequenceSHA256: candidateSequenceSHA256Overrides[id] ?? sha256Hex(
                    [
                        "cluster-1": "ATGGCTTAA",
                        "cluster-2": "CCCC",
                        "cluster-3": "GGGG",
                        "cluster-4": "TTTT",
                    ][id]!
                ),
                selectedEvidence: ONTMHCEvidenceLocator(
                    bamPath: evidence.bamPath,
                    queryName: id,
                    referenceName: evidence.referenceName,
                    readGroupID: evidence.readGroupID,
                    referenceStart: evidence.referenceStart,
                    cigar: evidence.cigar
                )
            )
        }
        var observations: [ONTMHCCandidateObservation] = []
        for candidate in candidates {
            observations.append(observation(candidate.stableClusterID, "sample-a", candidate.stableClusterID == "cluster-1" ? 7 : 4))
            if candidate.supportClass == .shared {
                observations.append(observation(candidate.stableClusterID, "sample-b", candidate.stableClusterID == "cluster-1" ? 3 : 2))
            }
        }
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: 1,
            createdAt: "2026-07-19T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [],
            sequenceFASTA: fasta,
            candidates: candidates.reversed(),
            observations: observations.reversed()
        )
        let unnameableRecord = ONTMHCUnnameableRecord(
            stableClusterID: "cluster-u",
            reason: .unresolvedLocus,
            failedMetrics: ["identity": 0.7],
            supportClass: .singleton,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 4,
            supportingSampleIDs: ["sample-a"],
            fastaRecordID: "cluster-u",
            sequenceSHA256: sha256Hex("ACGTACGT"),
            evidence: [
                ONTMHCEvidenceLocator(
                    bamPath: "artifacts/alignments/z.bam",
                    queryName: "cluster-u-z",
                    referenceName: "ref-z",
                    readGroupID: "sample-z",
                    referenceStart: 90,
                    cigar: "900M"
                ),
                ONTMHCEvidenceLocator(
                    bamPath: "artifacts/alignments/a.bam",
                    queryName: "cluster-u-a",
                    referenceName: "ref-a",
                    readGroupID: "sample-a",
                    referenceStart: 10,
                    cigar: "800M"
                ),
            ]
        )
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 1,
            createdAt: "2026-07-19T00:00:00Z",
            thresholds: .defaults,
            sequenceFASTA: ONTMHCArtifactReference(path: "unnameable_unmatched_clusters.fasta", sha256: String(repeating: "b", count: 64), sizeBytes: 100),
            clusters: [unnameableRecord],
            observations: [observation("cluster-u", "sample-a", 4)]
        )
        return (candidateDocument, unnameableDocument)
    }

    private func makeVersionTwoDocuments() throws -> (
        candidates: ONTMHCCandidateAllelesDocument,
        unnameable: ONTMHCUnnameableClustersDocument
    ) {
        let legacy = makeDocuments()
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: 2,
            createdAt: legacy.candidates.createdAt,
            thresholds: legacy.candidates.thresholds,
            inputs: legacy.candidates.inputs,
            evidence: legacy.candidates.evidence,
            sequenceFASTA: legacy.candidates.sequenceFASTA,
            candidates: legacy.candidates.candidates,
            observations: legacy.candidates.observations
        )
        let summary = try ONTMHCReciprocalQueryHitSummary(
            bamPath: "artifacts/alignments/reciprocal.bam",
            queryName: "cluster-u",
            alignmentCount: 3,
            targetAlignmentCounts: ["ref-b": 1, "ref-a": 2],
            exactMatchTargetNames: ["ref-a"],
            closestMatchTargetNames: ["ref-b", "ref-a"]
        )
        let selected = ONTMHCEvidenceLocator(
            bamPath: summary.bamPath,
            queryName: "cluster-u",
            referenceName: "ref-a",
            readGroupID: "sample-a",
            referenceStart: 10,
            cigar: "800M"
        )
        let record = ONTMHCUnnameableRecord(
            stableClusterID: "cluster-u",
            reason: .unresolvedLocus,
            failedMetrics: ["identity": 0.7],
            supportClass: .singleton,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 4,
            supportingSampleIDs: ["sample-a"],
            fastaRecordID: "cluster-u",
            sequenceSHA256: String(repeating: "f", count: 64),
            reciprocalHitSummary: summary,
            selectedEvidence: selected
        )
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 2,
            createdAt: legacy.unnameable.createdAt,
            thresholds: legacy.unnameable.thresholds,
            sequenceFASTA: legacy.unnameable.sequenceFASTA,
            clusters: [record],
            observations: legacy.unnameable.observations
        )
        return (candidateDocument, unnameableDocument)
    }

    private func observation(_ cluster: String, _ sample: String, _ reads: Int) -> ONTMHCCandidateObservation {
        ONTMHCCandidateObservation(
            stableClusterID: cluster,
            sampleID: sample,
            readGroupID: sample,
            sourceClusterIDs: ["source-\(cluster)-\(sample)"],
            sourceClusterReadCounts: ["source-\(cluster)-\(sample)": reads],
            aggregatedSampleReadCount: reads,
            evidence: []
        )
    }

    private func reportRow(sample: String, genotype: String, reads: Int) -> FullLengthONTMHCReportRow {
        FullLengthONTMHCReportRow(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: 20,
            sampleUniqueRetainedReads: reads,
            sampleUniqueRetainedPercent: Double(reads) / 20 * 100,
            overallInputReads: 20,
            overallUniqueRetainedReads: reads,
            overallUniqueRetainedPercent: Double(reads) / 20 * 100
        )
    }

    private func orderingProjection(
        candidateSpecs: [(stableID: String, name: String, locus: String)]
    ) throws -> FullLengthONTMHCWorkbookProjection {
        let candidates = candidateSpecs.map { spec in
            ONTMHCCandidateRecord(
                stableClusterID: spec.stableID,
                provisionalName: spec.name,
                locus: spec.locus,
                classification: .novel,
                supportClass: .singleton,
                closestReferenceName: spec.name,
                closestReferenceClass: .genomicDNA,
                snpCount: 1,
                insertedBases: 0,
                deletedBases: 0,
                longGapBases: 0,
                comparableBases: 1_000,
                shorterCoverage: 1,
                identity: 0.999,
                mappingQuality: 60,
                alignmentScore: 999,
                independentSampleCount: 1,
                occurrenceCount: 1,
                totalClusterReads: 1,
                supportingSampleIDs: ["sample-a"],
                fastaRecordID: spec.stableID,
                sequenceSHA256: String(repeating: "c", count: 64),
                selectedEvidence: ONTMHCEvidenceLocator(
                    bamPath: "artifacts/alignments/ordering.bam",
                    queryName: spec.stableID,
                    referenceName: spec.name,
                    readGroupID: "sample-a",
                    referenceStart: 0,
                    cigar: "1000M"
                )
            )
        }
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: 1,
            createdAt: "2026-07-22T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [],
            sequenceFASTA: ONTMHCArtifactReference(
                path: "candidate_alleles.fasta",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 1
            ),
            candidates: candidates,
            observations: candidateSpecs.map { observation($0.stableID, "sample-a", 1) }
        )
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 1,
            createdAt: "2026-07-22T00:00:00Z",
            thresholds: .defaults,
            sequenceFASTA: ONTMHCArtifactReference(
                path: "unnameable_unmatched_clusters.fasta",
                sha256: String(repeating: "b", count: 64),
                sizeBytes: 0
            ),
            clusters: [],
            observations: []
        )
        return try FullLengthONTMHCWorkbookProjection(
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument,
            sampleOrder: ["sample-a"]
        )
    }

    private func normalizedUnmatchedRow(
        category: FullLengthONTMHCUnmatchedRecordCategory,
        stableID: String,
        provisionalName: String?
    ) -> FullLengthONTMHCNormalizedUnmatchedRow {
        FullLengthONTMHCNormalizedUnmatchedRow(
            recordCategory: category,
            stableClusterID: stableID,
            provisionalAlleleName: provisionalName,
            locus: nil,
            classificationOrReason: category == .candidate ? "novel" : "unresolved-locus",
            closestReferenceAllele: nil,
            closestReferenceRawID: nil,
            snpCount: nil,
            insertedBases: nil,
            deletedBases: nil,
            longGapBases: nil,
            comparableBases: nil,
            failedMetrics: [:],
            supportClass: "singleton",
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 1,
            supportingSampleIDs: ["sample-a"],
            readsBySample: ["sample-a": 1],
            fastaRecordID: stableID,
            sequenceSHA256: String(repeating: "d", count: 64),
            nucleotideSequence: "ACGT",
            putativeAminoAcidTranslation: nil,
            translationStatus: .incompleteUnresolved
        )
    }

    private func normalizedGenBankRecord(
        stableID: String,
        sequence: String,
        translation: String?,
        status: String,
        sourceSequenceSHA256: String? = nil,
        accession: String? = nil,
        locusName: String? = nil
    ) throws -> GenBankRecord {
        var annotations = [
            SequenceAnnotation(
                type: .source,
                name: stableID,
                start: 0,
                end: sequence.count,
                strand: .forward,
                qualifiers: [
                    "stable_cluster_id": .init(stableID),
                    "sequence_sha256": .init(sourceSequenceSHA256 ?? sha256Hex(sequence)),
                    "translation_status": .init(status),
                ]
            ),
        ]
        if let translation {
            annotations.append(SequenceAnnotation(
                type: .cds,
                name: stableID,
                start: 0,
                end: sequence.count,
                strand: .forward,
                qualifiers: ["translation": .init(translation)]
            ))
        }
        return GenBankRecord(
            sequence: try Sequence(name: stableID, alphabet: .dna, bases: sequence),
            annotations: annotations,
            locus: .init(name: locusName ?? stableID, length: sequence.count, moleculeType: .dna, topology: .linear),
            accession: accession ?? stableID
        )
    }

    private func singleCandidateProjection(
        from documents: (
            candidates: ONTMHCCandidateAllelesDocument,
            unnameable: ONTMHCUnnameableClustersDocument
        )
    ) throws -> FullLengthONTMHCWorkbookProjection {
        let candidate = try XCTUnwrap(documents.candidates.candidates.first {
            $0.stableClusterID == "cluster-1"
        })
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: documents.candidates.schemaVersion,
            createdAt: documents.candidates.createdAt,
            thresholds: documents.candidates.thresholds,
            inputs: documents.candidates.inputs,
            evidence: documents.candidates.evidence,
            sequenceFASTA: documents.candidates.sequenceFASTA,
            candidates: [candidate],
            observations: documents.candidates.observations.filter {
                $0.stableClusterID == candidate.stableClusterID
            }
        )
        return try FullLengthONTMHCWorkbookProjection(
            candidateDocument: candidateDocument,
            unnameableDocument: documents.unnameable,
            sampleOrder: ["sample-a", "sample-b"]
        )
    }

    private func normalizedRows(
        projection: FullLengthONTMHCWorkbookProjection,
        candidateGenBankRecord: GenBankRecord? = nil,
        knownAlleleDisplayNames: [String: String] = [:]
    ) throws -> [FullLengthONTMHCNormalizedUnmatchedRow] {
        let candidateSequence = "ATGGCTTAA"
        let unnameableSequence = "ACGTACGT"
        return try projection.normalizedUnmatchedRows(
            candidateFASTARecords: [
                .init(name: "cluster-1", sequence: candidateSequence, readCount: 10),
            ],
            unnameableFASTARecords: [
                .init(name: "cluster-u", sequence: unnameableSequence, readCount: 4),
            ],
            candidateGenBankRecords: [
                try candidateGenBankRecord ?? normalizedGenBankRecord(
                    stableID: "cluster-1",
                    sequence: candidateSequence,
                    translation: "MA",
                    status: "full-length"
                ),
            ],
            unnameableGenBankRecords: [
                try normalizedGenBankRecord(
                    stableID: "cluster-u",
                    sequence: unnameableSequence,
                    translation: nil,
                    status: "incomplete/unresolved"
                ),
            ],
            knownAlleleDisplayNames: knownAlleleDisplayNames
        )
    }

    private func sha256Hex(_ sequence: String) -> String {
        SHA256.hash(data: Data(sequence.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func unzip(_ path: String, from url: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, path]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func assertXMLWellFormed(_ xml: String) throws {
        let process = Process()
        let input = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
        process.arguments = ["--noout", "-"]
        process.standardInput = input
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(xml.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, message)
    }
}
