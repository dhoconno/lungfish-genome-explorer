import XCTest
@testable import LungfishGenotypeUI
import LungfishIO

final class GenotypeResultPresentationPolicyTests: XCTestCase {
    func testTypedMiSeqHaplotypedUsableAnalysisUsesSynchronizedChoices() {
        let policy = makePolicy(
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped,
            analysis: usableAnalysis()
        )

        XCTAssertTrue(policy.appliesToHaplotypedMiSeq)
        XCTAssertEqual(policy.choices.map(\.displayName), [
            "Haplotype Calls",
            "Genotype Matrix",
        ])
        XCTAssertEqual(policy.defaultSummaryViewMode, .outline)
        XCTAssertEqual(
            policy.normalize(displayState: .init(viewportLens: .audit)).viewportLens,
            .summary
        )
        XCTAssertEqual(policy.persistencePolicy, .bundle)
    }

    func testExistingPoliciesRemainScopedToTheirWorkflowDeclarations() {
        let cases: [(name: String, policy: GenotypeResultPresentationPolicy, defaultMode: GenotypeSummaryViewMode, applies: Bool)] = [
            (
                "typed miSeq genotype-only",
                makePolicy(
                    workflowKind: .miSeqAmpliconMHCGenotype,
                    workflowMode: .genotypeOnly,
                    analysis: nil
                ),
                .matrix,
                false
            ),
            (
                "haplotyped non-miSeq",
                makePolicy(
                    workflowKind: .fullLengthONTMHCGenotype,
                    workflowMode: .haplotyped,
                    analysis: usableAnalysis(),
                    hasNativeGenotypeMatrixContent: true
                ),
                .outline,
                false
            ),
            (
                "legacy kind-only",
                makePolicy(
                    workflowKind: nil,
                    workflowMode: nil,
                    analysis: usableAnalysis(),
                    hasNativeGenotypeMatrixContent: true
                ),
                .outline,
                false
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(testCase.policy.defaultSummaryViewMode, testCase.defaultMode, testCase.name)
            XCTAssertEqual(testCase.policy.appliesToHaplotypedMiSeq, testCase.applies, testCase.name)
        }
    }

    func testMalformedAnalysisFallsBackToMatrixWithoutRewritingPreference() {
        let empty = makePolicy(
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped,
            analysis: emptyAnalysis()
        )
        let duplicate = makePolicy(
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped,
            analysis: duplicateKeyAnalysis()
        )

        for policy in [empty, duplicate] {
            XCTAssertFalse(policy.appliesToHaplotypedMiSeq)
            XCTAssertEqual(policy.defaultSummaryViewMode, .matrix)
            XCTAssertEqual(policy.normalize(displayState: .init()).summaryViewMode, .matrix)
            XCTAssertEqual(policy.persistencePolicy, .preserveStoredPreference)
            XCTAssertNotNil(policy.haplotypeCallsUnavailableExplanation)
        }
    }

    func testDuplicateNormalizedSampleIDsWithDistinctLociFallBackToMatrix() {
        let policy = makePolicy(
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped,
            analysis: duplicateSampleIDAnalysis()
        )

        XCTAssertFalse(policy.appliesToHaplotypedMiSeq)
        XCTAssertEqual(policy.defaultSummaryViewMode, .matrix)
        XCTAssertEqual(policy.persistencePolicy, .preserveStoredPreference)
    }

    func testStaleReviewAndAuditIngressNormalizeToHaplotypeCalls() {
        let policy = makePolicy(
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped,
            analysis: usableAnalysis()
        )

        for lens in [GenotypeResultViewportLens.review, .audit] {
            let normalized = policy.normalize(displayState: .init(viewportLens: lens, summaryViewMode: .matrix))
            XCTAssertEqual(normalized.viewportLens, .summary)
            XCTAssertEqual(normalized.summaryViewMode, .outline)
        }
    }

    func testReadOnlyBundleMakesSelectionSessionOnly() {
        let policy = makePolicy(
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped,
            analysis: usableAnalysis(),
            isReadOnly: true
        )

        XCTAssertEqual(policy.persistencePolicy, .sessionOnly)
        XCTAssertTrue(policy.viewportAccessibilityHelp.contains("session"))
        XCTAssertTrue(policy.inspectorAccessibilityHelp.contains("session"))
    }

    private func makePolicy(
        workflowKind: GenotypeResultWorkflowKind?,
        workflowMode: GenotypeResultWorkflowMode?,
        analysis: GenotypeHaplotypeAnalysis?,
        hasNativeGenotypeMatrixContent: Bool = false,
        isReadOnly: Bool = false
    ) -> GenotypeResultPresentationPolicy {
        GenotypeResultPresentationPolicy(
            workflowKind: workflowKind,
            workflowMode: workflowMode,
            manualHaplotypeEligibility: manualEligibility(
                workflowKind: workflowKind,
                workflowMode: workflowMode
            ),
            haplotypeAnalysis: analysis,
            hasNativeGenotypeMatrixContent: hasNativeGenotypeMatrixContent,
            isReadOnly: isReadOnly
        )
    }

    private func manualEligibility(
        workflowKind: GenotypeResultWorkflowKind?,
        workflowMode: GenotypeResultWorkflowMode?
    ) -> GenotypeManualHaplotypeEligibility {
        workflowMode == .genotypeOnly
            ? .eligible(resultKind: workflowKind ?? .miSeqAmpliconMHCGenotype)
            : .ineligible(reason: "This result declares that haplotyping was performed.")
    }

    private func usableAnalysis() -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "definitions",
            definitionSetName: "Definitions",
            speciesName: "Macaque",
            samples: [
                .init(sample: "Sample-1", calls: [call(locus: "MHC-A")]),
            ]
        )
    }

    private func emptyAnalysis() -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "definitions",
            definitionSetName: "Definitions",
            speciesName: "Macaque",
            samples: []
        )
    }

    private func duplicateKeyAnalysis() -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "definitions",
            definitionSetName: "Definitions",
            speciesName: "Macaque",
            samples: [
                .init(sample: "Sample-1", calls: [call(locus: "MHC-A")]),
                .init(sample: "Sample-1", calls: [call(locus: "MHC-A")]),
            ]
        )
    }

    private func duplicateSampleIDAnalysis() -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "definitions",
            definitionSetName: "Definitions",
            speciesName: "Macaque",
            samples: [
                .init(sample: "Sample-1", calls: [call(locus: "MHC-A")]),
                .init(sample: " Sample-1 ", calls: [call(locus: "MHC-B")]),
            ]
        )
    }

    private func call(locus: String) -> GenotypeHaplotypeLocusCall {
        GenotypeHaplotypeLocusCall(
            locus: locus,
            sourceLocus: locus,
            haplotype1: "M1",
            haplotype2: "M2",
            status: .called,
            matchedHaplotypes: [],
            observedGenotypeCount: 2,
            observedGenotypes: []
        )
    }
}
