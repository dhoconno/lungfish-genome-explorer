import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class FullLengthONTMHCCandidateGenBankArtifactBuilderTests: XCTestCase {
    func testCDNAGapSplitsExonsAndRecomputesCandidateTranslation() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-b",
            sequenceSHA256: "candidate-hash",
            cigar: "3=3I6=",
            referenceName: "ref-cdna",
            referenceClass: .cDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: "ATGCCCGCTTAA",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-cdna",
                sequence: "ATGGCTTAA",
                features: [
                    feature(type: "gene", start: 0, end: 9),
                    feature(type: "CDS", start: 0, end: 9, qualifiers: ["gene": ["Mafa-A1"]]),
                ]
            ),
            analysisName: "MHC run 7",
            projectBundleName: "Primate Cohort.lungfish",
            minimumIntronGapBases: 3
        )

        let record = try XCTUnwrap(FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first)
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))
        let exons = record.annotations.filter { $0.type == .exon }
        let introns = record.annotations.filter { $0.type == .intron }

        XCTAssertEqual(cds.intervals.map { [$0.start, $0.end] }, [[0, 3], [6, 12]])
        XCTAssertEqual(cds.qualifier("translation"), "MA")
        XCTAssertEqual(sourceTranslationStatus(record), "full-length")
        XCTAssertEqual(exons.map { $0.qualifier("number") }, ["1", "2"])
        XCTAssertEqual(exons.map { [$0.start, $0.end] }, [[0, 3], [6, 12]])
        XCTAssertEqual(introns.map { [$0.start, $0.end] }, [[3, 6]])
        XCTAssertEqual(introns.map { $0.qualifier("number") }, ["1"])
        XCTAssertTrue(record.values(forRecordField: "COMMENT").contains {
            $0.contains("inferred exon count: 2")
        })
        let text = GenBankWriter(url: URL(fileURLWithPath: "/dev/null")).format(record)
        XCTAssertTrue(text.contains("/stable_cluster_id=\"candidate-b\""), text)
        XCTAssertTrue(text.contains("/translation_status=\"full-length\""), text)
    }

    func testReverseAlignmentLiftsFeatureStrandAndTranslatesOriginalCandidateOrientation() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-reverse",
            sequenceSHA256: "reverse-hash",
            cigar: "9=",
            referenceName: "ref-genomic",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: "TTAAGCCAT",
            selectedAlignmentIsReverse: true,
            closestReference: makeReference(
                id: "ref-genomic",
                sequence: "ATGGCTTAA",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "MHC run 7",
            projectBundleName: nil,
            minimumIntronGapBases: 50
        )

        let record = try XCTUnwrap(FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first)
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))

        XCTAssertEqual(cds.intervals.map { [$0.start, $0.end] }, [[0, 9]])
        XCTAssertEqual(cds.strand, .reverse)
        XCTAssertEqual(cds.qualifier("translation"), "MA")
    }

    func testInternalStopTranslationIsRetainedAndReported() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-stop",
            sequenceSHA256: "stop-hash",
            cigar: "3=1X5=",
            referenceName: "ref-stop",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: "ATGTAGGCT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-stop",
                sequence: "ATGCAAGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "MHC run 7",
            projectBundleName: nil,
            minimumIntronGapBases: 50
        )

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))

        XCTAssertEqual(cds.qualifier("translation"), "M*A")
        XCTAssertEqual(sourceTranslationStatus(record), "pseudogene")
        XCTAssertTrue(record.values(forRecordField: "COMMENT").contains {
            $0.contains("candidate amino acids=2") && $0.contains("internal stops=1")
        })
    }

    func testInternalFrameDisruptingDeletionIsClassifiedAsPseudogene() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-frameshift",
            sequenceSHA256: "frameshift-hash",
            cigar: "3=1D5=",
            referenceName: "ref-frameshift",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: "ATGAAGCT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-frameshift",
                sequence: "ATGCAAGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "MHC run 7",
            projectBundleName: nil,
            minimumIntronGapBases: 50
        )

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))

        XCTAssertEqual(cds.qualifier("translation"), "MK")
        XCTAssertEqual(sourceTranslationStatus(record), "pseudogene")
    }

    func testPartialCDSMissingFivePrimeBoundaryOmitsTranslation() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-partial",
            sequenceSHA256: "partial-hash",
            cigar: "6=",
            referenceName: "ref-partial",
            referenceClass: .genomicDNA,
            referenceStart: 4
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: "CAAGCT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-partial",
                sequence: "ATGCAAGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 50
        )

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))

        XCTAssertNil(cds.qualifier("translation"))
        XCTAssertEqual(sourceTranslationStatus(record), "incomplete/unresolved")
        XCTAssertTrue(cds.qualifiers["note"]?.values.contains {
            $0.contains("5-prime CDS boundary")
        } == true)
    }

    func testAmbiguousOrStructurallyPartialCDSPreservesTranslationButIsNotFullLength() throws {
        let cases: [(
            stableID: String,
            sequence: String,
            referenceSequence: String,
            cigar: String,
            feature: ONTMHCReferenceVisualizationFeature,
            expectedTranslation: String
        )] = [
            (
                "candidate-ambiguous-aa", "ATGNNNGCT", "ATGAAAGCT", "3=3X3=",
                feature(type: "CDS", start: 0, end: 9),
                "MXA"
            ),
            (
                "candidate-partial-location", "ATGGCTTAA", "ATGGCTTAA", "9=",
                feature(type: "CDS", start: 0, end: 9, rawGenBankLocation: "<1..9"),
                "MA"
            ),
            (
                "candidate-unknown-strand", "ATGGCTTAA", "ATGGCTTAA", "9=",
                feature(type: "CDS", start: 0, end: 9, strand: "?"),
                "MA"
            ),
            (
                "candidate-codon-start", "AATGGCTTAA", "AATGGCTTAA", "10=",
                feature(type: "CDS", start: 0, end: 10, qualifiers: ["codon_start": ["2"]]),
                "MA"
            ),
        ]

        for testCase in cases {
            let candidate = try makeCandidate(
                stableID: testCase.stableID,
                sequenceSHA256: "\(testCase.stableID)-hash",
                cigar: testCase.cigar,
                referenceName: "ref-\(testCase.stableID)",
                referenceClass: .genomicDNA
            )
            let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
                subject: .candidate(candidate),
                sequence: testCase.sequence,
                selectedAlignmentIsReverse: false,
                closestReference: makeReference(
                    id: "ref-\(testCase.stableID)",
                    sequence: testCase.referenceSequence,
                    features: [testCase.feature]
                ),
                analysisName: "run",
                projectBundleName: nil,
                minimumIntronGapBases: 50
            )

            let record = try XCTUnwrap(
                FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
            )
            let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))
            XCTAssertEqual(cds.qualifier("translation"), testCase.expectedTranslation, testCase.stableID)
            XCTAssertEqual(
                sourceTranslationStatus(record),
                "incomplete/unresolved",
                testCase.stableID
            )
        }
    }

    func testLeadingHardClipOffsetsLiftedCandidateCoordinates() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-hard-clip",
            sequenceSHA256: "hard-clip-hash",
            cigar: "5H9=",
            referenceName: "ref-hard-clip",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: "NNNNNATGGCTTAA",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-hard-clip",
                sequence: "ATGGCTTAA",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 50
        )

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))

        XCTAssertEqual(cds.intervals.map { [$0.start, $0.end] }, [[5, 14]])
        XCTAssertEqual(cds.qualifier("translation"), "MA")
    }

    func testNoAlignmentUnnameableProducesSourceOnlyRecordWithSupportAndProjectComments() throws {
        let reciprocal = try ONTMHCReciprocalQueryHitSummary(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "unnameable-a",
            alignmentCount: 0,
            targetAlignmentCounts: [:],
            exactMatchTargetNames: [],
            closestMatchTargetNames: []
        )
        let unnameable = ONTMHCUnnameableRecord(
            stableClusterID: "unnameable-a",
            reason: .noAlignment,
            failedMetrics: [:],
            supportClass: .shared,
            independentSampleCount: 2,
            occurrenceCount: 3,
            totalClusterReads: 17,
            supportingSampleIDs: ["Sample-B", "Sample-A"],
            fastaRecordID: "unnameable-a",
            sequenceSHA256: "unnameable-hash",
            reciprocalHitSummary: reciprocal,
            selectedEvidence: nil
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .unnameable(unnameable),
            sequence: "ACGT",
            selectedAlignmentIsReverse: nil,
            closestReference: nil,
            analysisName: "MHC run 7",
            projectBundleName: "Primate Cohort.lungfish",
            minimumIntronGapBases: 50
        )

        let record = try XCTUnwrap(FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first)

        XCTAssertEqual(record.annotations.map(\.type), [.source])
        XCTAssertEqual(sourceTranslationStatus(record), "incomplete/unresolved")
        let comments = record.values(forRecordField: "COMMENT")
        XCTAssertTrue(comments.contains("Lungfish project: Primate Cohort.lungfish"))
        XCTAssertTrue(comments.contains { $0.contains("Sample-A, Sample-B") })
        XCTAssertTrue(comments.contains { $0.contains("annotation unavailable: no selected reciprocal alignment") })
    }

    func testRecordsAreDeterministicallySortedByStableClusterID() throws {
        let first = try makeCandidate(
            stableID: "candidate-a",
            sequenceSHA256: "a",
            cigar: "4=",
            referenceName: "ref",
            referenceClass: .genomicDNA
        )
        let second = try makeCandidate(
            stableID: "candidate-z",
            sequenceSHA256: "z",
            cigar: "4=",
            referenceName: "ref",
            referenceClass: .genomicDNA
        )
        let reference = makeReference(id: "ref", sequence: "ACGT", features: [])
        let inputs = [second, first].map {
            FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
                subject: .candidate($0), sequence: "ACGT",
                selectedAlignmentIsReverse: false, closestReference: reference,
                analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 50
            )
        }

        XCTAssertEqual(
            try FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: inputs).map(\.sequence.name),
            ["candidate-a", "candidate-z"]
        )
    }

    private func makeCandidate(
        stableID: String,
        sequenceSHA256: String,
        cigar: String,
        referenceName: String,
        referenceClass: MHCReferenceMoleculeClass,
        referenceStart: Int = 1
    ) throws -> ONTMHCCandidateRecord {
        let evidence = ONTMHCEvidenceLocator(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: stableID,
            referenceName: referenceName,
            readGroupID: nil,
            referenceStart: referenceStart,
            cigar: cigar
        )
        return ONTMHCCandidateRecord(
            stableClusterID: stableID,
            provisionalName: "Mafa-A1*001_1nt_nov",
            locus: "Mafa-A1",
            classification: .novel,
            supportClass: .shared,
            closestReferenceName: "Mafa-A1*001",
            closestReferenceClass: referenceClass,
            snpCount: 1,
            insertedBases: 0,
            deletedBases: 0,
            longGapBases: 0,
            comparableBases: 4,
            shorterCoverage: 1,
            identity: 0.99,
            mappingQuality: 60,
            alignmentScore: 4,
            independentSampleCount: 2,
            occurrenceCount: 3,
            totalClusterReads: 17,
            supportingSampleIDs: ["Sample-B", "Sample-A"],
            fastaRecordID: stableID,
            sequenceSHA256: sequenceSHA256,
            selectedEvidence: evidence
        )
    }

    private func makeReference(
        id: String,
        sequence: String,
        features: [ONTMHCReferenceVisualizationFeature]
    ) -> ONTMHCReferenceVisualizationRecord {
        ONTMHCReferenceVisualizationRecord(
            rawReferenceID: id,
            sourceOrdinal: 0,
            alleleName: "Mafa-A1*001",
            locus: "Mafa-A1",
            sequence: sequence,
            sequenceSHA256: "reference-hash",
            recordFields: ["SOURCE": ["Macaca fascicularis"]],
            features: features,
            annotatedTranslation: nil,
            genBankText: "",
            fastaText: "",
            roles: []
        )
    }

    private func feature(
        type: String,
        start: Int,
        end: Int,
        qualifiers: [String: [String]] = [:],
        rawGenBankLocation: String? = nil,
        strand: String = "+"
    ) -> ONTMHCReferenceVisualizationFeature {
        ONTMHCReferenceVisualizationFeature(
            type: type,
            start: start,
            end: end,
            strand: strand,
            sourceOrdinal: 0,
            rawGenBankLocation: rawGenBankLocation,
            qualifiers: qualifiers
        )
    }

    private func sourceTranslationStatus(_ record: GenBankRecord) -> String? {
        record.annotations.first(where: { $0.type == .source })?.qualifier("translation_status")
    }
}
