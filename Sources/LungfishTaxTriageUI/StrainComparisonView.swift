// StrainComparisonView.swift - Basic strain-level comparison between samples
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "StrainComparison")

// MARK: - StrainComparisonEntry

/// A single position where samples differ in their consensus sequence.
struct StrainComparisonEntry: Equatable {
    /// Reference accession (e.g. NC_009539.1).
    let accession: String

    /// 0-based position on the reference.
    let position: Int

    /// Reference base at this position (if available).
    let referenceBase: Character?

    /// Map of sample ID to the consensus base at this position.
    let sampleBases: [String: Character]
}

// MARK: - StrainComparisonView

/// A table view showing nucleotide positions where samples differ for a given organism.
///
/// This is a basic implementation suitable for displaying consensus-level SNP differences
/// between samples in a multi-sample TaxTriage batch run.
@MainActor
final class StrainComparisonView: NSView {

    // MARK: - State

    private var entries: [StrainComparisonEntry] = []
    /// FULL logical sample set. Used by the cell dataSource (via `sample_<id>`
    /// column identifiers) and preserved intact for any consumer that needs the
    /// complete sample list. Never replaced by the display window.
    private var sampleIds: [String] = []
    private var organismName: String = ""

    /// Display-only cap on instantiated per-sample columns. Windowing only ever
    /// affects which columns `rebuildColumns()` instantiates; `sampleIds` stays
    /// full.
    private var columnWindow = SampleColumnWindow()

    /// The display-only slice of `sampleIds` currently instantiated as columns.
    private var windowedSampleIds: [String] = []

    // MARK: - Child Views

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let columnWindowBanner = SampleColumnWindowBanner()
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private nonisolated(unsafe) var contentTypographyObserver: NSObjectProtocol?
#if DEBUG
    private var typographyReloadCount = 0
    private var typographyRealizedCellResolutionCount = 0
#endif

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        installContentTypographyObservation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        installContentTypographyObservation()
    }

    deinit {
        if let contentTypographyObserver {
            NotificationCenter.default.removeObserver(contentTypographyObserver)
        }
    }

    // MARK: - Setup

    private func setupViews() {
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerLabel.lineBreakMode = .byWordWrapping
        headerLabel.maximumNumberOfLines = 0
        headerLabel.cell?.wraps = true
        headerLabel.toolTip = headerLabel.stringValue
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(headerLabel)

        columnWindowBanner.onShowAll = { [weak self] in self?.showAllSampleColumns() }
        addSubview(columnWindowBanner)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 20
        tableView.style = .plain
        tableView.delegate = self
        tableView.dataSource = self

        scrollView.documentView = tableView

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            columnWindowBanner.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            columnWindowBanner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            columnWindowBanner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: columnWindowBanner.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func installContentTypographyObservation() {
        contentTypographyObserver = NotificationCenter.default.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyContentTypography()
            }
        }
        applyContentTypography()
    }

    private func applyContentTypography() {
        headerLabel.font = taxTriageContentFont(
            canonicalPointSize: 12,
            weight: .semibold,
            preferredFontProvider: preferredFontProvider
        )
        headerLabel.toolTip = headerLabel.stringValue
        headerLabel.setAccessibilityValue(headerLabel.stringValue)
        taxTriageApplyTableGeometry(
            to: tableView,
            minimumRowHeight: 20,
            preferredFontProvider: preferredFontProvider
        )
        let realizedCount = taxTriageForEachRealizedCell(in: tableView) {
            [weak self] column, _, view in
            guard let self, let field = view as? NSTextField else { return }
            self.applyContentTypography(to: field, column: column.identifier)
        }
#if DEBUG
        typographyRealizedCellResolutionCount = realizedCount
#endif
    }

    private func applyContentTypography(
        to field: NSTextField,
        column: NSUserInterfaceItemIdentifier
    ) {
        let isAlternateBase: Bool
        if column.rawValue.hasPrefix("sample_"),
           field.stringValue != "-",
           field.textColor == .lungfishDanger {
            isAlternateBase = true
        } else {
            isAlternateBase = false
        }
        field.font = taxTriageContentFont(
            canonicalPointSize: 11,
            weight: isAlternateBase ? .bold : .regular,
            monospaced: true,
            preferredFontProvider: preferredFontProvider
        )
        if !field.stringValue.isEmpty {
            field.toolTip = field.stringValue
            field.setAccessibilityValue(field.stringValue)
        }
    }

    func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        columnWindowBanner.setContentPreferredFontProvider(provider)
        applyContentTypography()
    }

    /// Keep the reveal banner in sync with the current window state.
    private func syncColumnWindowBanner() {
        columnWindowBanner.update(
            isWindowActive: isColumnWindowActive,
            shownCount: windowedSampleIds.count,
            totalCount: sampleIds.count
        )
    }

    private func rebuildColumns() {
        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }

        let accCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("accession"))
        accCol.title = "Accession"
        accCol.width = 120
        accCol.minWidth = 80
        tableView.addTableColumn(accCol)

        let posCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("position"))
        posCol.title = "Position"
        posCol.width = 80
        posCol.minWidth = 60
        tableView.addTableColumn(posCol)

        let refCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reference"))
        refCol.title = "Ref"
        refCol.width = 40
        refCol.minWidth = 30
        tableView.addTableColumn(refCol)

        // Display-only window: instantiate at most `columnWindow.limit` sample
        // columns. `sampleIds` (the full logical set) is unchanged; the cell
        // dataSource still resolves `sample_<id>` for the instantiated columns.
        windowedSampleIds = columnWindow.windowedSamples(from: sampleIds)
        for sampleId in windowedSampleIds {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sample_\(sampleId)"))
            col.title = sampleId
            col.headerToolTip = sampleId
            col.width = 60
            col.minWidth = 40
            tableView.addTableColumn(col)
        }
        applyCurrentColumnHeaderTypography()
    }

    private func applyCurrentColumnHeaderTypography() {
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        for column in tableView.tableColumns {
            column.headerCell.font = typography.font(for: .tableHeader)
            column.headerToolTip = column.headerToolTip ?? column.title
        }
    }

    // MARK: - Public API

    /// Configures the view with strain comparison data.
    ///
    /// - Parameters:
    ///   - entries: The differing positions to display.
    ///   - sampleIds: Ordered sample identifiers.
    ///   - organismName: The organism name for the header.
    func configure(entries: [StrainComparisonEntry], sampleIds: [String], organismName: String) {
        self.entries = entries
        self.sampleIds = sampleIds
        self.organismName = organismName

        if entries.isEmpty {
            headerLabel.stringValue = "\(organismName) \u{2014} No nucleotide differences detected"
        } else {
            headerLabel.stringValue = "\(organismName) \u{2014} \(entries.count) differing position(s)"
        }
        headerLabel.toolTip = headerLabel.stringValue
        headerLabel.setAccessibilityValue(headerLabel.stringValue)

        columnWindow.reset()
        rebuildColumns()
        syncColumnWindowBanner()
        tableView.reloadData()
        logger.info("Strain comparison: \(entries.count) SNP(s) for \(organismName, privacy: .public) across \(sampleIds.count) samples")
    }

    /// Whether the per-sample columns are currently capped by the display window.
    var isColumnWindowActive: Bool { columnWindow.caps(sampleIds) }

    /// Reveal every per-sample column, defeating the display cap.
    func showAllSampleColumns() {
        guard columnWindow.caps(sampleIds) else { return }
        columnWindow.revealAll()
        rebuildColumns()
        syncColumnWindowBanner()
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDataSource

extension StrainComparisonView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }
}

