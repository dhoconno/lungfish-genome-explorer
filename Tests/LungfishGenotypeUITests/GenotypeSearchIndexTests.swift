import XCTest
@testable import LungfishGenotypeUI

final class GenotypeSearchIndexTests: XCTestCase {
    private let alleleRowID = GenotypeCandidateMatrixRowID.known(
        locus: "A1",
        genotype: "internal-cluster-42"
    )
    private let coincidentalRowID = GenotypeCandidateMatrixRowID.known(
        locus: "B",
        genotype: "allele-1178"
    )

    func testDisplayedAlleleNormalizationMatchesPunctuationAndCompactVariants() {
        let index = makeIndex()

        for query in ["A1*007", "A1 007", "A1007"] {
            let matches = index.search(query)
            XCTAssertEqual(matches.mode, .projectedRow)
            XCTAssertEqual(matches.projectedRowIDs, [alleleRowID])
            XCTAssertEqual(matches.alleleCarrierSampleIDs, ["CR1178", "CR1178b"])
        }
    }

    func testSampleIdentityHasRoutingPriorityWithoutDiscardingIndependentRowHits() {
        let index = makeIndex()

        let full = index.search("CR1178")
        let substring = index.search("1178")

        XCTAssertEqual(full.mode, .sample)
        XCTAssertEqual(substring.mode, .sample)
        XCTAssertEqual(full.sampleIdentityAndMetadataIDs, ["CR1178", "CR1178b"])
        XCTAssertEqual(substring.sampleIdentityAndMetadataIDs, full.sampleIdentityAndMetadataIDs)
        XCTAssertEqual(substring.projectedRowIDs, [coincidentalRowID])
        XCTAssertEqual(substring.alleleCarrierSampleIDs, ["OTHER"])
    }

    func testSampleMetadataKeysValuesAndFieldFormsArePreindexed() {
        let index = makeIndex()

        XCTAssertEqual(index.search("Treatment Alpha").sampleIdentityAndMetadataIDs, ["CR1178"])
        XCTAssertEqual(index.search("cohort").sampleIdentityAndMetadataIDs, ["CR1178", "CR1178b"])
        XCTAssertEqual(index.search("cohort:Treatment Alpha").sampleIdentityAndMetadataIDs, ["CR1178"])
        XCTAssertEqual(index.search("cohort=Control").sampleIdentityAndMetadataIDs, ["CR1178b"])
    }

    func testVisibleReferenceMetadataAndRawGenotypeAreProjectedRowFields() {
        let index = makeIndex()

        XCTAssertEqual(index.search("reference seven").projectedRowIDs, [alleleRowID])
        XCTAssertEqual(index.search("internal-cluster").projectedRowIDs, [alleleRowID])
        XCTAssertEqual(index.search("stable-007").projectedRowIDs, [alleleRowID])
    }

    func testAnnotationAndCommentHitsRemainIndependentAndParticipateInPriority() {
        let index = makeIndex(
            annotations: [
                .init(target: .sample("CR1178"), text: "Unexpected phenotype"),
                .init(target: .row(alleleRowID), text: "Reference ambiguity"),
                .init(
                    target: .cell(rowID: alleleRowID, sampleID: "CR1178b"),
                    text: "Analyst cell observation"
                ),
            ]
        )

        let sampleNote = index.search("phenotype")
        XCTAssertEqual(sampleNote.mode, .sample)
        XCTAssertEqual(sampleNote.annotationAndCommentSampleIDs, ["CR1178"])
        XCTAssertTrue(sampleNote.annotationAndCommentRowIDs.isEmpty)

        let rowNote = index.search("ambiguity")
        XCTAssertEqual(rowNote.mode, .projectedRow)
        XCTAssertEqual(rowNote.annotationAndCommentRowIDs, [alleleRowID])
        XCTAssertTrue(rowNote.annotationAndCommentSampleIDs.isEmpty)

        let cellNote = index.search("cell observation")
        XCTAssertEqual(cellNote.mode, .sample)
        XCTAssertEqual(cellNote.annotationAndCommentSampleIDs, ["CR1178b"])
        XCTAssertEqual(cellNote.annotationAndCommentRowIDs, [alleleRowID])
    }

