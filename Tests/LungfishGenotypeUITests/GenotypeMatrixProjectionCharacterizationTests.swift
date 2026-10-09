// GenotypeMatrixProjectionCharacterizationTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Byte-level characterization of the matrix projection before Phase 4a moves
// it out of GenotypeComparisonMatrixView (Phase 2.3, REVIEW.md R6). One
// standalone matrix over a full-length ONT result walks a series of display
// states. After every step the filtered and unfiltered export snapshots, the
// summary, the columns and every visible cell are recorded, and the whole walk
// is compared with matrix-projection.json under Tests/Fixtures/golden/genotype-gui.
// The test pins current behaviour, finding S2 included: a duplicate occurrence
// shows the higher read count in the cell and the first occurrence in the
// heatmap fraction.

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishGenotypeUI

/// What one step records. The canonical encoder walks it through Mirror, so a
/// stored property added to a recorded type shows up and fails the compare.
private struct MatrixProjectionStep {
    let label: String
    let displayState: GenotypeResultDisplayState
    let summary: MatrixProjectionSummary
    let locusTitles: [String]
    let pinnedColumnTitles: [String]
    let sampleColumnTitles: [String]
    let sampleReadTitles: [String]
    let visibleSampleNames: [String]
    let activeSampleNames: [String]
    let activeSortDescriptorKey: String?
    let visibleRows: [MatrixProjectionRow]
    let cells: [MatrixProjectionCell]
    let filteredExport: GenotypeViewportExportSnapshot
    let unfilteredExport: GenotypeViewportExportSnapshot
}

private struct MatrixProjectionSummary {
    let visibleRows: Int
    let totalRows: Int
    let hiddenCells: Int
}

private struct MatrixProjectionRow {
    let id: String
    let genotype: String
    let locus: String
    let stableClusterID: String?
    let population: String
    let isIncompleteReferenceSpanCandidate: Bool
    let sampleCount: Int
    let totalUniqueReads: Int
}

private struct MatrixProjectionCell {
    let row: String
    let sample: String
    let cellText: String?
    let semanticText: String
    let colorRole: String
    let isItalic: Bool
    let evidenceReads: Int?
    let review: String?
    let commentCounts: GenotypeMatrixScopedCommentCounts
    let hasNativeCellCommentMarker: Bool
    /// The heatmap fraction of the cell under the display denominator, as a
    /// 6-decimal string so no float text reaches the file.
    let supportFraction: String?
}

@MainActor
final class GenotypeMatrixProjectionCharacterizationTests: GenotypeResultViewportTestCase {
    func testMatrixProjectionAcrossDisplayStates() throws {
        try GenotypeCharacterizationExpectedStore.verify(prefix: "matrix-projection") {
            let fixture = try makeMatrixProjectionFixture()
            defer { fixture.cleanup() }
            let steps = try walkDisplayStates(fixture)
            return ["matrix-projection.json": try GenotypeCharacterizationCanonicalizer(root: fixture.root).encode(steps)]
        }
    }

    // MARK: The walk