// MARK: - NSTableViewDelegate

extension StrainComparisonView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < entries.count else { return nil }
        let entry = entries[row]
        let id = column.identifier.rawValue

        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail

        switch id {
        case "accession":
            field.stringValue = entry.accession

        case "position":
            field.stringValue = "\(entry.position + 1)"  // 1-based display
            field.alignment = .right

        case "reference":
            field.stringValue = entry.referenceBase.map(String.init) ?? "-"
            field.alignment = .center

        default:
            if id.hasPrefix("sample_") {
                let sampleId = String(id.dropFirst("sample_".count))
                if let base = entry.sampleBases[sampleId] {
                    field.stringValue = String(base)
                    // Highlight if different from reference
                    if let refBase = entry.referenceBase, base != refBase {
                        field.textColor = .lungfishDanger
                    }
                } else {
                    field.stringValue = "-"
                    field.textColor = .tertiaryLabelColor
                }
                field.alignment = .center
            }
        }

        applyContentTypography(to: field, column: column.identifier)

        return field
    }
}

#if DEBUG
extension StrainComparisonView {
    /// Number of instantiated per-sample columns (identifier `sample_*`).
    var testingSampleColumnCount: Int {
        tableView.tableColumns.filter { $0.identifier.rawValue.hasPrefix("sample_") }.count
    }

    /// The FULL logical sample set (never windowed).
    var testingFullSampleIds: [String] { sampleIds }

    /// Whether the "Show all" reveal banner is currently visible.
    var testingColumnWindowBannerVisible: Bool { !columnWindowBanner.isHidden }

    /// Invoke the banner's "Show all" action, exercising the wired callback.
    func testingTapShowAllBanner() { columnWindowBanner.onShowAll?() }

    var testingTableView: NSTableView { tableView }
    var testingHeaderPointSize: CGFloat { headerLabel.font?.pointSize ?? 0 }
    var testingTypographyReloadCount: Int { typographyReloadCount }
    var testingTypographyRealizedCellResolutionCount: Int {
        typographyRealizedCellResolutionCount
    }
    var testingPresentationState: TaxTriageTablePresentationState {
        TaxTriageTablePresentationState(tableView: tableView)
    }

    func testingSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        setContentPreferredFontProvider(provider)
    }

    func testingCell(column identifier: String, row: Int) -> NSTextField? {
        guard let columnIndex = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == identifier
        }) else {
            return nil
        }
        return tableView.view(
            atColumn: columnIndex,
            row: row,
            makeIfNecessary: true
        ) as? NSTextField
    }

    func testingScroll(to origin: NSPoint) {
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
#endif
