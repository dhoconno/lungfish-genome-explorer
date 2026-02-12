// AnnotationTableDrawerView.swift - Geneious-style bottom annotation drawer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

/// Logger for annotation drawer operations
private let drawerLogger = Logger(subsystem: "com.lungfish.browser", category: "AnnotationDrawer")

// MARK: - AnnotationTableDrawerDelegate

/// Delegate protocol for annotation table selection events.
@MainActor
protocol AnnotationTableDrawerDelegate: AnyObject {
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didSelectAnnotation result: AnnotationSearchIndex.SearchResult)
}

// MARK: - AnnotationTableDrawerView

/// A bottom drawer panel that displays a sortable, filterable table of annotations.
///
/// Modeled after Geneious's annotation table panel. Shows all annotations loaded from
/// the search index with columns for Name, Type, Chromosome, Start, End, and Size.
/// Supports filtering by name (text field) and type (chip toggle buttons).
@MainActor
public class AnnotationTableDrawerView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Properties

    weak var delegate: AnnotationTableDrawerDelegate?

    /// Reference to the search index for direct SQL queries.
    private var searchIndex: AnnotationSearchIndex?

    /// Total annotation count in the database.
    private var totalAnnotationCount: Int = 0

    /// Filtered and displayed annotations.
    private(set) var displayedAnnotations: [AnnotationSearchIndex.SearchResult] = []

    /// Current name filter text.
    private var filterText: String = ""

    /// Visible annotation types (empty means show all).
    private var visibleTypes: Set<String> = []

    /// All distinct annotation types found in the data.
    private var availableTypes: [String] = []

    /// Whether the index is currently loading.
    private(set) var isLoading: Bool = true {
        didSet { updateLoadingState() }
    }

    // MARK: - UI Components

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let filterField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let headerBar = NSView()
    private let chipBar = NSView()
    private let chipScrollView = NSScrollView()
    private let chipStackView = NSStackView()
    private let dragHandle = NSView()
    private let loadingIndicator = NSProgressIndicator()
    private let tooManyLabel = NSTextField(wrappingLabelWithString: "")

    /// Maximum number of annotations to display in the table.
    /// Beyond this, user must filter to narrow down results.
    private static let maxDisplayCount = 5_000

    /// Chip buttons keyed by type name.
    private var chipButtons: [String: NSButton] = [:]

    // Column identifiers
    private static let nameColumn = NSUserInterfaceItemIdentifier("NameColumn")
    private static let typeColumn = NSUserInterfaceItemIdentifier("TypeColumn")
    private static let chromosomeColumn = NSUserInterfaceItemIdentifier("ChromosomeColumn")
    private static let startColumn = NSUserInterfaceItemIdentifier("StartColumn")
    private static let endColumn = NSUserInterfaceItemIdentifier("EndColumn")
    private static let sizeColumn = NSUserInterfaceItemIdentifier("SizeColumn")
    private static let strandColumn = NSUserInterfaceItemIdentifier("StrandColumn")

    /// Number formatter for genomic coordinates.
    private let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

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
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Drag handle bar at top (visual divider)
        dragHandle.wantsLayer = true
        dragHandle.layer?.backgroundColor = NSColor.separatorColor.cgColor
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragHandle)

        // Header bar with filter controls (row 1)
        headerBar.wantsLayer = true
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBar)

        // Filter search field
        filterField.placeholderString = "Filter annotations & variants..."
        filterField.font = .systemFont(ofSize: 11)
        filterField.controlSize = .small
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterFieldChanged(_:))
        filterField.setAccessibilityLabel("Filter annotations by name")
        headerBar.addSubview(filterField)

        // "All" convenience button
        let allButton = makeChipButton(title: "All", action: #selector(selectAllTypes(_:)))
        allButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(allButton)

        // "None" convenience button
        let noneButton = makeChipButton(title: "None", action: #selector(selectNoTypes(_:)))
        noneButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(noneButton)

        // Count label
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        headerBar.addSubview(countLabel)

        // Loading indicator
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.startAnimation(nil)
        headerBar.addSubview(loadingIndicator)

        // Chip bar (row 2) — horizontal scrolling row of type toggle chips
        chipBar.wantsLayer = true
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipBar)

        chipScrollView.translatesAutoresizingMaskIntoConstraints = false
        chipScrollView.hasHorizontalScroller = false
        chipScrollView.hasVerticalScroller = false
        chipScrollView.drawsBackground = false
        chipBar.addSubview(chipScrollView)

        chipStackView.orientation = .horizontal
        chipStackView.spacing = 4
        chipStackView.alignment = .centerY
        chipStackView.translatesAutoresizingMaskIntoConstraints = false
        chipScrollView.documentView = chipStackView

        // Configure table columns
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat)] = [
            (Self.nameColumn, "Name", 180, 80),
            (Self.typeColumn, "Type", 80, 50),
            (Self.chromosomeColumn, "Chromosome", 120, 60),
            (Self.startColumn, "Start", 100, 60),
            (Self.endColumn, "End", 100, 60),
            (Self.sizeColumn, "Size", 80, 50),
            (Self.strandColumn, "Strand", 50, 30),
        ]

        for (identifier, title, width, minWidth) in columns {
            let col = NSTableColumn(identifier: identifier)
            col.title = title
            col.width = width
            col.minWidth = minWidth
            col.resizingMask = .autoresizingMask

            let sortKey: String
            switch identifier {
            case Self.nameColumn: sortKey = "name"
            case Self.typeColumn: sortKey = "type"
            case Self.chromosomeColumn: sortKey = "chromosome"
            case Self.startColumn: sortKey = "start"
            case Self.endColumn: sortKey = "end"
            case Self.sizeColumn: sortKey = "size"
            case Self.strandColumn: sortKey = "strand"
            default: sortKey = "name"
            }
            col.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))

            tableView.addTableColumn(col)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.style = .plain
        tableView.gridStyleMask = .solidVerticalGridLineMask
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))

        // Context menu (built dynamically via NSMenuDelegate)
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // "Too many results" overlay label
        tooManyLabel.alignment = .center
        tooManyLabel.font = .systemFont(ofSize: 12)
        tooManyLabel.textColor = .secondaryLabelColor
        tooManyLabel.isHidden = true
        tooManyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tooManyLabel)

        // Layout
        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: topAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: 1),

            headerBar.topAnchor.constraint(equalTo: dragHandle.bottomAnchor),
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 28),

            filterField.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            filterField.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 8),
            filterField.widthAnchor.constraint(equalToConstant: 200),

            allButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            allButton.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 8),

            noneButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            noneButton.leadingAnchor.constraint(equalTo: allButton.trailingAnchor, constant: 4),

            loadingIndicator.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            loadingIndicator.leadingAnchor.constraint(equalTo: noneButton.trailingAnchor, constant: 8),

            countLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),

            chipBar.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            chipBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            chipBar.heightAnchor.constraint(equalToConstant: 26),

            chipScrollView.topAnchor.constraint(equalTo: chipBar.topAnchor),
            chipScrollView.leadingAnchor.constraint(equalTo: chipBar.leadingAnchor, constant: 8),
            chipScrollView.trailingAnchor.constraint(equalTo: chipBar.trailingAnchor, constant: -8),
            chipScrollView.bottomAnchor.constraint(equalTo: chipBar.bottomAnchor),

            chipStackView.topAnchor.constraint(equalTo: chipScrollView.topAnchor),
            chipStackView.leadingAnchor.constraint(equalTo: chipScrollView.leadingAnchor),
            chipStackView.bottomAnchor.constraint(equalTo: chipScrollView.bottomAnchor),
            // No trailing constraint — let stack view expand beyond scroll view for horizontal scrolling

            scrollView.topAnchor.constraint(equalTo: chipBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tooManyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            tooManyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            tooManyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            tooManyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
        ])

        // Hide chip bar initially (shown after data loads)
        chipBar.isHidden = true

        // Accessibility
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Annotation table drawer")
        setAccessibilityIdentifier("annotation-table-drawer")

        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityRole(.table)
        tableView.setAccessibilityLabel("Annotation table")

        updateCountLabel()
        drawerLogger.info("AnnotationTableDrawerView: Setup complete")
    }

    // MARK: - Chip Button Factory

    private func makeChipButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.controlSize = .small
        button.bezelStyle = .recessed
        button.isBordered = true
        button.setButtonType(.momentaryPushIn)
        return button
    }

    private func makeTypeChipButton(type: String) -> NSButton {
        let button = NSButton(title: type, target: self, action: #selector(typeChipToggled(_:)))
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.controlSize = .small
        button.bezelStyle = .recessed
        button.isBordered = true
        button.setButtonType(.pushOnPushOff)
        button.state = .on  // All types visible by default
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel("Toggle \(type) annotations")
        return button
    }

    // MARK: - Data Loading

    /// Connects the drawer to a search index for direct SQL queries.
    /// Does NOT load all annotations into memory — queries the database on demand.
    func setSearchIndex(_ index: AnnotationSearchIndex) {
        searchIndex = index
        isLoading = false

        // Get metadata from the index (types, total count) — instant for SQLite
        // Includes variant types and counts if variant database is available
        totalAnnotationCount = index.entryCount + index.variantCount
        availableTypes = index.allTypes

        // All types visible by default
        visibleTypes = Set(availableTypes)

        // Rebuild chip buttons
        rebuildChipButtons()

        // Query for initial display
        updateDisplayedAnnotations()
        drawerLogger.info("AnnotationTableDrawerView: Connected to index with \(self.totalAnnotationCount) annotations+variants, \(self.availableTypes.count) types")
    }

    /// Legacy entry point for when no search index is available (fallback).
    func setAnnotations(_ results: [AnnotationSearchIndex.SearchResult]) {
        searchIndex = nil
        isLoading = false
        totalAnnotationCount = results.count

        let typeSet = Set(results.map { $0.type })
        availableTypes = typeSet.sorted()
        visibleTypes = typeSet

        rebuildChipButtons()

        // For legacy mode, set results directly (capped at maxDisplayCount)
        if results.count > Self.maxDisplayCount {
            displayedAnnotations = []
            tableView.reloadData()
            scrollView.isHidden = true
            let total = numberFormatter.string(from: NSNumber(value: results.count)) ?? "\(results.count)"
            let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
            tooManyLabel.stringValue = "\(total) annotations match — use the search field or type filters to narrow to \(max) or fewer"
            tooManyLabel.isHidden = false
        } else {
            displayedAnnotations = results
            tableView.reloadData()
            scrollView.isHidden = false
            tooManyLabel.isHidden = true
        }
        updateCountLabel()
        drawerLogger.info("AnnotationTableDrawerView: Loaded \(results.count) annotations (legacy mode)")
    }

    // MARK: - Chip Management

    private func rebuildChipButtons() {
        // Remove existing chip buttons
        for view in chipStackView.arrangedSubviews {
            chipStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chipButtons.removeAll()

        // Create a chip for each type
        for type in availableTypes {
            let chip = makeTypeChipButton(type: type)
            chip.state = visibleTypes.contains(type) ? .on : .off
            chipStackView.addArrangedSubview(chip)
            chipButtons[type] = chip
        }

        // Show chip bar if we have types
        chipBar.isHidden = availableTypes.isEmpty
    }

    private func updateChipStates() {
        for (type, button) in chipButtons {
            button.state = visibleTypes.contains(type) ? .on : .off
        }
    }

    // MARK: - Filtering

    private func updateDisplayedAnnotations() {
        // Build the type filter set — only pass types if not all are selected
        let typeFilter: Set<String> = visibleTypes.count < availableTypes.count ? visibleTypes : []

        // SQLite mode: query the database directly with filters
        if let index = searchIndex, index.hasDatabaseBackend {
            // Get the matching count first (fast COUNT query)
            let matchingCount = index.queryCount(nameFilter: filterText, types: typeFilter) ?? 0

            if matchingCount > Self.maxDisplayCount {
                displayedAnnotations = []
                tableView.reloadData()
                scrollView.isHidden = true
                let total = numberFormatter.string(from: NSNumber(value: matchingCount)) ?? "\(matchingCount)"
                let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                tooManyLabel.stringValue = "\(total) annotations match — use the search field or type filters to narrow to \(max) or fewer"
                tooManyLabel.isHidden = false
            } else {
                // Use queryAll to include both annotations and variants
                let results = index.queryAll(nameFilter: filterText, types: typeFilter, limit: Self.maxDisplayCount)
                displayedAnnotations = results
                tableView.reloadData()
                scrollView.isHidden = false
                tooManyLabel.isHidden = true
            }
            updateCountLabel()
            return
        }

        // Legacy in-memory mode: filter allResults from the search index
        if let index = searchIndex {
            let hasFilters = !typeFilter.isEmpty || !filterText.isEmpty

            // Fast path: if no filters and total count exceeds limit, skip loading all entries
            if !hasFilters && index.entryCount > Self.maxDisplayCount {
                displayedAnnotations = []
                tableView.reloadData()
                scrollView.isHidden = true
                let total = numberFormatter.string(from: NSNumber(value: index.entryCount)) ?? "\(index.entryCount)"
                let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                tooManyLabel.stringValue = "\(total) annotations — use the search field or type filters to narrow to \(max) or fewer"
                tooManyLabel.isHidden = false
            } else {
                var results = index.allResults
                if !typeFilter.isEmpty {
                    results = results.filter { typeFilter.contains($0.type) }
                }
                if !filterText.isEmpty {
                    let lower = filterText.lowercased()
                    results = results.filter { $0.name.lowercased().contains(lower) }
                }
                if results.count > Self.maxDisplayCount {
                    displayedAnnotations = []
                    tableView.reloadData()
                    scrollView.isHidden = true
                    let total = numberFormatter.string(from: NSNumber(value: results.count)) ?? "\(results.count)"
                    let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                    tooManyLabel.stringValue = "\(total) annotations match — use the search field or type filters to narrow to \(max) or fewer"
                    tooManyLabel.isHidden = false
                } else {
                    displayedAnnotations = results
                    tableView.reloadData()
                    scrollView.isHidden = false
                    tooManyLabel.isHidden = true
                }
            }
        }
        updateCountLabel()
    }

    private func updateCountLabel() {
        if isLoading {
            countLabel.stringValue = "Building annotation index (scanning all chromosomes)..."
        } else if !tooManyLabel.isHidden {
            let total = numberFormatter.string(from: NSNumber(value: totalAnnotationCount)) ?? "\(totalAnnotationCount)"
            countLabel.stringValue = "\(total) total — filter to browse"
        } else if displayedAnnotations.count == totalAnnotationCount {
            countLabel.stringValue = "\(numberFormatter.string(from: NSNumber(value: totalAnnotationCount)) ?? "\(totalAnnotationCount)") annotations"
        } else {
            let shown = numberFormatter.string(from: NSNumber(value: displayedAnnotations.count)) ?? "\(displayedAnnotations.count)"
            let total = numberFormatter.string(from: NSNumber(value: totalAnnotationCount)) ?? "\(totalAnnotationCount)"
            countLabel.stringValue = "\(shown) of \(total)"
        }
    }

    private func updateLoadingState() {
        loadingIndicator.isHidden = !isLoading
        if isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
        updateCountLabel()
    }

    @objc private func filterFieldChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue
        updateDisplayedAnnotations()
    }

    @objc private func typeChipToggled(_ sender: NSButton) {
        let type = sender.title
        if sender.state == .on {
            visibleTypes.insert(type)
        } else {
            visibleTypes.remove(type)
        }
        updateDisplayedAnnotations()
    }

    @objc private func selectAllTypes(_ sender: Any) {
        visibleTypes = Set(availableTypes)
        updateChipStates()
        updateDisplayedAnnotations()
    }

    @objc private func selectNoTypes(_ sender: Any) {
        visibleTypes.removeAll()
        updateChipStates()
        updateDisplayedAnnotations()
    }

    // MARK: - Actions

    @objc private func tableViewDoubleClicked(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < displayedAnnotations.count else { return }
        let annotation = displayedAnnotations[row]
        drawerLogger.info("AnnotationTableDrawerView: Double-clicked '\(annotation.name, privacy: .public)' on \(annotation.chromosome, privacy: .public)")
        delegate?.annotationDrawer(self, didSelectAnnotation: annotation)
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        displayedAnnotations.count
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sortDescriptor = tableView.sortDescriptors.first,
              let key = sortDescriptor.key else { return }

        let ascending = sortDescriptor.ascending

        displayedAnnotations.sort { a, b in
            let result: ComparisonResult
            switch key {
            case "name":
                result = a.name.localizedCaseInsensitiveCompare(b.name)
            case "type":
                result = a.type.localizedCaseInsensitiveCompare(b.type)
            case "chromosome":
                result = a.chromosome.localizedCaseInsensitiveCompare(b.chromosome)
            case "start":
                result = a.start < b.start ? .orderedAscending : (a.start > b.start ? .orderedDescending : .orderedSame)
            case "end":
                result = a.end < b.end ? .orderedAscending : (a.end > b.end ? .orderedDescending : .orderedSame)
            case "size":
                let sizeA = a.end - a.start
                let sizeB = b.end - b.start
                result = sizeA < sizeB ? .orderedAscending : (sizeA > sizeB ? .orderedDescending : .orderedSame)
            case "strand":
                result = a.strand.compare(b.strand)
            default:
                result = .orderedSame
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        tableView.reloadData()
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedAnnotations.count, let column = tableColumn else { return nil }

        let annotation = displayedAnnotations[row]
        let identifier = column.identifier

        let cellView: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(tf)
            cellView.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let tf = cellView.textField!

        switch identifier {
        case Self.nameColumn:
            tf.stringValue = annotation.name
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        case Self.typeColumn:
            tf.stringValue = annotation.type
            tf.font = .systemFont(ofSize: 11)
        case Self.chromosomeColumn:
            tf.stringValue = annotation.chromosome
        case Self.startColumn:
            tf.stringValue = numberFormatter.string(from: NSNumber(value: annotation.start)) ?? "\(annotation.start)"
            tf.alignment = .right
        case Self.endColumn:
            tf.stringValue = numberFormatter.string(from: NSNumber(value: annotation.end)) ?? "\(annotation.end)"
            tf.alignment = .right
        case Self.sizeColumn:
            let size = annotation.end - annotation.start
            tf.stringValue = formatSize(size)
            tf.alignment = .right
        case Self.strandColumn:
            tf.stringValue = annotation.strand
            tf.alignment = .center
        default:
            tf.stringValue = ""
        }

        return cellView
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < displayedAnnotations.count else { return }
        let annotation = displayedAnnotations[row]
        drawerLogger.debug("AnnotationTableDrawerView: Selected '\(annotation.name, privacy: .public)' at row \(row)")
        delegate?.annotationDrawer(self, didSelectAnnotation: annotation)
    }

    // MARK: - Formatting

    private func formatSize(_ bp: Int) -> String {
        switch bp {
        case 0..<1_000:
            return "\(bp) bp"
        case 1_000..<1_000_000:
            return String(format: "%.1f kb", Double(bp) / 1_000.0)
        default:
            return String(format: "%.1f Mb", Double(bp) / 1_000_000.0)
        }
    }

    // MARK: - Public API

    /// Selects and scrolls to an annotation by name.
    @discardableResult
    func selectAnnotation(named name: String) -> Bool {
        guard let index = displayedAnnotations.firstIndex(where: { $0.name == name }) else {
            return false
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        return true
    }

    // MARK: - Context Menu Actions

    /// Looks up the translation string for an annotation from the SQLite database.
    func lookupTranslation(for annotation: AnnotationSearchIndex.SearchResult) -> String? {
        guard let db = searchIndex?.annotationDatabase else { return nil }
        guard let record = db.lookupAnnotation(
            name: annotation.name,
            chromosome: annotation.chromosome,
            start: annotation.start,
            end: annotation.end
        ) else { return nil }
        guard let attrs = record.attributes, !attrs.isEmpty else { return nil }
        let parsed = AnnotationDatabase.parseAttributes(attrs)
        return parsed["translation"]
    }

    @objc private func copyTranslationAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        guard let translation = lookupTranslation(for: annotation) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translation, forType: .string)
        drawerLogger.info("AnnotationTableDrawerView: Copied translation for '\(annotation.name, privacy: .public)' (\(translation.count) amino acids)")
    }

    @objc private func copyNameAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(annotation.name, forType: .string)
    }

    @objc private func copyCoordinatesAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let coords = "\(annotation.chromosome):\(annotation.start)-\(annotation.end)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(coords, forType: .string)
    }

    // MARK: - Extraction Actions

    private func makeAnnotation(from result: AnnotationSearchIndex.SearchResult) -> SequenceAnnotation {
        if let record = searchIndex?.annotationDatabase?.lookupAnnotation(
            name: result.name,
            chromosome: result.chromosome,
            start: result.start,
            end: result.end
        ) {
            return record.toAnnotation()
        }

        let type = AnnotationType.from(rawString: result.type) ?? .gene
        let strand: Strand = result.strand == "+" ? .forward : (result.strand == "-" ? .reverse : .unknown)
        return SequenceAnnotation(
            type: type,
            name: result.name,
            chromosome: result.chromosome,
            start: result.start,
            end: result.end,
            strand: strand
        )
    }

    @objc private func copyAsFASTAAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyAnnotationAsFASTARequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func copyTranslationAsFASTAAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyTranslationAsFASTARequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func extractSequenceAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .extractSequenceRequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func copySequenceAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyAnnotationSequenceRequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func copyReverseComplementAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyAnnotationReverseComplementRequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func zoomToAnnotationAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .zoomToAnnotationRequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func showInInspectorAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        // Select the annotation in the viewer first
        NotificationCenter.default.post(
            name: .annotationSelected,
            object: annotation
        )
        // Then show inspector
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "selection"]
        )
    }
}

