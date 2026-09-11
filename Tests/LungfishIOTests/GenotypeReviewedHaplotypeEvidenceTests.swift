import XCTest
@testable import LungfishIO

final class GenotypeReviewedHaplotypeEvidenceTests: XCTestCase {
    func testFalsePositiveExcludesOnlyTheExactCellAndKeepsRawCallsUntouched() {
        let retained = call(
            sample: "AnimalA",
            genotype: "01_M1_A_marker",
            reads: 100
        )
        let excluded = call(
            sample: "AnimalA",
            genotype: "02_M2_A_marker",
            reads: 3
        )
        let sameGenotypeOtherSample = call(
            sample: "AnimalB",
            genotype: "02_M2_A_marker",
            reads: 80
        )
        let calls = [retained, excluded, sameGenotypeOtherSample]
        let review = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: .cell(
                locus: "Mafa-A",
                genotype: excluded.genotype,
                sample: excluded.sample
            ),
            disposition: .falsePositive,
            author: "analyst",
            timestamp: "2026-09-11T00:00:00Z"
        )

        let filtered = GenotypeReviewedHaplotypeEvidence.callsForInference(
            calls,
            reviews: [review]
        )

        XCTAssertEqual(filtered, [retained, sameGenotypeOtherSample])
        XCTAssertEqual(calls, [retained, excluded, sameGenotypeOtherSample])
    }

    func testFalsePositiveWithStableClusterIdentityDoesNotExcludeAPlainCall() {
        let call = call(
            sample: "AnimalA",
            genotype: "02_M2_A_marker",
            reads: 3
        )
        let review = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: .cell(
                locus: "MHC-A",
                genotype: call.genotype,
                sample: call.sample,
                stableClusterID: "candidate-cluster"
            ),
            disposition: .falsePositive,
            author: "analyst",
            timestamp: "2026-09-11T00:00:00Z"
        )

        XCTAssertEqual(
            GenotypeReviewedHaplotypeEvidence.callsForInference(
                [call],
                reviews: [review]
            ),
            [call]
        )
    }

    func testFalseNegativeDoesNotFabricateCallsOrAlterRawEvidence() {
        let calls = [call(
            sample: "AnimalA",
            genotype: "01_M1_A_marker",
            reads: 100
        )]
        let review = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: .cell(
                locus: "MHC-A",
                genotype: "02_M2_A_marker",
                sample: "AnimalA"
            ),
            disposition: .falseNegative,
            author: "analyst",
            timestamp: "2026-09-11T00:00:00Z"
        )

        XCTAssertEqual(
            GenotypeReviewedHaplotypeEvidence.callsForInference(
                calls,
                reviews: [review]
            ),
            calls
        )
    }

    func testAllFalsePositiveSampleRemainsInAnalyzerRosterWithoutFabricatedEvidence() throws {
        let call = call(
            sample: "AnimalA",
            genotype: "01_M1_A_marker",
            reads: 3
        )
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "reviewed-evidence-roster-test",
            assayID: "MHC-exon2-miSeq",
            displayName: "Reviewed evidence roster test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                .init(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [
                        .init(
                            name: "M1A",
                            diagnosticAlleles: [call.genotype],
                            minimumMatches: 1
                        ),
                    ]
                ),
            ]
        )
        let review = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: .cell(
                locus: "MHC-A",
                genotype: call.genotype,
                sample: call.sample
            ),
            disposition: .falsePositive,
            author: "analyst",
            timestamp: "2026-09-11T00:00:00Z"
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [call],
            definitionSet: definition,
            dropoutFilter: nil,
            matrixReviews: [review]
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        XCTAssertEqual(analysis.samples.map(\.sample), ["AnimalA"])
        XCTAssertEqual(sample.calls.count, 1)
        XCTAssertTrue(sample.calls[0].observedGenotypes.isEmpty)
        XCTAssertNotEqual(sample.calls[0].status, .called)
    }

    private func call(sample: String, genotype: String, reads: Int) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }
}
