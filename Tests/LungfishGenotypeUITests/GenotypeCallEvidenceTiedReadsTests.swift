import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishGenotypeUI

/// Decision D2 of the Phase 2.3 follow-up, in the call evidence pane. The
/// pane's pooled locus and sample read summaries count a tied cluster once,
/// the same rule as the locus denominator, so a two-way tie is not counted
/// twice there.
@MainActor
final class GenotypeCallEvidenceTiedReadsTests: GenotypeResultViewportTestCase {
    func testEvidencePaneLocusAndSampleSummariesCountATiedClusterOnce() throws {
        let tie = ["01_M1_A1_001", "02_M1_A1_002"]
        let calls = [
            tiedCall(sample: "LF1", genotype: tie[0], reads: 1_000, ambiguousWith: tie),
            tiedCall(sample: "LF1", genotype: tie[1], reads: 1_000, ambiguousWith: tie),
            tiedCall(sample: "LF1", genotype: "03_M2_A1_003", reads: 15, ambiguousWith: nil),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "test-assay",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF1",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "M1A",
                            haplotype2: "M2A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: calls.map(\.genotype)
                        ),
                    ]
                ),
            ]
        )
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "LF1",
                    passedAlignments: 1_015,
                    passedUniqueReads: 1_015,
                    sampleTotalReads: 5_000,
                    sampleUniqueRetainedPercent: 20.3,
                    calls: calls
                ),
            ],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "LF1", locus: "MHC-A"))

        XCTAssertEqual(evidence.sampleAssignedGenotypeReads, 1_015, "the tied 1,000-read cluster counts once beside the 15-read allele")
        XCTAssertEqual(evidence.locusReadTotal, 1_015, "the pooled locus total counts the tie once, not 2,015")
        XCTAssertEqual(evidence.sampleFullLengthReads, 1_015)
    }

    private func tiedCall(sample: String, genotype: String, reads: Int, ambiguousWith: [String]?) -> ONTGenotypeCall {
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
            overallUniqueRetainedPercent: nil,
            ambiguousWith: ambiguousWith
        )
    }
}
