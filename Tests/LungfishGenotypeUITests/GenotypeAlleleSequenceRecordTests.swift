import Foundation
import XCTest
import LungfishIO
@testable import LungfishGenotypeUI

final class GenotypeAlleleSequenceRecordTests: XCTestCase {
    func testKnownPreservesValidatedFlatFilesAndBuildsAnnotatedEMBL() {
        let source = knownRecord()

        let record = GenotypeAlleleSequenceRecord.known(source)

        XCTAssertEqual(record.identity, "NHP00001")
        XCTAssertEqual(record.displayName, "Mafa-A1*001:01")
        XCTAssertEqual(record.genBankText, "\nLOCUS       supplied\n//\n")
        XCTAssertEqual(record.fastaText, "\n>supplied\nacgt\n")
        XCTAssertTrue(record.emblText.contains("ID   NHP00001; linear; genomic DNA; 64 BP."))
        XCTAssertTrue(record.emblText.contains("AC   NHP00001;"))
        XCTAssertTrue(record.emblText.contains("DE   MHC class I allele"))
        XCTAssertTrue(record.emblText.contains("OS   Macaca fascicularis"))
        XCTAssertTrue(record.emblText.contains("OC   Eukaryota; Metazoa."))
        XCTAssertTrue(record.emblText.contains("FT   source          1..64"))
        XCTAssertTrue(record.emblText.contains("FT                   /organism=\"Macaca fascicularis\""))
        XCTAssertTrue(record.emblText.contains("FT   CDS             complement(7..30)"))
        XCTAssertTrue(record.emblText.contains("FT                   /allele=\"Mafa-A1*001:01\""))
        XCTAssertTrue(record.emblText.contains("FT   long_feature_name 31..34"))
        XCTAssertEqual(record.emblText.components(separatedBy: "//").count, 2)
        XCTAssertTrue(record.emblText.hasSuffix("//\n"))
    }

    func testKnownEMBLUsesSourceOrdinalAndDeterministicQualifierOrdering() {
        let record = GenotypeAlleleSequenceRecord.known(knownRecord())

        let sourceRange = try! XCTUnwrap(record.emblText.range(of: "FT   source"))
        let cdsRange = try! XCTUnwrap(record.emblText.range(of: "FT   CDS"))
        let alleleRange = try! XCTUnwrap(record.emblText.range(of: "/allele="))
        let translationRange = try! XCTUnwrap(record.emblText.range(of: "/translation="))

        XCTAssertLessThan(sourceRange.lowerBound, cdsRange.lowerBound)
        XCTAssertLessThan(alleleRange.lowerBound, translationRange.lowerBound)
        XCTAssertTrue(record.emblText.contains(
            "     acgtacgtac gtacgtacgt acgtacgtac gtacgtacgt acgtacgtac gtacgtacgt        60"
        ))
        let finalSequenceLine = try! XCTUnwrap(
            record.emblText.split(separator: "\n").first {
                $0.hasPrefix("     acgt") && $0.hasSuffix("64")
            }
        )
        XCTAssertEqual(finalSequenceLine.count, 80)
    }