    /// Every display-state step starts from the base state and changes one
    /// control, so each file section reads on its own. The matrix-state steps
    /// (visibility, shared search, highlights, sort) accumulate, because they
    /// live outside the display state and reset only on configure.
    private func walkDisplayStates(_ fixture: GenotypeMatrixProjectionFixture) throws -> [MatrixProjectionStep] {
        typealias Names = GenotypeMatrixProjectionNames
        let matrix = fixture.matrix
        let base = GenotypeResultDisplayState(summaryViewMode: .matrix)
        var current = base
        var steps: [MatrixProjectionStep] = []
        func record(_ label: String) throws {
            steps.append(try recordStep(label, state: current, fixture: fixture))
        }
        func apply(_ label: String, from start: GenotypeResultDisplayState = base, _ mutate: (inout GenotypeResultDisplayState) -> Void) throws {
            var state = start
            mutate(&state)
            current = state
            matrix.applyDisplayState(state)
            try record(label)
        }

        matrix.applyDisplayState(base)
        current = base
        try record("configured")
        try apply("matrixMinimumReads 5") { $0.matrixMinimumReads = 5 }
        try apply("matrixMinimumPercent 10 on the viewed locus") {
            $0.matrixMinimumPercent = 10
            $0.matrixPercentDenominator = .viewedLocus
        }
        try apply("matrixMinimumPercent 10 on sample-retained reads") {
            $0.matrixMinimumPercent = 10
            $0.matrixPercentDenominator = .sampleRetained
        }
        try apply("matrixMinimumPrevalencePercent 50") { $0.matrixMinimumPrevalencePercent = 50 }
        try apply("global percent 20 with hideLowSupport on the viewed locus") {
            $0.hideLowSupport = true
            $0.minimumSupportPercent = 20
            $0.supportDenominator = .viewedLocus
        }
        try apply("global percent 20 with hideLowSupport on sample-retained reads") {
            $0.hideLowSupport = true
            $0.minimumSupportPercent = 20
            $0.supportDenominator = .sampleRetained
        }
        try apply("global percent 20 without hideLowSupport") { $0.minimumSupportPercent = 20 }
        try apply("min reads 5, min percent 10 and prevalence 50 together") {
            $0.matrixMinimumReads = 5
            $0.matrixMinimumPercent = 10
            $0.matrixMinimumPrevalencePercent = 50
        }
        try apply("matrixRowFilterText Mafa_B") { $0.matrixRowFilterText = "Mafa_B" }
        try apply("matrixSampleFilterText AnimalB") { $0.matrixSampleFilterText = "AnimalB" }
        try apply("diagnosticAllelesOnly") { $0.diagnosticAllelesOnly = true }

        // Matrix state outside the display state, accumulated from the base state.
        try apply("base state restored") { _ in }
        matrix.testingHideSamples(["AnimalD"])
        try record("hidden sample AnimalD")
        matrix.testingHideRows([.known(locus: "MHC-A", genotype: Names.rowA2)])
        try record("hidden row 02")
        matrix.applySharedSearchConstraints(
            allowedSampleIDs: ["AnimalA", "AnimalB", "AnimalC"],
            projectedRowIDs: [
                .known(locus: "MHC-A", genotype: Names.rowA1),
                .known(locus: "MHC-B", genotype: Names.rowB1),
                .candidate(stableClusterID: Names.sharedCluster),
                .candidate(stableClusterID: Names.spanCluster),
            ]
        )
        try record("shared search constraints")
        matrix.applyHighlight(.init(
            target: .init(genotype: Names.rowA1, locus: "MHC-A", sample: "AnimalA"),
            scope: .selectedCell, channel: .fill, color: AnnotationColor(red: 1, green: 0, blue: 0)
        ))
        matrix.applyHighlight(.init(
            target: .init(genotype: Names.rowB1, locus: "MHC-B"),
            scope: .selectedRow, channel: .border, color: AnnotationColor(red: 0, green: 1, blue: 0)
        ))
        try record("highlights on a cell fill and a row border")
        matrix.testingSetSortDescriptor(key: try XCTUnwrap(matrix.testingSortKey(forSample: "AnimalA")), ascending: false)
        try record("sorted by AnimalA descending")
        try apply("cellColorMode haplotype", from: current) { $0.cellColorMode = .haplotype }
        try apply("cellColorMode highlights", from: current) { $0.cellColorMode = .highlights }
        try apply("cellColorMode none", from: current) { $0.cellColorMode = .none }

        // The locus popup is hidden in production, so its steps are labelled test-only.
        matrix.testingSetLocusFilter("MHC-A")
        try record("test-only locus popup MHC-A")
        matrix.testingSetLocusFilter(nil)
        try record("test-only locus popup cleared")

        // A reconfigure with changed evidence under the same sidecar resets the matrix state.
        matrix.configure(result: fixture.changedResult, sidecar: fixture.sidecar)
        matrix.configureHaplotypeEvidence(fixture.haplotypeEvidence)
        pinProjectionMatrixPresentation(matrix)
        try apply("reconfigured with changed evidence") { _ in }
        try apply("reconfigured, matrixMinimumReads 5") { $0.matrixMinimumReads = 5 }
        return steps
    }

