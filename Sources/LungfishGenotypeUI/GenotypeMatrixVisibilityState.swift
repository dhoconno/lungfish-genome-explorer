import Foundation
import LungfishIO

public enum GenotypeMatrixVisibilityCommand: Equatable, Sendable {
    case hideSelectedRows
    case showOnlySelectedRows
    case showAllRows
    case hideSelectedColumns
    case showOnlySelectedColumns
    case showAllColumns
    case reset
}

struct GenotypeMatrixVisibilityState: Equatable, Sendable {
    typealias RowID = GenotypeCandidateMatrixRowID
    typealias SampleID = String

    let includedRows: Set<RowID>?
    let excludedRows: Set<RowID>
    let includedSamples: Set<SampleID>?
    let excludedSamples: Set<SampleID>

    init(
        includedRows: Set<RowID>? = nil,
        excludedRows: Set<RowID> = [],
        includedSamples: Set<SampleID>? = nil,
        excludedSamples: Set<SampleID> = []
    ) {
        self.includedRows = includedRows
        self.excludedRows = excludedRows
        self.includedSamples = includedSamples
        self.excludedSamples = excludedSamples
    }

    var isRowVisibilityActive: Bool {
        includedRows != nil || !excludedRows.isEmpty
    }

    var isSampleVisibilityActive: Bool {
        includedSamples != nil || !excludedSamples.isEmpty
    }

    var isActive: Bool {
        isRowVisibilityActive || isSampleVisibilityActive
    }

    func allows(row: RowID) -> Bool {
        (includedRows?.contains(row) ?? true) && !excludedRows.contains(row)
    }

    func allows(sample: SampleID) -> Bool {
        (includedSamples?.contains(sample) ?? true) && !excludedSamples.contains(sample)
    }

    func showingOnlyRows(_ rows: Set<RowID>) -> Self {
        guard !rows.isEmpty else { return self }
        return Self(
            includedRows: rows,
            excludedRows: [],
            includedSamples: includedSamples,
            excludedSamples: excludedSamples
        )
    }

    func hidingRows(_ rows: Set<RowID>) -> Self {
        guard !rows.isEmpty else { return self }
        return Self(
            includedRows: includedRows,
            excludedRows: excludedRows.union(rows),
            includedSamples: includedSamples,
            excludedSamples: excludedSamples
        )
    }

    func showingOnlySamples(_ samples: Set<SampleID>) -> Self {
        guard !samples.isEmpty else { return self }
        return Self(
            includedRows: includedRows,
            excludedRows: excludedRows,
            includedSamples: samples,
            excludedSamples: []
        )
    }

    func hidingSamples(_ samples: Set<SampleID>) -> Self {
        guard !samples.isEmpty else { return self }
        return Self(
            includedRows: includedRows,
            excludedRows: excludedRows,
            includedSamples: includedSamples,
            excludedSamples: excludedSamples.union(samples)
        )
    }

    func showingAllRows() -> Self {
        Self(
            includedRows: nil,
            excludedRows: [],
            includedSamples: includedSamples,
            excludedSamples: excludedSamples
        )
    }

    func showingAllSamples() -> Self {
        Self(
            includedRows: includedRows,
            excludedRows: excludedRows,
            includedSamples: nil,
            excludedSamples: []
        )
    }

    func reset() -> Self {
        Self()
    }
}

public enum GenotypeMatrixVisibilitySelectionShape: Equatable, Sendable {
    case none
    case rows(count: Int)
    case columns(count: Int)
    case cellRectangle(cellCount: Int, rowCount: Int, columnCount: Int)
    case sparseCells(cellCount: Int, rowCount: Int, columnCount: Int)
    case mixed(rowCount: Int, columnCount: Int)
}

struct GenotypeMatrixVisibilitySelectionSnapshot: Equatable, Sendable {
    typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    typealias RowID = GenotypeCandidateMatrixRowID
    typealias SampleID = String

    let rowIDs: Set<RowID>
    let sampleIDs: Set<SampleID>
    let uniqueTargetCount: Int
    let selectedCellCount: Int
    let shape: GenotypeMatrixVisibilitySelectionShape
    let summary: String

