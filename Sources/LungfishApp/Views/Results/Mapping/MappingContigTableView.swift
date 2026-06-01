import AppKit
import LungfishWorkflow
import LungfishAppKit

@MainActor
final class MappingContigTableView: BatchTableView<MappingContigSummary> {
    var scalarPasteboard: PasteboardWriting?

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: .init("contig"), title: "Contig", width: 220, minWidth: 140, defaultAscending: true),
            .init(identifier: .init("length"), title: "Length", width: 90, minWidth: 70, defaultAscending: false),
            .init(identifier: .init("reads"), title: "Mapped Reads", width: 110, minWidth: 88, defaultAscending: false),
            .init(identifier: .init("mappedPercent"), title: "% Mapped", width: 92, minWidth: 80, defaultAscending: false),
            .init(identifier: .init("depth"), title: "Mean Depth", width: 92, minWidth: 78, defaultAscending: false),
            .init(identifier: .init("breadth"), title: "Coverage Breadth", width: 126, minWidth: 110, defaultAscending: false),
            .init(identifier: .init("mapq"), title: "Median MAPQ", width: 96, minWidth: 82, defaultAscending: false),
            .init(identifier: .init("identity"), title: "Mean Identity", width: 102, minWidth: 88, defaultAscending: false),
        ]
    }

    override var searchPlaceholder: String { "Filter contigs\u{2026}" }
    override var searchAccessibilityIdentifier: String? { "mapping-result-search" }
    override var searchAccessibilityLabel: String? { "Filter mapped contigs" }
    override var tableAccessibilityIdentifier: String? { "mapping-result-contig-table" }
    override var tableAccessibilityLabel: String? { "Mapping contig table" }
    override var cellCopyPasteboard: PasteboardWriting? { scalarPasteboard }

    override var columnTypeHints: [String: Bool] {
        [
            "contig": false,
            "length": true,
            "reads": true,
            "mappedPercent": true,
            "depth": true,
            "breadth": true,
            "mapq": true,
            "identity": true,
        ]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        finishSetup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        finishSetup()
    }

    private func finishSetup() {
        tableView.allowsMultipleSelection = false
        tableView.sortDescriptors = [
            NSSortDescriptor(key: "reads", ascending: false)
        ]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: MappingContigSummary
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "contig":
            return (row.contigName, .left, .systemFont(ofSize: 12))
        case "length":
            return (row.contigLength.formatted(), .right, numericFont)
        case "reads":
            return (row.mappedReads.formatted(), .right, numericFont)
        case "mappedPercent":
            return (formatPercent(rawPercentValue(row.mappedReadPercent)), .right, numericFont)
        case "depth":
            return (String(format: "%.1f", row.meanDepth), .right, numericFont)
        case "breadth":
            return (formatPercent(rawPercentValue(row.coverageBreadth)), .right, numericFont)
        case "mapq":
            return (String(format: "%.1f", row.medianMAPQ), .right, numericFont)
        case "identity":
            return (formatPercent(rawPercentValue(row.meanIdentity)), .right, numericFont)
        default:
            return ("", .left, nil)
        }
    }

    override func columnValue(for columnId: String, row: MappingContigSummary) -> String {
        switch columnId {
        case "contig":
            return row.contigName
        case "length":
            return "\(row.contigLength)"
        case "reads":
            return "\(row.mappedReads)"
        case "mappedPercent":
            return String(rawPercentValue(row.mappedReadPercent))
        case "depth":
            return String(row.meanDepth)
        case "breadth":
            return String(rawPercentValue(row.coverageBreadth))
        case "mapq":
            return String(row.medianMAPQ)
        case "identity":
            return String(rawPercentValue(row.meanIdentity))
        default:
            return super.columnValue(for: columnId, row: row)
        }
    }

    override func rowMatchesFilter(_ row: MappingContigSummary, filterText: String) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let haystack = [
            row.contigName,
            row.contigLength.formatted(),
            row.mappedReads.formatted(),
            formatPercent(rawPercentValue(row.mappedReadPercent)),
            String(format: "%.1f", row.meanDepth),
            formatPercent(rawPercentValue(row.coverageBreadth)),
            String(format: "%.1f", row.medianMAPQ),
            formatPercent(rawPercentValue(row.meanIdentity)),
        ]

        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    override func compareRows(
        _ lhs: MappingContigSummary,
        _ rhs: MappingContigSummary,
        by key: String,
        ascending: Bool
    ) -> Bool {
        let comparison: ComparisonResult
        switch key {
        case "contig":
            comparison = lhs.contigName.localizedCaseInsensitiveCompare(rhs.contigName)
        case "length":
            comparison = compare(lhs.contigLength, rhs.contigLength)
        case "reads":
            comparison = compare(lhs.mappedReads, rhs.mappedReads)
        case "mappedPercent":
            comparison = compare(rawPercentValue(lhs.mappedReadPercent), rawPercentValue(rhs.mappedReadPercent))
        case "depth":
            comparison = compare(lhs.meanDepth, rhs.meanDepth)
        case "breadth":
            comparison = compare(rawPercentValue(lhs.coverageBreadth), rawPercentValue(rhs.coverageBreadth))
        case "mapq":
            comparison = compare(lhs.medianMAPQ, rhs.medianMAPQ)
        case "identity":
            comparison = compare(rawPercentValue(lhs.meanIdentity), rawPercentValue(rhs.meanIdentity))
        default:
            comparison = lhs.contigName.localizedCaseInsensitiveCompare(rhs.contigName)
        }

        if comparison == .orderedSame {
            let fallback = lhs.contigName.localizedCaseInsensitiveCompare(rhs.contigName)
            if fallback == .orderedSame {
                return false
            }
            return ascending ? fallback == .orderedAscending : fallback == .orderedDescending
        }

        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private var numericFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    private func rawPercentValue(_ value: Double) -> Double {
        value <= 1.0 ? value * 100.0 : value
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }

}

#if DEBUG
extension MappingContigTableView {
    func copyValue(row: Int, columnID: String, pasteboard: PasteboardWriting?) {
        guard row >= 0, row < displayedRows.count else { return }
        let content = cellContent(for: NSUserInterfaceItemIdentifier(columnID), row: displayedRows[row]).text
        pasteboard?.setString(content)
    }

    func record(at row: Int) -> MappingContigSummary? {
        guard row >= 0, row < displayedRows.count else { return nil }
        return displayedRows[row]
    }

    func applyTestFilter(
        columnID: String,
        op: FilterOperator,
        value: String,
        value2: String? = nil
    ) {
        setColumnFilter(ColumnFilter(columnId: columnID, op: op, value: value, value2: value2), for: columnID)
        testTableView.reloadData()
        let applyFilter = Selector(("applyFilter"))
        if responds(to: applyFilter), let method = method(for: applyFilter) {
            typealias ApplyIMP = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(method, to: ApplyIMP.self)(self, applyFilter)
        }
    }

    func clearTestFilters() {
        clearAllColumnFilters()
        let applyFilter = Selector(("applyFilter"))
        if responds(to: applyFilter), let method = method(for: applyFilter) {
            typealias ApplyIMP = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(method, to: ApplyIMP.self)(self, applyFilter)
        }
    }
}
#endif
