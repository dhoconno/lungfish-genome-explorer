// RNASeqBulkViewController.swift - The view of a bulk RNA-seq result (Phase 5.4 lane RS-BULK-VIEW M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One tab a count table, then Quality and Correlation. Every cell is read from the injected ``RNASeqBulkModel``, so a
// test reads what the screen shows with no window. Nothing here edits, renames or moves a file of the result.

import AppKit
import LungfishIO
import LungfishWorkflow
import Observation

@MainActor
public final class RNASeqBulkViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public static let accessibilityID = "rnaseq-bulk-view"
    public static let searchFieldID = "rnaseq-bulk-search"
    public static let tabsID = "rnaseq-bulk-tabs"
    public static let qualityTableID = "rnaseq-bulk-quality-table"
    /// The tag of the quality table. A count table's tag is its index in ``RNASeqBulkModel/tables``.
    public static let qualityTag = 1000

    public private(set) var model: RNASeqBulkModel
    public private(set) var result: RNASeqResult?
    public private(set) var bundleURL: URL?

    public let searchField = NSSearchField()
    public let tabView = NSTabView()
    public private(set) var countTables: [NSTableView] = []
    public let qualityTable = NSTableView()
    public let correlationPlot = RNASeqCorrelationPlotView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))

    private let matchLabel = RNASeqBulkViewController.label("", id: "rnaseq-bulk-matches")
    private var countCaptions: [NSTextField] = []
    private let qualityCaption = RNASeqBulkViewController.label("", id: "rnaseq-bulk-quality-caption", wraps: true)
    private let qualityNotes = RNASeqBulkViewController.label("", id: "rnaseq-bulk-quality-notes", wraps: true)
    private let correlationCaption = RNASeqBulkViewController.label("", id: "rnaseq-bulk-correlation-caption", wraps: true)
    private let correlationScale = RNASeqBulkViewController.label("", id: "rnaseq-bulk-correlation-scale", wraps: true)
    private let correlationChosen = RNASeqBulkViewController.label(
        "Choose a cell with the arrow keys or the pointer to read its value.", id: "rnaseq-bulk-correlation-selected", wraps: true)
    private var builtForShow = -1

    public init(model: RNASeqBulkModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    public override init(nibName: NSNib.Name?, bundle: Bundle?) {
        self.model = RNASeqBulkModel()
        super.init(nibName: nibName, bundle: bundle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func loadView() {
        let root = NSView()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Bulk RNA-seq result")
        root.setAccessibilityIdentifier(Self.accessibilityID)

        searchField.placeholderString = "Search genes by id or name"
        searchField.setAccessibilityIdentifier(Self.searchFieldID)
        searchField.setAccessibilityLabel("Search the count tables by feature id or gene name")
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        tabView.setAccessibilityIdentifier(Self.tabsID)
        tabView.translatesAutoresizingMaskIntoConstraints = false
        correlationPlot.onSelect = { [weak self] words in self?.correlationChosen.stringValue = words }

        for subview in [searchField, matchLabel, tabView] { root.addSubview(subview) }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            searchField.widthAnchor.constraint(equalToConstant: 280),
            matchLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            matchLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 12),
            matchLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            tabView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
        reloadFromModel()
        observeModel()
    }

    /// Shows a result the surface read. The quality tabs fill when the model has read the quality numbers.
    public func configure(result: RNASeqResult, bundleURL: URL) {
        self.result = result
        self.bundleURL = bundleURL
        model.show(result: result, bundleURL: bundleURL)
        if isViewLoaded { reloadFromModel() }
    }

    /// Builds the tabs again when the model holds other tables, and reloads every table from the model.
    public func reloadFromModel() {
        guard isViewLoaded else { return }
        if builtForShow != model.showCount {
            buildTabs()
            builtForShow = model.showCount
        }
        if searchField.stringValue != model.searchText { searchField.stringValue = model.searchText }
        for (index, table) in countTables.enumerated() where index < model.tables.count {
            countCaptions[index].stringValue = model.tables[index].caption
            table.reloadData()
        }
        matchLabel.stringValue = matchWords()
        showQuality()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        model.search(sender.stringValue)
        reloadFromModel()
    }

    /// How many rows the search keeps in the first table, or nothing when no search is typed.
    private func matchWords() -> String {
        guard let first = model.tables.first, !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return "\(first.visibleRows.count) of \(first.rowCount) \(first.rows == .gene ? "genes" : "transcripts") match"
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.tables
            _ = model.quality
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadFromModel()
                self?.observeModel()
            }
        }
    }

    // MARK: - Tabs

    private func buildTabs() {
        for item in tabView.tabViewItems { tabView.removeTabViewItem(item) }
        countTables = []
        countCaptions = []
        for (index, table) in model.tables.enumerated() {
            let caption = Self.label(table.caption, id: "rnaseq-bulk-table-caption-\(index)", wraps: true)
            let tableView = makeTable(id: "rnaseq-bulk-table-\(index)", tag: index, titles: model.columnTitles(table: index))
            tableView.setAccessibilityLabel("\(table.title) count table, \(table.unitWords)")
            for (column, sample) in tableView.tableColumns.enumerated() where column >= 4 {
                sample.headerToolTip = "\(table.sampleIDs[column - 4]), in \(table.unitWords)"
            }
            countTables.append(tableView)
            countCaptions.append(caption)
            addTab(title: table.title, id: "rnaseq-bulk-tab-\(index)", views: [caption], table: tableView, below: [])
        }
        let quality = configureTable(qualityTable, id: Self.qualityTableID, tag: Self.qualityTag, titles: [])
        quality.setAccessibilityLabel("Quality of each sample")
        addTab(title: "Quality", id: "rnaseq-bulk-tab-quality", views: [qualityCaption], table: quality, below: [qualityNotes])
        correlationPlot.translatesAutoresizingMaskIntoConstraints = false
        addTab(title: "Correlation", id: "rnaseq-bulk-tab-correlation", views: [correlationCaption], plot: correlationPlot,
               below: [correlationChosen, correlationScale])
    }

    private func addTab(title: String, id: String, views: [NSView], table: NSTableView? = nil,
                        plot: NSView? = nil, below: [NSView]) {
        let item = NSTabViewItem(identifier: id)
        item.label = title
        let pane = NSView()
        var body: NSView
        if let table {
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            body = scroll
        } else {
            body = plot ?? NSView()
        }
        let stack = NSStackView(views: views + [body] + below)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -8),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ]
        if plot != nil {
            let square = body.heightAnchor.constraint(equalTo: body.widthAnchor)
            square.priority = .defaultLow
            constraints += [square, body.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)]
        }
        for line in views + below { constraints.append(line.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)) }
        NSLayoutConstraint.activate(constraints)
        item.view = pane
        tabView.addTabViewItem(item)
    }

    private func makeTable(id: String, tag: Int, titles: [String]) -> NSTableView {
        configureTable(NSTableView(), id: id, tag: tag, titles: titles)
    }

    @discardableResult
    private func configureTable(_ table: NSTableView, id: String, tag: Int, titles: [String]) -> NSTableView {
        for column in table.tableColumns { table.removeTableColumn(column) }
        for (index, title) in titles.enumerated() { table.addTableColumn(Self.column(title, index: index)) }
        table.tag = tag
        table.setAccessibilityIdentifier(id)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 18
        table.dataSource = self
        table.delegate = self
        return table
    }

    private static func column(_ title: String, index: Int) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column-\(index)"))
        column.title = title
        column.width = index == 0 ? 150 : 100
        column.isEditable = false
        return column
    }

    // MARK: - Quality

    private func showQuality() {
        switch model.quality {
        case .loading:
            qualityCaption.stringValue = "Reading the quality numbers, after checking each file of the result against its sha256."
            correlationCaption.stringValue = qualityCaption.stringValue
            qualityNotes.stringValue = ""
            correlationScale.stringValue = ""
            setQualityColumns([])
        case .failed(let words):
            qualityCaption.stringValue = words
            correlationCaption.stringValue = words
            qualityNotes.stringValue = ""
            correlationScale.stringValue = ""
            setQualityColumns([])
        case .loaded(let quality):
            qualityCaption.stringValue = quality.summary.caption
            qualityNotes.stringValue = quality.notes.joined(separator: "\n")
            setQualityColumns(quality.samples.columns)
            correlationCaption.stringValue = quality.correlation.caption
            let cells = quality.correlationTable.rows.map { Array($0.dropFirst()) }
            if correlationPlot.cells != cells {
                correlationPlot.show(quality.correlation, cells: cells, caption: quality.correlation.caption)
            }
            correlationScale.stringValue = correlationPlot.lowestText.map {
                "A stronger blue square is a higher value, on a scale from the lowest value of the table, \($0), to 1. "
                    + "A grey square reads Not recorded."
            } ?? ""
        }
        qualityTable.reloadData()
    }

    private func setQualityColumns(_ names: [String]) {
        guard qualityTable.tableColumns.map(\.headerToolTip) != names.map(Optional.some) else { return }
        for column in qualityTable.tableColumns { qualityTable.removeTableColumn(column) }
        for (index, name) in names.enumerated() {
            let column = Self.column(RNASeqBulkQuality.columnTitles[name] ?? name, index: index)
            column.headerToolTip = name
            column.width = index == 2 ? 260 : 130
            qualityTable.addTableColumn(column)
        }
    }

    // MARK: - Cells

    /// The text a table shows at a row and column, read from the model. The tests read the screen through it.
    public func shownText(tableTag: Int, column: Int, row: Int) -> String {
        if tableTag == Self.qualityTag {
            guard case .loaded(let quality) = model.quality else { return "" }
            return quality.samples.rows[row][column]
        }
        let table = model.tables[tableTag]
        return model.shownCell(table: tableTag, row: table.visibleRows[row], column: column)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView.tag == Self.qualityTag {
            guard case .loaded(let quality) = model.quality else { return 0 }
            return quality.samples.rows.count
        }
        return tableView.tag < model.tables.count ? model.tables[tableView.tag].visibleRows.count : 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
        let id = NSUserInterfaceItemIdentifier("rnaseq-bulk-cell")
        let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? {
            let made = NSTextField(labelWithString: "")
            made.identifier = id
            made.isEditable = false
            made.lineBreakMode = .byTruncatingTail
            made.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            return made
        }()
        field.stringValue = shownText(tableTag: tableView.tag, column: column, row: row)
        field.alignment = tableView.tag != Self.qualityTag && column >= 4 ? .right : .left
        field.toolTip = field.stringValue
        return field
    }

    private static func label(_ text: String, id: String, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.isEditable = false
        field.isSelectable = true
        field.setAccessibilityIdentifier(id)
        return field
    }
}
