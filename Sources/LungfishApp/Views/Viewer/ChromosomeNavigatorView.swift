// ChromosomeNavigatorView.swift - Chromosome list navigator for reference bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import os.log

/// Logger for chromosome navigator operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "ChromosomeNavigator")

// MARK: - Chromosome Sort Utilities

/// Sort mode for the chromosome list.
enum ChromosomeSortMode: Int {
    case natural = 0
    case alphabetical = 1
    case bySize = 2
}

/// Returns a comparable sort key for a chromosome name.
///
/// Natural karyotype order: chr1..chr22, chrX, chrY, chrW, chrZ, chrM/MT, then others alphabetically.
private func chromosomeSortKey(_ name: String) -> (Int, Int, String) {
    var stripped = name
    for prefix in ["chromosome", "Chromosome", "CHROMOSOME", "chr", "Chr", "CHR"] {
        if stripped.hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
            break
        }
    }
    // Strip leading underscores/hyphens from scaffold-style names
    stripped = stripped.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))

    if let num = Int(stripped) {
        return (0, num, "")
    }

    switch stripped.uppercased() {
    case "X": return (1, 0, "")
    case "Y": return (1, 1, "")
    case "W": return (1, 2, "")
    case "Z": return (1, 3, "")
    case "M", "MT": return (2, 0, "")
    default: return (3, 0, name)
    }
}

/// Sorts chromosomes in natural karyotype order.
func naturalChromosomeSort(_ chromosomes: [ChromosomeInfo]) -> [ChromosomeInfo] {
    chromosomes.sorted { chromosomeSortKey($0.name) < chromosomeSortKey($1.name) }
}

// MARK: - ChromosomeNavigatorDelegate

/// Delegate protocol for chromosome selection events.
@MainActor
protocol ChromosomeNavigatorDelegate: AnyObject {
    func chromosomeNavigator(_ navigator: ChromosomeNavigatorView, didSelectChromosome chromosome: ChromosomeInfo)
}

// MARK: - ChromosomeNavigatorView

/// A drawer panel that displays a sortable, filterable list of chromosomes.
///
/// The navigator shows each chromosome's name and formatted length in an `NSTableView`.
/// Includes a sort popup (natural/alphabetical/by-size) and a filter search field.
///
/// Every command the row's context menu offers is also a cell accessibility
/// action and, for the selected row, a Selection > Table Row menu item
/// (``ResultRowMenuActions``), so keyboards, VoiceOver and AX automation can
/// drive the list without a mouse. Return or Enter navigates like a
/// double-click, and the sort pop-up mirrors its items as actions.
@MainActor
public class ChromosomeNavigatorView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, ResultRowMenuActions {

    // MARK: - Properties

    weak var delegate: ChromosomeNavigatorDelegate?

    /// Invoked with every selected chromosome when the user asks to extract
    /// them to a new bundle. A `nil` handler omits the menu item entirely,
    /// and the row cell actions, which are installed from the cell callback,
    /// follow it on the next reload.
    public var onExtractSelectedSequencesRequested: (([ChromosomeInfo]) -> Void)? {
        didSet { tableView.reloadData() }
    }

    /// Overrides `tableView.clickedRow` in tests, where there is no real click.
    private var testingClickedRow: Int?

    /// When true, `tableViewSelectionDidChange` will not call the delegate.
    /// Used by `selectChromosome(named:)` to update the table selection
    /// without triggering a full navigation (which would reset the reference frame).
    private var isSuppressingDelegateCallbacks = false

    /// The full (unfiltered, unsorted) chromosome list.
    private var allChromosomes: [ChromosomeInfo] = []

    /// The displayed (sorted and filtered) chromosome list that drives the table view.
    private(set) var displayedChromosomes: [ChromosomeInfo] = []

    /// Sets the chromosome list, applying current sort and filter.
    var chromosomes: [ChromosomeInfo] {
        get { allChromosomes }
        set {
            allChromosomes = newValue
            updateDisplayedChromosomes()
            logger.debug("ChromosomeNavigatorView: Loaded \(self.allChromosomes.count) chromosomes")
        }
    }

    /// Current sort mode.
    var sortMode: ChromosomeSortMode = .natural {
        didSet { updateDisplayedChromosomes() }
    }

