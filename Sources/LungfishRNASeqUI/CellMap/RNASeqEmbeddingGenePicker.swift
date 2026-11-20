// RNASeqEmbeddingGenePicker.swift - Choose a gene to colour the cell map by (Phase 5.5 lane CM-GENE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The picker lists the cell map's features by name and by id, read from the `features` table of `cellmap.sqlite` (5.5 G1),
// never from the parent's `genes.tsv`, which holds ids only when the parent has no reference set. A feature of type Gene
// Expression is offered. A feature of any other type, such as Antibody Capture, is listed after the genes with a note that
// it is not offered, since the map holds no values for it. A name that two ids hold lists each id. The read of the features
// and every search run off the main actor and the newest search wins. The colouring is the controller's, which takes a
// pick as one more colouring choice (`RNASeqCellMapViewController.showGenePicker`).

import AppKit
import LungfishIO

/// A gene as a colouring names it, the feature and how to show it, with the unit of the values.
public struct RNASeqGeneChoice: Hashable, Sendable {
    public var feature: Int
    public var id: String
    public var name: String
    public var unit: RNASeqCellMapDatabase.GeneUnit

    public init(feature: Int, id: String, name: String, unit: RNASeqCellMapDatabase.GeneUnit) {
        self.feature = feature
        self.id = id
        self.name = name
        self.unit = unit
    }

    /// The gene a row names, or nil for a feature of a type the map has no values for.
    public init?(entry: RNASeqGeneIndex.Entry, unit: RNASeqCellMapDatabase.GeneUnit) {
        guard entry.offered else { return nil }
        self.init(feature: entry.feature, id: entry.id, name: entry.name, unit: unit)
    }

    /// What a person reads for the gene, its name, or its id when the file holds no name.
    public var label: String { name.isEmpty ? id : name }

    public func with(unit: RNASeqCellMapDatabase.GeneUnit) -> RNASeqGeneChoice {
        var other = self
        other.unit = unit
        return other
    }
}

/// The features of a cell map, searched by name and by id.
public struct RNASeqGeneIndex: Sendable {
    public struct Entry: Equatable, Sendable {
        public var feature: Int
        public var id: String
        public var name: String
        public var type: String
        /// The cells with a count, as `features.cells` holds it.
        public var cells: Int
        /// Whether the map holds values for it, which only a Gene Expression feature has (5.5 G1).
        public var offered: Bool
        /// Another offered feature holds the same name, so a row shows its id beside it.
        public var sharesName: Bool
    }

    public static let offeredType = "Gene Expression"
    public let entries: [Entry]
    private let keys: [(name: String, id: String)]

    public init(features: [RNASeqCellMapDatabase.Feature]) {
        var held: [String: Int] = [:]
        for feature in features where feature.type == Self.offeredType && !feature.name.isEmpty { held[feature.name, default: 0] += 1 }
        entries = features.map { feature in
            let offered = feature.type == Self.offeredType
            return Entry(feature: feature.feature, id: feature.id, name: feature.name, type: feature.type, cells: feature.cells,
                         offered: offered, sharesName: offered && (held[feature.name] ?? 0) > 1)
        }
        keys = features.map { ($0.name.lowercased(), $0.id.lowercased()) }
    }

    /// The entries whose name or id holds `query`, ignoring case and the spaces around it. An exact match comes first, then a
    /// prefix, then the rest, the genes the map offers before the features it does not, and in feature order inside each
    /// group. An empty search lists nothing. It checks for a cancel as the reads do.
    public func search(_ query: String, limit: Int = 200) throws -> [Entry] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return [] }
        var groups = [[Int]](repeating: [], count: 6)
        for index in entries.indices {
            if index & 0xFFF == 0 { try Task.checkCancellation() }
            let key = keys[index]
            let tier: Int
            if key.name == wanted || key.id == wanted {
                tier = 0
            } else if key.name.hasPrefix(wanted) || key.id.hasPrefix(wanted) {
                tier = 1
            } else if key.name.contains(wanted) || key.id.contains(wanted) {
                tier = 2
            } else {
                continue
            }
            groups[(entries[index].offered ? 0 : 3) + tier].append(index)
        }
        return groups.joined().prefix(limit).map { entries[$0] }
    }
}

extension RNASeqCellMapDatabase.GeneValues {
    /// The gene's value in the cell `id`, from 1, or nil for a cell with no count. The cells rise, so this is a binary search.
    func value(ofCell id: Int) -> Double? {
        guard id >= 1, id <= Int(UInt32.max) else { return nil }
        let wanted = UInt32(id)
        var low = 0
        var high = cells.count
        while low < high {
            let middle = (low + high) / 2
            if cells[middle] < wanted { low = middle + 1 } else { high = middle }
        }
        guard low < cells.count, cells[low] == wanted else { return nil }
        switch values {
        case .umis(let umis): return Double(umis[low])
        case .normalised(let floats): return Double(floats[low])
        }
    }
}

extension RNASeqEmbeddingWords {
    /// A gene unit as a person reads it.
    public static func geneUnit(_ unit: RNASeqCellMapDatabase.GeneUnit) -> String { unit == .umis ? "UMIs" : "normalised UMIs" }

    /// W5, under the legend of a gene. The unit comes first, and a grey cell is never called off or not expressed.
    public static func geneColour(unit: RNASeqCellMapDatabase.GeneUnit, gene: String) -> String {
        "Colour shows \(geneUnit(unit)) of \(gene) in each cell. Grey cells have no UMIs of \(gene) counted, which does not show that the gene is off."
    }

