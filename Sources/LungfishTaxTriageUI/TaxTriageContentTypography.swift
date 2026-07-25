import AppKit
import LungfishCore
import LungfishKit

/// An ordinary TaxTriage table in production, with a DEBUG-only counter around
/// the real `reloadData()` entry point so typography tests can prove that a
/// notification did not ask AppKit to reload rows.
@MainActor
final class TaxTriageTableView: NSTableView {
#if DEBUG
    private(set) var testingReloadDataCallCount = 0

    override func reloadData() {
        testingReloadDataCallCount += 1
        super.reloadData()
    }
#endif
}

@MainActor
func taxTriageContentFont(
    canonicalPointSize: CGFloat,
    weight: NSFont.Weight = .regular,
    monospaced: Bool = false,
    digitsOnly: Bool = false,
    preferredFontProvider: any ContentPreferredFontProviding
) -> NSFont {
    let resolvedBody = ContentTypography.current(
        preferredFontProvider: preferredFontProvider
    ).font(for: .body)
    let canonicalBody = max(
        preferredFontProvider.canonicalUnscaledPointSize(for: .body),
        1
    )
    let resolvedPointSize = max(
        ContentTypography.minimumPointSize,
        canonicalPointSize * resolvedBody.pointSize / canonicalBody
    )
    if digitsOnly {
        return .monospacedDigitSystemFont(ofSize: resolvedPointSize, weight: weight)
    }
    if monospaced {
        return .monospacedSystemFont(ofSize: resolvedPointSize, weight: weight)
    }
    return .systemFont(ofSize: resolvedPointSize, weight: weight)
}

@MainActor
struct TaxTriageTableViewportAnchor {
    let horizontalOrigin: CGFloat
    let topRow: Int?
    let offsetWithinTopRow: CGFloat

    init(tableView: NSTableView) {
        horizontalOrigin = tableView.visibleRect.minX
        let rows = tableView.rows(in: tableView.visibleRect)
        guard rows.location != NSNotFound, rows.location < tableView.numberOfRows else {
            topRow = nil
            offsetWithinTopRow = 0
            return
        }
        topRow = rows.location
        offsetWithinTopRow = tableView.visibleRect.minY
            - tableView.rect(ofRow: rows.location).minY
    }

    func restore(in tableView: NSTableView, previousRowHeight: CGFloat) {
        guard let scrollView = tableView.enclosingScrollView else { return }
        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        origin.x = horizontalOrigin
        if let topRow, topRow >= 0, topRow < tableView.numberOfRows {
            let scaledOffset = previousRowHeight > 0
                ? offsetWithinTopRow * tableView.rowHeight / previousRowHeight
                : offsetWithinTopRow
            origin.y = tableView.rect(ofRow: topRow).minY + scaledOffset
        }
        let maxX = max(0, tableView.frame.width - clipView.bounds.width)
        let maxY = max(0, tableView.frame.height - clipView.bounds.height)
        origin.x = min(max(0, origin.x), maxX)
        origin.y = min(max(0, origin.y), maxY)
        clipView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}

@MainActor
func taxTriageApplyTableGeometry(
    to tableView: NSTableView,
    minimumRowHeight: CGFloat,
    preferredFontProvider: any ContentPreferredFontProviding
) {
    let anchor = TaxTriageTableViewportAnchor(tableView: tableView)
    let previousRowHeight = tableView.rowHeight
    let typography = ContentTypography.current(
        preferredFontProvider: preferredFontProvider
    )
    let contentFont = taxTriageContentFont(
        canonicalPointSize: 11,
        preferredFontProvider: preferredFontProvider
    )
    tableView.rowHeight = max(
        minimumRowHeight,
        ceil(contentFont.boundingRectForFont.height + 6)
    )
    if let headerView = tableView.headerView {
        var frame = headerView.frame
        frame.size.height = typography.tableHeaderHeight()
        headerView.frame = frame
    }
    for column in tableView.tableColumns {
        column.headerCell.font = typography.font(for: .tableHeader)
        column.headerToolTip = column.headerToolTip ?? column.title
    }
    tableView.enclosingScrollView?.tile()
    tableView.layoutSubtreeIfNeeded()
    anchor.restore(in: tableView, previousRowHeight: previousRowHeight)
}

@MainActor
func taxTriageForEachRealizedCell(
    in tableView: NSTableView,
    _ body: (_ column: NSTableColumn, _ row: Int, _ view: NSView) -> Void
) -> Int {
    let rows = tableView.rows(in: tableView.visibleRect)
    guard rows.location != NSNotFound else { return 0 }
    var count = 0
    let upperRow = min(NSMaxRange(rows), tableView.numberOfRows)
    for row in rows.location..<upperRow {
        for (columnIndex, column) in tableView.tableColumns.enumerated()
        where !column.isHidden {
            guard let view = tableView.view(
                atColumn: columnIndex,
                row: row,
                makeIfNecessary: false
            ) else {
                continue
            }
            body(column, row, view)
            count += 1
        }
    }
    return count
}

#if DEBUG
struct TaxTriageTablePresentationState: Equatable {
    let selectedRows: IndexSet
    let sortKeys: [String]
    let sortAscending: [Bool]
    let columnIdentifiers: [String]
    let columnWidths: [CGFloat]
    let topVisibleRow: Int?
    let horizontalOrigin: CGFloat
    let hasKeyboardFocus: Bool

    @MainActor
    init(tableView: NSTableView) {
        selectedRows = tableView.selectedRowIndexes
        sortKeys = tableView.sortDescriptors.map { $0.key ?? "" }
        sortAscending = tableView.sortDescriptors.map(\.ascending)
        columnIdentifiers = tableView.tableColumns.map(\.identifier.rawValue)
        columnWidths = tableView.tableColumns.map(\.width)
        let rows = tableView.rows(in: tableView.visibleRect)
        topVisibleRow = rows.location == NSNotFound ? nil : rows.location
        horizontalOrigin = tableView.visibleRect.minX
        hasKeyboardFocus = tableView.window?.firstResponder === tableView
    }
}
#endif