    /// Current filter text (empty = no filter).
    private var filterText: String = ""

    /// Index of the currently selected chromosome (in displayedChromosomes).
    var selectedChromosomeIndex: Int = 0 {
        didSet {
            guard selectedChromosomeIndex >= 0,
                  selectedChromosomeIndex < displayedChromosomes.count else { return }
            isSuppressingDelegateCallbacks = true
            defer { isSuppressingDelegateCallbacks = false }
            tableView.selectRowIndexes(IndexSet(integer: selectedChromosomeIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedChromosomeIndex)
        }
    }

    // MARK: - UI Components

    private let scrollView = NSScrollView()
    private let tableView = RowActivatingTableView()
    private let headerLabel = NSTextField(labelWithString: "Chromosomes")
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let filterField = NSSearchField()

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("ChromosomeCell")
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("ChromosomeColumn")

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    // MARK: - Setup

    private func setupView() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Header label
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(headerLabel)

        // Sort popup
        sortPopup.addItems(withTitles: ["Natural", "A-Z", "Size"])
        LungfishKitControlStyle.applyInspectorMetrics(to: sortPopup)
        sortPopup.translatesAutoresizingMaskIntoConstraints = false
        sortPopup.target = self
        sortPopup.action = #selector(sortModeChanged(_:))
        sortPopup.setAccessibilityLabel("Sort chromosomes")
        AccessibilityMenuMirror.install(on: sortPopup)
        addSubview(sortPopup)

        // Filter search field
        filterField.placeholderString = "Filter"
        LungfishKitControlStyle.applyInspectorMetrics(to: filterField)
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterFieldChanged(_:))
        filterField.setAccessibilityLabel("Filter chromosomes")
        addSubview(filterField)

