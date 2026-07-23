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

        let record = try XCTUnwrap(FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first)
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

        let comments = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        ).values(forRecordField: "COMMENT")

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

        let comments = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        ).values(forRecordField: "COMMENT")

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

        let comments = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        ).values(forRecordField: "COMMENT")
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

        let comments = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        ).values(forRecordField: "COMMENT")
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

            let comments = try XCTUnwrap(
                FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
            ).values(forRecordField: "COMMENT")
            XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-NS-1:") && $0.contains(testCase.expected) }, comments.joined(separator: "\n"))
        }
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

            let comments = try XCTUnwrap(
                FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
            ).values(forRecordField: "COMMENT")
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

        let comments = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        ).values(forRecordField: "COMMENT")

        XCTAssertTrue(comments.contains { $0 == "Lungfish intronic changes: INTRON-FILL-1" }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains { $0.hasPrefix("INTRON-FILL-1:") && $0.contains("20 bp") && $0.contains("closest cDNA contains no homologous intron sequence") })
        XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-NS-1:") && $0.contains("deletion") && $0.contains("frame-disrupting") })
        XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-NS-") && $0.contains("20 bp insertion") })
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

        let comments = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        ).values(forRecordField: "COMMENT")
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
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
        let comments = record.values(forRecordField: "COMMENT")
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-UNRESOLVED-1:") && $0.contains("skipped by CIGAR N") }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains { $0.hasPrefix("CDS-SYN-1:") && $0.contains("ref 9 C>T") && $0.contains("p.A3=") }, comments.joined(separator: "\n"))
        XCTAssertFalse(comments.contains { $0.contains("none detected in complete annotated region") })
        XCTAssertEqual(source.qualifier("translation_status"), "incomplete/unresolved")
        XCTAssertEqual(source.qualifier("trim_status"), "trimmed-to-partial-lifted-CDS")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "not-reference-ready")
        XCTAssertTrue(comments.contains("Lungfish reference readiness: not reference-ready; partial or unresolved lifted CDS"))
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

        let comments = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        ).values(forRecordField: "COMMENT")

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

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
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
        let original = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
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

        let comments = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        ).values(forRecordField: "COMMENT")
        XCTAssertTrue(comments.contains { $0.hasPrefix("UNCLASSIFIED-1:") && $0.contains("ref 2 C>G") && $0.contains("non-CDS exonic/UTR") }, comments.joined(separator: "\n"))
        XCTAssertFalse(comments.contains { $0.contains("candidate -") }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains { $0.hasPrefix("UNCLASSIFIED-1:") && $0.contains("outside cropped candidate ORIGIN") })
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
            cigar: "12=1X11=",
            referenceName: "ref-trimmed-forward",
            referenceClass: .genomicDNA
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

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))
        let comments = record.values(forRecordField: "COMMENT")
        let expectedOrigin = String(fullCandidateSequence.dropFirst(3).prefix(18))

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
            cigar: "15=",
            referenceName: "ref-trimmed-reverse",
            referenceClass: .genomicDNA
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

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        XCTAssertEqual(record.sequence.asString(), String(fullCandidateSequence.dropFirst(4).prefix(9)))
        XCTAssertEqual(source.qualifier("trim_start"), "5")
        XCTAssertEqual(source.qualifier("trim_end"), "13")
        XCTAssertEqual(record.annotations.first(where: { $0.type == .cds })?.intervals.map { [$0.start, $0.end] }, [[0, 9]])
    }

    func testPartialLiftedCDSCropsButRemainsIncompleteAndNotReferenceReady() throws {
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
                features: [feature(type: "CDS", start: 0, end: 9)]
            ),
            analysisName: "run", projectBundleName: nil, minimumIntronGapBases: 20
        )

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        XCTAssertEqual(record.sequence.asString(), "CAAGCT")
        XCTAssertEqual(source.qualifier("translation_status"), "incomplete/unresolved")
        XCTAssertEqual(source.qualifier("trim_status"), "trimmed-to-partial-lifted-CDS")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "not-reference-ready")
        let comments = record.values(forRecordField: "COMMENT")
        XCTAssertTrue(comments.contains { $0.contains("partial lifted CDS") }, comments.joined(separator: "\n"))
        XCTAssertTrue(comments.contains { $0.contains("not reference-ready") }, comments.joined(separator: "\n"))
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

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        XCTAssertEqual(record.sequence.asString(), sequence)
        XCTAssertEqual(source.qualifier("trim_start"), "1")
        XCTAssertEqual(source.qualifier("trim_end"), "8")
        XCTAssertEqual(source.qualifier("trim_status"), "unavailable-no-lifted-CDS")
        XCTAssertEqual(source.qualifier("reference_readiness_status"), "not-reference-ready")
        XCTAssertTrue(record.values(forRecordField: "COMMENT").contains { $0.contains("UTR trimming unavailable") && $0.contains("no lifted CDS") })
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

        XCTAssertEqual(record.sequence.asString(), "ATGGCTTAA")
        XCTAssertEqual(cds.intervals.map { [$0.start, $0.end] }, [[0, 9]])
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
        XCTAssertFalse(comments.contains { comment in
            consequenceSummaryPrefixes.contains { comment.hasPrefix($0) }
        })
        XCTAssertNil(record.annotations[0].qualifier("trim_status"))
        XCTAssertEqual(record.sequence.asString(), "ACGT")
    }

    func testAnnotatedUnnameableKeepsBoundaryCoverageTranslationStatusAndPriorFeatureShape() throws {
        let evidence = ONTMHCEvidenceLocator(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "unnameable-annotated",
            referenceName: "ref-unnameable-annotated",
            readGroupID: nil,
            referenceStart: 1,
            cigar: "3=3N3="
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
            subject: .unnameable(unnameable), sequence: "ATGGCT",
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

        let record = try XCTUnwrap(
            FullLengthONTMHCCandidateGenBankArtifactBuilder().records(from: [input]).first
        )
        let source = try XCTUnwrap(record.annotations.first(where: { $0.type == .source }))
        let cds = try XCTUnwrap(record.annotations.first(where: { $0.type == .cds }))
        let comments = record.values(forRecordField: "COMMENT")

        XCTAssertEqual(record.annotations.map(\.type), [.source, .gene, .exon, .exon, .cds])
        XCTAssertFalse(record.annotations.contains { $0.type == .intron })
        XCTAssertEqual(record.sequence.asString(), "ATGGCT")
        XCTAssertEqual(cds.intervals.map { [$0.start, $0.end] }, [[0, 6]])
        XCTAssertEqual(cds.qualifier("translation"), "MA")
        XCTAssertEqual(cds.qualifier("inference"), "alignment:reciprocal minimap2 CIGAR")
        XCTAssertEqual(source.qualifier("translation_status"), "full-length")
        XCTAssertNil(source.qualifier("trim_status"))
        XCTAssertNil(source.qualifier("reference_readiness_status"))
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
