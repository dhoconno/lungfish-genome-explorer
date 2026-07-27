import Foundation
import XCTest
import LungfishIO
@testable import LungfishGenotypeUI

final class GenotypeManualHaplotypeEligibilityTests: XCTestCase {
    func testExplicitFullLengthONTAndMiSeqGenotypeOnlyResultsAreEligible() {
        for kind in GenotypeResultWorkflowKind.allCases {
            let result = makeResult(
                legacyKind: kind.rawValue,
                workflowKind: kind,
                workflowMode: .genotypeOnly
            )
            XCTAssertEqual(
                GenotypeManualHaplotypeEligibility.evaluate(result),
                .eligible(resultKind: kind)
            )
        }
    }

    func testEachAuthoritativeHaplotypingIndicatorFailsClosed() {
        let revision = ONTGenotypeHaplotypeAnalysisRevision(
            id: "revision-1",
            method: .deterministic,
            path: "haplotypes/revision-1.json",
            createdAt: "2026-07-26T00:00:00Z",
            reviewState: .reviewed,
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 1,
            provenancePath: "provenance/revision-1.json"
        )
        let cases: [ONTGenotypeResultBundleData] = [
            makeResult(haplotypeAnalysisPath: "haplotypes/current.json"),
            makeResult(activeRevisionID: "revision-1"),
            makeResult(revisions: [revision]),
            makeResult(haplotypeDefinitionSetID: "definition-1"),
            makeResult(haplotypeAssayID: "assay-1"),
            makeResult(
                haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                    assayID: "assay-1",
                    definitionSetID: "definition-1",
                    definitionSetName: "Definition",
                    speciesName: "Species",
                    samples: []
                )
            ),
            makeResult(artifactHaplotypeAnalysisURL: URL(fileURLWithPath: "/tmp/haplotypes.json")),
        ]

        for result in cases {
            guard case .ineligible = GenotypeManualHaplotypeEligibility.evaluate(result) else {
                return XCTFail("Authoritative haplotyping state must fail closed")
            }
        }
    }

    func testAvailableAlleleReferenceAloneDoesNotMeanHaplotypingWasPerformed() {
        let result = makeResult(
            referenceMetadata: ONTGenotypeReferenceMetadata(
                fields: [],
                recordsBySequenceName: ["reference-1": ["definition": "Allele reference"]],
                alleleFieldKey: nil
            )
        )

        XCTAssertEqual(
            GenotypeManualHaplotypeEligibility.evaluate(result),
            .eligible(resultKind: .fullLengthONTMHCGenotype)
        )
    }

    func testModeAndHaplotypingStateDisagreementFailsClosed() {
        let result = makeResult(
            workflowMode: .genotypeOnly,
            haplotypeAnalysisPath: "haplotypes/current.json"
        )

        guard case .ineligible(let reason) = GenotypeManualHaplotypeEligibility.evaluate(result) else {
            return XCTFail("Expected disagreement to be ineligible")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("disagree"))
    }

    func testHaplotypedModeIsIneligibleEvenWhenArtifactsAreAbsent() {
        let result = makeResult(workflowMode: .haplotyped)
        guard case .ineligible = GenotypeManualHaplotypeEligibility.evaluate(result) else {
            return XCTFail("Haplotyped workflow mode must be ineligible")
        }
    }

    func testMalformedMixedAndPartialDeclarationsFailClosed() {
        let results = [
            makeResult(
                legacyKind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
                workflowKind: .fullLengthONTMHCGenotype
            ),
            makeResult(workflowKind: nil, workflowMode: .genotypeOnly),
            makeResult(workflowKind: .fullLengthONTMHCGenotype, workflowMode: nil),
            makeResult(legacyKind: "unsupported-genotype-result", workflowKind: nil, workflowMode: nil),
        ]

        for result in results {
            guard case .ineligible = GenotypeManualHaplotypeEligibility.evaluate(result) else {
                return XCTFail("Malformed/mixed/partial declaration must fail closed")
            }
        }
    }

    func testRecognizedLegacyGenotypeOnlySchemasRemainEligible() {
        for kind in GenotypeResultWorkflowKind.allCases {
            let result = makeResult(
                legacyKind: kind.rawValue,
                workflowKind: nil,
                workflowMode: nil
            )
            XCTAssertEqual(
                GenotypeManualHaplotypeEligibility.evaluate(result),
                .eligible(resultKind: kind)
            )
        }
        XCTAssertEqual(
            GenotypeManualHaplotypeEligibility.evaluate(
                makeResult(legacyKind: "ont-barcode-genotype", workflowKind: nil, workflowMode: nil)
            ),
            .eligible(resultKind: .miSeqAmpliconMHCGenotype)
        )
    }

    private func makeResult(
        legacyKind: String = GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
        workflowKind: GenotypeResultWorkflowKind? = .fullLengthONTMHCGenotype,
        workflowMode: GenotypeResultWorkflowMode? = .genotypeOnly,
        haplotypeAnalysisPath: String? = nil,
        activeRevisionID: String? = nil,
        revisions: [ONTGenotypeHaplotypeAnalysisRevision]? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil,
        artifactHaplotypeAnalysisURL: URL? = nil,
        referenceMetadata: ONTGenotypeReferenceMetadata? = nil
    ) -> ONTGenotypeResultBundleData {
        let manifest = ONTGenotypeResultBundleManifest(
            kind: legacyKind,
            workflowKind: workflowKind,
            workflowMode: workflowMode,
            outputName: "result",
            analysisName: "Result",
            primaryWorkbookPath: "result.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json",
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            activeHaplotypeAnalysisRevisionID: activeRevisionID,
            haplotypeAnalysisRevisions: revisions
        )
        return ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/result.lungfishgenotype"),
            manifest: manifest,
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/result.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/calls.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/provenance.json"),
                haplotypeAnalysisURL: artifactHaplotypeAnalysisURL
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1, retainedUniqueReads: 1),
            calls: [],
            samples: [],
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcReferenceVisualizations: nil,
            integrityWarnings: [],
            referenceMetadata: referenceMetadata
        )
    }
}