        // Configure table view
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.title = "Chromosome"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 36
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .sourceList
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))
        tableView.onActivateSelectedRow = { [weak self] in
            guard let self else { return }
            self.activate(row: self.tableView.selectedRow)
        }

        // Context menu for right-click actions
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu

        // Configure scroll view
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = true
        addSubview(scrollView)

        // Right-edge separator (matches inspector thin divider style)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Layout: header + sort on same row, filter below, table fills rest
        NSLayoutConstraint.activate([
            // Separator on right edge
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            sortPopup.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            sortPopup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sortPopup.leadingAnchor.constraint(greaterThanOrEqualTo: headerLabel.trailingAnchor, constant: 4),

            filterField.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filterField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Accessibility
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Chromosome navigator")
        setAccessibilityIdentifier("chromosome-navigator")

        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityRole(.table)
        tableView.setAccessibilityLabel("Chromosome list")

        logger.info("ChromosomeNavigatorView: Setup complete")
    }

    // MARK: - Sort / Filter

    private func updateDisplayedChromosomes() {
        // 1. Filter
        var result = allChromosomes
        if !filterText.isEmpty {
            let lowered = filterText.lowercased()
            result = result.filter { chrom in
                chrom.name.lowercased().contains(lowered)
                || chrom.aliases.contains(where: { $0.lowercased().contains(lowered) })
            }
        }

        // 2. Sort
        switch sortMode {
        case .natural:
            result = naturalChromosomeSort(result)
        case .alphabetical:
            result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .bySize:
            result.sort { $0.length > $1.length }
        }

        displayedChromosomes = result
        tableView.reloadData()
    }

    @objc private func sortModeChanged(_ sender: NSPopUpButton) {
        sortMode = ChromosomeSortMode(rawValue: sender.indexOfSelectedItem) ?? .natural
        logger.debug("ChromosomeNavigatorView: Sort mode changed to \(sender.indexOfSelectedItem)")
    }

    @objc private func filterFieldChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue
        updateDisplayedChromosomes()
        logger.debug("ChromosomeNavigatorView: Filter text: '\(self.filterText, privacy: .public)'")
    }

    // MARK: - Actions

    @objc private func tableViewDoubleClicked(_ sender: Any) {
        activate(row: tableView.clickedRow)
    }

    /// Navigates to the chromosome at `row`, what a double-click, Return and
    /// the row's Navigate to Chromosome action all do.
    private func activate(row: Int) {
        guard row >= 0, row < displayedChromosomes.count else { return }

        let chromosome = displayedChromosomes[row]
        logger.info("ChromosomeNavigatorView: Activated chromosome '\(chromosome.name, privacy: .public)'")
        delegate?.chromosomeNavigator(self, didSelectChromosome: chromosome)
    }

    // MARK: - Context Menu Actions

    /// Copies the chromosome name to the pasteboard.
    @objc private func copyChromosomeName(_ sender: NSMenuItem?) {
        guard let chromosome = sender?.representedObject as? ChromosomeInfo else { return }
        copyName(of: chromosome)
    }

    private func copyName(of chromosome: ChromosomeInfo) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(chromosome.name, forType: .string)
        logger.info("ChromosomeNavigatorView: Copied chromosome name '\(chromosome.name, privacy: .public)' to clipboard")
    }

    /// Copies the chromosome length as a formatted string to the pasteboard.
    @objc private func copyChromosomeLength(_ sender: NSMenuItem?) {
        guard let chromosome = sender?.representedObject as? ChromosomeInfo else { return }
        copyLength(of: chromosome)
    }

    private func copyLength(of chromosome: ChromosomeInfo) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(chromosome.length)", forType: .string)
        logger.info("ChromosomeNavigatorView: Copied chromosome length \(chromosome.length) to clipboard")
    }

    /// Posts a notification to show the chromosome details in the inspector.
    @objc private func showChromosomeInInspector(_ sender: NSMenuItem?) {
        guard let chromosome = sender?.representedObject as? ChromosomeInfo else { return }
        showInInspector(chromosome)
    }

    private func showInInspector(_ chromosome: ChromosomeInfo) {
        NotificationCenter.default.post(
            name: .chromosomeInspectorRequested,
            object: self,
            userInfo: [
                NotificationUserInfoKey.chromosome: chromosome,
                NotificationUserInfoKey.switchInspectorTab: true,
            ]
        )
        logger.info("ChromosomeNavigatorView: Show in Inspector requested for '\(chromosome.name, privacy: .public)'")
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        displayedChromosomes.count
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedChromosomes.count else { return nil }

        let chromosome = displayedChromosomes[row]

        let cellView: ChromosomeCellView
        if let existing = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? ChromosomeCellView {
            cellView = existing
        } else {
            cellView = ChromosomeCellView()
            cellView.identifier = Self.cellIdentifier
        }

        cellView.configure(with: chromosome)
        AccessibilityCellActions.install(accessibilityActions(for: cellView), on: cellView)
        return cellView
    }

    // MARK: - Accessibility cell actions

    /// The commands every cell of a row publishes to AX clients: Navigate to
    /// Chromosome, then the context menu's commands in menu order. Handlers
    /// resolve the row when they run, because cell views are recycled as the
    /// list scrolls and re-sorts.
    private func accessibilityActions(for cellView: NSView) -> [NSAccessibilityCustomAction] {
        func action(_ name: String, _ body: @escaping @MainActor (ChromosomeNavigatorView, Int, ChromosomeInfo) -> Void) -> NSAccessibilityCustomAction {
            AccessibilityCellActions.makeAction(name: name) { [weak self, weak cellView] in
                guard let self, let cellView,
                      let row = AccessibilityCellActions.currentRow(of: cellView),
                      row < self.displayedChromosomes.count else { return }
                body(self, row, self.displayedChromosomes[row])
            }
        }
        var actions = [action("Navigate to Chromosome") { navigator, row, _ in navigator.activate(row: row) }]
        if onExtractSelectedSequencesRequested != nil {
            actions.append(action("Extract to New Bundle\u{2026}") { navigator, row, _ in
                navigator.targetSelection(toRow: row)
                navigator.extractSelectedChromosomes(nil)
            })
        }
        actions.append(action("Copy Name") { navigator, _, chromosome in navigator.copyName(of: chromosome) })
        actions.append(action("Copy Length") { navigator, _, chromosome in navigator.copyLength(of: chromosome) })
        actions.append(action("Show in Inspector") { navigator, _, chromosome in navigator.showInInspector(chromosome) })
        return actions
    }

    /// Makes `row` the whole selection unless it is already part of it, the
    /// same reconciliation a right-click outside the selection performs.
    private func targetSelection(toRow row: Int) {
        guard !tableView.selectedRowIndexes.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - Selection > Table Row (ResultRowMenuActions)

    private var singleSelectedChromosome: ChromosomeInfo? {
        let selected = selectedChromosomes()
        return selected.count == 1 ? selected[0] : nil
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(activateSelectedRow(_:)), #selector(copySelectedRowName(_:)), #selector(showSelectedRowInInspector(_:)):
            return singleSelectedChromosome != nil
        case #selector(extractSelectedRowsToNewBundle(_:)):
            return onExtractSelectedSequencesRequested != nil && !selectedChromosomes().isEmpty
        default:
            return true
        }
    }

    @objc public func activateSelectedRow(_ sender: Any?) {
        activate(row: tableView.selectedRow)
    }

    @objc public func copySelectedRowName(_ sender: Any?) {
        guard let chromosome = singleSelectedChromosome else { return }
        copyName(of: chromosome)
    }

    @objc public func showSelectedRowInInspector(_ sender: Any?) {
        guard let chromosome = singleSelectedChromosome else { return }
        showInInspector(chromosome)
    }

    @objc public func extractSelectedRowsToNewBundle(_ sender: Any?) {
        extractSelectedChromosomes(sender)
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        36
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < displayedChromosomes.count else { return }

        // Shift- or command-click extends the selection. Navigating on every
        // such change would fire the primary action repeatedly and jump the
        // viewport somewhere the user did not click.
        guard tableView.selectedRowIndexes.count == 1 else { return }

        selectedChromosomeIndex = row
        let chromosome = displayedChromosomes[row]

        // When selection was set programmatically (e.g. navigateToChromosomeAndPosition),
        // do NOT call the delegate — the caller already set the reference frame and
        // the delegate would overwrite it with a full-chromosome view.
        if isSuppressingDelegateCallbacks {
            logger.info("ChromosomeNavigatorView: Programmatic selection of '\(chromosome.name, privacy: .public)' at index \(row) — delegate suppressed")
            return
        }

        logger.info("ChromosomeNavigatorView: User selected chromosome '\(chromosome.name, privacy: .public)' at index \(row)")
        delegate?.chromosomeNavigator(self, didSelectChromosome: chromosome)
    }

    // MARK: - Public API

    /// Selects a chromosome by name, scrolling it into view.
    ///
    /// This is a **programmatic** selection — the delegate callback is suppressed
    /// so the caller's reference frame is not overwritten.
    @discardableResult
    func selectChromosome(named name: String) -> Bool {
        guard let index = displayedChromosomes.firstIndex(where: { $0.name == name }) else {
            logger.debug("ChromosomeNavigatorView: Chromosome '\(name, privacy: .public)' not found")
            return false
        }
        // Suppress the delegate so tableViewSelectionDidChange doesn't reset the frame
        isSuppressingDelegateCallbacks = true
        defer { isSuppressingDelegateCallbacks = false }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        logger.info("ChromosomeNavigatorView: Programmatically selected '\(name, privacy: .public)' at index \(index)")
        return true
    }
}

