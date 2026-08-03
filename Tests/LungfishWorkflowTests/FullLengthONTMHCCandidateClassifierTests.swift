import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class FullLengthONTMHCCandidateClassifierTests: XCTestCase {
    private let genomicReference = MHCReferenceRecord(
        sequenceID: "ref-genomic",
        alleleName: "Mafa-A1*018:01:01:01",
        locus: "Mafa-A1",
        moleculeClass: .genomicDNA,
        classEvidence: .annotatedMetadata,
        sequenceLength: 1_200
    )

    private let cdnaReference = MHCReferenceRecord(
        sequenceID: "ref-cdna",
        alleleName: "Mafa-A1*018:01:01:01",
        locus: "Mafa-A1",
        moleculeClass: .cDNA,
        classEvidence: .annotatedMetadata,
        sequenceLength: 1_000
    )

    func testZeroSNPGenomicAlignmentWithIndelsIsKnown() throws {
        let cluster = makeCluster(
            sequenceLength: 1_250,
            alignments: [alignment(reference: genomicReference, cigar: "600=50I600=")]
        )

        guard case .known(let calls) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected known call")
        }
        XCTAssertEqual(calls.map(\.reference.sequenceID), ["ref-genomic"])
        XCTAssertEqual(calls.first?.comparableBases, 1_200)
        XCTAssertEqual(calls.first?.insertedBases, 50)
        XCTAssertEqual(calls.first?.alignmentScore, 2_000)
        XCTAssertEqual(calls.first?.evidence.cigar, "600=50I600=")
    }

    func testIncompleteZeroSNPGenomicMatchWithCDNAExtensionIsPartialExtension() throws {
        let cluster = makeCluster(
            sequenceLength: 1_200,
            alignments: [
                alignment(reference: cdnaReference, cigar: "500=50I500="),
                alignment(reference: genomicReference, cigar: "1100=100S"),
            ]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier()
            .classify(cluster) else {
            return XCTFail("Expected partial extension candidate")
        }
        XCTAssertEqual(candidate.classification, .partialExtension)
        XCTAssertEqual(
            candidate.provisionalName,
            "Mafa-A1*018:01:01:01_partial_ext"
        )
        XCTAssertEqual(candidate.extensionOf, ["Mafa-A1*018:01:01:01"])
        XCTAssertEqual(candidate.snpCount, 0)
        XCTAssertEqual(candidate.selectedEvidence.referenceName, genomicReference.sequenceID)
    }

    func testIncompleteZeroSNPGenomicMatchWithoutCDNAEvidenceIsPartialExtension() throws {
        let cluster = makeCluster(
            sequenceLength: 1_200,
            alignments: [alignment(reference: genomicReference, cigar: "1100=100S")]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier()
            .classify(cluster) else {
            return XCTFail("Expected partial extension candidate")
        }
        XCTAssertEqual(candidate.classification, .partialExtension)
        XCTAssertEqual(candidate.provisionalName, "Mafa-A1*018:01:01:01_partial_ext")
        XCTAssertEqual(candidate.extensionOf, ["Mafa-A1*018:01:01:01"])
        XCTAssertTrue(candidate.extensionInterpretations.isEmpty)
        XCTAssertEqual(candidate.snpCount, 0)
        XCTAssertEqual(candidate.selectedEvidence.referenceName, genomicReference.sequenceID)
    }

    func testExactEndToEndZeroSNPGenomicMatchRemainsKnownDespiteCDNAExtensionEvidence() throws {
        let cluster = makeCluster(
            sequenceLength: 1_200,
            alignments: [
                alignment(reference: cdnaReference, cigar: "500=50I500="),
                alignment(reference: genomicReference, cigar: "1200="),
            ]
        )

        guard case .known(let calls) = try FullLengthONTMHCCandidateClassifier()
            .classify(cluster) else {
            return XCTFail("Expected exact genomic known call")
        }
        XCTAssertEqual(calls.map(\.reference.sequenceID), [genomicReference.sequenceID])
    }

    func testCompleteExactCDNAWithOnlyIntronSizedQueryInsertionsIsExtension() throws {
        let cluster = makeCluster(
            sequenceLength: 1_050,
            alignments: [alignment(reference: cdnaReference, cigar: "500=50I500=")]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected cDNA extension candidate")
        }
        XCTAssertEqual(candidate.provisionalName, "Mafa-A1*018:01:01:01_ext")
        XCTAssertEqual(candidate.classification, .extension)
        XCTAssertEqual(candidate.snpCount, 0)
        XCTAssertEqual(candidate.insertedBases, 50)
        XCTAssertEqual(candidate.deletedBases, 0)
        XCTAssertEqual(candidate.longGapBases, 50)
        XCTAssertEqual(candidate.comparableBases, 1_000)
        XCTAssertEqual(candidate.shorterCoverage, 1)
        XCTAssertEqual(candidate.identity, 1)
    }

    func testMultipleInternalIntronSizedInsertionsFormExtensionAndPreserveIndelMetrics() throws {
        let cluster = makeCluster(
            sequenceLength: 1_110,
            alignments: [alignment(reference: cdnaReference, cigar: "300=50I300=60I400=")]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected cDNA extension candidate")
        }
        XCTAssertEqual(candidate.classification, .extension)
        XCTAssertEqual(candidate.insertedBases, 110)
        XCTAssertEqual(candidate.deletedBases, 0)
        XCTAssertEqual(candidate.longGapBases, 110)
    }

    func testCompleteCDNAExtensionAllowsOrdinaryIndelsWhenThereAreNoSNPs() throws {
        let deletionReference = MHCReferenceRecord(
            sequenceID: "ref-cdna-1001",
            alleleName: cdnaReference.alleleName,
            locus: cdnaReference.locus,
            moleculeClass: .cDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_001
        )
        for (cigar, sequenceLength, reference, insertedBases, deletedBases) in [
            ("499=1D1=50I500=", 1_050, deletionReference, 50, 1),
            ("499=1I1=50I500=", 1_051, cdnaReference, 51, 0),
        ] {
            let cluster = makeCluster(
                sequenceLength: sequenceLength,
                alignments: [alignment(reference: reference, cigar: cigar)]
            )

            guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
                return XCTFail("Expected structural cDNA extension for \(cigar)")
            }
            XCTAssertEqual(candidate.classification, .extension)
            XCTAssertEqual(candidate.snpCount, 0)
            XCTAssertEqual(candidate.insertedBases, insertedBases)
            XCTAssertEqual(candidate.deletedBases, deletedBases)
            XCTAssertEqual(candidate.provisionalName, "Mafa-A1*018:01:01:01_ext")
        }
    }

    func testCompleteCDNAExtensionRecognizesIntronInsertionAdjacentToOrdinaryDeletion() throws {
        let reference = MHCReferenceRecord(
            sequenceID: "ref-cdna-adjacent-deletion",
            alleleName: cdnaReference.alleleName,
            locus: cdnaReference.locus,
            moleculeClass: .cDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_001
        )
        let cluster = makeCluster(
            sequenceLength: 1_050,
            alignments: [alignment(reference: reference, cigar: "500=1D50I500=")]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected structural cDNA extension across adjacent deletion")
        }
        XCTAssertEqual(candidate.classification, .extension)
        XCTAssertEqual(candidate.provisionalName, "Mafa-A1*018:01:01:01_ext")
        XCTAssertEqual(candidate.snpCount, 0)
        XCTAssertEqual(candidate.insertedBases, 50)
        XCTAssertEqual(candidate.deletedBases, 1)
        XCTAssertEqual(candidate.longGapBases, 50)
    }

    func testCDNAMissingMoreThanFivePercentIsNeitherKnownNorExtension() throws {
        let longCDNA = MHCReferenceRecord(
            sequenceID: "ref-long-cdna",
            alleleName: "Mafa-A2*024:01:01:01",
            locus: "Mafa-A2",
            moleculeClass: .cDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let cluster = makeCluster(
            sequenceLength: 1_150,
            alignments: [alignment(
                reference: longCDNA,
                cigar: "500=50I600=",
                referenceStart: 101
            )]
        )

        guard case .unnameable = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected insufficient structural cDNA evidence")
        }
    }

    func testCDNAIntronFillWithSNPIsNovelNotExtension() throws {
        let cluster = makeCluster(
            sequenceLength: 1_050,
            alignments: [alignment(reference: cdnaReference, cigar: "499=1X50I500=")]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected novel candidate")
        }
        XCTAssertEqual(candidate.classification, .novel)
        XCTAssertEqual(candidate.provisionalName, "Mafa-A1*018:01:01:01_1nt_nov")
    }

    func testTerminalLongInsertionsAreCDNAExtensions() throws {
        for cigar in ["50I1000=", "1000=50I"] {
            let cluster = makeCluster(
                sequenceLength: 1_050,
                alignments: [alignment(reference: cdnaReference, cigar: cigar)]
            )

            guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
                return XCTFail("Expected extension for \(cigar)")
            }
            XCTAssertEqual(candidate.classification, .extension, cigar)
        }
    }

    func testExtensionRetainsAllCompatibleCDNAsWhileGenomicEvidenceResolvesClosestReference() throws {
        let secondCDNA = MHCReferenceRecord(
            sequenceID: "ref-cdna-2",
            alleleName: "Mafa-A1*018:01:01:02",
            locus: "Mafa-A1",
            moleculeClass: .cDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_000
        )
        let cluster = makeCluster(
            sequenceLength: 1_200,
            alignments: [
                alignment(reference: cdnaReference, cigar: "500=50I500="),
                alignment(reference: secondCDNA, cigar: "500=50I500="),
                alignment(reference: genomicReference, cigar: "599=1X600="),
            ]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected joint cDNA/genomic extension candidate")
        }
        XCTAssertEqual(candidate.classification, .extension)
        XCTAssertEqual(candidate.extensionOf, [
            "Mafa-A1*018:01:01:01",
            "Mafa-A1*018:01:01:02",
        ])
        XCTAssertEqual(candidate.extensionInterpretations.map(\.rawReferenceID), [
            "ref-cdna",
            "ref-cdna-2",
        ])
        XCTAssertTrue(candidate.provisionalNamingAmbiguous)
        XCTAssertEqual(candidate.closestReferenceClass, .genomicDNA)
        XCTAssertEqual(candidate.closestReferenceName, genomicReference.alleleName)
    }

    func testOffLocusCompatibleCDNADoesNotCreateNamingAmbiguityAfterGenomicResolution() throws {
        let offLocusCDNA = MHCReferenceRecord(
            sequenceID: "ref-cdna-b",
            alleleName: "Mafa-B*001:01:01:01",
            locus: "Mafa-B",
            moleculeClass: .cDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_000
        )
        let cluster = makeCluster(
            sequenceLength: 1_200,
            alignments: [
                alignment(reference: cdnaReference, cigar: "500=50I500="),
                alignment(reference: offLocusCDNA, cigar: "500=50I500="),
                alignment(reference: genomicReference, cigar: "599=1X600="),
            ]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected extension candidate")
        }
        XCTAssertEqual(candidate.provisionalName, "Mafa-A1*018:01:01:01_ext")
        XCTAssertFalse(candidate.provisionalNamingAmbiguous)
        XCTAssertEqual(candidate.extensionOf, [
            "Mafa-A1*018:01:01:01",
            "Mafa-B*001:01:01:01",
        ])
    }

    func testGenomicEvidenceResolvesLocusWithoutBeingConstrainedByHomologousCDNALocus() throws {
        let cdnaI = MHCReferenceRecord(
            sequenceID: "ref-cdna-i", alleleName: "Mafa-I*01:14:13", locus: "Mafa-I",
            moleculeClass: .cDNA, classEvidence: .annotatedMetadata, sequenceLength: 1_000
        )
        let genomicB = MHCReferenceRecord(
            sequenceID: "ref-genomic-b", alleleName: "Mafa-B*001:01:01:01", locus: "Mafa-B",
            moleculeClass: .genomicDNA, classEvidence: .annotatedMetadata, sequenceLength: 1_200
        )
        let cluster = makeCluster(
            sequenceLength: 1_200,
            alignments: [
                alignment(reference: cdnaI, cigar: "500=50I500="),
                alignment(reference: genomicB, cigar: "599=1X600="),
            ]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected extension candidate")
        }
        XCTAssertEqual(candidate.locus, "Mafa-B")
        XCTAssertEqual(candidate.closestReferenceName, "Mafa-B*001:01:01:01")
        XCTAssertEqual(candidate.provisionalName, "Mafa-B*001:01:01:01_ext")
        XCTAssertEqual(candidate.extensionOf, ["Mafa-I*01:14:13"])
        XCTAssertTrue(candidate.provisionalNamingAmbiguous)
    }

    func testBiologicallyTiedGenomicLociUseUnanimousCDNALocusRegardlessOfMAPQ() throws {
        let genomicB = MHCReferenceRecord(
            sequenceID: "ref-genomic-b",
            alleleName: "Mafa-B*001:01:01:01",
            locus: "Mafa-B",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let cluster = makeCluster(
            sequenceLength: 1_200,
            alignments: [
                alignment(reference: cdnaReference, cigar: "500=50I500="),
                alignment(reference: genomicReference, cigar: "599=1X600=", mapq: 10),
                alignment(reference: genomicB, cigar: "599=1X600=", mapq: 60),
            ]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected the unanimous cDNA locus to resolve the genomic tie")
        }
        XCTAssertEqual(candidate.locus, "Mafa-A1")
        XCTAssertEqual(candidate.closestReferenceName, genomicReference.alleleName)
        XCTAssertEqual(candidate.mappingQuality, 10)
        XCTAssertEqual(candidate.reciprocalHitSummary.closestMatchTargetNames, [
            "ref-genomic", "ref-genomic-b",
        ])
    }

    func testBiologicallyTiedGenomicLociWithAmbiguousCDNALociAreUnnameable() throws {
        let cdnaB = MHCReferenceRecord(
            sequenceID: "ref-cdna-b",
            alleleName: "Mafa-B*001:01:01:01",
            locus: "Mafa-B",
            moleculeClass: .cDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_000
        )
        let genomicB = MHCReferenceRecord(
            sequenceID: "ref-genomic-b",
            alleleName: "Mafa-B*001:01:01:01",
            locus: "Mafa-B",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let cluster = makeCluster(
            sequenceLength: 1_200,
            alignments: [
                alignment(reference: cdnaReference, cigar: "500=50I500="),
                alignment(reference: cdnaB, cigar: "500=50I500="),
                alignment(reference: genomicReference, cigar: "599=1X600=", mapq: 10),
                alignment(reference: genomicB, cigar: "599=1X600=", mapq: 60),
            ]
        )

        guard case .unnameable(let record) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected an unresolved cross-locus genomic tie")
        }
        XCTAssertEqual(record.reason, .unresolvedLocus)
        XCTAssertEqual(record.failedMetrics["ambiguous_best_genomic_locus"], 1)
    }

    func testEquallyCompatibleCrossLocusCDNAsWithoutGenomicResolverAreUnnameable() throws {
        let cdnaB = MHCReferenceRecord(
            sequenceID: "ref-cdna-b",
            alleleName: "Mafa-B*001:01:01:01",
            locus: "Mafa-B",
            moleculeClass: .cDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_000
        )
        let cluster = makeCluster(
            sequenceLength: 1_200,
            alignments: [
                alignment(reference: cdnaReference, cigar: "500=50I500="),
                alignment(reference: cdnaB, cigar: "500=50I500="),
            ]
        )

        guard case .unnameable(let record) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected cross-locus cDNA ambiguity without genomic evidence to be un-nameable")
        }
        XCTAssertEqual(record.reason, .unresolvedLocus)
        XCTAssertEqual(record.failedMetrics["ambiguous_compatible_cdna_locus"], 1)
        XCTAssertEqual(record.reciprocalHitSummary.closestMatchTargetNames, [
            "ref-cdna", "ref-cdna-b",
        ])
    }

    func testBiologicallyTiedNovelGenomicLociWithoutCDNAEvidenceAreUnnameable() throws {
        let genomicB = MHCReferenceRecord(
            sequenceID: "ref-genomic-b",
            alleleName: "Mafa-B*001:01:01:01",
            locus: "Mafa-B",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let cluster = makeCluster(alignments: [
            alignment(reference: genomicReference, cigar: "599=1X600=", mapq: 10),
            alignment(reference: genomicB, cigar: "599=1X600=", mapq: 60),
        ])

        guard case .unnameable(let record) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected a cross-locus novel tie without cDNA evidence to be un-nameable")
        }
        XCTAssertEqual(record.reason, .unresolvedLocus)
        XCTAssertEqual(record.failedMetrics["ambiguous_best_genomic_locus"], 1)
        XCTAssertEqual(record.reciprocalHitSummary.closestMatchTargetNames, [
            "ref-genomic", "ref-genomic-b",
        ])
    }

    func testMAPQDoesNotChooseBetweenBiologicallyTiedNovelReferencesAtOneLocus() throws {
        let lexicallyLater = MHCReferenceRecord(
            sequenceID: "ref-z-high-mapq",
            alleleName: "Mafa-A1*999:01",
            locus: "Mafa-A1",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let cluster = makeCluster(alignments: [
            alignment(reference: lexicallyLater, cigar: "599=1X600=", mapq: 60),
            alignment(reference: genomicReference, cigar: "599=1X600=", mapq: 1),
        ])

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected a same-locus novel candidate")
        }
        XCTAssertEqual(candidate.closestReferenceName, genomicReference.alleleName)
        XCTAssertEqual(candidate.mappingQuality, 1)
        XCTAssertEqual(candidate.reciprocalHitSummary.closestMatchTargetNames, [
            "ref-genomic", "ref-z-high-mapq",
        ])
    }

    func testEquivalentCohortEvidenceWithOppositeCanonicalStrandsIsUnnameable() throws {
        let forward = extensionInterpretation(reference: cdnaReference, isReverse: false)
        let reverse = extensionInterpretation(reference: cdnaReference, isReverse: true)
        let observations = [
            observation(
                sourceClusterIDs: ["source-1"],
                extensionInterpretations: [forward]
            ),
            observation(
                sampleID: "sample-2",
                readGroupID: "rg-2",
                sourceClusterIDs: ["source-2"],
                extensionInterpretations: [reverse]
            ),
        ]
        let cluster = makeCluster(
            sequenceLength: 1_050,
            observations: observations,
            alignments: [alignment(reference: cdnaReference, cigar: "500=50I500=", isReverse: false)]
        )

        guard case .unnameable(let record) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected already-canonical cohort evidence to reject a strand conflict")
        }
        XCTAssertEqual(record.failedMetrics["conflicting_cdna_strand"], 1)
    }

    func testCohortOnlyEquivalentCDNAReferencesWithOppositeCanonicalStrandsAreUnnameable() throws {
        let cdnaB = MHCReferenceRecord(
            sequenceID: "ref-cdna-b",
            alleleName: "Mafa-B*001:01:01:01",
            locus: "Mafa-B",
            moleculeClass: .cDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_000
        )
        let forward = extensionInterpretation(reference: cdnaReference, isReverse: false)
        let reverse = extensionInterpretation(reference: cdnaB, isReverse: true)
        let cluster = makeCluster(
            observations: [observation(extensionInterpretations: [forward, reverse])],
            alignments: [alignment(reference: genomicReference, cigar: "599=1X600=")]
        )

        guard case .unnameable(let record) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected a genuine cohort-only cross-reference strand conflict")
        }
        XCTAssertEqual(record.reason, .ambiguousReferenceClass)
        XCTAssertEqual(record.failedMetrics["conflicting_cdna_strand"], 1)
    }

    func testEquivalentReciprocalCDNAReferencesWithOppositeCanonicalStrandsAreUnnameable() throws {
        let secondCDNA = MHCReferenceRecord(
            sequenceID: "ref-cdna-2",
            alleleName: "Mafa-A1*018:01:01:02",
            locus: "Mafa-A1",
            moleculeClass: .cDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_000
        )
        let cluster = makeCluster(
            sequenceLength: 1_050,
            alignments: [
                alignment(reference: cdnaReference, cigar: "500=50I500=", isReverse: false),
                alignment(reference: secondCDNA, cigar: "500=50I500=", isReverse: true),
            ]
        )

        guard case .unnameable(let record) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected a genuine canonical cross-reference strand conflict")
        }
        XCTAssertEqual(record.reason, .ambiguousReferenceClass)
        XCTAssertEqual(record.failedMetrics["conflicting_cdna_strand"], 1)
    }

    func testKnownCallsPreserveEquallyBestAlleleAndReferenceIdentityTies() throws {
        let alleleTie = MHCReferenceRecord(
            sequenceID: "ref-second-allele",
            alleleName: "Mafa-A2*001:01",
            locus: "Mafa-A2",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let sameAlleleSecondRecord = MHCReferenceRecord(
            sequenceID: "ref-genomic-copy",
            alleleName: genomicReference.alleleName,
            locus: genomicReference.locus,
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let cluster = makeCluster(alignments: [
            alignment(reference: alleleTie, cigar: "1200=", mapq: 50, score: 2_000),
            alignment(reference: genomicReference, cigar: "1200=", mapq: 50, score: 2_000),
            alignment(reference: sameAlleleSecondRecord, cigar: "1200=", mapq: 50, score: 2_000),
            alignment(reference: genomicReference, cigar: "1200=", mapq: 40, score: 1_900),
        ])

        guard case .known(let calls) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected known calls")
        }
        XCTAssertEqual(calls.map(\.reference.sequenceID), [
            "ref-genomic", "ref-genomic-copy", "ref-second-allele",
        ])
        XCTAssertEqual(Set(calls.map(\.reference.alleleName)), [
            genomicReference.alleleName, alleleTie.alleleName,
        ])
        XCTAssertTrue(calls.allSatisfy {
            $0.comparableBases == 1_200 && $0.alignmentScore == 2_000 && $0.mappingQuality == 50
        })
    }

    func testSNPCountAloneNamesNovelCandidate() throws {
        for (snpCount, cigar) in [(1, "599=1X600="), (5, "595=5X600=")] {
            let cluster = makeCluster(
                stableClusterID: "cluster-\(snpCount)",
                fastaRecordID: "cluster-\(snpCount)",
                alignments: [alignment(
                    reference: genomicReference,
                    cigar: cigar,
                    queryName: "cluster-\(snpCount)"
                )]
            )

            guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
                return XCTFail("Expected novel candidate for \(snpCount) SNPs")
            }
            XCTAssertEqual(candidate.provisionalName, "Mafa-A1*018:01:01:01_\(snpCount)nt_nov")
            XCTAssertEqual(candidate.classification, .novel)
            XCTAssertEqual(candidate.snpCount, snpCount)
            XCTAssertFalse(candidate.provisionalName.contains("_0nt_nov"))
        }
    }

    func testSupportUsesDistinctSamplesRatherThanObservationCount() throws {
        let duplicateSample = makeCluster(
            observations: [
                observation(
                    sampleID: "sample-1",
                    readGroupID: "rg-1",
                    reads: 5,
                    sourceClusterIDs: ["source-1", "source-2"]
                ),
                observation(sampleID: "sample-1", readGroupID: "rg-1b", reads: 7),
            ],
            alignments: [alignment(reference: genomicReference, cigar: "595=5X600=")]
        )
        let shared = makeCluster(
            stableClusterID: "cluster-shared",
            fastaRecordID: "cluster-shared",
            observations: [
                observation(stableClusterID: "cluster-shared", sampleID: "sample-2", readGroupID: "rg-2", reads: 11),
                observation(stableClusterID: "cluster-shared", sampleID: "sample-1", readGroupID: "rg-1", reads: 13),
                observation(stableClusterID: "cluster-shared", sampleID: "sample-1", readGroupID: "rg-1b", reads: 17),
            ],
            alignments: [alignment(
                reference: genomicReference,
                cigar: "595=5X600=",
                queryName: "cluster-shared"
            )]
        )

        guard case .candidate(let singleton) = try FullLengthONTMHCCandidateClassifier().classify(duplicateSample),
              case .candidate(let sharedCandidate) = try FullLengthONTMHCCandidateClassifier().classify(shared) else {
            return XCTFail("Expected candidates")
        }
        XCTAssertEqual(singleton.supportClass, .singleton)
        XCTAssertEqual(singleton.independentSampleCount, 1)
        XCTAssertEqual(singleton.occurrenceCount, 3)
        XCTAssertEqual(singleton.totalClusterReads, 12)
        XCTAssertEqual(sharedCandidate.supportClass, .shared)
        XCTAssertEqual(sharedCandidate.independentSampleCount, 2)
        XCTAssertEqual(sharedCandidate.occurrenceCount, 3)
        XCTAssertEqual(sharedCandidate.totalClusterReads, 41)
        XCTAssertEqual(sharedCandidate.supportingSampleIDs, ["sample-1", "sample-2"])
    }

    func testRejectsNonpositiveOrInconsistentSupportInsteadOfPromotingSampleEligibility() throws {
        let classifier = FullLengthONTMHCCandidateClassifier()
        let valid = observation(sampleID: "sample-1", readGroupID: "rg-1", reads: 5)
        let invalidObservations = [
            observation(sampleID: "sample-2", readGroupID: "rg-zero", reads: 0),
            ONTMHCCandidateObservation(
                stableClusterID: "cluster-1",
                sampleID: "sample-2",
                readGroupID: "rg-empty-source",
                sourceClusterIDs: [""],
                sourceClusterReadCounts: ["": 5],
                aggregatedSampleReadCount: 5,
                evidence: [evidence(
                    queryName: "cluster-1",
                    referenceName: "source",
                    readGroupID: "rg-empty-source"
                )]
            ),
            ONTMHCCandidateObservation(
                stableClusterID: "cluster-1",
                sampleID: "sample-2",
                readGroupID: "rg-zero-source-count",
                sourceClusterIDs: ["source-2", "source-3"],
                sourceClusterReadCounts: ["source-2": 5, "source-3": 0],
                aggregatedSampleReadCount: 5,
                evidence: [evidence(
                    queryName: "cluster-1",
                    referenceName: "source",
                    readGroupID: "rg-zero-source-count"
                )]
            ),
            ONTMHCCandidateObservation(
                stableClusterID: "cluster-1",
                sampleID: "sample-2",
                readGroupID: "rg-inconsistent",
                sourceClusterIDs: ["source-2"],
                sourceClusterReadCounts: ["source-2": 4],
                aggregatedSampleReadCount: 5,
                evidence: [evidence(
                    queryName: "cluster-1",
                    referenceName: "source",
                    readGroupID: "rg-inconsistent"
                )]
            ),
            ONTMHCCandidateObservation(
                stableClusterID: "cluster-1",
                sampleID: "sample-2",
                readGroupID: "rg-wrong-target",
                sourceClusterIDs: ["source-2"],
                sourceClusterReadCounts: ["source-2": 5],
                aggregatedSampleReadCount: 5,
                genotypingHitSummaries: [try ONTMHCGenotypingTargetHitSummary(
                    bamPath: "artifacts/alignments/genotyping-evidence.bam",
                    targetName: "another-sample|source-2",
                    alignmentCount: 1,
                    queryAlignmentCounts: ["ref-genomic": 1],
                    exactMatchQueryNames: [],
                    closestMatchQueryNames: ["ref-genomic"]
                )]
            ),
        ]

        for invalid in invalidObservations {
            XCTAssertThrowsError(try classifier.classify(makeCluster(
                observations: [valid, invalid],
                alignments: [alignment(reference: genomicReference, cigar: "1X1199=")]
            ))) { error in
                XCTAssertTrue(error is FullLengthONTMHCCandidateClassifierError)
            }
        }
    }

    func testProvisionalLabelCollisionPreservesSeparateStableClusterRecords() throws {
        let first = makeCluster(
            stableClusterID: "cluster-a",
            fastaRecordID: "cluster-a",
            alignments: [alignment(
                reference: genomicReference,
                cigar: "595=5X600=",
                queryName: "cluster-a"
            )]
        )
        let second = makeCluster(
            stableClusterID: "cluster-b",
            fastaRecordID: "cluster-b",
            alignments: [alignment(
                reference: genomicReference,
                cigar: "595=5X600=",
                queryName: "cluster-b"
            )]
        )

        let results = try FullLengthONTMHCCandidateClassifier().classify([second, first])
        let records = results.compactMap(\.candidate)

        XCTAssertEqual(records.map(\.stableClusterID), ["cluster-a", "cluster-b"])
        XCTAssertEqual(Set(records.map(\.provisionalName)), ["Mafa-A1*018:01:01:01_5nt_nov"])
    }

    func testDefensibleHitsUseBindingOrderAndDeterministicRanking() throws {
        let laterAllele = MHCReferenceRecord(
            sequenceID: "ref-z",
            alleleName: "Mafa-B*999:01",
            locus: "Mafa-B",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let cluster = makeCluster(alignments: [
            alignment(reference: laterAllele, cigar: "590=1X608=", mapq: 60, score: 2_000),
            alignment(reference: genomicReference, cigar: "595=1X604=", mapq: 10, score: 1_000),
            alignment(reference: genomicReference, cigar: "594=2X604=", mapq: 60, score: 9_000),
        ])

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected ranked novel candidate")
        }
        XCTAssertEqual(candidate.closestReferenceName, "Mafa-A1*018:01:01:01")
        XCTAssertEqual(candidate.snpCount, 1)
        XCTAssertEqual(candidate.comparableBases, 1_200)
        XCTAssertEqual(candidate.alignmentScore, 1_000)
    }

    func testReciprocalSummaryCountsTargetsAndPreservesBiologicalClosestTies() throws {
        let tiedReference = MHCReferenceRecord(
            sequenceID: "ref-tied",
            alleleName: "Mafa-A1*019:01",
            locus: "Mafa-A1",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let cluster = makeCluster(alignments: [
            alignment(reference: genomicReference, cigar: "595=5X600=", referenceStart: 1),
            alignment(reference: genomicReference, cigar: "594=5X601=", referenceStart: 1),
            alignment(reference: tiedReference, cigar: "595=5X600=", referenceStart: 1),
        ])

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected candidate")
        }
        let summary = candidate.reciprocalHitSummary
        XCTAssertEqual(summary.queryName, cluster.stableClusterID)
        XCTAssertEqual(summary.alignmentCount, 3)
        XCTAssertEqual(summary.targetAlignmentCounts, ["ref-genomic": 2, "ref-tied": 1])
        XCTAssertEqual(summary.exactMatchTargetNames, [])
        XCTAssertEqual(summary.closestMatchTargetNames, ["ref-genomic", "ref-tied"])
        XCTAssertTrue(summary.closestMatchTargetNames.contains(candidate.selectedEvidence.referenceName))
    }

    func testReciprocalSummaryRecordsZeroSNPExactRelationshipForExtension() throws {
        let cluster = makeCluster(
            sequenceLength: 1_050,
            alignments: [
                alignment(reference: cdnaReference, cigar: "500=50I500="),
                alignment(reference: genomicReference, cigar: "500=1X499="),
            ]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected extension candidate")
        }
        XCTAssertEqual(candidate.reciprocalHitSummary.exactMatchTargetNames, ["ref-cdna"])
        XCTAssertEqual(candidate.reciprocalHitSummary.closestMatchTargetNames, ["ref-genomic"])
        XCTAssertEqual(candidate.selectedEvidence.referenceName, "ref-genomic")
    }

    func testUnnameableStoresOnlyClassifierSelectedClosestLocator() throws {
        let lexicalFirstButWorse = MHCReferenceRecord(
            sequenceID: "ref-a-worse",
            alleleName: "Mafa-A1*001:01",
            locus: "Mafa-A1",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let biologicalBest = MHCReferenceRecord(
            sequenceID: "ref-z-best",
            alleleName: "Mafa-A1*999:01",
            locus: "Mafa-A1",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let cluster = makeCluster(alignments: [
            alignment(reference: lexicalFirstButWorse, cigar: "400X800="),
            alignment(reference: biologicalBest, cigar: "301X899="),
        ])

        guard case .unnameable(let record) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected un-nameable result")
        }
        XCTAssertEqual(record.reciprocalHitSummary.alignmentCount, 2)
        XCTAssertEqual(record.reciprocalHitSummary.closestMatchTargetNames, ["ref-z-best"])
        XCTAssertEqual(record.selectedEvidence?.referenceName, "ref-z-best")
    }

    func testNoAlignmentUnnameableHasEmptyReciprocalSummaryAndNoSelectedLocator() throws {
        guard case .unnameable(let record) = try FullLengthONTMHCCandidateClassifier().classify(
            makeCluster(alignments: [])
        ) else {
            return XCTFail("Expected un-nameable result")
        }

        XCTAssertEqual(record.reciprocalHitSummary.queryName, record.stableClusterID)
        XCTAssertEqual(record.reciprocalHitSummary.alignmentCount, 0)
        XCTAssertEqual(record.reciprocalHitSummary.targetAlignmentCounts, [:])
        XCTAssertEqual(record.reciprocalHitSummary.exactMatchTargetNames, [])
        XCTAssertEqual(record.reciprocalHitSummary.closestMatchTargetNames, [])
        XCTAssertNil(record.selectedEvidence)
    }

    func testEveryUnnameableReasonAndFailedMetricProjection() throws {
        let cases: [(String, FullLengthONTMHCCandidateCluster, ONTMHCUnnameableReason, String?)] = [
            ("no alignment", makeCluster(alignments: []), .noAlignment, nil),
            (
                "aligned bases",
                makeCluster(sequenceLength: 999, alignments: [alignment(reference: genomicReference, cigar: "999=")]),
                .insufficientAlignedBases,
                "aligned_bases"
            ),
            (
                "coverage",
                makeCluster(sequenceLength: 2_000, alignments: [alignment(
                    resolution: .unresolvedLocus(referenceName: "long-ref", sequenceLength: 2_000),
                    cigar: "1X999="
                )]),
                .insufficientCoverage,
                "shorter_coverage"
            ),
            (
                "identity",
                makeCluster(
                    sequenceLength: 1_200,
                    alignments: [alignment(reference: genomicReference, cigar: "301X899=")]
                ),
                .insufficientIdentity,
                "identity"
            ),
            (
                "locus",
                makeCluster(alignments: [alignment(
                    resolution: .unresolvedLocus(referenceName: "unknown-ref", sequenceLength: 1_200),
                    cigar: "1X1199="
                )]),
                .unresolvedLocus,
                nil
            ),
            (
                "reference class",
                makeCluster(alignments: [alignment(
                    resolution: .ambiguousReferenceClass(
                        referenceName: "ambiguous-ref",
                        locus: "Mafa-A1",
                        sequenceLength: 1_200
                    ),
                    cigar: "1X1199="
                )]),
                .ambiguousReferenceClass,
                nil
            ),
        ]

        for (label, cluster, reason, failedMetric) in cases {
            guard case .unnameable(let record) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
                XCTFail("Expected un-nameable result for \(label)")
                continue
            }
            XCTAssertEqual(record.reason, reason, label)
            XCTAssertEqual(record.stableClusterID, cluster.stableClusterID, label)
            XCTAssertEqual(record.fastaRecordID, cluster.fastaRecordID, label)
            XCTAssertEqual(record.sequenceSHA256, cluster.sequenceSHA256, label)
            if let failedMetric {
                XCTAssertNotNil(record.failedMetrics[failedMetric], label)
            } else {
                XCTAssertTrue(record.failedMetrics.isEmpty, label)
            }
        }
    }

    func testUnnameableProjectionIncludesEveryFailedThresholdMetric() throws {
        let cluster = makeCluster(
            sequenceLength: 2_000,
            alignments: [alignment(
                resolution: .unresolvedLocus(referenceName: "long-ref", sequenceLength: 2_000),
                cigar: "800X100="
            )]
        )

        guard case .unnameable(let record) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected un-nameable result")
        }
        XCTAssertEqual(record.reason, .insufficientAlignedBases)
        XCTAssertEqual(record.failedMetrics["aligned_bases"], 900)
        XCTAssertEqual(record.failedMetrics["minimum_aligned_bases"], 1_000)
        XCTAssertEqual(record.failedMetrics["shorter_coverage"], 0.45)
        XCTAssertEqual(record.failedMetrics["minimum_shorter_coverage"], 0.70)
        XCTAssertEqual(
            try XCTUnwrap(record.failedMetrics["identity"]),
            100.0 / 900.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(record.failedMetrics["minimum_identity"], 0.75)
    }

    func testRejectsReciprocalEvidenceQueryReferenceAndBAMIdentityMismatches() throws {
        let queryMismatch = alignment(
            reference: genomicReference,
            cigar: "1X1199=",
            queryName: "another-cluster"
        )
        let referenceMismatch = alignment(
            resolution: .resolved(genomicReference),
            cigar: "1X1199=",
            referenceName: "another-reference"
        )
        let bamMismatch = alignment(
            resolution: .resolved(genomicReference),
            cigar: "1X1199=",
            bamPath: "artifacts/alignments/not-the-reciprocal.bam"
        )

        for alignment in [queryMismatch, referenceMismatch, bamMismatch] {
            XCTAssertThrowsError(try FullLengthONTMHCCandidateClassifier().classify(
                makeCluster(alignments: [alignment])
            )) { error in
                guard case .invalidAlignment(_, _, let field, _) = error as? FullLengthONTMHCCandidateClassifierError else {
                    return XCTFail("Expected typed invalid-alignment error, got \(error)")
                }
                XCTAssertTrue([
                    "evidence.queryName", "evidence.referenceName", "evidence.bamPath",
                ].contains(field))
            }
        }
    }

    func testRankingUsesAllDeclaredTieBreakers() throws {
        let referenceA = genomicReference
        let referenceB = MHCReferenceRecord(
            sequenceID: "ref-b",
            alleleName: "Mafa-A1*019:01",
            locus: "Mafa-A1",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let alignments = [
            alignment(reference: referenceB, cigar: "590=1X9=1I600=", mapq: 60, score: 2_000),
            alignment(reference: referenceB, cigar: "590=1X609=", mapq: 30, score: 1_500),
            alignment(reference: referenceA, cigar: "590=1X609=", mapq: 30, score: 1_500),
            alignment(reference: referenceA, cigar: "590=1X609=", mapq: 20, score: 1_500),
        ]

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(
            makeCluster(sequenceLength: 1_201, alignments: alignments)
        ) else {
            return XCTFail("Expected candidate")
        }
        XCTAssertEqual(candidate.closestReferenceName, referenceB.alleleName)
        XCTAssertEqual(candidate.mappingQuality, 60)
        XCTAssertEqual(candidate.alignmentScore, 2_000)
        XCTAssertEqual(candidate.insertedBases, 1)
    }

    func testClosestReferenceUsesSNPCountWithinSharedSequenceBeforeIndels() throws {
        let fewerSNPsButMoreEdits = MHCReferenceRecord(
            sequenceID: "ref-fewer-snps-more-edits",
            alleleName: "Mamu-DRB1*03:09:01:01",
            locus: "Mamu-DRB1",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_200
        )
        let moreSNPsButFewerEdits = MHCReferenceRecord(
            sequenceID: "ref-more-snps-fewer-edits",
            alleleName: "Mamu-DRB1*03:09:01:02",
            locus: "Mamu-DRB1",
            moleculeClass: .genomicDNA,
            classEvidence: .annotatedMetadata,
            sequenceLength: 1_201
        )
        let cluster = makeCluster(
            sequenceLength: 1_203,
            alignments: [
                alignment(
                    reference: fewerSNPsButMoreEdits,
                    cigar: "1X3I1199=",
                    score: 1_500
                ),
                alignment(
                    reference: moreSNPsButFewerEdits,
                    cigar: "2X1199=",
                    score: 2_000
                ),
            ]
        )

        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier()
            .classify(cluster) else {
            return XCTFail("Expected novel candidate")
        }

        XCTAssertEqual(candidate.closestReferenceName, fewerSNPsButMoreEdits.alleleName)
        XCTAssertEqual(candidate.snpCount, 1)
        XCTAssertEqual(candidate.insertedBases, 3)
        XCTAssertEqual(candidate.deletedBases, 0)
        XCTAssertEqual(
            candidate.reciprocalHitSummary.closestMatchTargetNames,
            [fewerSNPsButMoreEdits.sequenceID]
        )
        XCTAssertEqual(candidate.provisionalName, "Mamu-DRB1*03:09:01:01_1nt_nov")
    }

    func testRejectsInvalidThresholdsAndNumericInputs() throws {
        XCTAssertThrowsError(try ONTMHCCandidateThresholds(
            minimumAlignedBases: 0,
            minimumIdentity: 0.75,
            minimumShorterCoverage: 0.70,
            minimumIntronGapBases: 20
        ))
        XCTAssertThrowsError(try ONTMHCCandidateThresholds(
            minimumAlignedBases: 1_000,
            minimumIdentity: .nan,
            minimumShorterCoverage: 0.70,
            minimumIntronGapBases: 20
        ))
        XCTAssertThrowsError(try ONTMHCCandidateThresholds(
            minimumAlignedBases: 1_000,
            minimumIdentity: 0,
            minimumShorterCoverage: 0.70,
            minimumIntronGapBases: 20
        ))
        XCTAssertThrowsError(try FullLengthONTMHCCandidateClassifier().classify(
            makeCluster(sequenceLength: 0, alignments: [])
        ))
        XCTAssertThrowsError(try FullLengthONTMHCCandidateClassifier().classify(
            makeCluster(observations: [observation(reads: -1)], alignments: [])
        ))
        XCTAssertThrowsError(try FullLengthONTMHCCandidateClassifier().classify(
            makeCluster(alignments: [alignment(reference: genomicReference, cigar: "1200=", mapq: -1)])
        ))
        XCTAssertThrowsError(try FullLengthONTMHCCandidateClassifier().classify(
            makeCluster(alignments: [alignment(reference: genomicReference, cigar: "bad")])
        ))
    }

    func testCandidateDocumentsRoundTripCompleteProjectionWithoutSequenceBases() throws {
        let candidateResult = try FullLengthONTMHCCandidateClassifier().classify(
            makeCluster(alignments: [alignment(reference: genomicReference, cigar: "595=5X600=")])
        )
        guard case .candidate(let candidate) = candidateResult else {
            return XCTFail("Expected candidate")
        }
        let thresholds = ONTMHCCandidateThresholds.defaults
        let artifact = ONTMHCArtifactReference(path: "artifacts/candidates.fa", sha256: "abc", sizeBytes: 42)
        let document = ONTMHCCandidateAllelesDocument(
            schemaVersion: 2,
            createdAt: "2026-07-19T12:00:00Z",
            thresholds: thresholds,
            inputs: [artifact],
            evidence: [artifact],
            sequenceFASTA: artifact,
            candidates: [candidate],
            observations: makeCluster().observations
        )

        let data = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(ONTMHCCandidateAllelesDocument.self, from: data), document)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["schema_version"])
        XCTAssertNotNil(object["sequence_fasta"])
        let records = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        XCTAssertNil(records[0]["sequence"])
        XCTAssertEqual(records[0]["stable_cluster_id"] as? String, "cluster-1")

        var extensionObject = object
        var extensionRecords = records
        extensionRecords[0]["extension_of"] = ["Mafa-I*01:14:13", "Mafa-I*01:14:14"]
        extensionObject["candidates"] = extensionRecords
        let extensionData = try JSONSerialization.data(withJSONObject: extensionObject)
        let decodedExtension = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: extensionData
        )
        XCTAssertEqual(
            decodedExtension.candidates.first?.extensionOf,
            ["Mafa-I*01:14:13", "Mafa-I*01:14:14"]
        )

        let unnameableResult = try FullLengthONTMHCCandidateClassifier().classify(makeCluster(alignments: []))
        guard case .unnameable(let unnameable) = unnameableResult else {
            return XCTFail("Expected un-nameable record")
        }
        let unresolvedDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: 2,
            createdAt: "2026-07-19T12:00:00Z",
            thresholds: thresholds,
            sequenceFASTA: artifact,
            clusters: [unnameable],
            observations: makeCluster().observations
        )
        let unresolvedData = try JSONEncoder().encode(unresolvedDocument)
        XCTAssertEqual(
            try JSONDecoder().decode(ONTMHCUnnameableClustersDocument.self, from: unresolvedData),
            unresolvedDocument
        )
    }

    private func makeCluster(
        stableClusterID: String = "cluster-1",
        fastaRecordID: String = "cluster-1",
        sequenceLength: Int = 1_200,
        observations: [ONTMHCCandidateObservation]? = nil,
        alignments: [FullLengthONTMHCCandidateAlignment] = []
    ) -> FullLengthONTMHCCandidateCluster {
        FullLengthONTMHCCandidateCluster(
            stableClusterID: stableClusterID,
            fastaRecordID: fastaRecordID,
            sequenceSHA256: String(repeating: "a", count: 64),
            sequenceLength: sequenceLength,
            observations: observations ?? [observation(stableClusterID: stableClusterID)],
            alignments: alignments
        )
    }

    private func observation(
        stableClusterID: String = "cluster-1",
        sampleID: String = "sample-1",
        readGroupID: String = "rg-1",
        reads: Int = 5,
        sourceClusterIDs: [String] = ["source-1"],
        extensionInterpretations: [ONTMHCCDNAExtensionInterpretation] = []
    ) -> ONTMHCCandidateObservation {
        let summaries = sourceClusterIDs.compactMap { sourceClusterID in
            try? ONTMHCGenotypingTargetHitSummary(
                bamPath: "artifacts/alignments/genotyping-evidence.bam",
                targetName: "\(sampleID)|\(sourceClusterID)",
                alignmentCount: 1,
                queryAlignmentCounts: ["ref-genomic": 1],
                exactMatchQueryNames: [],
                closestMatchQueryNames: ["ref-genomic"],
                cdnaExtensionInterpretations: extensionInterpretations
            )
        }
        return ONTMHCCandidateObservation(
            stableClusterID: stableClusterID,
            sampleID: sampleID,
            readGroupID: readGroupID,
            sourceClusterIDs: sourceClusterIDs,
            sourceClusterReadCounts: positiveReadCounts(total: reads, sourceClusterIDs: sourceClusterIDs),
            aggregatedSampleReadCount: reads,
            genotypingHitSummaries: summaries
        )
    }

    private func alignment(
        reference: MHCReferenceRecord,
        cigar: String,
        mapq: Int = 60,
        score: Int = 2_000,
        queryName: String = "cluster-1",
        referenceStart: Int = 1,
        isReverse: Bool = false
    ) -> FullLengthONTMHCCandidateAlignment {
        alignment(
            resolution: .resolved(reference),
            cigar: cigar,
            mapq: mapq,
            score: score,
            queryName: queryName,
            referenceName: reference.sequenceID,
            referenceStart: referenceStart,
            isReverse: isReverse
        )
    }

    private func alignment(
        resolution: FullLengthONTMHCCandidateReferenceResolution,
        cigar: String,
        mapq: Int = 60,
        score: Int = 2_000,
        queryName: String = "cluster-1",
        referenceName: String? = nil,
        bamPath: String = "artifacts/alignments/unmatched-to-reference.bam",
        referenceStart: Int = 1,
        isReverse: Bool = false
    ) -> FullLengthONTMHCCandidateAlignment {
        FullLengthONTMHCCandidateAlignment(
            reference: resolution,
            cigar: cigar,
            nm: nil,
            mappingQuality: mapq,
            alignmentScore: score,
            evidence: evidence(
                queryName: queryName,
                referenceName: referenceName ?? resolution.referenceName,
                readGroupID: nil,
                cigar: cigar,
                bamPath: bamPath,
                referenceStart: referenceStart
            ),
            isReverse: isReverse
        )
    }

    private func extensionInterpretation(
        reference: MHCReferenceRecord,
        isReverse: Bool
    ) -> ONTMHCCDNAExtensionInterpretation {
        ONTMHCCDNAExtensionInterpretation(
            rawReferenceID: reference.sequenceID,
            alleleName: reference.alleleName,
            locus: reference.locus,
            cDNAReferenceCoverage: 1,
            clusterCoverage: 1_000.0 / 1_050.0,
            leadingClusterFlankBases: 0,
            trailingClusterFlankBases: 0,
            largestClusterStructuralSegmentBases: 50,
            largestCDNADeficitSegmentBases: 0,
            snpSubstitutions: 0,
            ordinaryIndelBases: 0,
            isReverse: isReverse,
            alignmentScore: 2_000,
            identity: 1
        )
    }

    private func positiveReadCounts(total: Int, sourceClusterIDs: [String]) -> [String: Int] {
        guard !sourceClusterIDs.isEmpty else { return [:] }
        let quotient = total / sourceClusterIDs.count
        let remainder = total % sourceClusterIDs.count
        return Dictionary(uniqueKeysWithValues: sourceClusterIDs.enumerated().map { index, sourceID in
            (sourceID, quotient + (index < remainder ? 1 : 0))
        })
    }

    private func evidence(
        queryName: String,
        referenceName: String,
        readGroupID: String?,
        cigar: String = "1200=",
        bamPath: String = "artifacts/alignments/unmatched-to-reference.bam",
        referenceStart: Int = 1
    ) -> ONTMHCEvidenceLocator {
        ONTMHCEvidenceLocator(
            bamPath: bamPath,
            queryName: queryName,
            referenceName: referenceName,
            readGroupID: readGroupID,
            referenceStart: referenceStart,
            cigar: cigar
        )
    }
}
