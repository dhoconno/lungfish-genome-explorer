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

    func testUnknownAndWrongTypeTypedDeclarationsFailClosedWithActionableReasons() throws {
        let unknownKind = try decodeManifest(
            workflowKindJSON: #""future-mhc-workflow""#,
            workflowModeJSON: #""genotypeOnly""#
        )
        let wrongTypeMode = try decodeManifest(
            workflowKindJSON: #""full-length-ont-mhc-genotype""#,
            workflowModeJSON: #"{"unexpected":true}"#
        )

        guard case .ineligible(let unknownReason) =
            GenotypeManualHaplotypeEligibility.evaluate(makeResult(manifest: unknownKind)) else {
            return XCTFail("Unknown workflow kind must fail closed")
        }
        XCTAssertTrue(unknownReason.localizedCaseInsensitiveContains("future-mhc-workflow"))

        guard case .ineligible(let wrongTypeReason) =
            GenotypeManualHaplotypeEligibility.evaluate(makeResult(manifest: wrongTypeMode)) else {
            return XCTFail("Wrong-type workflow mode must fail closed")
        }
        XCTAssertTrue(wrongTypeReason.localizedCaseInsensitiveContains("string"))
    }

    func testConclusiveLegacyGenotypeOnlySchemasRemainEligible() {
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
    }

    func testAmbiguousLegacyONTBarcodeKindFailsClosed() {
        let eligibility = GenotypeManualHaplotypeEligibility.evaluate(
            makeResult(legacyKind: "ont-barcode-genotype", workflowKind: nil, workflowMode: nil)
        )

        guard case .ineligible(let reason) = eligibility else {
            return XCTFail("Ambiguous legacy ONT/Illumina kind must fail closed")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("recognized"))
    }

    @MainActor
    func testViewportControllerExposesEligibilityAndDisabledReason() {
        let controller = GenotypeResultViewController()
        let result = makeResult(
            legacyKind: "ont-barcode-genotype",
            workflowKind: nil,
            workflowMode: nil
        )

        controller.configure(result: result)

        guard case .ineligible(let reason) = controller.manualHaplotypeEligibility else {
            return XCTFail("Expected the controller to preserve ineligibility")
        }
        XCTAssertEqual(controller.manualHaplotypeDisabledReason, reason)
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("recognized"))
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
        return makeResult(
            manifest: manifest,
            haplotypeAnalysis: haplotypeAnalysis,
            artifactHaplotypeAnalysisURL: artifactHaplotypeAnalysisURL,
            referenceMetadata: referenceMetadata
        )
    }

    private func makeResult(
        manifest: ONTGenotypeResultBundleManifest,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil,
        artifactHaplotypeAnalysisURL: URL? = nil,
        referenceMetadata: ONTGenotypeReferenceMetadata? = nil
    ) -> ONTGenotypeResultBundleData {
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

    private func decodeManifest(
        workflowKindJSON: String,
        workflowModeJSON: String
    ) throws -> ONTGenotypeResultBundleManifest {
        try JSONDecoder().decode(
            ONTGenotypeResultBundleManifest.self,
            from: Data(#"""
            {
              "schemaVersion": 1,
              "kind": "full-length-ont-mhc-genotype",
              "workflowKind": \#(workflowKindJSON),
              "workflowMode": \#(workflowModeJSON),
              "outputName": "result",
              "analysisName": "Result",
              "primaryWorkbookPath": "result.xlsx",
              "longSummaryCSVPath": "calls.csv",
              "sampleSummaryCSVPath": "samples.csv",
              "statsJSONPath": "stats.json",
              "provenancePath": "provenance.json"
            }
            """#.utf8)
        )
    }
}
