import XCTest
import LungfishIO
@testable import LungfishGenotypeUI

final class GenotypeMatrixVisibilityStateTests: XCTestCase {
    typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    typealias RowID = GenotypeCandidateMatrixRowID

    private let knownA = RowID.known(locus: "A1", genotype: "Mafa-A1*001:01")
    private let knownB = RowID.known(locus: "B", genotype: "Mafa-B*007:01")
    private let candidate = RowID.candidate(stableClusterID: "cluster-1178")

    func testDefaultStateAllowsEveryStableIdentityAndIsInactive() {
        let state = GenotypeMatrixVisibilityState()

        XCTAssertTrue(state.allows(row: knownA))
        XCTAssertTrue(state.allows(sample: "CR1178"))
        XCTAssertFalse(state.isRowVisibilityActive)
        XCTAssertFalse(state.isSampleVisibilityActive)
        XCTAssertFalse(state.isActive)
    }

    func testShowOnlyReplacesIncludeAndClearsExcludeForOneDimension() {
        let initial = GenotypeMatrixVisibilityState(
            includedRows: [knownA],
            excludedRows: [knownB],
            includedSamples: ["CR1178"],
            excludedSamples: ["CR1182"]
        )

        let state = initial.showingOnlyRows([knownB, candidate])

        XCTAssertEqual(state.includedRows, [knownB, candidate])
        XCTAssertEqual(state.excludedRows, [])
        XCTAssertEqual(state.includedSamples, ["CR1178"])
        XCTAssertEqual(state.excludedSamples, ["CR1182"])
        XCTAssertFalse(state.allows(row: knownA))
        XCTAssertTrue(state.allows(row: knownB))
        XCTAssertTrue(state.allows(row: candidate))
    }

    func testHideUnionsExcludeWhilePreservingShowOnlyInclude() {
        let state = GenotypeMatrixVisibilityState()
            .showingOnlyRows([knownA, knownB])
            .hidingRows([knownB])

        XCTAssertEqual(state.includedRows, [knownA, knownB])
        XCTAssertEqual(state.excludedRows, [knownB])
        XCTAssertTrue(state.allows(row: knownA))
        XCTAssertFalse(state.allows(row: knownB))
        XCTAssertFalse(state.allows(row: candidate))
    }

    func testHidingEveryIncludedIdentityCanProduceAnEmptyVisibleDimension() {
        let state = GenotypeMatrixVisibilityState()
            .showingOnlySamples(["CR1178", "CR1182"])
            .hidingSamples(["CR1178", "CR1182"])

        XCTAssertFalse(state.allows(sample: "CR1178"))
        XCTAssertFalse(state.allows(sample: "CR1182"))
        XCTAssertFalse(state.allows(sample: "CR1191"))
        XCTAssertTrue(state.isSampleVisibilityActive)
    }

    func testEmptyShowOnlyAndHideAreNoOps() {
        let initial = GenotypeMatrixVisibilityState(
            includedRows: [knownA],
            excludedRows: [knownB],
            includedSamples: ["CR1178"],
            excludedSamples: ["CR1182"]
        )

        XCTAssertEqual(initial.showingOnlyRows([]), initial)
        XCTAssertEqual(initial.hidingRows([]), initial)
        XCTAssertEqual(initial.showingOnlySamples([]), initial)
        XCTAssertEqual(initial.hidingSamples([]), initial)
    }

    func testShowAllClearsOnlyRequestedDimensionAndResetClearsBoth() {
        let initial = GenotypeMatrixVisibilityState(
            includedRows: [knownA],
            excludedRows: [knownB],
            includedSamples: ["CR1178"],
            excludedSamples: ["CR1182"]
        )

        let rowsRestored = initial.showingAllRows()
        XCTAssertNil(rowsRestored.includedRows)
        XCTAssertEqual(rowsRestored.excludedRows, [])
        XCTAssertEqual(rowsRestored.includedSamples, ["CR1178"])
        XCTAssertEqual(rowsRestored.excludedSamples, ["CR1182"])

        let samplesRestored = initial.showingAllSamples()
        XCTAssertNil(samplesRestored.includedSamples)
        XCTAssertEqual(samplesRestored.excludedSamples, [])
        XCTAssertEqual(samplesRestored.includedRows, [knownA])
        XCTAssertEqual(samplesRestored.excludedRows, [knownB])

        XCTAssertEqual(initial.reset(), GenotypeMatrixVisibilityState())
    }

    func testTargetExpansionUsesStableCandidateIdentityAndDeduplicatesDimensions() {
        let targets: [Target] = [
            .row(locus: "A1", genotype: "provisional-old", stableClusterID: "cluster-1178"),
            .cell(
                locus: "A1",
                genotype: "provisional-new",
                sample: "CR1178",
                stableClusterID: "cluster-1178"
            ),
            .cell(
                locus: "A1",
                genotype: "provisional-new",
                sample: "CR1178",
                stableClusterID: "cluster-1178"
            ),
            .column(sample: "CR1182"),
        ]

        let snapshot = GenotypeMatrixVisibilitySelectionSnapshot(targets: targets)

        XCTAssertEqual(snapshot.rowIDs, [candidate])
        XCTAssertEqual(snapshot.sampleIDs, ["CR1178", "CR1182"])
        XCTAssertEqual(snapshot.uniqueTargetCount, 3)
        XCTAssertEqual(snapshot.selectedCellCount, 1)
        XCTAssertEqual(snapshot.shape, .mixed(rowCount: 1, columnCount: 2))
        XCTAssertEqual(snapshot.summary, "Selected: 1 allele row and 2 sample columns")
    }