// MARK: - NSMenuDelegate

extension AnnotationTableDrawerView: NSMenuDelegate {

    private static func supportsTranslationMenu(for type: String) -> Bool {
        let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "cds" || normalized == "mat_peptide"
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let targetRow: Int
        if tableView.clickedRow >= 0 {
            targetRow = tableView.clickedRow
        } else {
            // Keyboard-invoked context menu (or tests) may not have a clicked row.
            targetRow = tableView.selectedRow
        }
        guard targetRow >= 0, targetRow < displayedAnnotations.count else { return }

        let annotation = displayedAnnotations[targetRow]
        let isCDS = Self.supportsTranslationMenu(for: annotation.type)

        // --- Copy submenu ---
        let copyMenu = NSMenu(title: "Copy")

        let copyNameItem = NSMenuItem(title: "Copy Name", action: #selector(copyNameAction(_:)), keyEquivalent: "")
        copyNameItem.target = self
        copyNameItem.representedObject = annotation
        copyMenu.addItem(copyNameItem)

        let copyCoordsItem = NSMenuItem(title: "Copy Coordinates", action: #selector(copyCoordinatesAction(_:)), keyEquivalent: "")
        copyCoordsItem.target = self
        copyCoordsItem.representedObject = annotation
        copyMenu.addItem(copyCoordsItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copySeqItem = NSMenuItem(title: "Copy Sequence", action: #selector(copySequenceAction(_:)), keyEquivalent: "")
        copySeqItem.target = self
        copySeqItem.representedObject = annotation
        copyMenu.addItem(copySeqItem)

        let copyRevCompItem = NSMenuItem(title: "Copy Reverse Complement", action: #selector(copyReverseComplementAction(_:)), keyEquivalent: "")
        copyRevCompItem.target = self
        copyRevCompItem.representedObject = annotation
        copyMenu.addItem(copyRevCompItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copyFASTAItem = NSMenuItem(title: "Copy as FASTA", action: #selector(copyAsFASTAAction(_:)), keyEquivalent: "")
        copyFASTAItem.target = self
        copyFASTAItem.representedObject = annotation
        copyMenu.addItem(copyFASTAItem)

        if isCDS {
            let copyProteinItem = NSMenuItem(title: "Copy Translation as FASTA", action: #selector(copyTranslationAsFASTAAction(_:)), keyEquivalent: "")
            copyProteinItem.target = self
            copyProteinItem.representedObject = annotation
            copyMenu.addItem(copyProteinItem)
        }

        // Copy Translation (raw amino acids, only for CDS with stored translation)
        let translation = isCDS ? lookupTranslation(for: annotation) : nil
        if isCDS {
            copyMenu.addItem(NSMenuItem.separator())
            let copyTransItem = NSMenuItem(title: "Copy Translation", action: #selector(copyTranslationAction(_:)), keyEquivalent: "")
            copyTransItem.target = self
            copyTransItem.representedObject = annotation
            if translation == nil {
                copyTransItem.isEnabled = false
                copyTransItem.toolTip = "No translation data available for this annotation"
            }
            copyMenu.addItem(copyTransItem)
        }

        let copyMenuItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyMenuItem.submenu = copyMenu
        menu.addItem(copyMenuItem)

        // --- Extract ---
        let extractItem = NSMenuItem(title: "Extract Sequence\u{2026}", action: #selector(extractSequenceAction(_:)), keyEquivalent: "")
        extractItem.target = self
        extractItem.representedObject = annotation
        menu.addItem(extractItem)

        menu.addItem(NSMenuItem.separator())

        // --- Navigation ---
        let zoomItem = NSMenuItem(title: "Zoom to Annotation", action: #selector(zoomToAnnotationAction(_:)), keyEquivalent: "")
        zoomItem.target = self
        zoomItem.representedObject = annotation
        menu.addItem(zoomItem)

        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showInInspectorAction(_:)), keyEquivalent: "")
        inspectorItem.target = self
        inspectorItem.representedObject = annotation
        menu.addItem(inspectorItem)
    }
}
