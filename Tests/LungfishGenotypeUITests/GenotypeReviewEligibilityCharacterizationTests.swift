// GenotypeReviewEligibilityCharacterizationTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Byte-level characterization of review eligibility before Phase 4a moves it
// out of GenotypeResultViewController and GenotypeComparisonMatrixView
// (Phase 2.3, REVIEW.md R6). A guarded controller over a genotype-only bundle
// walks about eighteen selections. For each one the controller's review
// capability, its agreement with the matrix, the context menu and the cell
// texts are recorded, first on a writable bundle, then after a reconfigure
// with changed evidence, and in a second test on a read-only bundle. The
// tables are compared with review-eligibility.json and
// review-eligibility-read-only.json under Tests/Fixtures/golden/genotype-gui.
// The tests pin current behaviour, finding S1 included: a production-shape
// catalog zero is not reviewable in the UI, so Mark False Negative stays
// disabled and its stored false negative is not drawn.

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishGenotypeUI

/// The whole table of one test. The canonical encoder walks it through Mirror.
private struct ReviewEligibilityTable {
    /// The raw support authority of the configured result, keyed by matrix target.
    let rawSupport: [GenotypeAnnotationSidecar.MatrixTarget: Int]
    /// The raw support of the changed result, when the table has a reconfigure pass.
    let changedRawSupport: [GenotypeAnnotationSidecar.MatrixTarget: Int]?
    let passes: [ReviewEligibilityPass]
}

private struct ReviewEligibilityPass {
    let label: String
    let cases: [ReviewEligibilityCase]
}

private struct ReviewEligibilityCase {
    let label: String
    let targets: [GenotypeAnnotationSidecar.MatrixTarget]
    /// What the controller holds as its selection after the matrix published the targets.
    let selectedTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    let capability: GenotypeMatrixReviewCapabilityState
    let matrixCapabilityEqualsController: Bool
    /// The target the context menu was built for, the last selected target.
    let menuTarget: GenotypeAnnotationSidecar.MatrixTarget?
    let menu: GenotypeMatrixContextMenuState?
    /// The matrix text of every selected cell, in selection order.
    let cellTexts: [String?]
}

@MainActor
final class GenotypeReviewEligibilityCharacterizationTests: GenotypeResultViewportTestCase {
    func testControllerCapabilityAndMenuVerdictTable() throws {
        try GenotypeCharacterizationExpectedStore.verify(prefix: "review-eligibility") {
            let scenario = try makeReviewEligibilityScenario(readOnly: false)
            defer { scenario.cleanup() }
            let writable = recordPass("writable bundle", controller: scenario.controller)
            configureReviewController(scenario.controller, result: scenario.changedResult)
            let reconfigured = recordPass("reconfigured with SUP S1 at 0 and SUP S2 at 5", controller: scenario.controller)
            let table = ReviewEligibilityTable(
                rawSupport: GenotypeMatrixReviewEligibility.rawSupport(in: scenario.result),
                changedRawSupport: GenotypeMatrixReviewEligibility.rawSupport(in: scenario.changedResult),
                passes: [writable, reconfigured]
            )
            return ["review-eligibility.json": try GenotypeCharacterizationCanonicalizer(root: scenario.root).encode(table)]
        }
    }

    /// The bundle folder is 0o555 before configure, so the annotation store
    /// opens read-only and every mutation is disabled with the read-only reason.
    func testReadOnlyBundleCapabilityAndMenuVerdictTable() throws {
        try XCTSkipIf(geteuid() == 0, "A read-only folder is writable to root, so this pass would equal the writable one.")
        try GenotypeCharacterizationExpectedStore.verify(prefix: "review-eligibility-read-only") {
            let scenario = try makeReviewEligibilityScenario(readOnly: true)
            defer { scenario.cleanup() }
            let pass = recordPass("read-only bundle", controller: scenario.controller)
            let table = ReviewEligibilityTable(
                rawSupport: GenotypeMatrixReviewEligibility.rawSupport(in: scenario.result),
                changedRawSupport: nil,
                passes: [pass]
            )
            return ["review-eligibility-read-only.json": try GenotypeCharacterizationCanonicalizer(root: scenario.root).encode(table)]
        }
    }

    // MARK: The selections

    private func selections() -> [(label: String, targets: [GenotypeAnnotationSidecar.MatrixTarget])] {
        typealias Names = GenotypeReviewEligibilityNames
        func cell(_ genotype: String, _ sample: String) -> GenotypeAnnotationSidecar.MatrixTarget {
            .cell(locus: Names.locus, genotype: genotype, sample: sample)
        }
        let supportedRow = GenotypeAnnotationSidecar.MatrixTarget.row(locus: Names.locus, genotype: Names.supported)
        return [
            ("empty selection", []),
            ("SUP S1, positive with a false positive", [cell(Names.supported, "S1")]),
            ("SUP S2, attested zero with a false negative", [cell(Names.supported, "S2")]),
            ("SUP S3, absent with a stored false negative", [cell(Names.supported, "S3")]),
            ("CAT S1, positive with a duplicate review pair and a comment", [cell(Names.catalog, "S1")]),
            ("CAT S2, catalog zero", [cell(Names.catalog, "S2")]),
            ("CAT S3, catalog zero with a false negative", [cell(Names.catalog, "S3")]),
            ("PROD S1, production-shape catalog zero with a stored false negative", [cell(Names.production, "S1")]),
            ("PROD S2, production-shape catalog zero", [cell(Names.production, "S2")]),
            ("PROD S3, positive", [cell(Names.production, "S3")]),
            ("two positives", [cell(Names.supported, "S1"), cell(Names.catalog, "S1")]),
            ("positive and attested zero", [cell(Names.supported, "S1"), cell(Names.supported, "S2")]),
            ("positive and absent", [cell(Names.supported, "S1"), cell(Names.supported, "S3")]),
            ("two zeros", [cell(Names.supported, "S2"), cell(Names.catalog, "S3")]),
            ("row SUP", [supportedRow]),
            ("column S2", [.column(sample: "S2")]),
            ("columns S1 and S2", [.column(sample: "S1"), .column(sample: "S2")]),
            ("cell and row", [cell(Names.supported, "S1"), supportedRow]),
        ]
    }

    // MARK: One pass

    private func recordPass(_ label: String, controller: GenotypeResultViewController) -> ReviewEligibilityPass {
        let matrix = controller.testingComparisonMatrix
        var cases: [ReviewEligibilityCase] = []
        for selection in selections() {
            matrix.testingSelectMatrixTargets(selection.targets)
            let capability = controller.testingMatrixReviewCapability
            let menuTarget = selection.targets.last
            cases.append(ReviewEligibilityCase(
                label: selection.label,
                targets: selection.targets,
                selectedTargets: controller.testingCurrentSelectionMatrixTargets,
                capability: capability,
                matrixCapabilityEqualsController: controller.testingComparisonMatrixReviewCapability == capability,
                menuTarget: menuTarget,
                menu: menuTarget.flatMap { controller.testingBuildMatrixContextMenu(for: $0) },
                cellTexts: selection.targets.compactMap { target -> String?? in
                    guard case let .cell(_, genotype, sample, _) = target else { return nil }
                    return .some(matrix.testingCellValue(genotype: genotype, sample: sample))
                }
            ))
        }
        matrix.testingSelectMatrixTargets([])
        return ReviewEligibilityPass(label: label, cases: cases)
    }
}