    func testKnownTargetIdentityIncludesLocusAndGenotype() {
        let snapshot = GenotypeMatrixVisibilitySelectionSnapshot(targets: [
            .row(locus: "A1", genotype: "Shared", stableClusterID: nil),
            .row(locus: "B", genotype: "Shared", stableClusterID: nil),
        ])

        XCTAssertEqual(snapshot.rowIDs, [
            .known(locus: "A1", genotype: "Shared"),
            .known(locus: "B", genotype: "Shared"),
        ])
        XCTAssertEqual(snapshot.shape, .rows(count: 2))
    }

    func testNoSelectionDescribesEntireMatrixWithoutVisibilityTargets() {
        let snapshot = GenotypeMatrixVisibilitySelectionSnapshot(targets: [])

        XCTAssertEqual(snapshot.shape, .none)
        XCTAssertEqual(snapshot.summary, "Scope: Entire matrix")
        XCTAssertTrue(snapshot.rowIDs.isEmpty)
        XCTAssertTrue(snapshot.sampleIDs.isEmpty)
    }

    func testRowAndColumnSelectionsHaveExactPluralizedSummaries() {
        let row = GenotypeMatrixVisibilitySelectionSnapshot(targets: [
            .row(locus: "A1", genotype: "Allele-1"),
        ])
        let columns = GenotypeMatrixVisibilitySelectionSnapshot(targets: [
            .column(sample: "CR1178"),
            .column(sample: "CR1182"),
        ])

        XCTAssertEqual(row.shape, .rows(count: 1))
        XCTAssertEqual(row.summary, "Selected: 1 allele row")
        XCTAssertEqual(columns.shape, .columns(count: 2))
        XCTAssertEqual(columns.summary, "Selected: 2 sample columns")
    }

    func testCompleteCellCartesianProductIsDescribedAsRectangle() {
        let targets: [Target] = [
            .cell(locus: "A1", genotype: "Allele-1", sample: "CR1178"),
            .cell(locus: "A1", genotype: "Allele-1", sample: "CR1182"),
            .cell(locus: "B", genotype: "Allele-2", sample: "CR1178"),
            .cell(locus: "B", genotype: "Allele-2", sample: "CR1182"),
        ]

        let snapshot = GenotypeMatrixVisibilitySelectionSnapshot(targets: targets)

        XCTAssertEqual(snapshot.shape, .cellRectangle(cellCount: 4, rowCount: 2, columnCount: 2))
        XCTAssertEqual(snapshot.summary, "Selected: 4 cells (2 rows × 2 columns)")
    }

    func testSparseCellsAreNotMisrepresentedAsRectangle() {
        let targets: [Target] = [
            .cell(locus: "A1", genotype: "Allele-1", sample: "CR1178"),
            .cell(locus: "B", genotype: "Allele-2", sample: "CR1182"),
        ]

        let snapshot = GenotypeMatrixVisibilitySelectionSnapshot(targets: targets)

        XCTAssertEqual(snapshot.shape, .sparseCells(cellCount: 2, rowCount: 2, columnCount: 2))
        XCTAssertEqual(snapshot.summary, "Selected: 2 cells across 2 rows and 2 columns")
    }

    func testCapabilitySnapshotEnablesOnlyCommandsBackedBySelectionOrActiveState() {
        let selection = GenotypeMatrixVisibilitySelectionSnapshot(targets: [
            .cell(locus: "A1", genotype: "Allele-1", sample: "CR1178"),
        ])
        let inactive = GenotypeMatrixVisibilityCapabilitySnapshot(
            selection: selection,
            visibility: .init()
        )

        XCTAssertTrue(inactive.canHideSelectedRows)
        XCTAssertTrue(inactive.canShowOnlySelectedRows)
        XCTAssertTrue(inactive.canHideSelectedColumns)
        XCTAssertTrue(inactive.canShowOnlySelectedColumns)
        XCTAssertFalse(inactive.canShowAllRows)
        XCTAssertFalse(inactive.canShowAllColumns)
        XCTAssertFalse(inactive.canResetVisibility)

        let active = GenotypeMatrixVisibilityCapabilitySnapshot(
            selection: .init(targets: []),
            visibility: .init(excludedRows: [knownA], excludedSamples: ["CR1178"])
        )
        XCTAssertFalse(active.canHideSelectedRows)
        XCTAssertFalse(active.canShowOnlySelectedRows)
        XCTAssertFalse(active.canHideSelectedColumns)
        XCTAssertFalse(active.canShowOnlySelectedColumns)
        XCTAssertTrue(active.canShowAllRows)
        XCTAssertTrue(active.canShowAllColumns)
        XCTAssertTrue(active.canResetVisibility)
    }

    func testCapabilitySnapshotProvidesExactCountedContextMenuLabels() {
        let snapshot = GenotypeMatrixVisibilityCapabilitySnapshot(
            selection: .init(targets: [
                .cell(locus: "A1", genotype: "Allele-1", sample: "CR1178"),
                .cell(locus: "B", genotype: "Allele-2", sample: "CR1178"),
            ]),
            visibility: .init()
        )

        XCTAssertEqual(snapshot.hideSelectedRowsTitle, "Hide 2 Selected Rows")
        XCTAssertEqual(snapshot.showOnlySelectedRowsTitle, "Show Only 2 Selected Rows")
        XCTAssertEqual(snapshot.hideSelectedColumnsTitle, "Hide 1 Selected Column")
        XCTAssertEqual(snapshot.showOnlySelectedColumnsTitle, "Show Only 1 Selected Column")
        XCTAssertEqual(snapshot.showAllTitle, "Show All Rows and Columns")
    }
}
