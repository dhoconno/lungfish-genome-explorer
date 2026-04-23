import AppKit
import LungfishCore

struct BundleBrowserState: Equatable {
    var filterText: String = ""
    var selectedSequenceName: String?
    var scrollOriginY: CGFloat = 0
}

private func bundleBrowserRoleDescription(for row: BundleBrowserSequenceSummary) -> String {
    if row.isMitochondrial {
        return "Mitochondrial"
    }
    if row.isPrimary {
        return "Primary"
    }
    return "Secondary"
}

@MainActor
final class BundleBrowserSequenceTableView: BatchTableView<BundleBrowserSequenceSummary> {
    private var preferredSelectedSequenceName: String?

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: .init("contig"), title: "Contig", width: 220, minWidth: 140, defaultAscending: true),
            .init(identifier: .init("length"), title: "Length", width: 90, minWidth: 70, defaultAscending: false),
            .init(identifier: .init("kind"), title: "Role", width: 110, minWidth: 88, defaultAscending: true),
            .init(identifier: .init("aliases"), title: "Aliases", width: 150, minWidth: 100, defaultAscending: true),
            .init(identifier: .init("description"), title: "Description", width: 220, minWidth: 140, defaultAscending: true),
            .init(identifier: .init("mappedReads"), title: "Mapped Reads", width: 110, minWidth: 88, defaultAscending: false),
            .init(identifier: .init("mappedPercent"), title: "% Mapped", width: 92, minWidth: 80, defaultAscending: false),
        ]
    }

    override var searchPlaceholder: String { "Filter sequences\u{2026}" }
    override var searchAccessibilityIdentifier: String? { "bundle-browser-search" }
    override var searchAccessibilityLabel: String? { "Filter bundle sequences" }
    override var tableAccessibilityIdentifier: String? { "bundle-browser-table" }
    override var tableAccessibilityLabel: String? { "Bundle browser sequence table" }

    override var columnTypeHints: [String: Bool] {
        [
            "length": true,
            "mappedReads": true,
            "mappedPercent": true,
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
        tableView.sortDescriptors = [NSSortDescriptor(key: "contig", ascending: true)]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: BundleBrowserSequenceSummary
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "contig":
            return (row.name, .left, .systemFont(ofSize: 12))
        case "length":
            return (row.length.formatted(), .right, numericFont)
        case "kind":
            return (bundleBrowserRoleDescription(for: row), .left, .systemFont(ofSize: 12))
        case "aliases":
            return (row.aliases.isEmpty ? "—" : row.aliases.joined(separator: ", "), .left, .systemFont(ofSize: 12))
        case "description":
            return (row.displayDescription ?? "—", .left, .systemFont(ofSize: 12))
        case "mappedReads":
            return (row.metrics?.mappedReads?.formatted() ?? "—", .right, numericFont)
        case "mappedPercent":
            if let mappedPercent = row.metrics?.mappedPercent {
                return (String(format: "%.1f%%", mappedPercent), .right, numericFont)
            }
            return ("—", .right, numericFont)
        default:
            return ("", .left, nil)
        }
    }

    override func rowMatchesFilter(_ row: BundleBrowserSequenceSummary, filterText: String) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let haystack = [
            row.name,
            row.displayDescription ?? "",
            row.aliases.joined(separator: " "),
            bundleBrowserRoleDescription(for: row),
            row.length.formatted(),
        ]

        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    override func compareRows(
        _ lhs: BundleBrowserSequenceSummary,
        _ rhs: BundleBrowserSequenceSummary,
        by key: String,
        ascending: Bool
    ) -> Bool {
        let comparison: ComparisonResult
        switch key {
        case "contig":
            comparison = lhs.name.localizedStandardCompare(rhs.name)
        case "length":
            comparison = compare(lhs.length, rhs.length)
        case "kind":
            comparison = bundleBrowserRoleDescription(for: lhs).localizedCaseInsensitiveCompare(bundleBrowserRoleDescription(for: rhs))
        case "aliases":
            comparison = lhs.aliases.joined(separator: ", ").localizedCaseInsensitiveCompare(rhs.aliases.joined(separator: ", "))
        case "description":
            comparison = (lhs.displayDescription ?? "").localizedCaseInsensitiveCompare(rhs.displayDescription ?? "")
        case "mappedReads":
            comparison = compare(lhs.metrics?.mappedReads ?? -1, rhs.metrics?.mappedReads ?? -1)
        case "mappedPercent":
            comparison = compare(lhs.metrics?.mappedPercent ?? -1, rhs.metrics?.mappedPercent ?? -1)
        default:
            comparison = lhs.name.localizedStandardCompare(rhs.name)
        }

        if comparison == .orderedSame {
            let fallback = lhs.name.localizedStandardCompare(rhs.name)
            if fallback == .orderedSame {
                return false
            }
            return ascending ? fallback == .orderedAscending : fallback == .orderedDescending
        }

        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    override func columnValue(for columnId: String, row: BundleBrowserSequenceSummary) -> String {
        switch columnId {
        case "contig":
            return row.name
        case "length":
            return "\(row.length)"
        case "kind":
            return bundleBrowserRoleDescription(for: row)
        case "aliases":
            return row.aliases.joined(separator: ", ")
        case "description":
            return row.displayDescription ?? ""
        case "mappedReads":
            return row.metrics?.mappedReads.map { String($0) } ?? ""
        case "mappedPercent":
            return row.metrics?.mappedPercent.map { String($0) } ?? ""
        default:
            return row.name
        }
    }

    override func columnHasData(_ columnId: NSUserInterfaceItemIdentifier) -> Bool {
        switch columnId.rawValue {
        case "mappedReads":
            return unfilteredRows.contains { $0.metrics?.mappedReads != nil }
        case "mappedPercent":
            return unfilteredRows.contains { $0.metrics?.mappedPercent != nil }
        case "aliases":
            return unfilteredRows.contains { !$0.aliases.isEmpty }
        case "description":
            return unfilteredRows.contains {
                guard let description = $0.displayDescription?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }
                return !description.isEmpty
            }
        default:
            return true
        }
    }

    override func didApplyDisplayedRows() {
        guard !displayedRows.isEmpty else {
            tableView.deselectAll(nil)
            onSelectionCleared?()
            return
        }

        let rowIndex = preferredSelectedSequenceName.flatMap { preferredName in
            displayedRows.firstIndex(where: { $0.name == preferredName })
        } ?? 0

        tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
    }

    override func tableViewSelectionDidChange(_ notification: Notification) {
        super.tableViewSelectionDidChange(notification)
        preferredSelectedSequenceName = selectedSequenceSummary?.name
    }

    var selectedSequenceSummary: BundleBrowserSequenceSummary? {
        let rowIndex = tableView.selectedRow
        guard rowIndex >= 0, rowIndex < displayedRows.count else { return nil }
        return displayedRows[rowIndex]
    }

    func setPreferredSelectionName(_ name: String?) {
        preferredSelectedSequenceName = name
    }

    func selectSequence(named name: String) {
        preferredSelectedSequenceName = name
        guard let rowIndex = displayedRows.firstIndex(where: { $0.name == name }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
    }

    private var numericFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
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

@MainActor
final class BundleBrowserViewController: NSViewController {
    var onOpenSequence: ((BundleBrowserSequenceSummary) -> Void)?

    private var summary: BundleBrowserSummary?
    private var bundleURL: URL?
    private var preferredSelectedSequenceName: String?
    private var loadedBundleURL: URL?

    private let splitView = NSSplitView()
    private let listPane = NSView()
    private let detailPane = NSView()
    private let sequenceTableView = BundleBrowserSequenceTableView()
    private let openButton = NSButton(title: "Open Focused Viewer", target: nil, action: nil)
    private let embeddedViewerController = ViewerViewController()
    private let detailStack = NSStackView()
    private let detailNameLabel = NSTextField(labelWithString: "")
    private let detailDescriptionLabel = NSTextField(labelWithString: "")
    private let detailLengthLabel = NSTextField(labelWithString: "")
    private let detailMetricsLabel = NSTextField(labelWithString: "")
    private let detailPlaceholderLabel = NSTextField(labelWithString: "Select a sequence to inspect.")

    override func loadView() {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        rootView.setAccessibilityIdentifier("bundle-browser-view")
        view = rootView

        configureSplitView()
        configureListPane()
        configureDetailPane()

        view.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func configure(summary: BundleBrowserSummary, bundleURL: URL? = nil, restoredState: BundleBrowserState? = nil) {
        self.summary = summary
        self.bundleURL = bundleURL?.standardizedFileURL

        let state = restoredState ?? BundleBrowserState(
            filterText: "",
            selectedSequenceName: summary.sequences.first?.name,
            scrollOriginY: 0
        )

        preferredSelectedSequenceName = state.selectedSequenceName ?? summary.sequences.first?.name
        sequenceTableView.setPreferredSelectionName(preferredSelectedSequenceName)
        sequenceTableView.configure(rows: summary.sequences)
        sequenceTableView.setFilterText(state.filterText)
        sequenceTableView.restoreScrollOriginY(state.scrollOriginY)
    }

    func captureState() -> BundleBrowserState {
        BundleBrowserState(
            filterText: sequenceTableView.currentFilterText,
            selectedSequenceName: selectedRow?.name,
            scrollOriginY: sequenceTableView.currentScrollOriginY
        )
    }

    @objc private func openSelectedSequence(_ sender: Any?) {
        guard let row = selectedRow else { return }
        onOpenSequence?(row)
    }

    var testDisplayedNames: [String] { sequenceTableView.displayedRows.map(\.name) }
    var testSelectedName: String? { selectedRow?.name }
    var testDetailLengthText: String { detailLengthLabel.stringValue }
    var testFilterText: String { sequenceTableView.currentFilterText }
    var testScrollOriginY: CGFloat { sequenceTableView.currentScrollOriginY }
    var testOpenButtonEnabled: Bool { openButton.isEnabled }

    func testSetFilterText(_ text: String) {
        sequenceTableView.setFilterText(text)
    }

    func testSelectRow(named name: String) {
        sequenceTableView.selectSequence(named: name)
    }

    func testInvokeOpen() {
        openSelectedSequence(nil)
    }

    func testSetScrollOriginY(_ originY: CGFloat) {
        sequenceTableView.restoreScrollOriginY(originY)
    }

    private var selectedRow: BundleBrowserSequenceSummary? {
        sequenceTableView.selectedSequenceSummary
    }

    private func configureSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setPosition(340, ofDividerAt: 0)

        listPane.translatesAutoresizingMaskIntoConstraints = false
        detailPane.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(listPane)
        splitView.addArrangedSubview(detailPane)

        NSLayoutConstraint.activate([
            listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            detailPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    private func configureListPane() {
        sequenceTableView.translatesAutoresizingMaskIntoConstraints = false
        sequenceTableView.onRowSelected = { [weak self] row in
            self?.preferredSelectedSequenceName = row.name
            self?.updateDetailPane(for: row)
        }
        sequenceTableView.onSelectionCleared = { [weak self] in
            self?.updateDetailPane(for: nil)
        }
        listPane.addSubview(sequenceTableView)

        NSLayoutConstraint.activate([
            sequenceTableView.topAnchor.constraint(equalTo: listPane.topAnchor),
            sequenceTableView.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            sequenceTableView.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            sequenceTableView.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
        ])
    }

    private func configureDetailPane() {
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8

        detailNameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        detailDescriptionLabel.font = .systemFont(ofSize: 12)
        detailDescriptionLabel.textColor = .secondaryLabelColor
        detailLengthLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detailMetricsLabel.font = .systemFont(ofSize: 12)
        detailMetricsLabel.textColor = .secondaryLabelColor
        detailPlaceholderLabel.font = .systemFont(ofSize: 13)
        detailPlaceholderLabel.textColor = .secondaryLabelColor
        detailPlaceholderLabel.alignment = .center
        detailPlaceholderLabel.maximumNumberOfLines = 0
        detailPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false

        [detailNameLabel, detailDescriptionLabel, detailLengthLabel, detailMetricsLabel].forEach {
            $0.lineBreakMode = .byTruncatingTail
            detailStack.addArrangedSubview($0)
        }

        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.setAccessibilityIdentifier("bundle-browser-open-button")
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openSelectedSequence(_:))

        embeddedViewerController.publishesGlobalViewportNotifications = true
        addChild(embeddedViewerController)
        let detailView = embeddedViewerController.view
        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailPane.addSubview(detailView)
        detailPane.addSubview(detailStack)
        detailPane.addSubview(openButton)
        detailPane.addSubview(detailPlaceholderLabel)

        NSLayoutConstraint.activate([
            detailStack.topAnchor.constraint(equalTo: detailPane.topAnchor, constant: 16),
            detailStack.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor, constant: 16),
            detailStack.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -12),

            openButton.centerYAnchor.constraint(equalTo: detailNameLabel.centerYAnchor),
            openButton.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor, constant: -16),

            detailView.topAnchor.constraint(equalTo: detailStack.bottomAnchor, constant: 12),
            detailView.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: detailPane.bottomAnchor),

            detailPlaceholderLabel.centerXAnchor.constraint(equalTo: detailView.centerXAnchor),
            detailPlaceholderLabel.centerYAnchor.constraint(equalTo: detailView.centerYAnchor),
            detailPlaceholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: detailView.leadingAnchor, constant: 24),
            detailPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailView.trailingAnchor, constant: -24),
        ])

        updateDetailPane(for: nil)
    }

    private func updateDetailPane(for row: BundleBrowserSequenceSummary?) {
        guard let row else {
            detailNameLabel.stringValue = "No sequence selected"
            detailDescriptionLabel.stringValue = ""
            detailLengthLabel.stringValue = ""
            detailMetricsLabel.stringValue = ""
            openButton.isEnabled = false
            embeddedViewerController.view.isHidden = true
            detailPlaceholderLabel.isHidden = false
            return
        }

        detailNameLabel.stringValue = row.name
        detailDescriptionLabel.stringValue = row.displayDescription ?? ""
        detailLengthLabel.stringValue = "\(row.length.formatted()) bp"

        if let mappedReads = row.metrics?.mappedReads {
            detailMetricsLabel.stringValue = "Mapped reads: \(mappedReads.formatted())"
        } else {
            let aliases = row.aliases.isEmpty ? "none" : row.aliases.joined(separator: ", ")
            detailMetricsLabel.stringValue = "Role: \(bundleBrowserRoleDescription(for: row)) | Aliases: \(aliases)"
        }

        openButton.isEnabled = true
        loadSequenceDetail(for: row)
    }

    private func loadSequenceDetail(for row: BundleBrowserSequenceSummary) {
        guard let bundleURL else {
            embeddedViewerController.view.isHidden = true
            detailPlaceholderLabel.stringValue = "Sequence detail is unavailable for this bundle summary."
            detailPlaceholderLabel.isHidden = false
            return
        }

        do {
            if loadedBundleURL != bundleURL {
                embeddedViewerController.clearViewport(statusMessage: "Loading sequence detail...")
                try embeddedViewerController.displayBundle(
                    at: bundleURL,
                    mode: .sequence(name: row.name, restoreViewState: false)
                )
                loadedBundleURL = bundleURL
            } else if let chromosome = embeddedViewerController.currentBundleDataProvider?.chromosomeInfo(named: row.name) {
                embeddedViewerController.navigateToChromosomeAndPosition(
                    chromosome: chromosome.name,
                    chromosomeLength: Int(chromosome.length),
                    start: 0,
                    end: Int(chromosome.length)
                )
            } else {
                try embeddedViewerController.displayBundle(
                    at: bundleURL,
                    mode: .sequence(name: row.name, restoreViewState: false)
                )
            }

            embeddedViewerController.view.isHidden = false
            detailPlaceholderLabel.isHidden = true
            detailPlaceholderLabel.stringValue = "Select a sequence to inspect."
        } catch {
            embeddedViewerController.view.isHidden = true
            detailPlaceholderLabel.stringValue = "Unable to load sequence detail for \(row.name)."
            detailPlaceholderLabel.isHidden = false
        }
    }
}
