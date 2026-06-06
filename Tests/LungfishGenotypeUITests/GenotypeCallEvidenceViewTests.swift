import XCTest
import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeCallEvidenceViewTests: XCTestCase {
    func testRendersEmptyState() {
        let view = GenotypeCallEvidenceView(evidence: nil)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        XCTAssertGreaterThan(host.frame.width, 0)
    }

    func testRendersFullEvidence() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "H22C112",
            locus: "MHC-A",
            slot: .h2,
            callName: "M2A",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 5,
            observedGenotypes: [
                "05_M1M2M3_A1_063g",
                "07_M1M2_70_156bp",
                "02_M2_G_02_06_156bp",
                "07_M3_70_156bp",
            ],
            diagnosticAlleles: [
                .init(allele: "05_M1M2M3_A1_063g", reads: 312, percentOfLocus: 0.41, isLowSupport: false),
                .init(allele: "07_M1M2_70_156bp", reads: 28, percentOfLocus: 0.036, isLowSupport: true),
                .init(allele: "02_M2_G_02_06_156bp", reads: 198, percentOfLocus: 0.26, isLowSupport: false),
            ],
            locusReadTotal: 757,
            neighborsBefore: [.init(animalId: "H22C115", summary: "M1A / M3A")],
            neighborsAfter: [.init(animalId: "H22C82", summary: "M1A / M1A")]
        )
        let view = GenotypeCallEvidenceView(evidence: evidence)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 800)
        XCTAssertGreaterThan(host.frame.width, 0)
    }

    func testNotAssayedEvidenceIsNotHomozygous() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW474",
            locus: "MHC-DPB",
            slot: .h1,
            callName: "Not assayed",
            status: .notAssayed,
            observedGenotypeCount: 0,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 0,
            neighborsBefore: [],
            neighborsAfter: [],
            errorExplanation: "MHC-DPB was not observed for this cohort.",
            h1Name: "Not assayed",
            h2Name: "Not assayed"
        )

        XCTAssertFalse(evidence.isHomozygous)
    }

    func testCandidateOverrideActionsShowWhichDiploidSlotWillChange() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            callName: "M4DP",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 3,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 500,
            neighborsBefore: [],
            neighborsAfter: [],
            h1Name: "M4DP",
            h2Name: "M7DP"
        )
        let candidate = GenotypeCallEvidenceView.CandidateHaplotype(
            name: "M3DP",
            observed: ["15_M3_DPA1_01"],
            missing: ["15_M3_DPB1_01"]
        )

        let actions = GenotypeCallEvidenceView.overrideActions(for: candidate, evidence: evidence)

        XCTAssertEqual(actions.map(\.slot), [.h1, .h2])
        XCTAssertEqual(actions.map(\.label), ["H1: M4DP -> M3DP", "H2: M7DP -> M3DP"])
        XCTAssertTrue(actions.first?.help.contains("H2 remains M7DP") ?? false)
        XCTAssertTrue(actions.last?.help.contains("H1 remains M4DP") ?? false)
    }

    func testGroupedCandidateOverrideActionsExpandToConcreteHaplotypes() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            callName: "M4DP / M7DP",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 3,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 500,
            neighborsBefore: [],
            neighborsAfter: [],
            h1Name: "M4DP",
            h2Name: "M7DP"
        )
        let candidate = GenotypeCallEvidenceView.CandidateHaplotype(
            name: "M5/M6DP",
            observed: ["15_M5M6_DPA1_01"],
            missing: ["15_M5M6_DPB1_01"]
        )

        let actions = GenotypeCallEvidenceView.overrideActions(for: candidate, evidence: evidence)

        XCTAssertEqual(actions.map(\.haplotypeName), ["M5DP", "M5DP", "M6DP", "M6DP"])
        XCTAssertEqual(actions.map(\.label), [
            "H1: M4DP -> M5DP",
            "H2: M7DP -> M5DP",
            "H1: M4DP -> M6DP",
            "H2: M7DP -> M6DP",
        ])
        XCTAssertFalse(actions.contains { $0.haplotypeName == "M5/M6DP" })
    }

    func testUnresolvedOverrideActionsAllowQuestionMarkAssignments() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            callName: "M4DP / M7DP",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 3,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 500,
            neighborsBefore: [],
            neighborsAfter: [],
            h1Name: "M4DP",
            h2Name: "M7DP"
        )

        let actions = GenotypeCallEvidenceView.unresolvedOverrideActions(for: evidence)

        XCTAssertEqual(actions.map(\.haplotypeName), ["?", "?"])
        XCTAssertEqual(actions.map(\.label), ["H1: M4DP -> ?", "H2: M7DP -> ?"])
        XCTAssertTrue(actions.first?.help.contains("Leave H1 unresolved") ?? false)
    }

    func testCandidateRowsUseSlotExplicitSetHaplotypeButtonsAndNotObservedMarkers() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeCallEvidenceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Menu(\"Override"))
        XCTAssertFalse(source.contains("Button(\"Set haplotype"))
        XCTAssertTrue(source.contains("overrideActions(for: candidate, evidence: evidence)"))
        XCTAssertTrue(source.contains("onOverrideRequested?(action.haplotypeName, action.slot)"))
        XCTAssertTrue(source.contains("[not observed]"))
    }

    func testReviewInspectorDoesNotUseTransientCellPopover() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("NSPopover"))
        XCTAssertFalse(source.contains("presentCellEvidencePopover"))
        XCTAssertTrue(source.contains("selectCellEvidence"))
    }

    func testResultViewportShowsRunThresholdSummaryInsteadOfDropoutEditor() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Dropout Thresholds"))
        XCTAssertFalse(source.contains("makeDropoutThresholdHost"))
        XCTAssertFalse(source.contains("applyDropoutThresholds"))
        XCTAssertTrue(source.contains("Haplotype Thresholds"))
        XCTAssertTrue(source.contains("Rerun Amplicon Genotyping"))
    }
}