    func testCommentCompatibilityIsFallbackAndCannotMaskAlleleRouting() {
        let index = makeIndex(
            annotations: [
                .init(
                    target: .sample("OTHER"),
                    text: "Please review A1*007 annotation"
                ),
            ]
        )

        let matches = index.search("A1*007")

        XCTAssertEqual(matches.mode, .projectedRow)
        XCTAssertEqual(matches.projectedRowIDs, [alleleRowID])
        XCTAssertEqual(matches.annotationAndCommentSampleIDs, ["OTHER"])
    }

    func testHaplotypeCarrierModeIsLastPriorityAndCapabilityGated() {
        let enabled = makeIndex(
            hasHaplotypingResult: true,
            haplotypes: {
                [
                    .init(
                        name: "HAP-A",
                        locus: "MHC-A",
                        aliases: ["Ancestral Seven"],
                        carrierSampleIDs: ["CR1178b"]
                    ),
                ]
            }
        )

        let matches = enabled.search("Ancestral Seven")
        XCTAssertEqual(matches.mode, .haplotypeCarrier)
        XCTAssertEqual(matches.haplotypeCarrierSampleIDs, ["CR1178b"])
        XCTAssertEqual(enabled.haplotypeRecordCount, 1)
    }

    func testHaplotypeCarrierRequiredFieldPrecedesCommentCompatibilityFallback() {
        let index = makeIndex(
            annotations: [
                .init(
                    target: .sample("OTHER"),
                    text: "Ancestral Seven comment"
                ),
            ],
            hasHaplotypingResult: true,
            haplotypes: {
                [
                    .init(
                        name: "HAP-A",
                        aliases: ["Ancestral Seven"],
                        carrierSampleIDs: ["CR1178b"]
                    ),
                ]
            }
        )

        let matches = index.search("Ancestral Seven")

        XCTAssertEqual(matches.mode, .haplotypeCarrier)
        XCTAssertEqual(matches.haplotypeCarrierSampleIDs, ["CR1178b"])
        XCTAssertEqual(matches.annotationAndCommentSampleIDs, ["OTHER"])
    }

    func testGenotypeOnlyIndexDoesNotEvaluateOrStoreHaplotypeRecords() {
        var haplotypeFactoryCalls = 0
        let index = makeIndex(
            hasHaplotypingResult: false,
            haplotypes: {
                haplotypeFactoryCalls += 1
                return [
                    .init(
                        name: "HAP-A",
                        carrierSampleIDs: ["CR1178"]
                    ),
                ]
            }
        )

        XCTAssertEqual(haplotypeFactoryCalls, 0)
        XCTAssertEqual(index.haplotypeRecordCount, 0)
        XCTAssertEqual(index.search("HAP-A").mode, .none)
        XCTAssertTrue(index.search("HAP-A").haplotypeCarrierSampleIDs.isEmpty)
        XCTAssertEqual(haplotypeFactoryCalls, 0)
    }

    func testUnicodeLetterAndDecimalDigitNormalizationPreservesOrder() {
        let unicodeRowID = GenotypeCandidateMatrixRowID.known(
            locus: "Unicode",
            genotype: "unicode-raw"
        )
        let index = GenotypeSearchIndex(
            samples: [],
            projectedRows: [
                .init(
                    id: unicodeRowID,
                    displayedAllele: "α1*٠٠٧",
                    rawGenotype: "unicode-raw",
                    locus: "Unicode",
                    carrierSampleIDs: []
                ),
            ],
            annotationsAndComments: [],
            hasHaplotypingResult: false
        )

        XCTAssertEqual(index.search("Α1 ٠٠٧").projectedRowIDs, [unicodeRowID])
        XCTAssertEqual(index.search("Α1-٠٠٧").projectedRowIDs, [unicodeRowID])
    }

