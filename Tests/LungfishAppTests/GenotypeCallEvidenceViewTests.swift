import XCTest
import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
@testable import LungfishApp

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

    func testCandidateRowsUseDirectSetHaplotypeButtonAndNotObservedMarkers() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Results/Genotype/GenotypeCallEvidenceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Menu(\"Override"))
        XCTAssertFalse(source.contains("Button(\"Set H1"))
        XCTAssertFalse(source.contains("Button(\"Set H2"))
        XCTAssertTrue(source.contains("Button(\"Set haplotype"))
        XCTAssertTrue(source.contains("[not observed]"))
    }

    func testReviewInspectorDoesNotUseTransientCellPopover() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("NSPopover"))
        XCTAssertFalse(source.contains("presentCellEvidencePopover"))
        XCTAssertTrue(source.contains("selectCellEvidence"))
    }
}