    // MARK: One step

    private func recordStep(
        _ label: String,
        state: GenotypeResultDisplayState,
        fixture: GenotypeMatrixProjectionFixture
    ) throws -> MatrixProjectionStep {
        let matrix = fixture.matrix
        let bundleURL = fixture.result.bundleURL
        let analysisName = fixture.result.manifest.analysisName
        return try fixture.withAquaDrawingAppearance {
            let rows = matrix.testingVisibleRows
            let samples = matrix.testingVisibleSampleNames
            var cells: [MatrixProjectionCell] = []
            for row in rows {
                for sample in samples {
                    let semantic = try XCTUnwrap(
                        matrix.testingSemanticCellState(genotype: row.genotype, sample: sample),
                        "\(label): no semantic state for \(row.genotype) in \(sample)"
                    )
                    cells.append(MatrixProjectionCell(
                        row: Self.label(for: row.id),
                        sample: sample,
                        cellText: matrix.testingCellValue(genotype: row.genotype, sample: sample),
                        semanticText: semantic.text.value,
                        colorRole: String(describing: semantic.text.colorRole),
                        isItalic: semantic.text.isItalic,
                        evidenceReads: semantic.evidenceReads,
                        review: semantic.review?.rawValue,
                        commentCounts: semantic.commentCounts,
                        hasNativeCellCommentMarker: semantic.hasNativeCellCommentMarker,
                        supportFraction: matrix.testingSupportFraction(rowID: row.id, sample: sample)
                            .map { String(format: "%.6f", $0) }
                    ))
                }
            }
            let summary = matrix.displaySummary
            return MatrixProjectionStep(
                label: label,
                displayState: state,
                summary: MatrixProjectionSummary(
                    visibleRows: summary.visibleRows, totalRows: summary.totalRows, hiddenCells: summary.hiddenCells
                ),
                locusTitles: matrix.testingLocusFilterTitles,
                pinnedColumnTitles: matrix.testingPinnedColumnTitles,
                sampleColumnTitles: matrix.testingVisibleSampleColumnTitles,
                sampleReadTitles: matrix.testingVisibleSampleReadTitles,
                visibleSampleNames: samples,
                activeSampleNames: matrix.testingActiveSampleNames,
                activeSortDescriptorKey: matrix.testingActiveSortDescriptorKey,
                visibleRows: rows.map { row in
                    MatrixProjectionRow(
                        id: Self.label(for: row.id),
                        genotype: row.genotype,
                        locus: row.locus,
                        stableClusterID: row.stableClusterID,
                        population: String(describing: row.population),
                        isIncompleteReferenceSpanCandidate: row.isIncompleteReferenceSpanCandidate,
                        sampleCount: row.sampleCount,
                        totalUniqueReads: row.totalUniqueReads
                    )
                },
                cells: cells,
                filteredExport: matrix.exportSnapshot(bundleURL: bundleURL, analysisName: analysisName, lens: "summary.matrix"),
                unfilteredExport: matrix.exportSnapshot(
                    bundleURL: bundleURL, analysisName: analysisName, lens: "summary.matrix", unfiltered: true
                )
            )
        }
    }

    private static func label(for id: GenotypeCandidateMatrixRowID) -> String {
        switch id {
        case let .known(locus, genotype):
            return "known:\(locus):\(genotype)"
        case let .candidate(stableClusterID):
            return "candidate:\(stableClusterID)"
        }
    }
}
