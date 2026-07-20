import Foundation
import LungfishIO
@testable import LungfishWorkflow
import XCTest

final class FullLengthONTMHCWorkbookProjectionTests: XCTestCase {
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

    private func makeDocuments() -> (
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
                sequenceSHA256: String(repeating: id.last == "1" ? "1" : "2", count: 64),
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
            sequenceSHA256: String(repeating: "f", count: 64),
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