    init(targets: [Target]) {
        let uniqueTargets = Set(targets)
        var rows: Set<RowID> = []
        var samples: Set<SampleID> = []
        var cells: Set<CellIdentity> = []
        var containsRows = false
        var containsColumns = false
        var containsCells = false

        for target in uniqueTargets {
            switch target {
            case let .row(locus, genotype, stableClusterID):
                containsRows = true
                rows.insert(Self.rowID(locus: locus, genotype: genotype, stableClusterID: stableClusterID))
            case let .column(sample):
                containsColumns = true
                samples.insert(sample)
            case let .cell(locus, genotype, sample, stableClusterID):
                containsCells = true
                let row = Self.rowID(locus: locus, genotype: genotype, stableClusterID: stableClusterID)
                rows.insert(row)
                samples.insert(sample)
                cells.insert(CellIdentity(row: row, sample: sample))
            }
        }

        rowIDs = rows
        sampleIDs = samples
        uniqueTargetCount = uniqueTargets.count
        selectedCellCount = cells.count

        let kindCount = [containsRows, containsColumns, containsCells].filter { $0 }.count
        if uniqueTargets.isEmpty {
            shape = .none
            summary = "Scope: Entire matrix"
        } else if kindCount > 1 {
            shape = .mixed(rowCount: rows.count, columnCount: samples.count)
            summary = "Selected: \(Self.counted(rows.count, singular: "allele row")) and "
                + "\(Self.counted(samples.count, singular: "sample column"))"
        } else if containsRows {
            shape = .rows(count: rows.count)
            summary = "Selected: \(Self.counted(rows.count, singular: "allele row"))"
        } else if containsColumns {
            shape = .columns(count: samples.count)
            summary = "Selected: \(Self.counted(samples.count, singular: "sample column"))"
        } else {
            let expectedRectangleCount = rows.count.multipliedReportingOverflow(by: samples.count)
            let isRectangle = !expectedRectangleCount.overflow && cells.count == expectedRectangleCount.partialValue
            if isRectangle {
                shape = .cellRectangle(
                    cellCount: cells.count,
                    rowCount: rows.count,
                    columnCount: samples.count
                )
                summary = "Selected: \(Self.counted(cells.count, singular: "cell")) "
                    + "(\(Self.counted(rows.count, singular: "row", includesCount: true)) × "
                    + "\(Self.counted(samples.count, singular: "column", includesCount: true)))"
            } else {
                shape = .sparseCells(
                    cellCount: cells.count,
                    rowCount: rows.count,
                    columnCount: samples.count
                )
                summary = "Selected: \(Self.counted(cells.count, singular: "cell")) across "
                    + "\(Self.counted(rows.count, singular: "row")) and "
                    + "\(Self.counted(samples.count, singular: "column"))"
            }
        }
    }

    private struct CellIdentity: Hashable, Sendable {
        let row: RowID
        let sample: SampleID
    }

    private static func rowID(
        locus: String,
        genotype: String,
        stableClusterID: String?
    ) -> RowID {
        if let stableClusterID {
            return .candidate(stableClusterID: stableClusterID)
        }
        return .known(locus: locus, genotype: genotype)
    }

    private static func counted(
        _ count: Int,
        singular: String,
        includesCount: Bool = true
    ) -> String {
        let noun = count == 1 ? singular : "\(singular)s"
        return includesCount ? "\(count) \(noun)" : noun
    }
}

public struct GenotypeMatrixVisibilityCapabilitySnapshot: Equatable, Sendable {
    let selection: GenotypeMatrixVisibilitySelectionSnapshot
    let visibility: GenotypeMatrixVisibilityState

    public static var empty: Self {
        Self(selection: .init(targets: []), visibility: .init())
    }

    public var selectionShape: GenotypeMatrixVisibilitySelectionShape {
        selection.shape
    }

    public var summary: String { selection.summary }
    public var selectedRowCount: Int { selection.rowIDs.count }
    public var selectedColumnCount: Int { selection.sampleIDs.count }
    public var selectedCellCount: Int { selection.selectedCellCount }
    public var isRowVisibilityActive: Bool { visibility.isRowVisibilityActive }
    public var isColumnVisibilityActive: Bool { visibility.isSampleVisibilityActive }
    public var canHideSelectedRows: Bool { !selection.rowIDs.isEmpty }
    public var canShowOnlySelectedRows: Bool { !selection.rowIDs.isEmpty }
    public var canHideSelectedColumns: Bool { !selection.sampleIDs.isEmpty }
    public var canShowOnlySelectedColumns: Bool { !selection.sampleIDs.isEmpty }
    public var canShowAllRows: Bool { visibility.isRowVisibilityActive }
    public var canShowAllColumns: Bool { visibility.isSampleVisibilityActive }
    public var canResetVisibility: Bool { visibility.isActive }

    public var hideSelectedRowsTitle: String {
        countedCommand("Hide", count: selection.rowIDs.count, singular: "Selected Row")
    }

    public var showOnlySelectedRowsTitle: String {
        countedCommand("Show Only", count: selection.rowIDs.count, singular: "Selected Row")
    }

    public var hideSelectedColumnsTitle: String {
        countedCommand("Hide", count: selection.sampleIDs.count, singular: "Selected Column")
    }

    public var showOnlySelectedColumnsTitle: String {
        countedCommand("Show Only", count: selection.sampleIDs.count, singular: "Selected Column")
    }

    public var showAllTitle: String {
        "Show All Rows and Columns"
    }

    private func countedCommand(_ verb: String, count: Int, singular: String) -> String {
        "\(verb) \(count) \(count == 1 ? singular : "\(singular)s")"
    }
}