    func testShortOrPunctuationOnlyQueriesDoNotUseNormalizedFallback() {
        let index = makeIndex()

        XCTAssertEqual(index.search("*").mode, .none)
        XCTAssertTrue(index.search("*").projectedRowIDs.isEmpty)
        XCTAssertTrue(index.search("A 1").projectedRowIDs.isEmpty)
        XCTAssertTrue(index.search("A*").projectedRowIDs.isEmpty)
    }

    func testEmptyAndWhitespaceQueriesReturnNoSearchMode() {
        let index = makeIndex()

        XCTAssertEqual(index.search("").mode, .none)
        XCTAssertEqual(index.search("  \n ").mode, .none)
        XCTAssertTrue(index.search("").sampleIdentityAndMetadataIDs.isEmpty)
        XCTAssertTrue(index.search("").projectedRowIDs.isEmpty)
    }

    func testIndexOwnsAnImmutableSnapshotOfMutableInputs() {
        var metadata = ["cohort": "Treatment Alpha"]
        var samples = [
            GenotypeSearchIndex.SampleRecord(
                stableID: "CR1178",
                metadata: metadata
            ),
        ]
        let index = GenotypeSearchIndex(
            samples: samples,
            projectedRows: [],
            annotationsAndComments: [],
            hasHaplotypingResult: false
        )

        metadata["cohort"] = "Mutated"
        samples[0] = .init(stableID: "Changed", metadata: metadata)

        XCTAssertEqual(index.search("Treatment Alpha").sampleIdentityAndMetadataIDs, ["CR1178"])
        XCTAssertTrue(index.search("Mutated").sampleIdentityAndMetadataIDs.isEmpty)
        XCTAssertTrue(index.search("Changed").sampleIdentityAndMetadataIDs.isEmpty)
    }

    func testProjectedRowCarrierLookupIsPrecomputedOnceAndReusedAcrossQueries() {
        let index = makeIndex(
            annotations: [
                .init(target: .row(alleleRowID), text: "review carrier lookup"),
            ]
        )

        XCTAssertEqual(index.projectedRowCarrierLookupCount, 2)
        XCTAssertEqual(
            index.search("review carrier").annotationAndCommentCarrierSampleIDs,
            ["CR1178", "CR1178b"]
        )
        XCTAssertEqual(index.search("A1*007").alleleCarrierSampleIDs, ["CR1178", "CR1178b"])
        XCTAssertEqual(index.projectedRowCarrierLookupCount, 2)
    }

    private func makeIndex(
        annotations: [GenotypeSearchIndex.AnnotationOrCommentRecord] = [],
        hasHaplotypingResult: Bool = false,
        haplotypes: () -> [GenotypeSearchIndex.HaplotypeCarrierRecord] = { [] }
    ) -> GenotypeSearchIndex {
        GenotypeSearchIndex(
            samples: [
                .init(
                    stableID: "CR1178",
                    identityAliases: ["Animal 1178"],
                    metadata: ["cohort": "Treatment Alpha"]
                ),
                .init(
                    stableID: "CR1178b",
                    metadata: ["cohort": "Control"]
                ),
                .init(stableID: "OTHER"),
            ],
            projectedRows: [
                .init(
                    id: alleleRowID,
                    displayedAllele: "Mafa-A1*007:01",
                    rawGenotype: "internal-cluster-42",
                    locus: "A1",
                    stableClusterID: "stable-007",
                    visibleReferenceMetadata: ["description": "Reference Seven"],
                    carrierSampleIDs: ["CR1178", "CR1178b"]
                ),
                .init(
                    id: coincidentalRowID,
                    displayedAllele: "Mafa-B*1178:01",
                    rawGenotype: "allele-1178",
                    locus: "B",
                    carrierSampleIDs: ["OTHER"]
                ),
            ],
            annotationsAndComments: annotations,
            hasHaplotypingResult: hasHaplotypingResult,
            haplotypeCarriers: haplotypes
        )
    }
}
