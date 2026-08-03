import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class FullLengthONTMHCCandidateGenBankArtifactBuilderTests: XCTestCase {
    func testGenomicCandidateCommentsEnumerateCodingAndIntronicConsequences() throws {
        let referenceSequence = "ATGGCTGAATTTAAAGCTCAAGGATCTTAA"
        var candidateBases = Array(referenceSequence)
        candidateBases[10] = "C" // intron 1
        candidateBases[12] = "G" // exon 2, AAA -> GAA (K -> E)
        candidateBases[17] = "C" // exon 2, GCT -> GCC (A -> A)
        candidateBases[21] = "A" // exon 3, GGA -> AGA (G -> R)
        let candidateSequence = String(candidateBases)
        let candidate = try makeCandidate(
            stableID: "candidate-consequences",
            sequenceSHA256: "consequence-hash",
            cigar: "10=1X1=1X4=1X3=1X8=",
            referenceName: "ref-consequences",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-consequences",
                sequence: referenceSequence,
                features: [
                    feature(type: "gene", start: 0, end: 30),
                    feature(type: "exon", start: 0, end: 9, qualifiers: ["number": ["1"]], sourceOrdinal: 1),
                    feature(type: "exon", start: 12, end: 21, qualifiers: ["number": ["2"]], sourceOrdinal: 2),
                    feature(type: "exon", start: 21, end: 30, qualifiers: ["number": ["3"]], sourceOrdinal: 3),
                    feature(type: "intron", start: 9, end: 12, qualifiers: ["number": ["1"]], sourceOrdinal: 4),
                    feature(type: "CDS", start: 0, end: 9, rawGenBankLocation: "join(1..9,13..30)", sourceOrdinal: 5),
                    feature(type: "CDS", start: 12, end: 21, rawGenBankLocation: "join(1..9,13..30)", sourceOrdinal: 5),
                    feature(type: "CDS", start: 21, end: 30, rawGenBankLocation: "join(1..9,13..30)", sourceOrdinal: 5),
                ]
            ),
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20
        )

        let record = try buildRecord(input)
        let comments = record.values(forRecordField: "COMMENT")

        XCTAssertTrue(comments.contains { $0 == "Lungfish exon 2/3 nonsynonymous changes: CDS-NS-1, CDS-NS-2" }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains { $0 == "Lungfish CDS nonsynonymous changes: CDS-NS-1, CDS-NS-2" })
        XCTAssertTrue(comments.contains { $0 == "Lungfish CDS synonymous changes: CDS-SYN-1" })
        XCTAssertTrue(comments.contains { $0 == "Lungfish intronic changes: INTRON-1" })
        XCTAssertTrue(comments.contains { $0.contains("CDS-NS-1:") && $0.contains("ref 13 A>G") && $0.contains("exon 2") && $0.contains("p.K4E") && $0.contains("missense") })
        XCTAssertTrue(comments.contains { $0.contains("CDS-SYN-1:") && $0.contains("ref 18 T>C") && $0.contains("p.A5=") && $0.contains("synonymous") })
        XCTAssertTrue(comments.contains { $0.contains("CDS-NS-2:") && $0.contains("ref 22 G>A") && $0.contains("exon 3") && $0.contains("p.G7R") })
        XCTAssertTrue(comments.contains { $0.contains("INTRON-1:") && $0.contains("ref 11 T>C") && $0.contains("intron 1") && $0.contains("splice/regulatory impact not assessed") })
        XCTAssertTrue(comments.contains { $0.contains("coordinate convention") && $0.contains("1-based") && $0.contains("stored candidate ORIGIN") })
    }

    func testSameCodonSubstitutionsAreGroupedBeforeTranslation() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-grouped-codon",
            sequenceSHA256: "grouped-hash",
            cigar: "3=2X4=",
            referenceName: "ref-grouped-codon",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: "ATGGGAGCT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-grouped-codon",
                sequence: "ATGAAAGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        let details = comments.filter { $0.hasPrefix("CDS-NS-") }
        XCTAssertEqual(details.count, 1, comments.joined(separator: "\n"))
        let detail = try XCTUnwrap(details.first)
        XCTAssertTrue(detail.contains("ref codon AAA>GGA"))
        XCTAssertTrue(detail.contains("p.K2G"))
        XCTAssertTrue(detail.contains("ref 4 A>G"))
        XCTAssertTrue(detail.contains("ref 5 A>G"))
    }

    func testReverseAlignmentReportsStoredCandidateCoordinates() throws {
        let orientedCandidate = "ATGGAAGCT"
        let storedCandidate = TranslationEngine.reverseComplement(orientedCandidate)
        let candidate = try makeCandidate(
            stableID: "candidate-reverse-change",
            sequenceSHA256: "reverse-change-hash",
            cigar: "4=1X4=",
            referenceName: "ref-reverse-change",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: storedCandidate,
            selectedAlignmentIsReverse: true,
            closestReference: makeReference(
                id: "ref-reverse-change",
                sequence: "ATGCAAGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        XCTAssertTrue(comments.contains { $0.contains("CDS-NS-1:") && $0.contains("ref 4 C>G") && $0.contains("candidate 6") && $0.contains("p.Q2E") }, comments.joined(separator: "\n"))
    }

    func testReverseStrandCDSUsesTranscriptOrientedCodons() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-reverse-strand-cds",
            sequenceSHA256: "reverse-strand-cds-hash",
            cigar: "5=1X3=",
            referenceName: "ref-reverse-strand-cds",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: "AGCTTCCAT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-reverse-strand-cds",
                sequence: "AGCTTGCAT",
                features: [feature(type: "CDS", start: 0, end: 9, strand: "-")]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")
        XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-NS-1:") && $0.contains("ref 6 G>C") && $0.contains("ref codon CAA>GAA") && $0.contains("p.Q2E") }, comments.joined(separator: "\n"))
    }

    func testPartialCDSChangeIsEnumeratedAsUnresolvedNotSynonymousOrNonsynonymous() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-partial-consequence",
            sequenceSHA256: "partial-consequence-hash",
            cigar: "4=1X4=",
            referenceName: "ref-partial-consequence",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAAGCT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-partial-consequence", sequence: "ATGCAAGCT",
                features: [
                    feature(type: "exon", start: 0, end: 9, qualifiers: ["number": ["2"]], sourceOrdinal: 1),
                    feature(type: "CDS", start: 0, end: 9, rawGenBankLocation: "<1..9", sourceOrdinal: 2),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")
        XCTAssertTrue(comments.contains {
            $0 == "CDS-UNRESOLVED-1: ref 4 C>G; candidate 4; exon 2; partial CDS annotation; protein effect unresolved"
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains { $0 == "Lungfish CDS nonsynonymous changes: unresolved: CDS-UNRESOLVED-1" })
        XCTAssertTrue(comments.contains { $0 == "Lungfish CDS synonymous changes: unresolved: CDS-UNRESOLVED-1" })
        XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-NS-") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-SYN-") })
    }

    func testCodingIndelsDistinguishFramePreservingAndFrameDisruptingEffects() throws {
        let cases = [
            (id: "frame-preserving", sequence: "ATGAAAACCGCT", cigar: "6=3I3=", expected: "frame-preserving"),
            (id: "frame-disrupting", sequence: "ATGAAAAGCT", cigar: "6=1I3=", expected: "frame-disrupting"),
            (id: "complex-net-frame-preserving", sequence: "ATGGAAGCT", cigar: "3=1D1I5=", expected: "net 0 bp; frame-preserving"),
        ]
        for testCase in cases {
            let candidate = try makeCandidate(
                stableID: testCase.id,
                sequenceSHA256: "\(testCase.id)-hash",
                cigar: testCase.cigar,
                referenceName: "ref-indel",
                referenceClass: .genomicDNA
            )
            let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
                subject: .candidate(candidate), sequence: testCase.sequence,
                selectedAlignmentIsReverse: false,
                closestReference: makeReference(
                    id: "ref-indel", sequence: "ATGAAAGCT",
                    features: [feature(type: "CDS", start: 0, end: 9)]
                ),
                analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
            )

            let comments = try buildRecord(input).values(forRecordField: "COMMENT")
            XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-NS-1:") && $0.contains(testCase.expected) }, comments.joined(separator: "\n"))
        }
    }

    func testGenomicLongCodingInsertionRemainsInLiftedCDSTranslationAndComments() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-genomic-long-coding-insertion",
            sequenceSHA256: "candidate-genomic-long-coding-insertion-hash",
            cigar: "3=1X2=3I3=",
            referenceName: "ref-genomic-long-coding-insertion",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAACCCGCT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-genomic-long-coding-insertion", sequence: "ATGAAAGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 3
        )

        let record = try buildRecord(input)
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))
        let comments = record.values(forRecordField: "COMMENT")

        XCTAssertEqual(record.sequence.asString(), "ATGGAACCCGCT")
        XCTAssertEqual(cds.intervals.map { [$0.start, $0.end] }, [[0, 12]])
        XCTAssertEqual(cds.qualifier("translation"), "MEPA")
        XCTAssertEqual(source.qualifier("translation_status"), "full-length")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "reference-ready")
        XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-NS-") && $0.contains("p.K2E") })
        XCTAssertTrue(comments.contains {
            $0.hasPrefix("CDS-NS-") && $0.contains("3 bp insertion") && $0.contains("frame-preserving")
        })
        XCTAssertFalse(comments.contains { $0.hasPrefix("INTRON-FILL-") })
    }

    func testMultiBaseTouchingReplacementIndelsGroupButSeparatedIndelsRemainDistinct() throws {
        let cases = [
            (
                id: "touching-replacement",
                sequence: "ATGCCAGCT",
                cigar: "3=2D2I4=",
                expectedDetailCount: 1,
                expectedFragments: ["2 bp deletion", "2 bp insertion", "net 0 bp; frame-preserving"]
            ),
            (
                id: "separated-indels",
                sequence: "ATGACCGCT",
                cigar: "3=2D1=2I3=",
                expectedDetailCount: 2,
                expectedFragments: ["net -2 bp; frame-disrupting", "net 2 bp; frame-disrupting"]
            ),
        ]
        for testCase in cases {
            let candidate = try makeCandidate(
                stableID: testCase.id,
                sequenceSHA256: "\(testCase.id)-hash",
                cigar: testCase.cigar,
                referenceName: "ref-\(testCase.id)",
                referenceClass: .genomicDNA
            )
            let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
                subject: .candidate(candidate), sequence: testCase.sequence,
                selectedAlignmentIsReverse: false,
                closestReference: makeReference(
                    id: "ref-\(testCase.id)", sequence: "ATGAAAGCT",
                    features: [feature(type: "CDS", start: 0, end: 9)]
                ),
                analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
            )

            let comments = try buildRecord(input).values(forRecordField: "COMMENT")
            let details = comments.filter { $0.hasPrefix("CDS-NS-") }

            XCTAssertEqual(details.count, testCase.expectedDetailCount, comments.joined(separator: "\n"))
            for fragment in testCase.expectedFragments {
                XCTAssertTrue(details.contains { $0.contains(fragment) }, comments.joined(separator: "\n"))
            }
        }
    }

    func testCDNAIntronFillIsExcludedFromCodingIndelsAndAdjacentDeletionRemainsIndependent() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-intron-fill",
            sequenceSHA256: "intron-fill-hash",
            cigar: "3=1D20I5=",
            referenceName: "ref-cdna-fill",
            referenceClass: .cDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: "ATG" + String(repeating: "T", count: 20) + "AAGCT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-cdna-fill", sequence: "ATGCAAGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let record = try buildRecord(input)
        let comments = record.values(forRecordField: "COMMENT")
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))

        XCTAssertTrue(comments.contains { $0 == "Lungfish intronic changes: INTRON-FILL-1" }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains { $0.hasPrefix("INTRON-FILL-1:") && $0.contains("20 bp") && $0.contains("closest cDNA contains no homologous intron sequence") })
        XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-NS-1:") && $0.contains("deletion") && $0.contains("frame-disrupting") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-NS-") && $0.contains("20 bp insertion") })
        XCTAssertEqual(cds.intervals.map { [$0.start, $0.end] }, [[0, 3], [23, 28]])
        XCTAssertEqual(cds.qualifier("translation"), "MK")
        XCTAssertEqual(
            record.annotations.filter { $0.type == .exon }.map { [$0.start, $0.end] },
            [[0, 3], [23, 28]]
        )
        XCTAssertEqual(
            record.annotations.filter { $0.type == .intron }.map { [$0.start, $0.end] },
            [[3, 23]]
        )
    }

    func testMissingOrPartialAnnotationDoesNotEmitDefinitiveNone() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-no-annotation",
            sequenceSHA256: "no-annotation-hash",
            cigar: "4=",
            referenceName: "ref-no-annotation",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ACGT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(id: "ref-no-annotation", sequence: "ACGT", features: []),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")
        for prefix in consequenceSummaryPrefixes {
            XCTAssertTrue(comments.contains { $0.hasPrefix(prefix) && $0.contains("unavailable") })
            XCTAssertFalse(comments.contains { $0.hasPrefix(prefix) && $0.contains("none detected in complete annotated region") })
        }
    }

    func testMOperationUsesDirectBaseComparisonAndSkippedRegionPreventsDefinitiveNone() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-m-and-skip",
            sequenceSHA256: "m-and-skip-hash",
            cigar: "3M3N3M",
            referenceName: "ref-m-and-skip",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGCT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-m-and-skip", sequence: "ATGAAAGCC",
                features: [
                    feature(
                        type: "exon", start: 0, end: 9,
                        qualifiers: ["number": ["2"]], sourceOrdinal: 1
                    ),
                    feature(type: "CDS", start: 0, end: 9, sourceOrdinal: 2),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let record = try buildRecord(input)
        let comments = record.values(forRecordField: "COMMENT")
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-UNRESOLVED-1:") && $0.contains("skipped by CIGAR N") }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-SYN-1:") && $0.contains("ref 9 C>T") && $0.contains("p.A3=") }, comments.joined(separator: "\n"))
        XCTAssertFalse(comments.contains { $0.contains("none detected in complete annotated region") })
        XCTAssertEqual(source.qualifier("translation_status"), "incomplete/unresolved")
        XCTAssertEqual(source.qualifier("trim_status"), "trimmed-to-partial-lifted-CDS")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "not-reference-ready-incomplete")
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish unobserved internal reference sequence: 4..6 (3 bases)"
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish annotated reference features partially observed: exon 2 (6 of 9 bases observed; 3 missing)"
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish partial candidate sequence contains observed bases only; missing reference bases were not imputed"
        }, comments.joined(separator: "\n"))
        XCTAssertEqual(
            source.qualifier("unobserved_internal_reference_regions"),
            "4..6 (3 bases)"
        )
    }

    func testExon23SummaryExcludesExon1OnlyUnresolvedEvidence() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-exon1-skip",
            sequenceSHA256: "candidate-exon1-skip-hash",
            cigar: "3=3N6=",
            referenceName: "ref-exon1-skip",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGCTTAA",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-exon1-skip", sequence: "ATGAAAGCTTAA",
                features: [
                    feature(type: "gene", start: 0, end: 12, sourceOrdinal: 1),
                    feature(type: "exon", start: 0, end: 6, qualifiers: ["number": ["1"]], sourceOrdinal: 2),
                    feature(type: "exon", start: 6, end: 12, qualifiers: ["number": ["2"]], sourceOrdinal: 3),
                    feature(type: "CDS", start: 0, end: 6, rawGenBankLocation: "join(1..6,7..12)", sourceOrdinal: 4),
                    feature(type: "CDS", start: 6, end: 12, rawGenBankLocation: "join(1..6,7..12)", sourceOrdinal: 4),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        XCTAssertTrue(comments.contains {
            $0 == "Lungfish exon 2/3 nonsynonymous changes: none detected in complete annotated region"
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0.hasPrefix("CDS-UNRESOLVED-1:") && $0.contains("ref 4-6 skipped by CIGAR N")
        })
        XCTAssertFalse(comments.contains {
            $0.hasPrefix("Lungfish exon 2/3 nonsynonymous changes:") && $0.contains("CDS-UNRESOLVED-1")
        })
    }

    func testUnchangedAmbiguousCDSCodonEmitsExactUnresolvedConsequence() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-unchanged-ambiguous-codon",
            sequenceSHA256: "unchanged-ambiguous-codon-hash",
            cigar: "9=",
            referenceName: "ref-unchanged-ambiguous-codon",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGNNNGCT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-unchanged-ambiguous-codon", sequence: "ATGNNNGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let record = try buildRecord(input)
        let comments = record.values(forRecordField: "COMMENT")

        XCTAssertEqual(sourceTranslationStatus(record), "incomplete/unresolved")
        XCTAssertTrue(comments.contains(
            "CDS-UNRESOLVED-1: ambiguous reference/candidate CDS bases at ref 4,5,6; "
                + "candidate translation contains X; protein effect unresolved"
        ), comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish CDS nonsynonymous changes: unresolved: CDS-UNRESOLVED-1"
        })
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish CDS synonymous changes: unresolved: CDS-UNRESOLVED-1"
        })
        XCTAssertFalse(comments.contains { $0.contains("none detected in complete annotated region") })
    }

    func testUnsupportedTranslationTableIsUnresolvedAndNotReferenceReady() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-translation-table-2",
            sequenceSHA256: "candidate-translation-table-2-hash",
            cigar: "9=",
            referenceName: "ref-translation-table-2",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGAAAGCT",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-translation-table-2", sequence: "ATGAAAGCT",
                features: [feature(
                    type: "CDS", start: 0, end: 9,
                    qualifiers: ["transl_table": ["2"]]
                )]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let record = try buildRecord(input)
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))
        let comments = record.values(forRecordField: "COMMENT")

        XCTAssertNil(cds.qualifier("translation"))
        XCTAssertEqual(source.qualifier("translation_status"), "incomplete/unresolved")
        XCTAssertEqual(source.qualifier("trim_status"), "trimmed-to-partial-lifted-CDS")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "not-reference-ready-incomplete")
        for prefix in consequenceSummaryPrefixes {
            XCTAssertTrue(comments.contains {
                $0 == "\(prefix) unavailable: translation table 2 is unsupported"
            }, comments.joined(separator: "\n"))
        }
        XCTAssertTrue(comments.contains {
            $0.hasPrefix("Lungfish candidate reference assessment:")
        })
    }

    func testConsequenceCommentsRoundTripThroughGenBankWriterAndReader() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("candidate-consequence-roundtrip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidate = try makeCandidate(
            stableID: "candidate-roundtrip", sequenceSHA256: "roundtrip-hash",
            cigar: "4=1X4=", referenceName: "ref-roundtrip", referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAAGCT", selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-roundtrip", sequence: "ATGCAAGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )
        let original = try buildRecord(input)
        let url = root.appendingPathComponent("candidate.gb")
        try GenBankWriter(url: url).write([original])
        let parsed = try XCTUnwrap(GenBankReader(url: url).readAllSync().first)
        let comments = parsed.values(forRecordField: "COMMENT")

        XCTAssertEqual(parsed.sequence.asString(), original.sequence.asString())
        XCTAssertTrue(comments.contains { $0.contains("Lungfish CDS nonsynonymous changes: CDS-NS-1") })
        XCTAssertTrue(comments.contains { $0.contains("CDS-NS-1:") && $0.contains("p.Q2E") })
    }

    func testNonCDSExonicChangeIsReportedAsUnclassifiedNotIntronic() throws {
        let candidate = try makeCandidate(
            stableID: "candidate-utr-change", sequenceSHA256: "utr-change-hash",
            cigar: "1=1X7=", referenceName: "ref-utr-change", referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "AGGATGGCT", selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-utr-change", sequence: "ACGATGGCT",
                features: [
                    feature(type: "5'UTR", start: 0, end: 3, sourceOrdinal: 1),
                    feature(type: "exon", start: 0, end: 9, qualifiers: ["number": ["1"]], sourceOrdinal: 2),
                    feature(type: "CDS", start: 3, end: 9, sourceOrdinal: 3),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")
        XCTAssertTrue(comments.contains { $0.hasPrefix("UNCLASSIFIED-1:") && $0.contains("ref 2 C>G") && $0.contains("non-CDS exonic/UTR") }, comments.joined(separator: "\n"))
        XCTAssertFalse(comments.contains { $0.contains("candidate -") }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains { $0.hasPrefix("UNCLASSIFIED-1:") && $0.contains("outside cropped candidate ORIGIN") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("INTRON-") })
    }

    func testIntronicChangesOutsideCandidateCropUseReferenceOnlyCoordinates() throws {
        let referenceSequence = "AAACCCATGGCTTAA"
        let candidate = try makeCandidate(
            stableID: "candidate-intronic-outside-crop",
            sequenceSHA256: "candidate-intronic-outside-crop-hash",
            cigar: "1=1X1I13=",
            referenceName: "ref-intronic-outside-crop",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: "AGT" + String(referenceSequence.dropFirst(2)),
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-intronic-outside-crop", sequence: referenceSequence,
                features: [
                    feature(type: "gene", start: 0, end: 15, sourceOrdinal: 1),
                    feature(type: "intron", start: 0, end: 3, qualifiers: ["number": ["1"]], sourceOrdinal: 2),
                    feature(type: "exon", start: 6, end: 15, qualifiers: ["number": ["2"]], sourceOrdinal: 3),
                    feature(type: "CDS", start: 6, end: 15, sourceOrdinal: 4),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let record = try buildRecord(input)
        let comments = record.values(forRecordField: "COMMENT")

        XCTAssertEqual(record.sequence.asString(), "ATGGCTTAA")
        XCTAssertTrue(comments.contains {
            $0.hasPrefix("INTRON-1:")
                && $0.contains("ref 2 A>G")
                && $0.contains("outside cropped GenBank ORIGIN")
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0.hasPrefix("INTRON-2:")
                && $0.contains("1 bp insertion at ref boundary 2/3")
                && $0.contains("outside cropped GenBank ORIGIN")
        }, comments.joined(separator: "\n"))
        XCTAssertFalse(comments.contains { $0.contains("candidate -") || $0.contains("candidate 0") })
    }

    func testIntronicDeletionOutsideCandidateCropUsesExplicitReferenceOnlyCoordinate() throws {
        let referenceSequence = "AAACCCATGGCTTAA"
        let candidateSequence = String(referenceSequence.prefix(1) + referenceSequence.dropFirst(2))
        let candidate = try makeCandidate(
            stableID: "candidate-intronic-deletion-outside-crop",
            sequenceSHA256: "candidate-intronic-deletion-outside-crop-hash",
            cigar: "1=1D13=",
            referenceName: "ref-intronic-deletion-outside-crop",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-intronic-deletion-outside-crop", sequence: referenceSequence,
                features: [
                    feature(type: "gene", start: 0, end: 15, sourceOrdinal: 1),
                    feature(type: "intron", start: 0, end: 3, qualifiers: ["number": ["1"]], sourceOrdinal: 2),
                    feature(type: "exon", start: 6, end: 15, qualifiers: ["number": ["2"]], sourceOrdinal: 3),
                    feature(type: "CDS", start: 6, end: 15, sourceOrdinal: 4),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let record = try buildRecord(input)
        let comments = record.values(forRecordField: "COMMENT")

        XCTAssertEqual(record.sequence.asString(), "ATGGCTTAA")
        XCTAssertTrue(comments.contains {
            $0 == "INTRON-1: 1 bp deletion at ref 2-2; outside cropped GenBank ORIGIN; intron 1; direct CDS translation effect none; splice/regulatory impact not assessed"
        }, comments.joined(separator: "\n"))
        XCTAssertFalse(comments.contains { $0.contains("candidate -") || $0.contains("candidate 0") })
    }

    func testIntronicDeletionInsideCandidateCropReportsStoredCandidateBoundary() throws {
        let referenceSequence = "ATGCCCGCTTAA"
        let candidateSequence = String(referenceSequence.prefix(4) + referenceSequence.dropFirst(5))
        let candidate = try makeCandidate(
            stableID: "candidate-intronic-deletion-inside-crop",
            sequenceSHA256: "candidate-intronic-deletion-inside-crop-hash",
            cigar: "4=1D7=",
            referenceName: "ref-intronic-deletion-inside-crop",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-intronic-deletion-inside-crop", sequence: referenceSequence,
                features: [
                    feature(type: "gene", start: 0, end: 12, sourceOrdinal: 1),
                    feature(type: "exon", start: 0, end: 3, qualifiers: ["number": ["1"]], sourceOrdinal: 2),
                    feature(type: "intron", start: 3, end: 6, qualifiers: ["number": ["1"]], sourceOrdinal: 3),
                    feature(type: "exon", start: 6, end: 12, qualifiers: ["number": ["2"]], sourceOrdinal: 4),
                    feature(type: "CDS", start: 0, end: 3, rawGenBankLocation: "join(1..3,7..12)", sourceOrdinal: 5),
                    feature(type: "CDS", start: 6, end: 12, rawGenBankLocation: "join(1..3,7..12)", sourceOrdinal: 5),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let record = try buildRecord(input)
        let comments = record.values(forRecordField: "COMMENT")

        XCTAssertEqual(record.sequence.asString(), candidateSequence)
        XCTAssertTrue(comments.contains {
            $0 == "INTRON-1: 1 bp deletion at ref 5-5; candidate boundary 4/5; intron 1; direct CDS translation effect none; splice/regulatory impact not assessed"
        }, comments.joined(separator: "\n"))
    }

    func testCodingDeletionDisjointFromIntronDoesNotConstructInvalidOverlapRange() throws {
        let referenceSequence = "ATGCCCGCTTAA"
        let candidateSequence = String(referenceSequence.dropFirst())
        let candidate = try makeCandidate(
            stableID: "candidate-coding-deletion-before-intron",
            sequenceSHA256: "candidate-coding-deletion-before-intron-hash",
            cigar: "1D11=",
            referenceName: "ref-coding-deletion-before-intron",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-coding-deletion-before-intron", sequence: referenceSequence,
                features: [
                    feature(type: "gene", start: 0, end: 12, sourceOrdinal: 1),
                    feature(type: "exon", start: 0, end: 3, qualifiers: ["number": ["1"]], sourceOrdinal: 2),
                    feature(type: "intron", start: 3, end: 6, qualifiers: ["number": ["1"]], sourceOrdinal: 3),
                    feature(type: "exon", start: 6, end: 12, qualifiers: ["number": ["2"]], sourceOrdinal: 4),
                    feature(type: "CDS", start: 0, end: 3, rawGenBankLocation: "join(1..3,7..12)", sourceOrdinal: 5),
                    feature(type: "CDS", start: 6, end: 12, rawGenBankLocation: "join(1..3,7..12)", sourceOrdinal: 5),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        XCTAssertTrue(comments.contains {
            $0.hasPrefix("CDS-NS-1:") && $0.contains("1 bp deletion at ref 1-1")
        }, comments.joined(separator: "\n"))
        XCTAssertFalse(comments.contains { $0.hasPrefix("INTRON-") })
    }

    func testCandidateOriginCropsTerminalUTRsRetainsIntronsAndRebasesFeaturesAndConsequences() throws {
        let referenceSequence = "GGGATGAAACCCTTTGCTTAACCC"
        var candidateBases = Array(referenceSequence)
        candidateBases[12] = "C"
        let fullCandidateSequence = String(candidateBases)
        let candidate = try makeCandidate(
            stableID: "candidate-trimmed-forward",
            sequenceSHA256: sha256Hex(fullCandidateSequence),
            cigar: "3S9=1X8=3S",
            referenceName: "ref-trimmed-forward",
            referenceClass: .genomicDNA,
            referenceStart: 4
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: fullCandidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-trimmed-forward",
                sequence: referenceSequence,
                features: [
                    feature(type: "gene", start: 0, end: 24, sourceOrdinal: 1),
                    feature(type: "exon", start: 0, end: 9, qualifiers: ["number": ["1"]], sourceOrdinal: 2),
                    feature(type: "exon", start: 12, end: 24, qualifiers: ["number": ["2"]], sourceOrdinal: 3),
                    feature(type: "intron", start: 9, end: 12, qualifiers: ["number": ["1"]], sourceOrdinal: 4),
                    feature(type: "5'UTR", start: 0, end: 3, sourceOrdinal: 5),
                    feature(type: "3'UTR", start: 21, end: 24, sourceOrdinal: 6),
                    feature(type: "CDS", start: 3, end: 9, rawGenBankLocation: "join(4..9,13..21)", sourceOrdinal: 7),
                    feature(type: "CDS", start: 12, end: 21, rawGenBankLocation: "join(4..9,13..21)", sourceOrdinal: 7),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)
        let record = result.record
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))
        let comments = record.values(forRecordField: "COMMENT")
        let expectedOrigin = String(fullCandidateSequence.dropFirst(3).prefix(18))

        XCTAssertEqual(result.rawSequence, fullCandidateSequence)
        XCTAssertEqual(result.externalSequence, expectedOrigin)
        XCTAssertEqual(result.trimRange, 3..<21)
        XCTAssertEqual(result.translationStatus, .fullLength)
        XCTAssertEqual(result.referenceReadiness, .referenceReady)
        XCTAssertEqual(record.sequence.asString(), expectedOrigin)
        XCTAssertEqual(record.locus.length, 18)
        XCTAssertEqual(source.intervals.map { [$0.start, $0.end] }, [[0, 18]])
        XCTAssertEqual(cds.intervals.map { [$0.start, $0.end] }, [[0, 6], [9, 18]])
        XCTAssertEqual(record.annotations.filter { $0.type == .intron }.map { [$0.start, $0.end] }, [[6, 9]])
        XCTAssertFalse(record.annotations.contains { $0.type == .utr5 || $0.type == .utr3 })
        XCTAssertEqual(source.qualifier("sequence_sha256"), sha256Hex(fullCandidateSequence))
        XCTAssertEqual(source.qualifier("original_sequence_length"), "24")
        XCTAssertEqual(source.qualifier("trim_start"), "4")
        XCTAssertEqual(source.qualifier("trim_end"), "21")
        XCTAssertEqual(source.qualifier("genbank_sequence_sha256"), sha256Hex(expectedOrigin))
        XCTAssertEqual(source.qualifier("trim_status"), "trimmed-to-outer-lifted-CDS")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "reference-ready")
        XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-NS-1:") && $0.contains("candidate 10") }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0.contains("outer lifted CDS span; original length=24; trim start=4; trim end=21; retained length=18")
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains("Lungfish GenBank sequence SHA-256: " + sha256Hex(expectedOrigin)))
    }

    func testReverseCandidateCropUsesStoredOrientationCoordinates() throws {
        let referenceSequence = "GGATGCAAGCTCCCA"
        let fullCandidateSequence = TranslationEngine.reverseComplement(referenceSequence)
        let candidate = try makeCandidate(
            stableID: "candidate-trimmed-reverse",
            sequenceSHA256: sha256Hex(fullCandidateSequence),
            cigar: "2S9=4S",
            referenceName: "ref-trimmed-reverse",
            referenceClass: .genomicDNA,
            referenceStart: 3
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: fullCandidateSequence,
            selectedAlignmentIsReverse: true,
            closestReference: makeReference(
                id: "ref-trimmed-reverse", sequence: referenceSequence,
                features: [feature(type: "CDS", start: 2, end: 11)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)
        let record = result.record
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        XCTAssertEqual(result.rawSequence, fullCandidateSequence)
        XCTAssertEqual(result.externalSequence, String(fullCandidateSequence.dropFirst(4).prefix(9)))
        XCTAssertEqual(result.trimRange, 4..<13)
        XCTAssertEqual(result.translationStatus, .fullLength)
        XCTAssertEqual(result.referenceReadiness, .referenceReady)
        XCTAssertEqual(record.sequence.asString(), String(fullCandidateSequence.dropFirst(4).prefix(9)))
        XCTAssertEqual(source.qualifier("trim_start"), "5")
        XCTAssertEqual(source.qualifier("trim_end"), "13")
        XCTAssertEqual(record.annotations.first(where: { $0.type == .cds })?.intervals.map { [$0.start, $0.end] }, [[0, 9]])
    }

    func testLeadingTerminalSoftClipRescuesCompleteCDSAndCountsTerminalSNP() throws {
        let referenceSequence = "GGGATGCCAAAT"
        let candidateSequence = "GGATGCGAAATTT"
        let candidate = try makeCandidate(
            stableID: "candidate-leading-terminal-rescue",
            sequenceSHA256: sha256Hex(candidateSequence),
            cigar: "7S4=2S",
            referenceName: "ref-leading-terminal-rescue",
            referenceClass: .genomicDNA,
            referenceStart: 9
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-leading-terminal-rescue",
                sequence: referenceSequence,
                features: [feature(type: "CDS", start: 3, end: referenceSequence.count)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)

        XCTAssertEqual(result.externalSequence, "ATGCGAAAT")
        XCTAssertEqual(result.trimRange, 2..<11)
        XCTAssertEqual(result.referenceReadiness, .referenceReady)
        XCTAssertEqual(result.substitutionCount, 1)
        XCTAssertEqual(result.comparableBases, 9)
        XCTAssertEqual(result.identity, 8.0 / 9.0, accuracy: 0.000_001)
        XCTAssertEqual(result.shorterCoverage, 1, accuracy: 0.000_001)
        XCTAssertTrue(result.record.values(forRecordField: "COMMENT").contains {
            $0 == "Lungfish terminal local-clipping rescue: leading reference bases=5; trailing reference bases=0; rescued substitutions=1; eligibility=single terminal CDS interval, canonical A/C/G/T, missing bases < 20, mismatches <= max(1,floor(0.20*missing bases)); rescue mode=substitution-only (no indel inference); selected POS/CIGAR/NM/AS evidence retained unchanged"
        })
    }

    func testTrailingTerminalSoftClipRescuesCompleteCDS() throws {
        let referenceSequence = "ATGCCAAATGGG"
        let candidateSequence = "GGATGCCAAATTT"
        let candidate = try makeCandidate(
            stableID: "candidate-trailing-terminal-rescue",
            sequenceSHA256: sha256Hex(candidateSequence),
            cigar: "2S4=7S",
            referenceName: "ref-trailing-terminal-rescue",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-trailing-terminal-rescue",
                sequence: referenceSequence,
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)

        XCTAssertEqual(result.externalSequence, "ATGCCAAAT")
        XCTAssertEqual(result.trimRange, 2..<11)
        XCTAssertEqual(result.referenceReadiness, .referenceReady)
        XCTAssertEqual(result.substitutionCount, 0)
        XCTAssertEqual(result.comparableBases, 9)
        XCTAssertEqual(result.identity, 1)
        XCTAssertEqual(result.shorterCoverage, 1, accuracy: 0.000_001)
        XCTAssertTrue(result.record.values(forRecordField: "COMMENT").contains {
            $0 == "Lungfish terminal local-clipping rescue: leading reference bases=0; trailing reference bases=5; rescued substitutions=0; eligibility=single terminal CDS interval, canonical A/C/G/T, missing bases < 20, mismatches <= max(1,floor(0.20*missing bases)); rescue mode=substitution-only (no indel inference); selected POS/CIGAR/NM/AS evidence retained unchanged"
        })
    }

    func testCanonicalSubstitutionCountExcludesTerminalUTRChanges() throws {
        let referenceSequence = "AATGGCTTAAT"
        let candidateSequence = "CATGGCTTAAG"
        let candidate = try makeCandidate(
            stableID: "candidate-terminal-utr-substitutions",
            sequenceSHA256: sha256Hex(candidateSequence),
            cigar: "1X9=1X",
            referenceName: "ref-terminal-utr-substitutions",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-terminal-utr-substitutions",
                sequence: referenceSequence,
                features: [
                    feature(type: "5'UTR", start: 0, end: 1, sourceOrdinal: 1),
                    feature(type: "CDS", start: 1, end: 10, sourceOrdinal: 2),
                    feature(type: "3'UTR", start: 10, end: 11, sourceOrdinal: 3),
                ]
            ),
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)

        XCTAssertEqual(result.externalSequence, "ATGGCTTAA")
        XCTAssertEqual(result.trimRange, 1..<10)
        XCTAssertEqual(result.referenceReadiness, .referenceReady)
        XCTAssertEqual(result.substitutionCount, 0)
        XCTAssertEqual(result.comparableBases, 9)
        XCTAssertEqual(result.identity, 1)
        XCTAssertEqual(result.shorterCoverage, 1)
    }

    func testCanonicalComparisonExcludesAlignedBasesBeyondObservedPartialCDS() throws {
        let referenceSequence = "ATGAAAAAAACCCGGAAAAAAAAAATTTAA"
        let baselineSequence = String(referenceSequence.dropFirst(8).prefix(12))
        var candidateBases = Array(referenceSequence.dropFirst(8).prefix(12))
        candidateBases[10] = candidateBases[10] == "A" ? "C" : "A"
        let candidateSequence = String(candidateBases)
        let candidate = try makeCandidate(
            stableID: "candidate-partial-cds-trailing-mismatch",
            sequenceSHA256: sha256Hex(candidateSequence),
            cigar: "10=1X1=",
            referenceName: "ref-partial-cds-trailing-mismatch",
            referenceClass: .genomicDNA,
            referenceStart: 9
        )
        let joinedCDS = "join(1..3,11..15,26..30)"
        let reference = makeReference(
            id: "ref-partial-cds-trailing-mismatch",
            sequence: referenceSequence,
            features: [
                feature(type: "CDS", start: 0, end: 3, rawGenBankLocation: joinedCDS, sourceOrdinal: 1),
                feature(type: "CDS", start: 10, end: 15, rawGenBankLocation: joinedCDS, sourceOrdinal: 1),
                feature(type: "CDS", start: 25, end: 30, rawGenBankLocation: joinedCDS, sourceOrdinal: 1),
            ]
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: reference,
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)
        let baseline = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: .init(
            subject: .candidate(makeCandidate(
                stableID: "candidate-partial-cds-baseline",
                sequenceSHA256: sha256Hex(baselineSequence),
                cigar: "12=",
                referenceName: "ref-partial-cds-trailing-mismatch",
                referenceClass: .genomicDNA,
                referenceStart: 9
            )),
            sequence: baselineSequence,
            selectedAlignmentIsReverse: false,
            closestReference: reference,
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20
        ))

        XCTAssertEqual(result.externalSequence, String(candidateSequence.dropFirst(2).prefix(5)))
        XCTAssertEqual(result.externalSequence, baseline.externalSequence)
        XCTAssertEqual(result.trimRange, 2..<7)
        XCTAssertEqual(result.substitutionCount, 0)
        XCTAssertEqual(result.substitutionCount, baseline.substitutionCount)
        XCTAssertEqual(result.comparableBases, 5)
        XCTAssertEqual(result.comparableBases, baseline.comparableBases)
        XCTAssertEqual(result.identity, 1)
        XCTAssertEqual(result.shorterCoverage, 1)
    }

    func testReverseCanonicalComparisonUsesStoredCoordinatesForPartialCDSCrop() throws {
        let referenceSequence = "ATGAAAAAAACCCGGAAAAAAAAAATTTAA"
        let baselineOriented = String(referenceSequence.dropFirst(8).prefix(12))
        var changedOrientedBases = Array(baselineOriented)
        changedOrientedBases[8] = changedOrientedBases[8] == "A" ? "C" : "A"
        let changedStored = TranslationEngine.reverseComplement(String(changedOrientedBases))
        let baselineStored = TranslationEngine.reverseComplement(baselineOriented)
        let joinedCDS = "join(1..3,11..15,26..30)"
        let reference = makeReference(
            id: "ref-reverse-partial-cds-trailing-mismatch",
            sequence: referenceSequence,
            features: [
                feature(type: "CDS", start: 0, end: 3, rawGenBankLocation: joinedCDS, sourceOrdinal: 1),
                feature(type: "CDS", start: 10, end: 15, rawGenBankLocation: joinedCDS, sourceOrdinal: 1),
                feature(type: "CDS", start: 25, end: 30, rawGenBankLocation: joinedCDS, sourceOrdinal: 1),
            ]
        )
        let builder = FullLengthONTMHCCandidateGenBankArtifactBuilder()
        let changed = try builder.build(from: .init(
            subject: .candidate(makeCandidate(
                stableID: "candidate-reverse-partial-cds-trailing-mismatch",
                sequenceSHA256: sha256Hex(changedStored),
                cigar: "8=1X3=",
                referenceName: reference.rawReferenceID,
                referenceClass: .genomicDNA,
                referenceStart: 9
            )),
            sequence: changedStored,
            selectedAlignmentIsReverse: true,
            closestReference: reference,
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20
        ))
        let baseline = try builder.build(from: .init(
            subject: .candidate(makeCandidate(
                stableID: "candidate-reverse-partial-cds-baseline",
                sequenceSHA256: sha256Hex(baselineStored),
                cigar: "12=",
                referenceName: reference.rawReferenceID,
                referenceClass: .genomicDNA,
                referenceStart: 9
            )),
            sequence: baselineStored,
            selectedAlignmentIsReverse: true,
            closestReference: reference,
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20
        ))

        XCTAssertEqual(changed.trimRange, 5..<10)
        XCTAssertEqual(changed.externalSequence, baseline.externalSequence)
        XCTAssertEqual(changed.substitutionCount, 0)
        XCTAssertEqual(changed.substitutionCount, baseline.substitutionCount)
        XCTAssertEqual(changed.comparableBases, 5)
        XCTAssertEqual(changed.comparableBases, baseline.comparableBases)
        XCTAssertEqual(changed.identity, 1)
    }

    func testInsufficientTerminalSoftClipDoesNotRescuePartialCDS() throws {
        let referenceSequence = "ATGCAAGCT"
        let candidateSequence = "TTCAAGCT"
        let candidate = try makeCandidate(
            stableID: "candidate-insufficient-terminal-rescue",
            sequenceSHA256: sha256Hex(candidateSequence),
            cigar: "2S6=",
            referenceName: "ref-insufficient-terminal-rescue",
            referenceClass: .genomicDNA,
            referenceStart: 4
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-insufficient-terminal-rescue",
                sequence: referenceSequence,
                features: [feature(type: "CDS", start: 0, end: referenceSequence.count)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)

        XCTAssertEqual(result.externalSequence, "CAAGCT")
        XCTAssertEqual(result.referenceReadiness, .incomplete)
        XCTAssertEqual(result.substitutionCount, 0)
        XCTAssertFalse(result.record.values(forRecordField: "COMMENT").contains {
            $0.hasPrefix("Lungfish terminal local-clipping rescue:")
        })
    }

    func testLongMissingTerminalCDSRangeDoesNotRescueEvenWithAmpleSoftClip() throws {
        let referenceSequence = String(repeating: "A", count: 25)
        let candidateSequence = referenceSequence
        let candidate = try makeCandidate(
            stableID: "candidate-long-terminal-gap",
            sequenceSHA256: sha256Hex(candidateSequence),
            cigar: "20S5=",
            referenceName: "ref-long-terminal-gap",
            referenceClass: .genomicDNA,
            referenceStart: 21
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-long-terminal-gap", sequence: referenceSequence,
                features: [feature(type: "CDS", start: 0, end: referenceSequence.count)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)

        XCTAssertEqual(result.externalSequence, "AAAAA")
        XCTAssertEqual(result.referenceReadiness, .incomplete)
        XCTAssertFalse(result.record.values(forRecordField: "COMMENT").contains {
            $0.hasPrefix("Lungfish terminal local-clipping rescue:")
        })
    }

    func testAmbiguousTerminalSoftClipBaseDoesNotRescue() throws {
        let referenceSequence = "ATGCCAAAT"
        let candidateSequence = "ATGCNAAAT"
        let candidate = try makeCandidate(
            stableID: "candidate-ambiguous-terminal-gap",
            sequenceSHA256: sha256Hex(candidateSequence),
            cigar: "5S4=",
            referenceName: "ref-ambiguous-terminal-gap",
            referenceClass: .genomicDNA,
            referenceStart: 6
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-ambiguous-terminal-gap", sequence: referenceSequence,
                features: [feature(type: "CDS", start: 0, end: referenceSequence.count)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)

        XCTAssertEqual(result.externalSequence, "AAAT")
        XCTAssertEqual(result.referenceReadiness, .incomplete)
    }

    func testTerminalHardClipDoesNotRescue() throws {
        let referenceSequence = "GGGATGCCAAAT"
        let candidateSequence = "NNNNNAAAT"
        let candidate = try makeCandidate(
            stableID: "candidate-hard-clipped-terminal-gap",
            sequenceSHA256: sha256Hex(candidateSequence),
            cigar: "5H4=",
            referenceName: "ref-hard-clipped-terminal-gap",
            referenceClass: .genomicDNA,
            referenceStart: 9
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-hard-clipped-terminal-gap", sequence: referenceSequence,
                features: [feature(type: "CDS", start: 3, end: referenceSequence.count)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)

        XCTAssertEqual(result.externalSequence, "AAAT")
        XCTAssertEqual(result.referenceReadiness, .incomplete)
        XCTAssertFalse(result.record.values(forRecordField: "COMMENT").contains {
            $0.hasPrefix("Lungfish terminal local-clipping rescue:")
        })
    }

    func testTerminalSoftClipAboveMismatchAllowanceDoesNotRescue() throws {
        let referenceSequence = "ATGCCAAAT"
        let candidateSequence = "ATGAAAAAT"
        let candidate = try makeCandidate(
            stableID: "candidate-terminal-mismatch-ratio",
            sequenceSHA256: sha256Hex(candidateSequence),
            cigar: "5S4=",
            referenceName: "ref-terminal-mismatch-ratio",
            referenceClass: .genomicDNA,
            referenceStart: 6
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: candidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-terminal-mismatch-ratio", sequence: referenceSequence,
                features: [feature(type: "CDS", start: 0, end: referenceSequence.count)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)

        XCTAssertEqual(result.externalSequence, "AAAT")
        XCTAssertEqual(result.referenceReadiness, .incomplete)
        XCTAssertFalse(result.record.values(forRecordField: "COMMENT").contains {
            $0.hasPrefix("Lungfish terminal local-clipping rescue:")
        })
    }

    func testReverseOrientationTerminalSoftClipRescueUsesOrientedQuery() throws {
        let referenceSequence = "ATGCCAAAT"
        let orientedCandidate = "GGATGCGAAATTT"
        let storedCandidate = TranslationEngine.reverseComplement(orientedCandidate)
        let candidate = try makeCandidate(
            stableID: "candidate-reverse-terminal-rescue",
            sequenceSHA256: sha256Hex(storedCandidate),
            cigar: "7S4=2S",
            referenceName: "ref-reverse-terminal-rescue",
            referenceClass: .genomicDNA,
            referenceStart: 6
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: storedCandidate,
            selectedAlignmentIsReverse: true,
            closestReference: makeReference(
                id: "ref-reverse-terminal-rescue",
                sequence: referenceSequence,
                features: [feature(type: "CDS", start: 0, end: referenceSequence.count)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)

        XCTAssertEqual(
            result.externalSequence,
            TranslationEngine.reverseComplement("ATGCGAAAT")
        )
        XCTAssertEqual(result.trimRange, 2..<11)
        XCTAssertEqual(result.referenceReadiness, .referenceReady)
        XCTAssertEqual(result.substitutionCount, 1)
    }

    func testPartialLiftedCDSPublishesObservedSequenceAndDocumentsMissingReferenceFeatures() throws {
        let fullCandidateSequence = "TTCAAGCTGG"
        let candidate = try makeCandidate(
            stableID: "candidate-trimmed-partial",
            sequenceSHA256: sha256Hex(fullCandidateSequence),
            cigar: "2S6=2S",
            referenceName: "ref-trimmed-partial",
            referenceClass: .genomicDNA,
            referenceStart: 4
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: fullCandidateSequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-trimmed-partial", sequence: "ATGCAAGCT",
                features: [
                    feature(
                        type: "exon", start: 0, end: 2,
                        qualifiers: ["number": ["1"]], sourceOrdinal: 1
                    ),
                    feature(
                        type: "intron", start: 2, end: 5,
                        qualifiers: ["number": ["1"]], sourceOrdinal: 2
                    ),
                    feature(
                        type: "exon", start: 5, end: 9,
                        qualifiers: ["number": ["2"]], sourceOrdinal: 3
                    ),
                    feature(type: "CDS", start: 0, end: 9, sourceOrdinal: 4),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)
        let record = result.record
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        XCTAssertEqual(result.rawSequence, fullCandidateSequence)
        XCTAssertEqual(result.externalSequence, "CAAGCT")
        XCTAssertEqual(result.trimRange, 2..<8)
        XCTAssertEqual(result.translationStatus, .incompleteUnresolved)
        XCTAssertEqual(result.referenceReadiness, .incomplete)
        XCTAssertEqual(record.sequence.asString(), "CAAGCT")
        XCTAssertEqual(source.qualifier("translation_status"), "incomplete/unresolved")
        XCTAssertEqual(source.qualifier("trim_status"), "trimmed-to-partial-lifted-CDS")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "not-reference-ready-incomplete")
        let comments = record.values(forRecordField: "COMMENT")
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish partial reference coverage: observed reference interval 4..9 of 9 bases"
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish missing terminal reference sequence: leading=3 bases; trailing=0 bases"
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish annotated reference features absent from observed sequence: exon 1"
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish annotated reference features partially observed: intron 1 (2 of 3 bases observed; 1 missing)"
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish partial candidate sequence contains observed bases only; missing reference bases were not imputed"
        }, comments.joined(separator: "\n"))
        XCTAssertEqual(source.qualifier("observed_reference_start"), "4")
        XCTAssertEqual(source.qualifier("observed_reference_end"), "9")
        XCTAssertEqual(source.qualifier("reference_sequence_length"), "9")
        XCTAssertEqual(source.qualifier("missing_leading_reference_bases"), "3")
        XCTAssertEqual(source.qualifier("missing_trailing_reference_bases"), "0")
        XCTAssertEqual(source.qualifier("missing_reference_features"), "exon 1")
        XCTAssertEqual(
            source.qualifier("partially_observed_reference_features"),
            "intron 1 (2 of 3 bases observed; 1 missing)"
        )
        XCTAssertEqual(
            try FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).count,
            1
        )
    }

    func testCandidateWithoutLiftedCDSRemainsUntrimmedAndExplicitlyUnavailable() throws {
        let sequence = "AACCGGTT"
        let candidate = try makeCandidate(
            stableID: "candidate-untrimmed-no-cds",
            sequenceSHA256: sha256Hex(sequence),
            cigar: "8=",
            referenceName: "ref-untrimmed-no-cds",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: sequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(id: "ref-untrimmed-no-cds", sequence: sequence, features: []),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)
        let record = result.record
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        XCTAssertEqual(result.rawSequence, sequence)
        XCTAssertNil(result.externalSequence)
        XCTAssertNil(result.trimRange)
        XCTAssertEqual(result.translationStatus, .incompleteUnresolved)
        XCTAssertEqual(result.referenceReadiness, .unavailable)
        XCTAssertEqual(record.sequence.asString(), sequence)
        XCTAssertEqual(source.qualifier("trim_start"), "1")
        XCTAssertEqual(source.qualifier("trim_end"), "8")
        XCTAssertEqual(source.qualifier("trim_status"), "unavailable-no-lifted-CDS")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "not-reference-ready-unavailable")
        XCTAssertTrue(record.values(forRecordField: "COMMENT").contains { $0.contains("UTR trimming unavailable") && $0.contains("no lifted CDS") })
        XCTAssertTrue(try FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).isEmpty)
    }

    func testShortCatalogReferenceDocumentsCoverageThatCannotBeAssessed() throws {
        let sequence = "ATGCAAGCT"
        let candidate = try makeCandidate(
            stableID: "candidate-short-catalog-reference",
            sequenceSHA256: sha256Hex(sequence),
            cigar: "9=",
            referenceName: "ref-short-catalog",
            referenceClass: .genomicDNA
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate),
            sequence: sequence,
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-short-catalog", sequence: sequence,
                features: [feature(type: "CDS", start: 0, end: sequence.count)]
            ),
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20,
            referenceCatalogCoverage: .init(
                selectedReferenceLength: 9,
                longestSameLocusGenomicReferenceLength: 18
            )
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)
        let source = try XCTUnwrap(result.record.annotations.first(where: { $0.type == .source }))
        XCTAssertEqual(result.referenceReadiness, .referenceReady)
        XCTAssertTrue(result.record.values(forRecordField: "COMMENT").contains {
            $0 == "Lungfish closest-reference catalog coverage: selected genomic reference record spans 9 bases; same-locus genomic records span up to 18 bases; sequence outside the selected reference record cannot be assessed"
        })
        XCTAssertEqual(source.qualifier("selected_reference_length"), "9")
        XCTAssertEqual(source.qualifier("longest_same_locus_reference_length"), "18")
        XCTAssertEqual(source.qualifier("outside_selected_reference_coverage"), "unassessed")
    }

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

        let record = try buildRecord(input)
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

        let record = try buildRecord(input)
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

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)
        let record = result.record
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))

        XCTAssertEqual(result.externalSequence, "ATGTAGGCT")
        XCTAssertEqual(result.trimRange, 0..<9)
        XCTAssertEqual(result.translationStatus, .pseudogene)
        XCTAssertEqual(result.referenceReadiness, .referenceReady)
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

        let record = try buildRecord(input)
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

        let record = try buildRecord(input)
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

            let record = try buildRecord(input)
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

        let record = try buildRecord(input)
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))

        XCTAssertEqual(record.sequence.asString(), "ATGGCTTAA")
        XCTAssertEqual(cds.intervals.map { [$0.start, $0.end] }, [[0, 9]])
        XCTAssertEqual(cds.qualifier("translation"), "MA")
    }

    func testNoAlignmentUnnameableBuildRetainsDiagnosticRecordButCompatibilityWrapperOmitsIt() throws {
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

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)
        let record = result.record

        XCTAssertEqual(record.annotations.map(\.type), [.source])
        XCTAssertEqual(result.rawSequence, "ACGT")
        XCTAssertNil(result.externalSequence)
        XCTAssertNil(result.trimRange)
        XCTAssertEqual(result.translationStatus, .incompleteUnresolved)
        XCTAssertEqual(result.referenceReadiness, .unavailable)
        XCTAssertTrue(try FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).isEmpty)
        XCTAssertEqual(sourceTranslationStatus(record), "incomplete/unresolved")
        let comments = record.values(forRecordField: "COMMENT")
        XCTAssertTrue(comments.contains("Lungfish project: Primate Cohort.lungfish"))
        XCTAssertTrue(comments.contains { $0.contains("Sample-A, Sample-B") })
        XCTAssertTrue(comments.contains { $0.contains("annotation unavailable: no selected reciprocal alignment") })
        XCTAssertFalse(comments.contains { comment in
            consequenceSummaryPrefixes.contains { comment.hasPrefix($0) }
        })
        XCTAssertEqual(record.annotations[0].qualifier("trim_status"), "unavailable-no-lifted-CDS")
        XCTAssertEqual(
            record.annotations[0].qualifier("reference_readiness_status"),
            "not-reference-ready-unavailable"
        )
        XCTAssertEqual(record.sequence.asString(), "ACGT")
    }

    func testUnnameableWithoutExternalSequenceIdentityFailsClosed() throws {
        let reciprocal = try ONTMHCReciprocalQueryHitSummary(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "unnameable-internal-only",
            alignmentCount: 0,
            targetAlignmentCounts: [:],
            exactMatchTargetNames: [],
            closestMatchTargetNames: []
        )
        let unnameable = ONTMHCUnnameableRecord(
            stableClusterID: "unnameable-internal-only",
            reason: .noAlignment,
            failedMetrics: [:],
            supportClass: .singleton,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 4,
            supportingSampleIDs: ["Sample-A"],
            fastaRecordID: nil,
            sequenceSHA256: nil,
            reciprocalHitSummary: reciprocal,
            selectedEvidence: nil
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .unnameable(unnameable),
            sequence: "ACGT",
            selectedAlignmentIsReverse: nil,
            closestReference: nil,
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 50
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)

        XCTAssertEqual(result.record.sequence.name, "unnameable-internal-only")
        XCTAssertEqual(result.rawSequence, "ACGT")
        XCTAssertNil(result.externalSequence)
        XCTAssertNil(result.trimRange)
        XCTAssertEqual(result.referenceReadiness, .unavailable)
        XCTAssertTrue(try FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).isEmpty)
    }

    func testReferenceReadyUnnameableWithoutPairedExternalIdentityRemainsDiagnosticOnly() throws {
        let evidence = ONTMHCEvidenceLocator(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "unnameable-ready-internal-only",
            referenceName: "ref-unnameable-ready-internal-only",
            readGroupID: nil,
            referenceStart: 1,
            cigar: "2S6=2S"
        )
        let reciprocal = try ONTMHCReciprocalQueryHitSummary(
            bamPath: evidence.bamPath,
            queryName: evidence.queryName,
            alignmentCount: 1,
            targetAlignmentCounts: [evidence.referenceName: 1],
            exactMatchTargetNames: [evidence.referenceName],
            closestMatchTargetNames: [evidence.referenceName]
        )
        let unnameable = ONTMHCUnnameableRecord(
            stableClusterID: "unnameable-ready-internal-only",
            reason: .unresolvedLocus,
            failedMetrics: [:],
            supportClass: .singleton,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 4,
            supportingSampleIDs: ["Sample-A"],
            fastaRecordID: nil,
            sequenceSHA256: nil,
            reciprocalHitSummary: reciprocal,
            selectedEvidence: evidence
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .unnameable(unnameable),
            sequence: "CCATGGCTAA",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: evidence.referenceName,
                sequence: "ATGGCT",
                features: [feature(type: "CDS", start: 0, end: 6)]
            ),
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20
        )

        let builder = FullLengthONTMHCCandidateGenBankArtifactBuilder()
        let result = try builder.build(from: input)
        let source = try XCTUnwrap(result.record.annotations.first(where: { $0.type == .source }))
        let comments = result.record.values(forRecordField: "COMMENT")

        XCTAssertEqual(result.rawSequence, "CCATGGCTAA")
        XCTAssertNil(result.externalSequence)
        XCTAssertEqual(result.trimRange, 2..<8)
        XCTAssertEqual(result.translationStatus, .fullLength)
        XCTAssertEqual(result.referenceReadiness, .referenceReady)
        XCTAssertEqual(result.record.sequence.name, "unnameable-ready-internal-only")
        XCTAssertEqual(result.record.sequence.asString(), "CCATGGCTAA")
        XCTAssertEqual(source.qualifier("stable_cluster_id"), "unnameable-ready-internal-only")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "reference-ready")
        XCTAssertEqual(source.qualifier("trim_status"), "not-exported-missing-external-identity")
        XCTAssertTrue(comments.contains {
            $0.contains("paired external FASTA identity and checksum are unavailable")
        })
        XCTAssertTrue(try builder.records(from: [input]).isEmpty)
    }

    func testPartialUnnameableRetainsRawDiagnosticButHasNoExternalSequence() throws {
        let evidence = ONTMHCEvidenceLocator(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "unnameable-partial",
            referenceName: "ref-unnameable-partial",
            readGroupID: nil,
            referenceStart: 4,
            cigar: "2S6=2S"
        )
        let reciprocal = try ONTMHCReciprocalQueryHitSummary(
            bamPath: evidence.bamPath,
            queryName: evidence.queryName,
            alignmentCount: 1,
            targetAlignmentCounts: [evidence.referenceName: 1],
            exactMatchTargetNames: [],
            closestMatchTargetNames: [evidence.referenceName]
        )
        let unnameable = ONTMHCUnnameableRecord(
            stableClusterID: "unnameable-partial",
            reason: .unresolvedLocus,
            failedMetrics: [:],
            supportClass: .singleton,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 4,
            supportingSampleIDs: ["Sample-A"],
            fastaRecordID: "unnameable-partial",
            sequenceSHA256: "unnameable-partial-hash",
            reciprocalHitSummary: reciprocal,
            selectedEvidence: evidence
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .unnameable(unnameable),
            sequence: "TTCAAGCTGG",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: evidence.referenceName,
                sequence: "ATGCAAGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run",
            projectBundleName: nil,
            minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)
        let source = try XCTUnwrap(result.record.annotations.first(where: { $0.type == .source }))

        XCTAssertEqual(result.rawSequence, "TTCAAGCTGG")
        XCTAssertNil(result.externalSequence)
        XCTAssertEqual(result.trimRange, 2..<8)
        XCTAssertEqual(result.translationStatus, .incompleteUnresolved)
        XCTAssertEqual(result.referenceReadiness, .incomplete)
        XCTAssertEqual(result.record.sequence.asString(), "TTCAAGCTGG")
        XCTAssertEqual(source.qualifier("trim_status"), "not-exported-partial-lifted-CDS")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "not-reference-ready-incomplete")
        XCTAssertTrue(try FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).isEmpty)
    }

    func testAnnotatedUnnameableKeepsBoundaryCoverageTranslationStatusAndPriorFeatureShape() throws {
        let evidence = ONTMHCEvidenceLocator(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "unnameable-annotated",
            referenceName: "ref-unnameable-annotated",
            readGroupID: nil,
            referenceStart: 1,
            cigar: "2S3=3N3=2S"
        )
        let reciprocal = try ONTMHCReciprocalQueryHitSummary(
            bamPath: evidence.bamPath,
            queryName: evidence.queryName,
            alignmentCount: 1,
            targetAlignmentCounts: [evidence.referenceName: 1],
            exactMatchTargetNames: [evidence.referenceName],
            closestMatchTargetNames: [evidence.referenceName]
        )
        let unnameable = ONTMHCUnnameableRecord(
            stableClusterID: "unnameable-annotated",
            reason: .unresolvedLocus,
            failedMetrics: [:],
            supportClass: .singleton,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 4,
            supportingSampleIDs: ["Sample-A"],
            fastaRecordID: "unnameable-annotated",
            sequenceSHA256: "unnameable-annotated-hash",
            reciprocalHitSummary: reciprocal,
            selectedEvidence: evidence
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .unnameable(unnameable), sequence: "CCATGGCTAA",
            selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: evidence.referenceName, sequence: "ATGAAAGCT",
                features: [
                    feature(type: "gene", start: 0, end: 9, sourceOrdinal: 1),
                    feature(type: "exon", start: 0, end: 3, sourceOrdinal: 2),
                    feature(type: "intron", start: 3, end: 6, sourceOrdinal: 3),
                    feature(type: "exon", start: 6, end: 9, sourceOrdinal: 4),
                    feature(type: "CDS", start: 0, end: 9, sourceOrdinal: 5),
                ]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input)
        let record = result.record
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))
        let comments = record.values(forRecordField: "COMMENT")

        XCTAssertEqual(result.rawSequence, "CCATGGCTAA")
        XCTAssertEqual(result.externalSequence, "ATGGCT")
        XCTAssertEqual(result.trimRange, 2..<8)
        XCTAssertEqual(result.translationStatus, .fullLength)
        XCTAssertEqual(result.referenceReadiness, .referenceReady)
        XCTAssertEqual(record.annotations.map(\.type), [.source, .gene, .exon, .exon, .cds])
        XCTAssertFalse(record.annotations.contains { $0.type == .intron })
        XCTAssertEqual(record.sequence.asString(), "ATGGCT")
        XCTAssertEqual(cds.intervals.map { [$0.start, $0.end] }, [[0, 6]])
        XCTAssertEqual(cds.qualifier("translation"), "MA")
        XCTAssertEqual(cds.qualifier("inference"), "alignment:reciprocal minimap2 CIGAR")
        XCTAssertEqual(source.qualifier("translation_status"), "full-length")
        XCTAssertEqual(source.qualifier("trim_status"), "trimmed-to-outer-lifted-CDS")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "reference-ready")
        XCTAssertFalse(comments.contains { comment in
            consequenceSummaryPrefixes.contains { comment.hasPrefix($0) }
        })
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
        let reference = makeReference(
            id: "ref",
            sequence: "ACGT",
            features: [feature(type: "CDS", start: 0, end: 4)]
        )
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

    func testExtensionRecordCommentsPersistCDNAAndSelectedGenomicInterpretations() throws {
        let interpretation = ONTMHCCDNAExtensionInterpretation(
            rawReferenceID: "ref-cdna", alleleName: "Mafa-A1*002", locus: "Mafa-A1",
            cDNAReferenceCoverage: 1, clusterCoverage: 0.5,
            leadingClusterFlankBases: 100, trailingClusterFlankBases: 100,
            largestClusterStructuralSegmentBases: 100, largestCDNADeficitSegmentBases: 0,
            snpSubstitutions: 0, ordinaryIndelBases: 0, isReverse: false,
            alignmentScore: 1_000, identity: 1
        )
        let candidate = try makeCandidate(
            stableID: "extension-a", sequenceSHA256: "hash", cigar: "3=1X5=",
            referenceName: "ref-genomic", referenceClass: .genomicDNA,
            classification: .extension, extensionOf: ["Mafa-A1*002"],
            extensionInterpretations: [interpretation]
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAAGCT", selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-genomic",
                sequence: "ATGCAAGCT",
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extension-comment-roundtrip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = try buildRecord(input)
        let url = root.appendingPathComponent("extension.gb")
        try GenBankWriter(url: url).write([original])
        let parsed = try XCTUnwrap(GenBankReader(url: url).readAllSync().first)
        let comments = parsed.values(forRecordField: "COMMENT")

        XCTAssertEqual(parsed.sequence.asString(), original.sequence.asString())
        XCTAssertTrue(comments.contains { $0 == "Lungfish extension of: Mafa-A1*002" })
        XCTAssertTrue(comments.contains {
            $0.contains("Lungfish cDNA sequence comparison:")
                && $0.contains("allele=Mafa-A1*002")
                && $0.contains("raw_id=ref-cdna")
                && $0.contains("cDNA coverage=1.0")
                && $0.contains("cluster coverage=0.5")
                && $0.contains("identity=1.0")
                && $0.contains("SNP substitutions=0")
                && $0.contains("ordinary indel bases=0")
                && $0.contains("SNP-defined amino-acid differences=none")
                && $0.contains("leading flank=100")
                && $0.contains("trailing flank=100")
                && $0.contains("largest structural segment=100")
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish genomic feature scaffold: ref-genomic (Mafa-A1*001); used only to lift exon, intron, and CDS coordinates; sequence differences relative to this scaffold are intentionally not reported"
        })
        XCTAssertFalse(comments.contains { $0.contains("selected genomic closest reference") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish selected reference:") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish reciprocal alignment:") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish translation comparison:") })
        for prefix in consequenceSummaryPrefixes {
            XCTAssertFalse(comments.contains { $0.hasPrefix(prefix) })
        }
        XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-NS-") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-SYN-") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("INTRON-") })
    }

    func testPartialExtensionCommentsExplainCDNAEvidenceAndIncompleteGenomicMatch() throws {
        let interpretation = ONTMHCCDNAExtensionInterpretation(
            rawReferenceID: "ref-cdna", alleleName: "Mamu-DRB*W001:01", locus: "Mamu-DRB",
            cDNAReferenceCoverage: 1, clusterCoverage: 0.8,
            leadingClusterFlankBases: 0, trailingClusterFlankBases: 100,
            largestClusterStructuralSegmentBases: 100, largestCDNADeficitSegmentBases: 0,
            snpSubstitutions: 0, ordinaryIndelBases: 0, isReverse: false,
            alignmentScore: 1_000, identity: 1
        )
        let candidate = try makeCandidate(
            stableID: "partial-extension-a", sequenceSHA256: "partial-extension-hash",
            cigar: "8=1S", referenceName: "ref-genomic", referenceClass: .genomicDNA,
            classification: .partialExtension, extensionOf: ["Mamu-DRB*W001:01"],
            extensionInterpretations: [interpretation], snpCount: 0
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAAGCT", selectedAlignmentIsReverse: false,
            closestReference: makeReference(
                id: "ref-genomic",
                sequence: "ATGGAAGC",
                features: [feature(type: "CDS", start: 0, end: 8)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        XCTAssertTrue(comments.contains {
            $0 == "Lungfish partial extension: the selected genomic comparison is zero-SNP across the shared sequence, but it is not an exact end-to-end match"
        })
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish incomplete genomic comparison: start=1; cigar=8=1S; reference span=8; candidate span=9; insertions=0; deletions=0; skipped=0; soft clipped=1; hard clipped=0"
        }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains { $0 == "Lungfish extension of: Mamu-DRB*W001:01" })
        XCTAssertTrue(comments.contains {
            $0.contains("Lungfish cDNA sequence comparison:")
                && $0.contains("allele=Mamu-DRB*W001:01")
        })
    }

    func testExtensionWithoutVisualizationOmitsReferenceComparisonPlaceholders() throws {
        let candidate = try makeCandidate(
            stableID: "extension-no-visualization", sequenceSHA256: "no-visualization-hash",
            cigar: "9=", referenceName: "ref-unavailable", referenceClass: .genomicDNA,
            classification: .extension, extensionOf: ["Mafa-A1*001"]
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAAGCT",
            selectedAlignmentIsReverse: false, closestReference: nil,
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        XCTAssertTrue(comments.contains {
            $0 == "Lungfish selected genomic feature scaffold reference: ref-unavailable (Mafa-A1*001); annotations unavailable; orientation=forward; sequence differences relative to this scaffold are intentionally not reported"
        })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish selected reference") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish reciprocal alignment:") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish translation comparison:") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish annotation unavailable:") })
        for prefix in consequenceSummaryPrefixes {
            XCTAssertFalse(comments.contains { $0.hasPrefix(prefix) })
        }
        XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("INTRON-") })
    }

    func testCDNAExtensionWithoutVisualizationRetainsLabeledReferenceAndOrientation() throws {
        let candidate = try makeCandidate(
            stableID: "cdna-extension-no-visualization",
            sequenceSHA256: "cdna-no-visualization-hash",
            cigar: "9=", referenceName: "ref-cdna-unavailable", referenceClass: .cDNA,
            classification: .extension, extensionOf: ["Mafa-A1*001"]
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAAGCT",
            selectedAlignmentIsReverse: true, closestReference: nil,
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        XCTAssertTrue(comments.contains {
            $0 == "Lungfish feature reference: ref-cdna-unavailable (Mafa-A1*001) [cDNA]; annotations unavailable; orientation=reverse; no genomic feature scaffold was selected"
        })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish selected reference") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish reciprocal alignment:") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish translation comparison:") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish annotation unavailable:") })
        for prefix in consequenceSummaryPrefixes {
            XCTAssertFalse(comments.contains { $0.hasPrefix(prefix) })
        }
        XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("INTRON-") })
    }

    func testExtensionWithUnknownOrientationRetainsReferenceIdentityWithoutCIGAR() throws {
        let candidate = try makeCandidate(
            stableID: "extension-no-alignment", sequenceSHA256: "no-alignment-hash",
            cigar: "9=", referenceName: "ref-unavailable", referenceClass: .genomicDNA,
            classification: .extension, extensionOf: ["Mafa-A1*001"]
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAAGCT",
            selectedAlignmentIsReverse: nil, closestReference: nil,
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        XCTAssertTrue(comments.contains {
            $0 == "Lungfish selected genomic feature scaffold reference: ref-unavailable (Mafa-A1*001); annotations unavailable; orientation=unavailable; sequence differences relative to this scaffold are intentionally not reported"
        })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish selected reference") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish reciprocal alignment:") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish translation comparison:") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish annotation unavailable:") })
        for prefix in consequenceSummaryPrefixes {
            XCTAssertFalse(comments.contains { $0.hasPrefix(prefix) })
        }
        XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("INTRON-") })
    }

    func testExtensionClassificationEmitsInterpretationsWhenExtensionNamesAreUnavailable() throws {
        let interpretation = ONTMHCCDNAExtensionInterpretation(
            rawReferenceID: "legacy-cdna", alleleName: "Mafa-A1*002", locus: "Mafa-A1",
            cDNAReferenceCoverage: 1, clusterCoverage: 0.5,
            leadingClusterFlankBases: 100, trailingClusterFlankBases: 100,
            largestClusterStructuralSegmentBases: 100, largestCDNADeficitSegmentBases: 0,
            snpSubstitutions: 0, ordinaryIndelBases: 0, isReverse: false,
            alignmentScore: 1_000, identity: 1
        )
        let candidate = try makeCandidate(
            stableID: "legacy-extension", sequenceSHA256: "legacy-extension-hash",
            cigar: "9=", referenceName: "legacy-genomic", referenceClass: .genomicDNA,
            classification: .extension, extensionOf: [],
            extensionInterpretations: [interpretation]
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAAGCT",
            selectedAlignmentIsReverse: nil, closestReference: nil,
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        XCTAssertTrue(comments.contains {
            $0 == "Lungfish extension of: unavailable (no cDNA allele name recorded)"
        })
        XCTAssertTrue(comments.contains {
            $0.contains("Lungfish cDNA sequence comparison:")
                && $0.contains("allele=Mafa-A1*002")
                && $0.contains("raw_id=legacy-cdna")
        })
    }

    func testNovelClassificationIgnoresStaleExtensionMetadata() throws {
        let interpretation = ONTMHCCDNAExtensionInterpretation(
            rawReferenceID: "stale-cdna", alleleName: "Mafa-A1*002", locus: "Mafa-A1",
            cDNAReferenceCoverage: 1, clusterCoverage: 0.5,
            leadingClusterFlankBases: 100, trailingClusterFlankBases: 100,
            largestClusterStructuralSegmentBases: 100, largestCDNADeficitSegmentBases: 0,
            snpSubstitutions: 0, ordinaryIndelBases: 0, isReverse: false,
            alignmentScore: 1_000, identity: 1
        )
        let candidate = try makeCandidate(
            stableID: "novel-stale-extension", sequenceSHA256: "novel-stale-extension-hash",
            cigar: "9=", referenceName: "ref-genomic", referenceClass: .genomicDNA,
            classification: .novel, extensionOf: ["Mafa-A1*002"],
            extensionInterpretations: [interpretation]
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAAGCT",
            selectedAlignmentIsReverse: nil, closestReference: nil,
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish extension of:") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish cDNA sequence comparison:") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish provisional naming ambiguity:") })
    }

    func testAmbiguousExtensionCommentRequiresMultipleCDNAInterpretations() throws {
        let interpretations = [
            ONTMHCCDNAExtensionInterpretation(
                rawReferenceID: "ref-cdna-1", alleleName: "Mafa-A1*001", locus: "Mafa-A1",
                cDNAReferenceCoverage: 1, clusterCoverage: 0.5,
                leadingClusterFlankBases: 100, trailingClusterFlankBases: 100,
                largestClusterStructuralSegmentBases: 100, largestCDNADeficitSegmentBases: 0,
                snpSubstitutions: 0, ordinaryIndelBases: 0, isReverse: false,
                alignmentScore: 1_000, identity: 1
            ),
            ONTMHCCDNAExtensionInterpretation(
                rawReferenceID: "ref-cdna-2", alleleName: "Mafa-A1*002", locus: "Mafa-A1",
                cDNAReferenceCoverage: 1, clusterCoverage: 0.5,
                leadingClusterFlankBases: 100, trailingClusterFlankBases: 100,
                largestClusterStructuralSegmentBases: 100, largestCDNADeficitSegmentBases: 0,
                snpSubstitutions: 0, ordinaryIndelBases: 0, isReverse: false,
                alignmentScore: 1_000, identity: 1
            ),
        ]
        let candidate = try makeCandidate(
            stableID: "ambiguous-extension", sequenceSHA256: "ambiguous-extension-hash",
            cigar: "9=", referenceName: "ref-genomic", referenceClass: .genomicDNA,
            classification: .extension, extensionOf: ["Mafa-A1*001", "Mafa-A1*002"],
            extensionInterpretations: interpretations, provisionalNamingAmbiguous: true
        )
        let input = FullLengthONTMHCCandidateGenBankArtifactBuilder.Input(
            subject: .candidate(candidate), sequence: "ATGGAAGCT",
            selectedAlignmentIsReverse: nil, closestReference: nil,
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let comments = try buildRecord(input).values(forRecordField: "COMMENT")

        XCTAssertEqual(
            comments.filter { $0.hasPrefix("Lungfish cDNA sequence comparison:") }.count,
            2
        )
        XCTAssertTrue(comments.contains {
            $0 == "Lungfish provisional naming ambiguity: multiple compatible cDNA allele names; provisional base name was not assigned from a unique cDNA interpretation"
        })
    }

    private func makeCandidate(
        stableID: String,
        sequenceSHA256: String,
        cigar: String,
        referenceName: String,
        referenceClass: MHCReferenceMoleculeClass,
        referenceStart: Int = 1,
        classification: ONTMHCCandidateClassification = .novel,
        extensionOf: [String] = [],
        extensionInterpretations: [ONTMHCCDNAExtensionInterpretation] = [],
        provisionalNamingAmbiguous: Bool = false,
        snpCount: Int = 1
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
            classification: classification,
            supportClass: .shared,
            closestReferenceName: "Mafa-A1*001",
            closestReferenceClass: referenceClass,
            snpCount: snpCount,
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
            selectedEvidence: evidence,
            extensionOf: extensionOf,
            extensionInterpretations: extensionInterpretations,
            provisionalNamingAmbiguous: provisionalNamingAmbiguous
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
        strand: String = "+",
        sourceOrdinal: Int = 0
    ) -> ONTMHCReferenceVisualizationFeature {
        ONTMHCReferenceVisualizationFeature(
            type: type,
            start: start,
            end: end,
            strand: strand,
            sourceOrdinal: sourceOrdinal,
            rawGenBankLocation: rawGenBankLocation,
            qualifiers: qualifiers
        )
    }

    private func buildRecord(
        _ input: FullLengthONTMHCCandidateGenBankArtifactBuilder.Input
    ) throws -> GenBankRecord {
        try FullLengthONTMHCCandidateGenBankArtifactBuilder().build(from: input).record
    }

    private func sourceTranslationStatus(_ record: GenBankRecord) -> String? {
        record.annotations.first(where: { $0.type == .source })?.qualifier("translation_status")
    }

    private func sha256Hex(_ sequence: String) -> String {
        SHA256.hash(data: Data(sequence.uppercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var consequenceSummaryPrefixes: [String] {
        [
            "Lungfish exon 2/3 nonsynonymous changes:",
            "Lungfish CDS nonsynonymous changes:",
            "Lungfish CDS synonymous changes:",
            "Lungfish intronic changes:",
        ]
    }
}