// MARK: - NSMenuDelegate

extension ChromosomeNavigatorView: NSMenuDelegate {

    /// Builds the context menu dynamically based on the clicked row.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = testingClickedRow ?? tableView.clickedRow
        guard clickedRow >= 0, clickedRow < displayedChromosomes.count else {
            // Right-clicked on empty space - no menu items
            return
        }

        // Right-clicking outside the current selection targets that row alone,
        // matching FASTACollectionViewController's reconciliation.
        targetSelection(toRow: clickedRow)

        let selected = selectedChromosomes()

        if onExtractSelectedSequencesRequested != nil {
            let extractItem = NSMenuItem(
                title: "Extract to New Bundle\u{2026}",
                action: #selector(extractSelectedChromosomes(_:)),
                keyEquivalent: ""
            )
            extractItem.target = self
            extractItem.isEnabled = !selected.isEmpty
            menu.addItem(extractItem)
            menu.addItem(.separator())
        }

        let chromosome = displayedChromosomes[clickedRow]

        // Copy Name
        let copyNameItem = NSMenuItem(title: "Copy Name", action: #selector(copyChromosomeName(_:)), keyEquivalent: "")
        copyNameItem.target = self
        copyNameItem.representedObject = chromosome
        menu.addItem(copyNameItem)

        // Copy Length
        let copyLengthItem = NSMenuItem(title: "Copy Length", action: #selector(copyChromosomeLength(_:)), keyEquivalent: "")
        copyLengthItem.target = self
        copyLengthItem.representedObject = chromosome
        menu.addItem(copyLengthItem)

        menu.addItem(NSMenuItem.separator())

        // Show in Inspector — inspects a single chromosome, so it is disabled
        // for a multi-row selection.
        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showChromosomeInInspector(_:)), keyEquivalent: "")
        inspectorItem.target = self
        inspectorItem.representedObject = chromosome
        inspectorItem.isEnabled = selected.count <= 1
        menu.addItem(inspectorItem)
    }

    private func selectedChromosomes() -> [ChromosomeInfo] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < displayedChromosomes.count else { return nil }
            return displayedChromosomes[row]
        }
    }

    @objc private func extractSelectedChromosomes(_ sender: Any?) {
        let selected = selectedChromosomes()
        guard !selected.isEmpty else { return }
        onExtractSelectedSequencesRequested?(selected)
    }

    // MARK: - Test seams

    func testingSelectRows(_ rows: [Int]) {
        tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    var testingTableView: NSTableView { tableView }

    var testingSortPopUp: NSPopUpButton { sortPopup }

    func testingBuildContextMenu(_ menu: NSMenu, clickedRow: Int) {
        testingClickedRow = clickedRow
        defer { testingClickedRow = nil }
        menuNeedsUpdate(menu)
    }

    var testingSelectedChromosomeNames: [String] { selectedChromosomes().map(\.name) }

    func testingContextMenuTitles(clickedRow: Int) -> [String] {
        let menu = NSMenu()
        testingClickedRow = clickedRow
        defer { testingClickedRow = nil }
        menuNeedsUpdate(menu)
        return menu.items.map(\.title)
    }

    func testingInvokeContextMenuItem(titled title: String, clickedRow: Int) {
        let menu = NSMenu()
        testingClickedRow = clickedRow
        defer { testingClickedRow = nil }
        menuNeedsUpdate(menu)
        guard let item = menu.items.first(where: { $0.title == title }),
              let action = item.action else { return }
        _ = perform(action, with: item)
    }
}