    /// The normalised value's formula as `cellmap.sqlite` records it.
    public static func normalisedFormula(_ formula: String) -> String { "Normalised UMIs are \(formula)." }

    public static let genePopUpItem = "Gene…"
    public static func genePopUpTitle(_ gene: String) -> String { "Gene: \(gene)" }
    public static let geneUnitTitle = "Gene values"
    public static let geneUnitSegments = ["Normalised UMIs", "UMIs"]

    public static func noGeneValues(_ gene: String) -> String { "The cell map holds no values for \(gene)." }
    public static let genePickerReading = "Reading the genes of this cell map."
    public static let genePickerPrompt = "Type a gene name or an id."
    public static func genePickerNone(_ query: String) -> String { "No gene of this cell map matches \(query)." }
    public static func genePickerLimit(_ limit: Int) -> String { "Showing the first \(limit) matches. Type more of the name to narrow them." }
    public static func genePickerNotOffered(_ type: String) -> String { "\(type) features are listed but not offered for colouring in this version." }
}

/// The popover's content: a search field, the matches with their id, type and cells, and a line of words.
@MainActor
public final class RNASeqEmbeddingGenePickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public static let accessibilityID = "rnaseq-cell-map-gene-picker"
    public static let limit = 200
    private static let columns: [(id: String, title: String, width: CGFloat)] = [("name", "Gene", 110), ("id", "ID", 150), ("type", "Type", 120), ("cells", "Cells", 56)]

    /// Called with a row that the map offers, when a person double clicks it or presses Return.
    public var onPick: ((RNASeqGeneIndex.Entry) -> Void)?
    public private(set) var results: [RNASeqGeneIndex.Entry] = []
    /// The latest search, which a test can wait on.
    public private(set) var searchWork: Task<Void, Never>?
    public let searchField = NSSearchField()
    public let status = NSTextField(wrappingLabelWithString: RNASeqEmbeddingWords.genePickerReading)
    private let table = NSTableView()
    private var index: RNASeqGeneIndex?
    private var query = ""
    private var generation = 0

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 340))
        root.setAccessibilityIdentifier(Self.accessibilityID)
        searchField.placeholderString = "Gene name or id"
        searchField.setAccessibilityIdentifier("rnaseq-cell-map-gene-picker-search")
        searchField.delegate = self
        for column in Self.columns {
            let made = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            made.title = column.title
            made.width = column.width
            table.addTableColumn(made)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.setAccessibilityIdentifier("rnaseq-cell-map-gene-picker-results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        status.isSelectable = true
        status.setAccessibilityIdentifier("rnaseq-cell-map-gene-picker-status")
        for view in [searchField, scroll, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        preferredContentSize = root.frame.size
        view = root
    }

    /// The search field takes the keyboard when the popover appears, so a person types a name at once.
    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    /// Gives the picker the features once they are read, and runs a search made before that.
    public func show(index: RNASeqGeneIndex) {
        self.index = index
        if query.isEmpty { setStatus(RNASeqEmbeddingWords.genePickerPrompt) } else { search(query) }
    }

    /// Shows why the features could not be read.
    public func showFailure(_ words: String) {
        index = nil
        results = []
        table.reloadData()
        setStatus(words)
    }

    /// Lists the matches of `text` off the main actor. A newer search cancels this one, so the rows shown are the newest's.
    public func search(_ text: String) {
        query = text
        searchWork?.cancel()
        generation += 1
        guard let index else { return }
        let mine = generation
        let limit = Self.limit
        searchWork = Task { [weak self] in
            guard let found = try? await offMain({ try index.search(text, limit: limit) }), let self, mine == self.generation,
                  !Task.isCancelled else { return }
            self.results = found
            self.table.reloadData()
            self.setStatus(found.isEmpty ? (text.trimmingCharacters(in: .whitespaces).isEmpty ? RNASeqEmbeddingWords.genePickerPrompt
                                                                                                  : RNASeqEmbeddingWords.genePickerNone(text))
                           : Self.note(for: found))
        }
    }

    /// Hands a row that the map offers to `onPick`. A feature of another type is not offered, so it does nothing.
    public func pick(_ entry: RNASeqGeneIndex.Entry) {
        guard entry.offered else { return }
        onPick?(entry)
    }

    private static func note(for found: [RNASeqGeneIndex.Entry]) -> String {
        if found.count >= limit { return RNASeqEmbeddingWords.genePickerLimit(limit) }
        if let other = found.first(where: { !$0.offered }) { return RNASeqEmbeddingWords.genePickerNotOffered(other.type) }
        return ""
    }

    private func setStatus(_ words: String) { status.stringValue = words }

    @objc private func rowDoubleClicked() {
        if results.indices.contains(table.clickedRow) { pick(results[table.clickedRow]) }
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { results.indices.contains(row) && results[row].offered }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let entry = results[row]
        let text: String
        switch column {
        case "name": text = entry.name.isEmpty ? entry.id : entry.name
        case "id": text = entry.id
        case "type": text = entry.type
        default: text = String(entry.cells)
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.textColor = entry.offered ? .labelColor : .tertiaryLabelColor
        field.setAccessibilityIdentifier("rnaseq-cell-map-gene-picker-\(column)-\(row)")
        return field
    }

    // MARK: - Search field

    public func controlTextDidChange(_ notification: Notification) { search(searchField.stringValue) }

    /// Return picks the selected row, or the first row that the map offers.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let chosen = results.indices.contains(table.selectedRow) ? results[table.selectedRow] : results.first { $0.offered }
        if let chosen { pick(chosen) }
        return true
    }
}