    func testCandidateCatalogUsesAccessionAndTrimmedGenBankSequence() throws {
        let url = try writeCandidateGenBank([
            candidateGenBank(accession: "candidate-accession", sequence: "acgtacgt")
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let candidate = makeCandidate(
            stableID: "stable-a",
            accession: "candidate-accession",
            displayName: "Mafa-A1*001:01_1nt_nov"
        )

        let catalog = try GenotypeAlleleSequenceRecord.candidateCatalog(
            candidates: [candidate],
            genBankURL: url
        )
        let record = try XCTUnwrap(catalog["stable-a"])

        XCTAssertEqual(record.identity, "stable-a")
        XCTAssertEqual(record.displayName, "Mafa-A1*001:01_1nt_nov")
        XCTAssertTrue(record.genBankText.contains("ACCESSION   candidate-accession"))
        XCTAssertTrue(record.genBankText.contains("        1 acgtacgt"))
        XCTAssertEqual(
            record.fastaText,
            ">candidate-accession Mafa-A1*001:01_1nt_nov\nACGTACGT\n"
        )
        XCTAssertTrue(record.emblText.contains("AC   candidate-accession;"))
        XCTAssertTrue(record.emblText.contains("FT   CDS             1..8"))
        XCTAssertTrue(record.genBankText.hasSuffix("//\n"))
        XCTAssertTrue(record.emblText.hasSuffix("//\n"))
    }

    func testCandidateCatalogKeepsDistinctStableIDsWithSameDisplayName() throws {
        let url = try writeCandidateGenBank([
            candidateGenBank(accession: "accession-a", sequence: "AAAA"),
            candidateGenBank(accession: "accession-b", sequence: "CCCC"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let candidates = [
            makeCandidate(stableID: "stable-a", accession: "accession-a", displayName: "Mafa-B*001_ext"),
            makeCandidate(stableID: "stable-b", accession: "accession-b", displayName: "Mafa-B*001_ext"),
        ]

        let catalog = try GenotypeAlleleSequenceRecord.candidateCatalog(
            candidates: candidates,
            genBankURL: url
        )

        XCTAssertEqual(Set(catalog.keys), ["stable-a", "stable-b"])
        XCTAssertEqual(catalog["stable-a"]?.fastaText, ">accession-a Mafa-B*001_ext\nAAAA\n")
        XCTAssertEqual(catalog["stable-b"]?.fastaText, ">accession-b Mafa-B*001_ext\nCCCC\n")
    }

    func testCandidateCatalogRejectsDuplicateAccessions() throws {
        let url = try writeCandidateGenBank([
            candidateGenBank(accession: "duplicate", sequence: "AAAA"),
            candidateGenBank(accession: "duplicate", sequence: "CCCC"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try GenotypeAlleleSequenceRecord.candidateCatalog(
            candidates: [
                makeCandidate(stableID: "stable-a", accession: "duplicate", displayName: "allele-a")
            ],
            genBankURL: url
        )) { error in
            XCTAssertEqual(
                error as? GenotypeAlleleSequenceRecord.CatalogError,
                .duplicateCandidateAccession("duplicate")
            )
        }
    }

    func testCandidateCatalogRejectsDuplicateStableIDs() throws {
        let url = try writeCandidateGenBank([
            candidateGenBank(accession: "accession-a", sequence: "AAAA"),
            candidateGenBank(accession: "accession-b", sequence: "CCCC"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try GenotypeAlleleSequenceRecord.candidateCatalog(
            candidates: [
                makeCandidate(stableID: "stable", accession: "accession-a", displayName: "allele-a"),
                makeCandidate(stableID: "stable", accession: "accession-b", displayName: "allele-b"),
            ],
            genBankURL: url
        )) { error in
            XCTAssertEqual(
                error as? GenotypeAlleleSequenceRecord.CatalogError,
                .duplicateStableClusterID("stable")
            )
        }
    }

    func testCandidateCatalogRequiresGenBankACCESSIONRatherThanLocusFallback() throws {
        let url = try writeCandidateGenBank([
            """
            LOCUS       locus-only 4 bp DNA linear
            DEFINITION  Missing accession fixture.
            ORIGIN
                    1 acgt
            //
            """
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try GenotypeAlleleSequenceRecord.candidateCatalog(
            candidates: [
                makeCandidate(stableID: "stable", accession: "locus-only", displayName: "allele")
            ],
            genBankURL: url
        )) { error in
            XCTAssertEqual(
                error as? GenotypeAlleleSequenceRecord.CatalogError,
                .missingCandidateAccession("locus-only")
            )
        }
    }

    func testCandidateCatalogReportsMissingArtifactAndMissingAccession() throws {
        XCTAssertThrowsError(try GenotypeAlleleSequenceRecord.candidateCatalog(
            candidates: [makeCandidate(stableID: "stable", accession: "missing", displayName: "allele")],
            genBankURL: nil
        )) { error in
            XCTAssertEqual(
                error as? GenotypeAlleleSequenceRecord.CatalogError,
                .missingCandidateGenBankArtifact
            )
        }

        let url = try writeCandidateGenBank([
            candidateGenBank(accession: "present", sequence: "AAAA")
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try GenotypeAlleleSequenceRecord.candidateCatalog(
            candidates: [makeCandidate(stableID: "stable", accession: "missing", displayName: "allele")],
            genBankURL: url
        )) { error in
            XCTAssertEqual(
                error as? GenotypeAlleleSequenceRecord.CatalogError,
                .candidateAccessionNotFound("missing")
            )
        }
    }

    func testUnavailableNeverSubstitutesASequence() {
        let record = GenotypeAlleleSequenceRecord.unavailable(
            identity: "stable-missing",
            displayName: "Mafa-A1*missing_nov"
        )

        XCTAssertEqual(record.fastaText, ">stable-missing Mafa-A1*missing_nov validated allele record unavailable\n")
        XCTAssertTrue(record.genBankText.contains("0 bp"))
        XCTAssertTrue(record.genBankText.contains("validated allele record unavailable"))
        XCTAssertFalse(record.genBankText.contains("ORIGIN      \n        1"))
        XCTAssertTrue(record.emblText.contains("0 BP."))
        XCTAssertTrue(record.emblText.contains("CC   Validated allele record unavailable."))
        XCTAssertTrue(record.genBankText.hasSuffix("//\n"))
        XCTAssertTrue(record.emblText.hasSuffix("//\n"))
    }

    func testKnownEMBLOmitsUnavailableMetadataWithoutEmptyPlaceholders() {
        let source = ONTMHCReferenceVisualizationRecord(
            rawReferenceID: "minimal",
            sourceOrdinal: 0,
            alleleName: "Minimal",
            locus: nil,
            sequence: "ACGT",
            sequenceSHA256: "unused-by-formatter",
            recordFields: [:],
            features: [],
            annotatedTranslation: nil,
            genBankText: "LOCUS minimal\n//\n",
            fastaText: ">minimal\nACGT\n",
            roles: [.init(role: .exactKnownCall, candidateStableClusterIDs: [])]
        )

        let embl = GenotypeAlleleSequenceRecord.known(source).emblText

        XCTAssertTrue(embl.hasPrefix("ID   minimal; linear; 4 BP.\n"))
        XCTAssertFalse(embl.contains("; ;"))
        XCTAssertFalse(embl.contains("\nOS   "))
        XCTAssertFalse(embl.contains("\nOC   "))
    }

    func testFASTAUppercasesWrapsAtSixtyAndHasExactlyOneTrailingNewline() throws {
        let sequence = String(repeating: "acgt", count: 16)
        let url = try writeCandidateGenBank([
            candidateGenBank(accession: "wrapped", sequence: sequence)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let record = try XCTUnwrap(GenotypeAlleleSequenceRecord.candidateCatalog(
            candidates: [makeCandidate(stableID: "stable", accession: "wrapped", displayName: "allele")],
            genBankURL: url
        )["stable"])
        let lines = record.fastaText.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[1].count, 60)
        XCTAssertEqual(lines[2], "ACGT")
        XCTAssertEqual(lines[3], "")
        XCTAssertFalse(record.fastaText.hasSuffix("\n\n"))
    }
}

private extension GenotypeAlleleSequenceRecordTests {
    func knownRecord() -> ONTMHCReferenceVisualizationRecord {
        ONTMHCReferenceVisualizationRecord(
            rawReferenceID: "NHP00001",
            sourceOrdinal: 0,
            alleleName: "Mafa-A1*001:01",
            locus: "Mafa-A1",
            sequence: String(repeating: "ACGT", count: 16),
            sequenceSHA256: "unused-by-formatter",
            recordFields: [
                "DEFINITION": ["MHC class I allele"],
                "LOCUS.MOLECULE_TYPE": ["genomic DNA"],
                "SOURCE": ["Macaca fascicularis"],
                "ORGANISM": ["Macaca fascicularis"],
                "TAXONOMY": ["Eukaryota; Metazoa."],
            ],
            features: [
                ONTMHCReferenceVisualizationFeature(
                    type: "CDS",
                    start: 6,
                    end: 30,
                    strand: "-",
                    sourceOrdinal: 2,
                    rawGenBankLocation: "complement(7..30)",
                    qualifiers: [
                        "translation": ["MHCPEPTIDE"],
                        "allele": ["Mafa-A1*001:01"],
                    ]
                ),
                ONTMHCReferenceVisualizationFeature(
                    type: "source",
                    start: 0,
                    end: 64,
                    strand: "+",
                    sourceOrdinal: 1,
                    rawGenBankLocation: "1..64",
                    qualifiers: ["organism": ["Macaca fascicularis"]]
                ),
                ONTMHCReferenceVisualizationFeature(
                    type: "long_feature_name",
                    start: 30,
                    end: 34,
                    strand: "+",
                    sourceOrdinal: 3,
                    rawGenBankLocation: "31..34",
                    qualifiers: [:]
                ),
            ],
            annotatedTranslation: "MHCPEPTIDE",
            genBankText: "\nLOCUS       supplied\n//\n\n",
            fastaText: "\n>supplied\nacgt\n\n",
            roles: [.init(role: .exactKnownCall, candidateStableClusterIDs: [])]
        )
    }

    func candidateGenBank(accession: String, sequence: String) -> String {
        """
        LOCUS       \(accession) \(sequence.count) bp DNA linear
        DEFINITION  Candidate allele.
        ACCESSION   \(accession)
        SOURCE      Macaca fascicularis
          ORGANISM  Macaca fascicularis
                    Eukaryota; Metazoa.
        FEATURES             Location/Qualifiers
             source          1..\(sequence.count)
                             /organism="Macaca fascicularis"
             CDS             1..\(sequence.count)
                             /allele="candidate"
        ORIGIN
                1 \(sequence)
        //
        """
    }

    func writeCandidateGenBank(_ records: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("candidate-sequence-records-\(UUID().uuidString).gb")
        try (records.joined(separator: "\n") + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    func makeCandidate(
        stableID: String,
        accession: String,
        displayName: String
    ) -> ONTMHCCandidateRecord {
        ONTMHCCandidateRecord(
            stableClusterID: stableID,
            provisionalName: displayName,
            locus: "Mafa-A1",
            classification: .novel,
            supportClass: .shared,
            closestReferenceName: "Mafa-A1*001:01",
            closestReferenceClass: .genomicDNA,
            snpCount: 1,
            insertedBases: 0,
            deletedBases: 0,
            longGapBases: 0,
            comparableBases: 4,
            shorterCoverage: 1,
            identity: 0.75,
            mappingQuality: 60,
            alignmentScore: 3,
            independentSampleCount: 2,
            occurrenceCount: 2,
            totalClusterReads: 20,
            supportingSampleIDs: ["sample-a", "sample-b"],
            fastaRecordID: accession,
            sequenceSHA256: String(repeating: "a", count: 64),
            selectedEvidence: .init(
                bamPath: "internal.bam",
                queryName: stableID,
                referenceName: "NHP00001",
                readGroupID: nil,
                referenceStart: 0,
                cigar: "4M"
            )
        )
    }
}