// MARK: - ChromosomeCellView

/// Custom cell view for a chromosome row in the navigator.
private class ChromosomeCellView: NSTableCellView {

    private let nameLabel = NSTextField(labelWithString: "")
    private let lengthLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCell()
    }

    private func setupCell() {
        nameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        lengthLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        lengthLabel.textColor = .secondaryLabelColor
        lengthLabel.alignment = .left
        lengthLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lengthLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            lengthLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            lengthLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            lengthLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    func configure(with chromosome: ChromosomeInfo) {
        nameLabel.stringValue = chromosome.name

        // Show length, with aliases appended in a lighter font
        let lengthStr = Self.formatLength(chromosome.length)
        if !chromosome.aliases.isEmpty {
            let aliasStr = chromosome.aliases.joined(separator: ", ")
            let attributed = NSMutableAttributedString(
                string: lengthStr,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            attributed.append(NSAttributedString(
                string: "  \(aliasStr)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            ))
            lengthLabel.attributedStringValue = attributed
        } else {
            lengthLabel.stringValue = lengthStr
        }

        setAccessibilityLabel("\(chromosome.name), \(lengthStr)")

        // Build tooltip with full chromosome info
        var tip = "\(chromosome.name)\n\(lengthStr)"
        if let desc = chromosome.fastaDescription, !desc.isEmpty {
            tip += "\n\(desc)"
        }
        if !chromosome.aliases.isEmpty {
            tip += "\nAliases: \(chromosome.aliases.joined(separator: ", "))"
        }
        self.toolTip = tip
    }

    static func formatLength(_ length: Int64) -> String {
        switch length {
        case 0..<1_000:
            return "\(length) bp"
        case 1_000..<1_000_000:
            return String(format: "%.1f Kb", Double(length) / 1_000.0)
        case 1_000_000..<1_000_000_000:
            return String(format: "%.1f Mb", Double(length) / 1_000_000.0)
        default:
            return String(format: "%.2f Gb", Double(length) / 1_000_000_000.0)
        }
    }
}
