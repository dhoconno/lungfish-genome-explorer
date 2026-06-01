import AppKit
import LungfishIO
import LungfishAppKit

@MainActor
final class GenotypeResultTableView: BatchTableView<ONTGenotypeSampleResult> {
    private enum ColumnID {
        static let sample = NSUserInterfaceItemIdentifier("sample")
        static let qc = NSUserInterfaceItemIdentifier("qc")
        static let calls = NSUserInterfaceItemIdentifier("calls")
        static let alignments = NSUserInterfaceItemIdentifier("alignments")
        static let uniqueReads = NSUserInterfaceItemIdentifier("uniqueReads")
        static let retainedPercent = NSUserInterfaceItemIdentifier("retainedPercent")
        static let topGenotype = NSUserInterfaceItemIdentifier("topGenotype")
    }

    override var searchPlaceholder: String { "Filter samples, QC, or genotypes" }
    override var searchAccessibilityIdentifier: String? { "genotype-result-sample-filter" }
    override var tableAccessibilityIdentifier: String? { "genotype-result-sample-table" }
    override var tableAccessibilityLabel: String? { "Genotype result samples" }

    override var columnSpecs: [BatchColumnSpec] {
        [
            BatchColumnSpec(identifier: ColumnID.sample, title: "Sample", width: 140, minWidth: 90, defaultAscending: true),
            BatchColumnSpec(identifier: ColumnID.qc, title: "QC", width: 92, minWidth: 74, defaultAscending: true),
            BatchColumnSpec(identifier: ColumnID.calls, title: "Calls", width: 70, minWidth: 56, defaultAscending: false),
            BatchColumnSpec(identifier: ColumnID.alignments, title: "Alignments", width: 92, minWidth: 78, defaultAscending: false),
            BatchColumnSpec(identifier: ColumnID.uniqueReads, title: "Unique", width: 78, minWidth: 64, defaultAscending: false),
            BatchColumnSpec(identifier: ColumnID.retainedPercent, title: "Retained %", width: 88, minWidth: 74, defaultAscending: false),
            BatchColumnSpec(identifier: ColumnID.topGenotype, title: "Top Genotype", width: 210, minWidth: 120, defaultAscending: true),
        ]
    }

    override var columnTypeHints: [String: Bool] {
        [
            ColumnID.calls.rawValue: true,
            ColumnID.alignments.rawValue: true,
            ColumnID.uniqueReads.rawValue: true,
            ColumnID.retainedPercent.rawValue: true,
        ]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: ONTGenotypeSampleResult
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column {
        case ColumnID.sample:
            return (row.sample, .left, .systemFont(ofSize: 12, weight: .medium))
        case ColumnID.qc:
            return (row.qcStatus.displayName, .left, nil)
        case ColumnID.calls:
            return ("\(row.callCount)", .right, nil)
        case ColumnID.alignments:
            return (Self.integer(row.passedAlignments), .right, nil)
        case ColumnID.uniqueReads:
            return (Self.integer(row.passedUniqueReads), .right, nil)
        case ColumnID.retainedPercent:
            return (Self.percent(row.sampleUniqueRetainedPercent), .right, nil)
        case ColumnID.topGenotype:
            return (row.topCall?.genotype ?? "", .left, nil)
        default:
            return ("", .left, nil)
        }
    }

    override func rowMatchesFilter(_ row: ONTGenotypeSampleResult, filterText: String) -> Bool {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if row.sample.localizedCaseInsensitiveContains(needle) { return true }
        if row.qcStatus.displayName.localizedCaseInsensitiveContains(needle) { return true }
        return row.calls.contains { $0.genotype.localizedCaseInsensitiveContains(needle) }
    }

    override func compareRows(
        _ lhs: ONTGenotypeSampleResult,
        _ rhs: ONTGenotypeSampleResult,
        by key: String,
        ascending: Bool
    ) -> Bool {
        let ordered: ComparisonResult
        switch key {
        case ColumnID.calls.rawValue:
            ordered = compare(lhs.callCount, rhs.callCount)
        case ColumnID.alignments.rawValue:
            ordered = compare(lhs.passedAlignments, rhs.passedAlignments)
        case ColumnID.uniqueReads.rawValue:
            ordered = compare(lhs.passedUniqueReads, rhs.passedUniqueReads)
        case ColumnID.retainedPercent.rawValue:
            ordered = compare(lhs.sampleUniqueRetainedPercent ?? -1, rhs.sampleUniqueRetainedPercent ?? -1)
        case ColumnID.qc.rawValue:
            ordered = lhs.qcStatus.displayName.localizedStandardCompare(rhs.qcStatus.displayName)
        case ColumnID.topGenotype.rawValue:
            ordered = (lhs.topCall?.genotype ?? "").localizedStandardCompare(rhs.topCall?.genotype ?? "")
        default:
            ordered = lhs.sample.localizedStandardCompare(rhs.sample)
        }
        return ascending ? ordered == .orderedAscending : ordered == .orderedDescending
    }

    override func columnValue(for columnId: String, row: ONTGenotypeSampleResult) -> String {
        cellContent(for: NSUserInterfaceItemIdentifier(columnId), row: row).text
    }

    override func sampleId(for row: ONTGenotypeSampleResult) -> String? {
        row.sample
    }

    override func rowIdentity(for row: ONTGenotypeSampleResult) -> String? {
        row.sample
    }

    func selectSample(named sample: String) {
        guard let index = displayedRows.firstIndex(where: { $0.sample == sample }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: tableView))
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func integer(_ value: Int) -> String {
        value.formatted(.number)
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.1f%%", value)
    }
}
