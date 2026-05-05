// MultipleSequenceAlignmentViewController.swift - Native MSA bundle viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO

private enum MultipleSequenceAlignmentAccessibilityID {
    static let root = "multiple-sequence-alignment-bundle-view"
    static let textView = "multiple-sequence-alignment-text-view"
    static let matrixView = "multiple-sequence-alignment-matrix-view"
    static let overviewSignal = "multiple-sequence-alignment-overview-signal"
    static let annotationTrackPrefix = "multiple-sequence-alignment-annotation-track"
    static let rowGutter = "multiple-sequence-alignment-row-gutter"
    static let columnHeader = "multiple-sequence-alignment-column-header"
    static let searchField = "multiple-sequence-alignment-search-field"
    static let zoomOutButton = "multiple-sequence-alignment-zoom-out-button"
    static let zoomInButton = "multiple-sequence-alignment-zoom-in-button"
    static let fitColumnsButton = "multiple-sequence-alignment-fit-columns-button"
    static let siteMode = "multiple-sequence-alignment-site-mode"
    static let colorScheme = "multiple-sequence-alignment-color-scheme"
}

private enum MSAAlignmentCanvasMetrics {
    static let rowGutterWidth: CGFloat = 232
    static let headerHeight: CGFloat = 24
    static let overviewHeight: CGFloat = 18
    static let consensusRowHeight: CGFloat = 26
    static let rowHeight: CGFloat = 24
    static let defaultColumnWidth: CGFloat = 12
    static let minimumOverviewColumnWidth: CGFloat = 0.04
    static let letterColumnWidth: CGFloat = 8
    static let blockColumnWidth: CGFloat = 2
    static let maximumColumnWidth: CGFloat = 36
    static let zoomFactor: CGFloat = 1.35
    static let maximumAnnotationZoomColumnWidth: CGFloat = 28
    static let annotationLaneHeight: CGFloat = 6
}

private enum MSAZoomRenderingMode: Equatable {
    case letters
    case residueBlocks
    case aggregateDifferences

    static func forColumnWidth(_ columnWidth: CGFloat) -> MSAZoomRenderingMode {
        if columnWidth < MSAAlignmentCanvasMetrics.blockColumnWidth {
            return .aggregateDifferences
        }
        if columnWidth < MSAAlignmentCanvasMetrics.letterColumnWidth {
            return .residueBlocks
        }
        return .letters
    }

    var displayTitle: String {
        switch self {
        case .letters:
            return "letters"
        case .residueBlocks:
            return "residue blocks"
        case .aggregateDifferences:
            return "aggregate differences"
        }
    }
}

enum MultipleSequenceAlignmentNavigationDirection {
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
}

enum MultipleSequenceAlignmentColorScheme: Int, CaseIterable {
    case nucleotide
    case conservation

    var title: String {
        switch self {
        case .nucleotide:
            return "Nucleotide"
        case .conservation:
            return "Conservation"
        }
    }
}

private struct MSAAlignmentSequence: Equatable {
    let name: String
    let sequence: [Character]

    var sequenceString: String { String(sequence) }
    var ungappedSequenceString: String {
        sequence.filter { Self.isGap($0) == false }.map(String.init).joined()
    }

    private static func isGap(_ residue: Character) -> Bool {
        residue == "-" || residue == "."
    }
}

private struct MSAColumnSummary: Equatable {
    let index: Int
    let consensus: Character
    let residueCounts: [Character: Int]
    let gapFraction: Double
    let conservation: Double
    let variable: Bool
    let parsimonyInformative: Bool
}

private struct MSAAlignmentAnnotationTrack: Equatable {
    let annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord
    let rowIndex: Int

    var rowName: String { annotation.rowName }
    var trackName: String { annotation.sourceTrackName }
    var name: String { annotation.name }
    var type: String { annotation.type }

    var alignmentColumnRange: ClosedRange<Int>? {
        guard let start = annotation.alignedIntervals.map(\.start).min(),
              let end = annotation.alignedIntervals.map(\.end).max(),
              end > start else {
            return nil
        }
        return start...(end - 1)
    }
}

private struct MSAOrientationNumberingTick: Equatable {
    let displayColumn: Int
    let alignmentColumn: Int
    let label: String
}

private enum MSAVisibleDisplayColumns {
    static func range(
        displayedColumnCount: Int,
        columnWidth: CGFloat,
        minX: CGFloat,
        maxX: CGFloat,
        overscan: Int = 2
    ) -> Range<Int> {
        guard displayedColumnCount > 0,
              columnWidth.isFinite,
              columnWidth > 0,
              minX.isFinite,
              maxX.isFinite else {
            return 0..<0
        }

        let rawStart = floor(min(minX, maxX) / columnWidth) - CGFloat(overscan)
        let rawEnd = ceil(max(minX, maxX) / columnWidth) + CGFloat(overscan)
        let start = clampedIndex(rawStart, count: displayedColumnCount)
        let end = clampedIndex(rawEnd, count: displayedColumnCount)
        guard start < end else { return 0..<0 }
        return start..<end
    }

    private static func clampedIndex(_ value: CGFloat, count: Int) -> Int {
        guard value.isFinite else { return 0 }
        if value <= 0 {
            return 0
        }
        if value >= CGFloat(count) {
            return count
        }
        return Int(value)
    }
}

private enum MSAOrientationNumbering {
    static let targetPixelSpacing: CGFloat = 90

    static func ticks(
        displayedColumns: [Int],
        columnWidth: CGFloat,
        visibleDisplayColumns: Range<Int>
    ) -> [MSAOrientationNumberingTick] {
        guard !displayedColumns.isEmpty,
              !visibleDisplayColumns.isEmpty,
              columnWidth.isFinite,
              columnWidth > 0,
              displayedColumns.indices.contains(visibleDisplayColumns.lowerBound),
              displayedColumns.indices.contains(visibleDisplayColumns.upperBound - 1) else {
            return []
        }

        let targetColumns = max(1, Int(ceil(targetPixelSpacing / columnWidth)))
        let interval = niceInterval(near: targetColumns)
        let firstDisplayColumn = visibleDisplayColumns.lowerBound
        let lastDisplayColumn = visibleDisplayColumns.upperBound - 1
        let firstCoordinate = displayedColumns[firstDisplayColumn] + 1
        let lastCoordinate = displayedColumns[lastDisplayColumn] + 1
        var ticks: [MSAOrientationNumberingTick] = [
            MSAOrientationNumberingTick(
                displayColumn: firstDisplayColumn,
                alignmentColumn: displayedColumns[firstDisplayColumn],
                label: label(for: firstCoordinate)
            ),
        ]

        var coordinate = ((firstCoordinate / interval) + 1) * interval
        while coordinate <= lastCoordinate {
            let alignmentColumn = coordinate - 1
            guard let displayColumn = firstDisplayedColumn(
                atOrAfter: alignmentColumn,
                displayedColumns: displayedColumns,
                visibleDisplayColumns: visibleDisplayColumns
            ) else {
                coordinate += interval
                continue
            }
            if ticks.last?.displayColumn != displayColumn {
                let actualCoordinate = displayedColumns[displayColumn] + 1
                ticks.append(
                    MSAOrientationNumberingTick(
                        displayColumn: displayColumn,
                        alignmentColumn: displayedColumns[displayColumn],
                        label: label(for: actualCoordinate)
                    )
                )
            }
            coordinate += interval
        }

        return ticks
    }

    private static func firstDisplayedColumn(
        atOrAfter alignmentColumn: Int,
        displayedColumns: [Int],
        visibleDisplayColumns: Range<Int>
    ) -> Int? {
        var low = visibleDisplayColumns.lowerBound
        var high = visibleDisplayColumns.upperBound
        while low < high {
            let mid = (low + high) / 2
            if displayedColumns[mid] < alignmentColumn {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return visibleDisplayColumns.contains(low) ? low : nil
    }

    private static func niceInterval(near target: Int) -> Int {
        guard target > 1 else { return 1 }
        var magnitude = 1
        while magnitude * 10 < target {
            magnitude *= 10
        }
        for multiplier in [1, 2, 5, 10] {
            let candidate = multiplier * magnitude
            if candidate >= target {
                return candidate
            }
        }
        return magnitude * 10
    }

    private static func label(for coordinate: Int) -> String {
        guard coordinate >= 1_000 else { return "\(coordinate)" }
        if coordinate.isMultiple(of: 1_000) {
            return "\(coordinate / 1_000) kb"
        }
        let value = Double(coordinate) / 1_000
        return String(format: "%.1f kb", value)
    }
}

struct MultipleSequenceAlignmentSelectionExportRequest: Equatable, Sendable {
    let bundleURL: URL
    let outputKind: String
    let rows: String?
    let columns: String?
    let suggestedName: String
    let displayName: String
}

struct MultipleSequenceAlignmentTreeInferenceRequest: Equatable, Sendable {
    let bundleURL: URL
    let rows: String?
    let columns: String?
    let suggestedName: String
    let displayName: String
}

struct MultipleSequenceAlignmentAnnotationAddRequest: Equatable, Sendable {
    let bundleURL: URL
    let row: String
    let columns: String
    let name: String
    let type: String
    let strand: String
    let note: String?
    let qualifiers: [String]
    let displayName: String
}

struct MultipleSequenceAlignmentAnnotationProjectionRequest: Equatable, Sendable {
    let bundleURL: URL
    let sourceAnnotationID: String
    let targetRows: String
    let conflictPolicy: String
    let displayName: String
}

@MainActor
final class MultipleSequenceAlignmentViewController: NSViewController {
    private(set) var bundleURL: URL?
    private(set) var bundle: MultipleSequenceAlignmentBundle?

    var onExtractSequenceRequested: (([String], String) -> Void)?
    var onExtractAnnotatedSequenceRequested: (([String], String, [String: [SequenceAnnotation]]) -> Void)?
    var onExportFASTARequested: (([String], String) -> Void)?
    var onExportMSASelectionRequested: ((MultipleSequenceAlignmentSelectionExportRequest) -> Void)?
    var onCreateBundleRequested: (([String], String) -> Void)?
    var onCreateAnnotatedBundleRequested: (([String], String, [String: [SequenceAnnotation]]) -> Void)?
    var onRunOperationRequested: (([String], String) -> Void)?
    var onInferTreeRequested: ((MultipleSequenceAlignmentTreeInferenceRequest) -> Void)?
    var onAddAnnotationRequested: ((MultipleSequenceAlignmentAnnotationAddRequest) -> Void)?
    var onProjectAnnotationRequested: ((MultipleSequenceAlignmentAnnotationProjectionRequest) -> Void)?
    var onSelectionStateChanged: ((MultipleSequenceAlignmentSelectionState?) -> Void)?

    private var alignmentRows: [MSAAlignmentSequence] = []
    private var rowIDsByIndex: [String] = []
    private var columnSummaries: [MSAColumnSummary] = []
    private var displayedColumns: [Int] = []
    private var coordinateMapsByRowID: [String: MultipleSequenceAlignmentBundle.RowCoordinateMap] = [:]
    private var annotationStore = MultipleSequenceAlignmentBundle.AnnotationStore()
    private var annotationTracks: [MSAAlignmentAnnotationTrack] = []
    private var drawerAnnotationByResultID: [UUID: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord] = [:]
    private var selectedRowIndex: Int?
    private var selectedAlignmentColumn: Int?
    private var selectedRowRange: ClosedRange<Int>?
    private var selectedAlignmentColumnRange: ClosedRange<Int>?
    private var selectionAnchor: (row: Int, alignmentColumn: Int)?
    private var alignmentColumnWidth = MSAAlignmentCanvasMetrics.defaultColumnWidth
    private var colorScheme: MultipleSequenceAlignmentColorScheme = .nucleotide
    private var numberingMode: MSAAlignmentNumberingMode = .both
    private var consensusDisplayOptions = MSAConsensusDisplayOptions()
    private var referenceRowID: String?
    private var residueIdentityDisplayMode: MSAResidueIdentityDisplayMode = .letters

    private let searchField = NSSearchField()
    private let zoomOutButton = NSButton(title: "", target: nil, action: nil)
    private let zoomInButton = NSButton(title: "", target: nil, action: nil)
    private let fitColumnsButton = NSButton(title: "", target: nil, action: nil)
    private let siteModeControl = NSSegmentedControl(
        labels: ["All Sites", "Variable Sites"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let previousVariableButton = NSButton(title: "Previous Variable", target: nil, action: nil)
    private let nextVariableButton = NSButton(title: "Next Variable", target: nil, action: nil)
    private let canvasContainer = NSView()
    private let cornerHeaderView = MSAAlignmentCornerHeaderView()
    private let rowGutterView = MSAAlignmentRowGutterView()
    private let columnHeaderView = MSAAlignmentColumnHeaderView()
    private let overviewSignalView = MSAAlignmentOverviewSignalView()
    private let alignmentMatrixView = MSAAlignmentMatrixView()
    private let colorSchemeControl = NSSegmentedControl(
        labels: MultipleSequenceAlignmentColorScheme.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let alignmentScrollView = NSScrollView()
    private let annotationDrawer = AnnotationTableDrawerView()
    private var annotationDrawerHeightConstraint: NSLayoutConstraint?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = NSView()
        view.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.root)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        configureLayout()
    }

    func displayBundle(at url: URL) throws {
        _ = view
        let loaded = try MultipleSequenceAlignmentBundle.load(from: url)
        let primaryAlignmentURL = url.appendingPathComponent("alignment/primary.aligned.fasta")
        let primaryAlignmentText = try String(contentsOf: primaryAlignmentURL, encoding: .utf8)
        let parsedRows = try Self.parseAlignedFASTA(primaryAlignmentText)

        bundleURL = url
        bundle = loaded
        alignmentRows = parsedRows
        rowIDsByIndex = loaded.rows.map(\.id)
        columnSummaries = Self.computeColumnSummaries(for: parsedRows)
        coordinateMapsByRowID = Dictionary(uniqueKeysWithValues: (try loaded.loadCoordinateMaps()).map { ($0.rowID, $0) })
        annotationStore = try loaded.loadAnnotationStore()
        refreshAnnotationTracks()
        displayedColumns = Array(0..<columnSummaries.count)
        selectedRowIndex = parsedRows.isEmpty ? nil : 0
        selectedAlignmentColumn = displayedColumns.first
        selectedRowRange = selectedRowIndex.map { $0...$0 }
        selectedAlignmentColumnRange = selectedAlignmentColumn.map { $0...$0 }
        selectionAnchor = selectedRowIndex.flatMap { row in selectedAlignmentColumn.map { (row, $0) } }
        colorScheme = .nucleotide
        numberingMode = .both
        consensusDisplayOptions = MSAConsensusDisplayOptions()
        referenceRowID = loaded.manifest.referenceRowID ?? loaded.rows.first?.id
        residueIdentityDisplayMode = .letters
        colorSchemeControl.selectedSegment = colorScheme.rawValue
        siteModeControl.selectedSegment = 0
        searchField.stringValue = ""

        configureCanvasViews()
        zoomToFit()
        refreshAnnotationDrawer()
        scrollSelectionIntoView()
        notifySelectionStateIfAvailable()
    }

    @objc private func siteModeChanged(_ sender: NSSegmentedControl) {
        applySiteMode()
    }

    @objc private func performSearchFromField(_ sender: NSSearchField) {
        performSearch()
    }

    @objc private func previousVariableSite(_ sender: NSButton) {
        moveVariableSelection(direction: -1)
    }

    @objc private func nextVariableSite(_ sender: NSButton) {
        moveVariableSelection(direction: 1)
    }

    @objc private func zoomOutAlignment(_ sender: Any?) {
        zoomOut()
    }

    @objc private func zoomInAlignment(_ sender: Any?) {
        zoomIn()
    }

    @objc private func fitAlignmentColumns(_ sender: Any?) {
        zoomToFit()
    }

    @objc private func colorSchemeChanged(_ sender: NSSegmentedControl) {
        guard let scheme = MultipleSequenceAlignmentColorScheme(rawValue: sender.selectedSegment) else { return }
        colorScheme = scheme
        configureCanvasViews()
    }

    public func zoomOut() {
        setAlignmentColumnWidth(
            alignmentColumnWidth / MSAAlignmentCanvasMetrics.zoomFactor,
            centeredOnDisplayColumn: visibleCenterDisplayColumn()
        )
    }

    public func zoomIn() {
        setAlignmentColumnWidth(
            alignmentColumnWidth * MSAAlignmentCanvasMetrics.zoomFactor,
            centeredOnDisplayColumn: visibleCenterDisplayColumn()
        )
    }

    public func zoomToFit() {
        guard !displayedColumns.isEmpty else { return }
        let visibleWidth = effectiveVisibleMatrixWidth()
        let fittedWidth = min(
            MSAAlignmentCanvasMetrics.defaultColumnWidth,
            max(
                MSAAlignmentCanvasMetrics.minimumOverviewColumnWidth,
                (visibleWidth - 8) / CGFloat(max(displayedColumns.count, 1))
            )
        )
        setAlignmentColumnWidth(fittedWidth, centeredOnDisplayColumn: 0)
        centerDisplayColumn(0)
    }

    public func resetZoom() {
        setAlignmentColumnWidth(
            MSAAlignmentCanvasMetrics.defaultColumnWidth,
            centeredOnDisplayColumn: visibleCenterDisplayColumn()
        )
    }

    func applyNumberingMode(_ mode: MSAAlignmentNumberingMode) {
        numberingMode = mode
        configureCanvasViews()
    }

    func applyConsensusDisplayOptions(_ options: MSAConsensusDisplayOptions) {
        consensusDisplayOptions = options
        configureCanvasViews()
    }

    func applyReferenceRowID(_ rowID: String?) {
        if let rowID, rowIDsByIndex.contains(rowID) {
            referenceRowID = rowID
        } else {
            referenceRowID = rowIDsByIndex.first
        }
        configureCanvasViews()
        notifySelectionStateIfAvailable()
    }

    func applyResidueIdentityDisplayMode(_ mode: MSAResidueIdentityDisplayMode) {
        residueIdentityDisplayMode = mode
        configureCanvasViews()
    }

    private func configureLayout() {
        let toolbar = configureToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        configureCanvas()
        configureAnnotationDrawer()

        view.addSubview(toolbar)
        view.addSubview(canvasContainer)
        view.addSubview(annotationDrawer)
        let drawerHeightConstraint = annotationDrawer.heightAnchor.constraint(equalToConstant: 126)
        annotationDrawerHeightConstraint = drawerHeightConstraint
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            annotationDrawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            annotationDrawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            annotationDrawer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            drawerHeightConstraint,

            canvasContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvasContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasContainer.bottomAnchor.constraint(equalTo: annotationDrawer.topAnchor),
        ])
    }

    private func configureToolbar() -> NSView {
        searchField.placeholderString = "Find sequence or column"
        searchField.target = self
        searchField.action = #selector(performSearchFromField(_:))
        LungfishAppKitControlStyle.applyInspectorMetrics(to: searchField)
        searchField.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.searchField)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 190).isActive = true

        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutAlignment(_:))
        configureIconButton(
            zoomOutButton,
            symbolName: "minus.magnifyingglass",
            fallbackTitle: "-",
            accessibilityLabel: "Zoom out"
        )
        zoomOutButton.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.zoomOutButton)

        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInAlignment(_:))
        configureIconButton(
            zoomInButton,
            symbolName: "plus.magnifyingglass",
            fallbackTitle: "+",
            accessibilityLabel: "Zoom in"
        )
        zoomInButton.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.zoomInButton)

        fitColumnsButton.target = self
        fitColumnsButton.action = #selector(fitAlignmentColumns(_:))
        configureIconButton(
            fitColumnsButton,
            symbolName: "arrow.left.and.right",
            fallbackTitle: "Fit",
            accessibilityLabel: "Fit alignment columns"
        )
        fitColumnsButton.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.fitColumnsButton)

        siteModeControl.selectedSegment = 0
        siteModeControl.target = self
        siteModeControl.action = #selector(siteModeChanged(_:))
        LungfishAppKitControlStyle.applyInspectorMetrics(to: siteModeControl)
        siteModeControl.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.siteMode)

        previousVariableButton.target = self
        previousVariableButton.action = #selector(previousVariableSite(_:))
        previousVariableButton.bezelStyle = .rounded
        LungfishAppKitControlStyle.applyInspectorMetrics(to: previousVariableButton)

        nextVariableButton.target = self
        nextVariableButton.action = #selector(nextVariableSite(_:))
        nextVariableButton.bezelStyle = .rounded
        LungfishAppKitControlStyle.applyInspectorMetrics(to: nextVariableButton)

        colorSchemeControl.selectedSegment = MultipleSequenceAlignmentColorScheme.nucleotide.rawValue
        colorSchemeControl.target = self
        colorSchemeControl.action = #selector(colorSchemeChanged(_:))
        LungfishAppKitControlStyle.applyInspectorMetrics(to: colorSchemeControl)
        colorSchemeControl.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.colorScheme)
        colorSchemeControl.setAccessibilityLabel("Alignment color scheme")

        let toolbar = NSStackView(views: [
            searchField,
            zoomOutButton,
            zoomInButton,
            fitColumnsButton,
            siteModeControl,
            previousVariableButton,
            nextVariableButton,
            colorSchemeControl,
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 6, right: 12)
        return toolbar
    }

    private func configureIconButton(
        _ button: NSButton,
        symbolName: String,
        fallbackTitle: String,
        accessibilityLabel: String
    ) {
        LungfishAppKitControlStyle.configureInspectorIconButton(
            button,
            symbolName: symbolName,
            fallbackTitle: fallbackTitle,
            accessibilityLabel: accessibilityLabel
        )
    }

    private func configureCanvas() {
        canvasContainer.translatesAutoresizingMaskIntoConstraints = false
        canvasContainer.wantsLayer = true
        canvasContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        cornerHeaderView.translatesAutoresizingMaskIntoConstraints = false
        rowGutterView.translatesAutoresizingMaskIntoConstraints = false
        columnHeaderView.translatesAutoresizingMaskIntoConstraints = false
        overviewSignalView.translatesAutoresizingMaskIntoConstraints = false
        alignmentScrollView.translatesAutoresizingMaskIntoConstraints = false

        rowGutterView.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.rowGutter)
        rowGutterView.setAccessibilityElement(true)
        rowGutterView.setAccessibilityRole(.group)
        rowGutterView.setAccessibilityLabel("Alignment rows")
        columnHeaderView.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.columnHeader)
        columnHeaderView.setAccessibilityElement(true)
        columnHeaderView.setAccessibilityRole(.group)
        columnHeaderView.setAccessibilityLabel("Consensus sequence")
        overviewSignalView.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.overviewSignal)
        overviewSignalView.setAccessibilityElement(true)
        overviewSignalView.setAccessibilityRole(.group)
        overviewSignalView.setAccessibilityLabel("Alignment conservation overview")

        alignmentMatrixView.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.matrixView)
        alignmentMatrixView.setAccessibilityElement(true)
        alignmentMatrixView.setAccessibilityRole(.group)
        alignmentMatrixView.setAccessibilityLabel("Multiple sequence alignment matrix")
        alignmentMatrixView.onSelectionChanged = { [weak self] row, alignmentColumn in
            self?.select(row: row, alignmentColumn: alignmentColumn)
        }
        alignmentMatrixView.onSelectionRangeChanged = { [weak self] rowRange, alignmentColumnRange in
            self?.select(rowRange: rowRange, alignmentColumnRange: alignmentColumnRange)
        }
        alignmentMatrixView.onKeyboardNavigation = { [weak self] direction, extendingSelection in
            self?.moveActiveCell(direction, extendingSelection: extendingSelection)
        }
        alignmentMatrixView.onMagnification = { [weak self] magnification in
            guard let self else { return }
            let factor = max(0.2, 1 + magnification)
            self.setAlignmentColumnWidth(
                self.alignmentColumnWidth * factor,
                centeredOnDisplayColumn: self.visibleCenterDisplayColumn()
            )
        }
        alignmentMatrixView.contextMenuProvider = { [weak self] row, alignmentColumn in
            guard let self else { return nil }
            if !self.selectionContains(row: row, alignmentColumn: alignmentColumn) {
                self.select(row: row, alignmentColumn: alignmentColumn)
            }
            return self.selectionContextMenu()
        }
        alignmentMatrixView.onAnnotationSelected = { [weak self] annotation in
            self?.selectAnnotation(annotation, zoom: false)
        }
        alignmentMatrixView.annotationContextMenuProvider = { [weak self] annotation in
            self?.annotationContextMenu(for: annotation)
        }

        alignmentScrollView.hasVerticalScroller = true
        alignmentScrollView.hasHorizontalScroller = true
        alignmentScrollView.autohidesScrollers = false
        alignmentScrollView.documentView = alignmentMatrixView
        alignmentScrollView.drawsBackground = true
        alignmentScrollView.backgroundColor = .textBackgroundColor
        alignmentScrollView.setAccessibilityIdentifier(MultipleSequenceAlignmentAccessibilityID.textView)
        alignmentScrollView.setAccessibilityLabel("Multiple sequence alignment viewport")

        canvasContainer.addSubview(cornerHeaderView)
        canvasContainer.addSubview(columnHeaderView)
        canvasContainer.addSubview(overviewSignalView)
        canvasContainer.addSubview(rowGutterView)
        canvasContainer.addSubview(alignmentScrollView)

        let gutterWidth = MSAAlignmentCanvasMetrics.rowGutterWidth
        let headerHeight = MSAAlignmentCanvasMetrics.headerHeight
        let overviewHeight = MSAAlignmentCanvasMetrics.overviewHeight
        NSLayoutConstraint.activate([
            cornerHeaderView.topAnchor.constraint(equalTo: canvasContainer.topAnchor),
            cornerHeaderView.leadingAnchor.constraint(equalTo: canvasContainer.leadingAnchor),
            cornerHeaderView.widthAnchor.constraint(equalToConstant: gutterWidth),
            cornerHeaderView.heightAnchor.constraint(equalToConstant: headerHeight + overviewHeight),

            columnHeaderView.topAnchor.constraint(equalTo: canvasContainer.topAnchor),
            columnHeaderView.leadingAnchor.constraint(equalTo: cornerHeaderView.trailingAnchor),
            columnHeaderView.trailingAnchor.constraint(equalTo: canvasContainer.trailingAnchor),
            columnHeaderView.heightAnchor.constraint(equalToConstant: headerHeight),

            overviewSignalView.topAnchor.constraint(equalTo: columnHeaderView.bottomAnchor),
            overviewSignalView.leadingAnchor.constraint(equalTo: cornerHeaderView.trailingAnchor),
            overviewSignalView.trailingAnchor.constraint(equalTo: canvasContainer.trailingAnchor),
            overviewSignalView.heightAnchor.constraint(equalToConstant: overviewHeight),

            rowGutterView.topAnchor.constraint(equalTo: cornerHeaderView.bottomAnchor),
            rowGutterView.leadingAnchor.constraint(equalTo: canvasContainer.leadingAnchor),
            rowGutterView.widthAnchor.constraint(equalToConstant: gutterWidth),
            rowGutterView.bottomAnchor.constraint(equalTo: canvasContainer.bottomAnchor),

            alignmentScrollView.topAnchor.constraint(equalTo: overviewSignalView.bottomAnchor),
            alignmentScrollView.leadingAnchor.constraint(equalTo: rowGutterView.trailingAnchor),
            alignmentScrollView.trailingAnchor.constraint(equalTo: canvasContainer.trailingAnchor),
            alignmentScrollView.bottomAnchor.constraint(equalTo: canvasContainer.bottomAnchor),
        ])

        alignmentScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(alignmentClipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: alignmentScrollView.contentView
        )
    }

    private func configureAnnotationDrawer() {
        annotationDrawer.translatesAutoresizingMaskIntoConstraints = false
        annotationDrawer.delegate = self
        annotationDrawer.allowsAnnotationEditing = false
        annotationDrawer.setAnnotations([])
    }

    @objc private func alignmentClipViewBoundsDidChange(_ notification: Notification) {
        let origin = alignmentScrollView.contentView.bounds.origin
        rowGutterView.verticalOffset = origin.y
        rowGutterView.horizontalOffset = origin.x
        columnHeaderView.horizontalOffset = origin.x
        rowGutterView.needsDisplay = true
        columnHeaderView.needsDisplay = true
    }

    private func configureCanvasViews() {
        let consensusResidues = displayedConsensusResidues()
        cornerHeaderView.configure(title: numberingMode.showsSourceCoordinates ? "Consensus / Coordinates" : "Consensus")
        rowGutterView.configure(
            rows: alignmentRows,
            rowIDsByIndex: rowIDsByIndex,
            coordinateMapsByRowID: coordinateMapsByRowID,
            displayedColumns: displayedColumns,
            consensusResidues: consensusResidues,
            columnWidth: alignmentColumnWidth,
            numberingMode: numberingMode
        )
        columnHeaderView.configure(
            columnSummaries: columnSummaries,
            consensusResidues: consensusResidues,
            displayedColumns: displayedColumns,
            columnWidth: alignmentColumnWidth,
            numberingMode: numberingMode
        )
        overviewSignalView.configure(
            columnSummaries: columnSummaries,
            displayedColumns: displayedColumns,
            columnWidth: alignmentColumnWidth
        )
        alignmentMatrixView.configure(
            rows: alignmentRows,
            columnSummaries: columnSummaries,
            consensusResidues: consensusResidues,
            referenceRowIndex: referenceRowIndex(),
            residueIdentityDisplayMode: residueIdentityDisplayMode,
            displayedColumns: displayedColumns,
            annotationTracks: annotationTracks,
            columnWidth: alignmentColumnWidth,
            colorScheme: colorScheme
        )
        applySelectionToCanvasViews()
    }

    private func applySiteMode() {
        if siteModeControl.selectedSegment == 1 {
            displayedColumns = columnSummaries.filter(\.variable).map(\.index)
        } else {
            displayedColumns = Array(0..<columnSummaries.count)
        }

        if let selectedAlignmentColumn, !displayedColumns.contains(selectedAlignmentColumn) {
            self.selectedAlignmentColumn = displayedColumns.first
        } else if selectedAlignmentColumn == nil {
            selectedAlignmentColumn = displayedColumns.first
        }

        configureCanvasViews()
        scrollSelectionIntoView()
    }

    private func performSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        if let requestedColumn = Int(query), requestedColumn > 0, requestedColumn <= columnSummaries.count {
            let column = requestedColumn - 1
            if !displayedColumns.contains(column) {
                siteModeControl.selectedSegment = 0
                applySiteMode()
            }
            select(row: selectedRowIndex ?? 0, alignmentColumn: column)
            return
        }

        let lowerQuery = query.lowercased()
        if let rowIndex = alignmentRows.firstIndex(where: { $0.name.lowercased().contains(lowerQuery) }) {
            select(row: rowIndex, alignmentColumn: selectedAlignmentColumn ?? displayedColumns.first)
        }
    }

    private func moveVariableSelection(direction: Int) {
        let variableColumns = columnSummaries.filter(\.variable).map(\.index)
        guard !variableColumns.isEmpty else { return }
        let current = selectedAlignmentColumn ?? variableColumns[0]
        let currentIndex = variableColumns.firstIndex(of: current) ?? (direction > 0 ? -1 : variableColumns.count)
        let nextIndex = min(max(currentIndex + direction, 0), variableColumns.count - 1)
        if siteModeControl.selectedSegment != 1 {
            siteModeControl.selectedSegment = 1
            applySiteMode()
        }
        select(row: selectedRowIndex ?? 0, alignmentColumn: variableColumns[nextIndex])
    }

    private func select(row: Int, alignmentColumn: Int?) {
        guard row >= 0, row < alignmentRows.count else { return }
        if let alignmentColumn {
            select(rowRange: row...row, alignmentColumnRange: alignmentColumn...alignmentColumn)
        } else {
            selectedRowIndex = row
            selectedAlignmentColumn = nil
            selectedRowRange = row...row
            selectedAlignmentColumnRange = nil
            selectionAnchor = nil
            applySelectionToCanvasViews()
            scrollSelectionIntoView()
            refreshAnnotationDrawer()
            notifySelectionStateIfAvailable()
        }
    }

    private func select(rowRange: ClosedRange<Int>, alignmentColumnRange: ClosedRange<Int>) {
        guard alignmentRows.indices.contains(rowRange.lowerBound),
              alignmentRows.indices.contains(rowRange.upperBound) else { return }
        let normalizedColumnRange = min(alignmentColumnRange.lowerBound, alignmentColumnRange.upperBound)...max(alignmentColumnRange.lowerBound, alignmentColumnRange.upperBound)
        selectedRowIndex = rowRange.lowerBound
        selectedAlignmentColumn = normalizedColumnRange.lowerBound
        selectedRowRange = rowRange
        selectedAlignmentColumnRange = normalizedColumnRange
        selectionAnchor = (rowRange.lowerBound, normalizedColumnRange.lowerBound)
        applySelectionToCanvasViews()
        scrollSelectionIntoView()
        refreshAnnotationDrawer()
        notifySelectionStateIfAvailable()
    }

    private func moveActiveCell(
        _ direction: MultipleSequenceAlignmentNavigationDirection,
        extendingSelection: Bool = false
    ) {
        guard !alignmentRows.isEmpty, !displayedColumns.isEmpty else { return }
        let currentRow = selectedRowIndex ?? 0
        let currentColumn = selectedAlignmentColumn ?? displayedColumns[0]
        let currentDisplayColumn = displayedColumns.firstIndex(of: currentColumn) ?? 0
        let rowStep = pageRowStep()

        let targetRow: Int
        let targetDisplayColumn: Int
        switch direction {
        case .up:
            targetRow = currentRow - 1
            targetDisplayColumn = currentDisplayColumn
        case .down:
            targetRow = currentRow + 1
            targetDisplayColumn = currentDisplayColumn
        case .left:
            targetRow = currentRow
            targetDisplayColumn = currentDisplayColumn - 1
        case .right:
            targetRow = currentRow
            targetDisplayColumn = currentDisplayColumn + 1
        case .home:
            targetRow = currentRow
            targetDisplayColumn = 0
        case .end:
            targetRow = currentRow
            targetDisplayColumn = displayedColumns.count - 1
        case .pageUp:
            targetRow = currentRow - rowStep
            targetDisplayColumn = currentDisplayColumn
        case .pageDown:
            targetRow = currentRow + rowStep
            targetDisplayColumn = currentDisplayColumn
        }

        let clampedRow = min(max(targetRow, 0), alignmentRows.count - 1)
        let clampedDisplayColumn = min(max(targetDisplayColumn, 0), displayedColumns.count - 1)
        let targetColumn = displayedColumns[clampedDisplayColumn]

        if extendingSelection {
            let anchor = selectionAnchor ?? (currentRow, currentColumn)
            let rowRange = min(anchor.row, clampedRow)...max(anchor.row, clampedRow)
            let columnRange = min(anchor.alignmentColumn, targetColumn)...max(anchor.alignmentColumn, targetColumn)
            selectedRowIndex = clampedRow
            selectedAlignmentColumn = targetColumn
            selectedRowRange = rowRange
            selectedAlignmentColumnRange = columnRange
            selectionAnchor = anchor
            applySelectionToCanvasViews()
            scrollSelectionIntoView()
            refreshAnnotationDrawer()
            notifySelectionStateIfAvailable()
        } else {
            select(rowRange: clampedRow...clampedRow, alignmentColumnRange: targetColumn...targetColumn)
        }
    }

    private func pageRowStep() -> Int {
        let visibleHeight = alignmentScrollView.contentView.bounds.height
        guard visibleHeight > 0 else { return 10 }
        return max(1, Int(floor(visibleHeight / MSAAlignmentCanvasMetrics.rowHeight)))
    }

    private func selectionContains(row: Int, alignmentColumn: Int) -> Bool {
        guard let rowRange = selectedRowRange,
              let columnRange = selectedAlignmentColumnRange else {
            return false
        }
        return rowRange.contains(row) && columnRange.contains(alignmentColumn)
    }

    func notifySelectionStateIfAvailable() {
        onSelectionStateChanged?(selectionState())
    }

    private func selectionState() -> MultipleSequenceAlignmentSelectionState? {
        guard let rowIndex = selectedRowIndex,
              let column = selectedAlignmentColumn,
              alignmentRows.indices.contains(rowIndex),
              alignmentRows[rowIndex].sequence.indices.contains(column),
              columnSummaries.indices.contains(column) else {
            return nil
        }

        let row = alignmentRows[rowIndex]
        let residue = String(row.sequence[column])
        let summary = columnSummaries[column]
        let countsText = summary.residueCounts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? String(lhs.key) < String(rhs.key) : lhs.value > rhs.value
            }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        let siteKind = summary.variable
            ? (summary.parsimonyInformative ? "parsimony-informative variable site" : "variable site")
            : "conserved site"
        var detailRows: [(String, String)] = [
                ("Alignment Column", "\(column + 1)"),
                ("Residue", residue),
                ("Consensus", String(displayedConsensusResidue(for: summary))),
                ("Site", siteKind),
                ("Conservation", Self.percent(summary.conservation)),
                ("Gaps", Self.percent(summary.gapFraction)),
                ("Counts", countsText.isEmpty ? "none" : countsText),
        ]
        if let referenceRowIndex = referenceRowIndex(),
           let referenceRow = alignmentRows[safe: referenceRowIndex],
           let referenceResidue = referenceRow.sequence[safe: column] {
            detailRows.insert(("Reference", "\(referenceRow.name) \(referenceResidue)"), at: 3)
        }
        if let rowID = rowIDsByIndex[safe: rowIndex],
           let coordinateMap = coordinateMapsByRowID[rowID],
           coordinateMap.alignmentToUngapped.indices.contains(column) {
            let ungapped = coordinateMap.alignmentToUngapped[column].map { "\($0 + 1)" } ?? "gap"
            detailRows.insert(("Ungapped Coordinate", ungapped), at: 1)
        }
        if let rowRange = selectedRowRange,
           let columnRange = selectedAlignmentColumnRange,
           (rowRange.count > 1 || columnRange.count > 1) {
            detailRows.insert(("Selection", "\(rowRange.count) row\(rowRange.count == 1 ? "" : "s"), columns \(columnRange.lowerBound + 1)-\(columnRange.upperBound + 1)"), at: 0)
        }
        return MultipleSequenceAlignmentSelectionState(
            title: selectedSelectionTitle(),
            subtitle: "column \(column + 1) • residue \(residue)",
            detailRows: detailRows
        )
    }

    private func applySelectionToCanvasViews() {
        rowGutterView.selectedRowIndex = selectedRowIndex
        rowGutterView.selectedRowRange = selectedRowRange
        columnHeaderView.selectedAlignmentColumn = selectedAlignmentColumn
        columnHeaderView.selectedAlignmentColumnRange = selectedAlignmentColumnRange
        alignmentMatrixView.selectedRowIndex = selectedRowIndex
        alignmentMatrixView.selectedAlignmentColumn = selectedAlignmentColumn
        alignmentMatrixView.selectedRowRange = selectedRowRange
        alignmentMatrixView.selectedAlignmentColumnRange = selectedAlignmentColumnRange
        alignmentMatrixView.updateAccessibilityOverlays()
        rowGutterView.needsDisplay = true
        columnHeaderView.needsDisplay = true
        alignmentMatrixView.needsDisplay = true
    }

    private func scrollSelectionIntoView() {
        guard let row = selectedRowIndex,
              let column = selectedAlignmentColumn,
              let rect = alignmentMatrixView.rectFor(row: row, alignmentColumn: column) else {
            return
        }
        alignmentMatrixView.scrollToVisible(rect.insetBy(dx: -40, dy: -16))
    }

    private func setAlignmentColumnWidth(
        _ requestedWidth: CGFloat,
        centeredOnDisplayColumn displayColumn: Int?
    ) {
        let clampedWidth = min(
            MSAAlignmentCanvasMetrics.maximumColumnWidth,
            max(MSAAlignmentCanvasMetrics.minimumOverviewColumnWidth, requestedWidth)
        )
        guard abs(clampedWidth - alignmentColumnWidth) > 0.001 else { return }
        let centerDisplayColumn = displayColumn
            ?? selectedAlignmentColumn.flatMap { displayedColumns.firstIndex(of: $0) }
            ?? visibleCenterDisplayColumn()

        alignmentColumnWidth = clampedWidth
        configureCanvasViews()
        if let centerDisplayColumn {
            self.centerDisplayColumn(centerDisplayColumn)
        }
    }

    private func effectiveVisibleMatrixWidth() -> CGFloat {
        let clipWidth = alignmentScrollView.contentView.bounds.width
        if clipWidth > 0 {
            return clipWidth
        }
        return max(320, view.bounds.width - MSAAlignmentCanvasMetrics.rowGutterWidth)
    }

    private func visibleCenterDisplayColumn() -> Int? {
        guard !displayedColumns.isEmpty else { return nil }
        let bounds = alignmentScrollView.contentView.bounds
        let x = bounds.width > 0 ? bounds.midX : 0
        let rawDisplayColumn = x / max(alignmentColumnWidth, MSAAlignmentCanvasMetrics.minimumOverviewColumnWidth)
        return min(max(Int(rawDisplayColumn.rounded()), 0), displayedColumns.count - 1)
    }

    private func centerDisplayColumn(_ displayColumn: Int) {
        guard displayedColumns.indices.contains(displayColumn),
              let documentView = alignmentScrollView.documentView else {
            return
        }
        let clipView = alignmentScrollView.contentView
        let visibleWidth = effectiveVisibleMatrixWidth()
        let maxX = max(0, documentView.bounds.width - visibleWidth)
        let targetMidX = CGFloat(displayColumn) * alignmentColumnWidth + alignmentColumnWidth / 2
        let x = min(max(targetMidX - visibleWidth / 2, 0), maxX)
        clipView.setBoundsOrigin(NSPoint(x: x, y: clipView.bounds.origin.y))
        alignmentScrollView.reflectScrolledClipView(clipView)
        alignmentClipViewBoundsDidChange(Notification(name: NSView.boundsDidChangeNotification, object: clipView))
    }

    private func selectedSelectionTitle() -> String {
        guard let rowRange = selectedRowRange else {
            return selectedRowIndex.flatMap { alignmentRows[safe: $0]?.name } ?? "Alignment selection"
        }
        if rowRange.count == 1, let rowIndex = rowRange.first {
            return alignmentRows[safe: rowIndex]?.name ?? "Alignment selection"
        }
        return "\(rowRange.count) rows"
    }

    private func displayedConsensusResidues() -> [Character] {
        columnSummaries.map { displayedConsensusResidue(for: $0) }
    }

    private func displayedConsensusResidue(for summary: MSAColumnSummary) -> Character {
        let shouldMask = summary.conservation < consensusDisplayOptions.lowSupportThreshold
            || summary.gapFraction >= consensusDisplayOptions.highGapThreshold
        if shouldMask {
            return consensusDisplayOptions.maskSymbolMode.symbol(alphabet: bundle?.manifest.alphabet ?? "")
        }
        return summary.consensus
    }

    private func referenceRowIndex() -> Int? {
        guard let referenceRowID else { return nil }
        return rowIDsByIndex.firstIndex(of: referenceRowID)
    }

    private func displayedResidue(rowIndex: Int, alignmentColumn: Int) -> Character? {
        guard let residue = alignmentRows[safe: rowIndex]?.sequence[safe: alignmentColumn] else {
            return nil
        }
        switch residueIdentityDisplayMode {
        case .letters:
            return residue
        case .dotsToConsensus:
            guard let consensus = displayedConsensusResidues()[safe: alignmentColumn] else { return residue }
            return residuesMatch(residue, consensus) ? "." : residue
        case .dotsToReference:
            guard let referenceRowIndex = referenceRowIndex(),
                  let referenceResidue = alignmentRows[safe: referenceRowIndex]?.sequence[safe: alignmentColumn] else {
                return residue
            }
            return residuesMatch(residue, referenceResidue) ? "." : residue
        }
    }

    private func residuesMatch(_ lhs: Character, _ rhs: Character) -> Bool {
        String(lhs).uppercased() == String(rhs).uppercased()
    }

    private func refreshAnnotationDrawer() {
        let rows = annotationDrawerRows()
        drawerAnnotationByResultID = Dictionary(uniqueKeysWithValues: rows.map { ($0.result.id, $0.annotation) })
        annotationDrawer.setAnnotations(rows.map(\.result))
    }

    private func refreshAnnotationTracks() {
        annotationTracks = annotationStore.allAnnotations.compactMap { annotation in
            let rowIndex = rowIDsByIndex.firstIndex(of: annotation.rowID)
                ?? alignmentRows.firstIndex { $0.name == annotation.rowName }
            guard let rowIndex else { return nil }
            return MSAAlignmentAnnotationTrack(annotation: annotation, rowIndex: rowIndex)
        }
        alignmentMatrixView.annotationTracks = annotationTracks
        alignmentMatrixView.updateAccessibilityOverlays()
        alignmentMatrixView.needsDisplay = true
    }

    private func annotationDrawerRows() -> [(result: AnnotationSearchIndex.SearchResult, annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord)] {
        annotationStore.allAnnotations.map { annotation in
            let resultID = UUID()
            return (
                AnnotationSearchIndex.SearchResult(
                    id: resultID,
                    name: annotation.name,
                    chromosome: annotation.rowName,
                    start: annotation.sourceIntervals.map(\.start).min() ?? 0,
                    end: annotation.sourceIntervals.map(\.end).max() ?? 0,
                    trackId: annotation.sourceTrackID,
                    type: annotation.type,
                    strand: annotation.strand,
                    attributes: drawerAttributes(for: annotation)
                ),
                annotation
            )
        }
    }

    private func drawerAttributes(
        for annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord
    ) -> [String: String] {
        var attributes = annotation.qualifiers.mapValues { $0.joined(separator: ", ") }
        attributes["source_coordinates"] = coordinateText(
            sequenceName: annotation.sourceSequenceName,
            intervals: annotation.sourceIntervals
        )
        attributes["alignment_columns"] = intervalText(annotation.alignedIntervals, oneBased: true)
        attributes["consensus_columns"] = intervalText(annotation.alignedIntervals, oneBased: true)
        attributes["alignment_row"] = annotation.rowName
        attributes["source_sequence"] = annotation.sourceSequenceName
        attributes["source_track"] = annotation.sourceTrackName
        attributes["origin"] = annotation.origin.rawValue
        return attributes
    }

    private func coordinateText(
        sequenceName: String,
        intervals: [AnnotationInterval]
    ) -> String {
        let spans = intervalText(intervals, oneBased: true)
        return spans.isEmpty ? sequenceName : "\(sequenceName):\(spans)"
    }

    private func intervalText(
        _ intervals: [AnnotationInterval],
        oneBased: Bool
    ) -> String {
        intervals.map { interval in
            let start = oneBased ? interval.start + 1 : interval.start
            return "\(start)-\(interval.end)"
        }.joined(separator: ",")
    }

    private func selectedAnnotations() -> [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord] {
        let allAnnotations = annotationStore.allAnnotations
        guard !allAnnotations.isEmpty else { return [] }
        guard let rowRange = selectedRowRange else { return allAnnotations }
        let selectedRowIDs = Set(rowRange.compactMap { rowIDsByIndex[safe: $0] })
        let columnRange = selectedAlignmentColumnRange
        return allAnnotations.filter { annotation in
            guard selectedRowIDs.contains(annotation.rowID) else { return false }
            guard let columnRange else { return true }
            return annotation.alignedIntervals.contains { interval in
                interval.start <= columnRange.upperBound && interval.end > columnRange.lowerBound
            }
        }
    }

    private func annotationContextMenu(
        for annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord
    ) -> NSMenu {
        let menu = NSMenu()
        let selectItem = NSMenuItem(title: "Select Annotation", action: #selector(selectAnnotationFromMenu(_:)), keyEquivalent: "")
        selectItem.target = self
        selectItem.representedObject = annotation
        menu.addItem(selectItem)

        let centerItem = NSMenuItem(title: "Center on Annotation", action: #selector(centerAnnotationFromMenu(_:)), keyEquivalent: "")
        centerItem.target = self
        centerItem.representedObject = annotation
        menu.addItem(centerItem)

        let zoomItem = NSMenuItem(title: "Zoom to Annotation", action: #selector(zoomAnnotationFromMenu(_:)), keyEquivalent: "")
        zoomItem.target = self
        zoomItem.representedObject = annotation
        menu.addItem(zoomItem)
        return menu
    }

    @objc private func selectAnnotationFromMenu(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord else { return }
        selectAnnotation(annotation, zoom: false)
    }

    @objc private func centerAnnotationFromMenu(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord else { return }
        selectAnnotation(annotation, zoom: false)
        centerAnnotation(annotation)
    }

    @objc private func zoomAnnotationFromMenu(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord else { return }
        selectAnnotation(annotation, zoom: true)
    }

    private func selectAnnotation(
        _ annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord,
        zoom: Bool
    ) {
        guard let rowIndex = rowIDsByIndex.firstIndex(of: annotation.rowID)
                ?? alignmentRows.firstIndex(where: { $0.name == annotation.rowName }),
              let columnRange = annotationAlignmentColumnRange(annotation) else {
            return
        }
        ensureColumnsAreDisplayed(columnRange)
        if zoom {
            zoomToAnnotation(annotation)
        }
        select(rowRange: rowIndex...rowIndex, alignmentColumnRange: columnRange)
        centerAnnotation(annotation)
    }

    private func annotationAlignmentColumnRange(
        _ annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord
    ) -> ClosedRange<Int>? {
        guard let start = annotation.alignedIntervals.map(\.start).min(),
              let end = annotation.alignedIntervals.map(\.end).max(),
              end > start else {
            return nil
        }
        return start...(end - 1)
    }

    private func ensureColumnsAreDisplayed(_ columnRange: ClosedRange<Int>) {
        guard displayedColumns.contains(columnRange.lowerBound),
              displayedColumns.contains(columnRange.upperBound) else {
            siteModeControl.selectedSegment = 0
            applySiteMode()
            return
        }
    }

    private func zoomToAnnotation(_ annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord) {
        guard let columnRange = annotationAlignmentColumnRange(annotation) else { return }
        let visibleWidth = max(320, alignmentScrollView.contentView.bounds.width, view.bounds.width - MSAAlignmentCanvasMetrics.rowGutterWidth)
        let targetWidth = min(
            MSAAlignmentCanvasMetrics.maximumAnnotationZoomColumnWidth,
            max(MSAAlignmentCanvasMetrics.defaultColumnWidth, floor((visibleWidth - 80) / CGFloat(max(columnRange.count, 1))))
        )
        guard targetWidth > alignmentColumnWidth else { return }
        alignmentColumnWidth = targetWidth
        configureCanvasViews()
    }

    private func centerAnnotation(_ annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord) {
        guard let rowIndex = rowIDsByIndex.firstIndex(of: annotation.rowID)
                ?? alignmentRows.firstIndex(where: { $0.name == annotation.rowName }),
              let columnRange = annotationAlignmentColumnRange(annotation),
              let startRect = alignmentMatrixView.rectFor(row: rowIndex, alignmentColumn: columnRange.lowerBound),
              let endRect = alignmentMatrixView.rectFor(row: rowIndex, alignmentColumn: columnRange.upperBound) else {
            return
        }
        let rect = startRect.union(endRect).insetBy(dx: -alignmentColumnWidth * 2, dy: -MSAAlignmentCanvasMetrics.rowHeight)
        centerMatrixRect(rect)
    }

    private func centerMatrixRect(_ rect: NSRect) {
        guard let documentView = alignmentScrollView.documentView else { return }
        let clipView = alignmentScrollView.contentView
        let visibleSize = clipView.bounds.size
        guard visibleSize.width > 0, visibleSize.height > 0 else {
            documentView.scrollToVisible(rect)
            return
        }
        let maxX = max(0, documentView.bounds.width - visibleSize.width)
        let maxY = max(0, documentView.bounds.height - visibleSize.height)
        let x = min(max(rect.midX - visibleSize.width / 2, 0), maxX)
        let y = min(max(rect.midY - visibleSize.height / 2, 0), maxY)
        clipView.setBoundsOrigin(NSPoint(x: x, y: y))
        alignmentScrollView.reflectScrolledClipView(clipView)
        alignmentClipViewBoundsDidChange(Notification(name: NSView.boundsDidChangeNotification, object: clipView))
    }

    private func selectionContextMenu() -> NSMenu {
        let menu = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: selectedFASTARecords().count,
            handlers: FASTASequenceActionHandlers(
                onExtractSequence: { [weak self] in self?.extractSelectedSequences() },
                onBlast: nil,
                onCopy: { [weak self] in self?.copySelectedFASTAToPasteboard() },
                onExport: { [weak self] in self?.exportSelectedSequences() },
                onCreateBundle: { [weak self] in self?.createBundleFromSelectedSequences() },
                onAlignWithMAFFT: nil,
                onRunOperation: nil
            )
        )
        let treeItem = NSMenuItem(
            title: "Build Tree with IQ-TREE…",
            action: #selector(inferTreeFromMenu(_:)),
            keyEquivalent: ""
        )
        treeItem.target = self
        treeItem.isEnabled = bundleURL != nil
        menu.addItem(treeItem)
        menu.addItem(.separator())
        let addAnnotationItem = NSMenuItem(
            title: "Add Annotation from Selection…",
            action: #selector(addAnnotationFromMenu(_:)),
            keyEquivalent: ""
        )
        addAnnotationItem.target = self
        menu.addItem(addAnnotationItem)
        let applyAnnotationItem = NSMenuItem(
            title: "Apply Annotation to Selected Rows",
            action: #selector(applyAnnotationFromMenu(_:)),
            keyEquivalent: ""
        )
        applyAnnotationItem.target = self
        applyAnnotationItem.isEnabled = selectedRowRange?.count ?? 0 > 1 && !selectedAnnotations().isEmpty
        menu.addItem(applyAnnotationItem)
        return menu
    }

    @objc private func addAnnotationFromMenu(_ sender: Any?) {
        presentAddAnnotationDialog(window: view.window)
    }

    @objc private func applyAnnotationFromMenu(_ sender: Any?) {
        do {
            try applySelectedAnnotationsToSelectedRows()
        } catch {
            presentError(error, title: "Apply Annotation Failed")
        }
    }

    @objc private func inferTreeFromMenu(_ sender: Any?) {
        inferTreeFromAlignment()
    }

    private func selectedFASTARecords() -> [String] {
        guard let rowRange = selectedRowRange,
              let selectedAlignmentColumn,
              alignmentRows.indices.contains(rowRange.lowerBound),
              alignmentRows.indices.contains(rowRange.upperBound) else {
            return []
        }
        let isBlock = rowRange.count > 1 || (selectedAlignmentColumnRange?.count ?? 1) > 1
        if !isBlock {
            let row = alignmentRows[rowRange.lowerBound]
            return [Self.fastaRecord(name: row.name, sequence: row.ungappedSequenceString)]
        }
        let columnRange = selectedAlignmentColumnRange ?? selectedAlignmentColumn...selectedAlignmentColumn
        return rowRange.compactMap { rowIndex in
            guard let row = alignmentRows[safe: rowIndex] else { return nil }
            let sliced = columnRange.compactMap { column in row.sequence[safe: column] }
            let ungapped = sliced.filter { Self.isGap($0) == false }.map(String.init).joined()
            let name = selectedFASTARecordName(row: row, columnRange: columnRange, isBlock: true)
            return Self.fastaRecord(name: name, sequence: ungapped)
        }
    }

    private func selectedFASTAName() -> String {
        guard let rowIndex = selectedRowIndex,
              alignmentRows.indices.contains(rowIndex) else {
            return bundle?.manifest.name ?? "alignment-selection"
        }
        return alignmentRows[rowIndex].name
    }

    private func extractSelectedSequences() {
        let records = selectedFASTARecords()
        guard !records.isEmpty else { return }
        let annotations = selectedExtractionAnnotationsByRecord()
        if !annotations.isEmpty {
            onExtractAnnotatedSequenceRequested?(records, selectedFASTAName(), annotations)
            return
        }
        onExtractSequenceRequested?(records, selectedFASTAName())
    }

    private func copySelectedFASTAToPasteboard() {
        let records = selectedFASTARecords()
        guard !records.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(records.joined(separator: ""), forType: .string)
    }

    private func exportSelectedSequences() {
        let records = selectedFASTARecords()
        guard !records.isEmpty else { return }
        if let request = selectedMSASelectionExportRequest(
            suggestedName: "\(selectedFASTAName()).fasta",
            outputKind: "fasta"
        ) {
            onExportMSASelectionRequested?(request)
            return
        }
        onExportFASTARequested?(records, "\(selectedFASTAName()).fasta")
    }

    private func selectedMSASelectionExportRequest(
        suggestedName: String,
        outputKind: String
    ) -> MultipleSequenceAlignmentSelectionExportRequest? {
        guard let bundleURL,
              let rowRange = selectedRowRange,
              alignmentRows.indices.contains(rowRange.lowerBound),
              alignmentRows.indices.contains(rowRange.upperBound) else {
            return nil
        }
        let rowIDs = rowRange.compactMap { rowIDsByIndex[safe: $0] }
        guard rowIDs.isEmpty == false else { return nil }

        let isBlock = rowRange.count > 1 || (selectedAlignmentColumnRange?.count ?? 1) > 1
        let columns: String?
        if isBlock, let columnRange = selectedAlignmentColumnRange {
            columns = "\(columnRange.lowerBound + 1)-\(columnRange.upperBound + 1)"
        } else {
            columns = nil
        }

        return MultipleSequenceAlignmentSelectionExportRequest(
            bundleURL: bundleURL,
            outputKind: outputKind,
            rows: rowIDs.joined(separator: ","),
            columns: columns,
            suggestedName: suggestedName,
            displayName: selectedFASTAName()
        )
    }

    private func createBundleFromSelectedSequences() {
        let records = selectedFASTARecords()
        guard !records.isEmpty else { return }
        if let request = selectedMSASelectionExportRequest(
            suggestedName: "\(selectedFASTAName()).lungfishref",
            outputKind: "reference"
        ) {
            onExportMSASelectionRequested?(request)
            return
        }
        let annotations = selectedExtractionAnnotationsByRecord()
        if !annotations.isEmpty {
            onCreateAnnotatedBundleRequested?(records, selectedFASTAName(), annotations)
            return
        }
        onCreateBundleRequested?(records, selectedFASTAName())
    }

    private func runOperationOnSelectedSequences() {
        let records = selectedFASTARecords()
        guard !records.isEmpty else { return }
        onRunOperationRequested?(records, selectedFASTAName())
    }

    private func inferTreeFromAlignment() {
        guard let bundleURL else { return }
        let displayName = bundle?.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? bundle?.manifest.name ?? bundleURL.deletingPathExtension().lastPathComponent
            : bundleURL.deletingPathExtension().lastPathComponent
        let selectedRows: String?
        if let selectedRowRange, selectedRowRange.count > 1 {
            let rowIDs = selectedRowRange.compactMap { rowIDsByIndex[safe: $0] }
            selectedRows = rowIDs.isEmpty ? nil : rowIDs.joined(separator: ",")
        } else {
            selectedRows = nil
        }
        let selectedColumns: String?
        if let columnRange = selectedAlignmentColumnRange, columnRange.count > 1 {
            selectedColumns = "\(columnRange.lowerBound + 1)-\(columnRange.upperBound + 1)"
        } else {
            selectedColumns = nil
        }
        onInferTreeRequested?(
            MultipleSequenceAlignmentTreeInferenceRequest(
                bundleURL: bundleURL,
                rows: selectedRows,
                columns: selectedColumns,
                suggestedName: "\(displayName).lungfishtree",
                displayName: displayName
            )
        )
    }

    private static func fastaRecord(name: String, sequence: String) -> String {
        ">\(name)\n\(sequence)\n"
    }

    func presentAddAnnotationDialog(window: NSWindow?) {
        guard selectedRowRange?.count == 1,
              selectedAlignmentColumnRange != nil else {
            presentErrorMessage(
                title: "No Alignment Range",
                message: "Select one row and one or more alignment columns before adding an annotation."
            )
            return
        }
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Add Annotation"
        alert.informativeText = "Add an annotation for the selected alignment range."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 82))
        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 54, width: 66, height: 20)
        accessoryView.addSubview(nameLabel)
        let nameField = NSTextField(frame: NSRect(x: 72, y: 52, width: 236, height: 24))
        nameField.placeholderString = "Annotation name"
        accessoryView.addSubview(nameField)

        let typeLabel = NSTextField(labelWithString: "Type:")
        typeLabel.frame = NSRect(x: 0, y: 18, width: 66, height: 20)
        accessoryView.addSubview(typeLabel)
        let typePopup = NSPopUpButton(frame: NSRect(x: 72, y: 16, width: 236, height: 24))
        typePopup.addItems(withTitles: ["gene", "CDS", "exon", "mRNA", "region", "misc_feature", "primer"])
        accessoryView.addSubview(typePopup)
        alert.accessoryView = accessoryView

        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            let response = await alert.beginSheetModal(for: window)
            guard response == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try self.addAnnotationFromSelection(
                    name: name.isEmpty ? "New Annotation" : name,
                    type: typePopup.selectedItem?.title ?? "region"
                )
            } catch {
                self.presentError(error, title: "Add Annotation Failed")
            }
        }
    }

    @discardableResult
    private func addAnnotationFromSelection(
        name: String,
        type: String,
        strand: String = "."
    ) throws -> MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord? {
        guard let bundle,
              let rowIndex = selectedRowRange?.lowerBound,
              selectedRowRange?.count == 1,
              let rowID = rowIDsByIndex[safe: rowIndex],
              let columnRange = selectedAlignmentColumnRange else {
            throw MultipleSequenceAlignmentBundle.ImportError.malformedInput("Select one row and one or more alignment columns.")
        }
        if let onAddAnnotationRequested, let bundleURL {
            let columns = "\(columnRange.lowerBound + 1)-\(columnRange.upperBound + 1)"
            onAddAnnotationRequested(
                MultipleSequenceAlignmentAnnotationAddRequest(
                    bundleURL: bundleURL,
                    row: rowID,
                    columns: columns,
                    name: name,
                    type: type,
                    strand: strand,
                    note: nil,
                    qualifiers: ["created_by=lungfish-gui"],
                    displayName: name
                )
            )
            return nil
        }
        let annotation = try bundle.makeAnnotationFromAlignedSelection(
            rowID: rowID,
            alignedIntervals: [AnnotationInterval(start: columnRange.lowerBound, end: columnRange.upperBound + 1)],
            name: name,
            type: type,
            strand: strand,
            qualifiers: ["created_by": ["lungfish-gui"]]
        )
        let updatedBundle = try bundle.appendingAnnotations(
            [annotation],
            editDescription: "Add annotation from MSA selection",
            argv: ["lungfish-gui", "msa", "add-annotation", bundle.url.path, "--row", rowID, "--columns", "\(columnRange.lowerBound + 1)-\(columnRange.upperBound + 1)"]
        )
        self.bundle = updatedBundle
        annotationStore = try updatedBundle.loadAnnotationStore()
        refreshAnnotationTracks()
        configureCanvasViews()
        refreshAnnotationDrawer()
        notifySelectionStateIfAvailable()
        return annotation
    }

    @discardableResult
    func applySelectedAnnotationsToSelectedRows() throws -> [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord] {
        guard let bundle,
              let rowRange = selectedRowRange,
              rowRange.count > 1 else {
            return []
        }
        let selectedRowIDs = rowRange.compactMap { rowIDsByIndex[safe: $0] }
        let selectedRowIDSet = Set(selectedRowIDs)
        let annotationsToProject = selectedAnnotations()
            .filter { selectedRowIDSet.contains($0.rowID) }
        guard !annotationsToProject.isEmpty else { return [] }

        if let onProjectAnnotationRequested, let bundleURL {
            for annotation in annotationsToProject {
                let targetRows = selectedRowIDs
                    .filter { $0 != annotation.rowID }
                    .joined(separator: ",")
                guard targetRows.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { continue }
                onProjectAnnotationRequested(
                    MultipleSequenceAlignmentAnnotationProjectionRequest(
                        bundleURL: bundleURL,
                        sourceAnnotationID: annotation.id,
                        targetRows: targetRows,
                        conflictPolicy: MultipleSequenceAlignmentBundle.AnnotationProjectionConflictPolicy.append.rawValue,
                        displayName: annotation.name
                    )
                )
            }
            return []
        }

        var projected: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord] = []
        var seen = Set<String>()
        for annotation in annotationsToProject {
            for targetRowID in selectedRowIDs where targetRowID != annotation.rowID {
                guard let targetMap = coordinateMapsByRowID[targetRowID] else { continue }
                let projection = MultipleSequenceAlignmentBundle.projectAnnotation(
                    annotation,
                    to: targetMap,
                    conflictPolicy: .append
                )
                guard !projection.sourceIntervals.isEmpty else { continue }
                guard seen.insert(projection.id).inserted else { continue }
                projected.append(projection)
            }
        }
        guard !projected.isEmpty else { return [] }
        let updatedBundle = try bundle.appendingAnnotations(
            projected,
            editDescription: "Apply MSA annotation to selected rows",
            argv: ["lungfish-gui", "msa", "apply-annotation", bundle.url.path]
        )
        self.bundle = updatedBundle
        annotationStore = try updatedBundle.loadAnnotationStore()
        refreshAnnotationTracks()
        configureCanvasViews()
        refreshAnnotationDrawer()
        notifySelectionStateIfAvailable()
        return projected
    }

    private func selectedExtractionAnnotationsByRecord() -> [String: [SequenceAnnotation]] {
        guard let rowRange = selectedRowRange,
              alignmentRows.indices.contains(rowRange.lowerBound),
              alignmentRows.indices.contains(rowRange.upperBound) else {
            return [:]
        }
        let columnRange = selectedAlignmentColumnRange
        let isBlock = rowRange.count > 1 || (columnRange?.count ?? 1) > 1
        var result: [String: [SequenceAnnotation]] = [:]
        for rowIndex in rowRange {
            guard let row = alignmentRows[safe: rowIndex],
                  let rowID = rowIDsByIndex[safe: rowIndex] else { continue }
            let recordName = selectedFASTARecordName(row: row, columnRange: columnRange, isBlock: isBlock)
            let rowAnnotations = annotationStore.allAnnotations
                .filter { $0.rowID == rowID }
                .compactMap { annotation -> SequenceAnnotation? in
                    let intervals: [AnnotationInterval]
                    if let columnRange, isBlock {
                        intervals = localIntervals(
                            for: annotation.alignedIntervals,
                            row: row,
                            columnRange: columnRange
                        )
                    } else {
                        intervals = annotation.sourceIntervals
                    }
                    guard !intervals.isEmpty else { return nil }
                    return SequenceAnnotation(
                        type: AnnotationType(rawValue: annotation.type) ?? .custom,
                        name: annotation.name,
                        chromosome: recordName,
                        intervals: intervals,
                        strand: Strand(rawValue: annotation.strand) ?? .unknown,
                        qualifiers: annotation.qualifiers.mapValues { AnnotationQualifier($0) },
                        note: annotation.note
                    )
                }
            if !rowAnnotations.isEmpty {
                result[recordName] = rowAnnotations
            }
        }
        return result
    }

    private func selectedFASTARecordName(
        row: MSAAlignmentSequence,
        columnRange: ClosedRange<Int>?,
        isBlock: Bool
    ) -> String {
        guard isBlock, let columnRange else { return row.name }
        return "\(row.name)_columns_\(columnRange.lowerBound + 1)-\(columnRange.upperBound + 1)"
    }

    private func localIntervals(
        for alignedIntervals: [AnnotationInterval],
        row: MSAAlignmentSequence,
        columnRange: ClosedRange<Int>
    ) -> [AnnotationInterval] {
        var localCoordinateByAlignmentColumn: [Int: Int] = [:]
        var localCoordinate = 0
        for column in columnRange {
            guard let residue = row.sequence[safe: column] else { continue }
            if Self.isGap(residue) { continue }
            localCoordinateByAlignmentColumn[column] = localCoordinate
            localCoordinate += 1
        }

        var selectedLocalCoordinates: [Int] = []
        for interval in alignedIntervals {
            let lower = max(interval.start, columnRange.lowerBound)
            let upper = min(interval.end, columnRange.upperBound + 1)
            guard lower < upper else { continue }
            for column in lower..<upper {
                if let local = localCoordinateByAlignmentColumn[column] {
                    selectedLocalCoordinates.append(local)
                }
            }
        }
        return Self.collapseCoordinatesToIntervals(selectedLocalCoordinates)
    }

    private static func collapseCoordinatesToIntervals(_ coordinates: [Int]) -> [AnnotationInterval] {
        let sorted = Array(Set(coordinates)).sorted()
        guard let first = sorted.first else { return [] }
        var intervals: [AnnotationInterval] = []
        var start = first
        var previous = first
        for coordinate in sorted.dropFirst() {
            if coordinate == previous + 1 {
                previous = coordinate
            } else {
                intervals.append(AnnotationInterval(start: start, end: previous + 1))
                start = coordinate
                previous = coordinate
            }
        }
        intervals.append(AnnotationInterval(start: start, end: previous + 1))
        return intervals
    }

    private func presentError(_ error: Error, title: String) {
        presentErrorMessage(title: title, message: error.localizedDescription)
    }

    private func presentErrorMessage(title: String, message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private static func parseAlignedFASTA(_ text: String) throws -> [MSAAlignmentSequence] {
        var rows: [MSAAlignmentSequence] = []
        var currentName: String?
        var currentSequence = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                if let currentName {
                    rows.append(MSAAlignmentSequence(name: currentName, sequence: Array(currentSequence)))
                }
                currentName = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                currentSequence = ""
            } else {
                currentSequence += line.filter { !$0.isWhitespace }
            }
        }
        if let currentName {
            rows.append(MSAAlignmentSequence(name: currentName, sequence: Array(currentSequence)))
        }
        guard !rows.isEmpty else {
            throw NSError(
                domain: "MultipleSequenceAlignmentViewController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Alignment bundle contains no renderable rows."]
            )
        }
        let lengths = Set(rows.map(\.sequence.count))
        guard lengths.count == 1 else {
            throw NSError(
                domain: "MultipleSequenceAlignmentViewController",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Alignment rows have inconsistent lengths."]
            )
        }
        return rows
    }

    private static func computeColumnSummaries(for rows: [MSAAlignmentSequence]) -> [MSAColumnSummary] {
        guard let alignedLength = rows.first?.sequence.count else { return [] }
        return (0..<alignedLength).map { column in
            var counts: [Character: Int] = [:]
            var gapCount = 0
            for row in rows {
                let residue = Character(String(row.sequence[column]).uppercased())
                if isGap(residue) {
                    gapCount += 1
                } else {
                    counts[residue, default: 0] += 1
                }
            }
            let nonGapTotal = counts.values.reduce(0, +)
            let consensus = counts.sorted { lhs, rhs in
                lhs.value == rhs.value ? String(lhs.key) < String(rhs.key) : lhs.value > rhs.value
            }.first?.key ?? "-"
            let maxCount = counts.values.max() ?? 0
            let informativeResidues = counts.values.filter { $0 >= 2 }.count
            return MSAColumnSummary(
                index: column,
                consensus: consensus,
                residueCounts: counts,
                gapFraction: rows.isEmpty ? 0 : Double(gapCount) / Double(rows.count),
                conservation: nonGapTotal == 0 ? 0 : Double(maxCount) / Double(nonGapTotal),
                variable: counts.count > 1,
                parsimonyInformative: informativeResidues >= 2
            )
        }
    }

    private static func isGap(_ residue: Character) -> Bool {
        residue == "-" || residue == "."
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

extension MultipleSequenceAlignmentViewController: AnnotationTableDrawerDelegate {
    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        didSelectAnnotation result: AnnotationSearchIndex.SearchResult
    ) {
        guard let annotation = drawerAnnotationByResultID[result.id] else { return }
        selectAnnotation(annotation, zoom: false)
    }

    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        didRequestExtract annotations: [SequenceAnnotation]
    ) {
        var records: [String] = []
        var extractedAnnotations: [String: [SequenceAnnotation]] = [:]
        for annotation in annotations {
            guard let rowName = annotation.chromosome,
                  let row = alignmentRows.first(where: { $0.name == rowName }) else { continue }
            let sequence = row.ungappedSequenceString
            let intervals = annotation.intervals
            let extracted = intervals.compactMap { interval -> String? in
                guard interval.start >= 0,
                      interval.end <= sequence.count,
                      interval.end > interval.start else { return nil }
                let startIndex = sequence.index(sequence.startIndex, offsetBy: interval.start)
                let endIndex = sequence.index(sequence.startIndex, offsetBy: interval.end)
                return String(sequence[startIndex..<endIndex])
            }.joined()
            guard !extracted.isEmpty else { continue }

            let recordName = "\(rowName)_\(Self.sanitizedFASTAComponent(annotation.name))"
            records.append(Self.fastaRecord(name: recordName, sequence: extracted))
            extractedAnnotations[recordName] = [
                SequenceAnnotation(
                    type: annotation.type,
                    name: annotation.name,
                    chromosome: recordName,
                    intervals: Self.rebasedIntervals(intervals),
                    strand: annotation.strand,
                    qualifiers: annotation.qualifiers,
                    note: annotation.note
                ),
            ]
        }
        guard !records.isEmpty else { return }
        onExtractAnnotatedSequenceRequested?(
            records,
            bundle?.manifest.name ?? "alignment-annotations",
            extractedAnnotations
        )
    }

    func annotationDrawerSelectedSequenceRegion(
        _ drawer: AnnotationTableDrawerView
    ) -> AnnotationTableDrawerSelectionRegion? {
        nil
    }

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int) {}

    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        didResolveGeneRegions regions: [GeneRegion]
    ) {}

    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        didUpdateVisibleVariantRenderKeys keys: Set<String>?
    ) {}

    func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {
        guard let heightConstraint = annotationDrawerHeightConstraint else { return }
        let availableHeight = max(160, view.bounds.height - 140)
        heightConstraint.constant = min(max(heightConstraint.constant + deltaY, 96), availableHeight)
        view.layoutSubtreeIfNeeded()
    }

    func annotationDrawerDidFinishDraggingDivider(_ drawer: AnnotationTableDrawerView) {}

    private static func sanitizedFASTAComponent(_ value: String) -> String {
        let replaced = value.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+",
            with: "_",
            options: .regularExpression
        )
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "annotation" : trimmed
    }

    private static func rebasedIntervals(_ intervals: [AnnotationInterval]) -> [AnnotationInterval] {
        var offset = 0
        return intervals.map { interval in
            let length = max(0, interval.end - interval.start)
            defer { offset += length }
            return AnnotationInterval(start: offset, end: offset + length)
        }
    }
}

extension MultipleSequenceAlignmentViewController {
    var testingRenderedRowNames: [String] {
        alignmentRows.map(\.name)
    }

    var testingDisplayedAlignmentColumnCount: Int {
        displayedColumns.count
    }

    var testingConsensusPreview: String {
        columnSummaries.map(\.consensus).map(String.init).joined()
    }

    var testingConsensusDisplayPreview: String {
        displayedConsensusResidues().map(String.init).joined()
    }

    var testingConsensusNumberingPreview: [String] {
        columnHeaderView.testingNumberingPreview
    }

    var testingConsensusAccessibilityLabel: String? {
        columnHeaderView.accessibilityLabel()
    }

    var testingReferenceRowName: String? {
        referenceRowIndex().flatMap { alignmentRows[safe: $0]?.name }
    }

    var testingSelectedRowName: String? {
        if let rowRange = selectedRowRange, rowRange.count > 1 {
            return "\(rowRange.count) rows"
        }
        return selectedRowIndex.flatMap { alignmentRows[safe: $0]?.name }
    }

    var testingSelectedAlignmentColumn: Int? {
        selectedAlignmentColumn.map { $0 + 1 }
    }

    var testingSelectedAlignmentColumnRange: ClosedRange<Int>? {
        selectedAlignmentColumnRange.map { ($0.lowerBound + 1)...($0.upperBound + 1) }
    }

    var testingAlignmentColumnWidth: CGFloat {
        alignmentColumnWidth
    }

    var testingZoomRenderingMode: String {
        alignmentMatrixView.testingZoomRenderingModeTitle
    }

    func testingVisibleDisplayColumnRangeDescription(for dirtyRect: NSRect) -> String {
        alignmentMatrixView.testingVisibleDisplayColumnRangeDescription(for: dirtyRect)
    }

    func testingVisibleOrientationNumberingPreview(width: CGFloat) -> [String] {
        columnHeaderView.testingVisibleOrientationNumberingPreview(width: width)
    }

    var testingOverviewSignalSummary: String {
        overviewSignalView.summaryText
    }

    var testingColorSchemeName: String {
        colorScheme.title
    }

    var testingNumberingModeTitle: String {
        numberingMode.displayTitle
    }

    var testingColumnHeaderNumberingVisible: Bool {
        columnHeaderView.testingNumberingVisible
    }

    var testingRowNumberingPreview: [String] {
        rowGutterView.testingNumberingPreview
    }

    var testingAnnotationTrackRows: [String] {
        annotationTracks.map { track in
            let columns = intervalText(track.annotation.alignedIntervals, oneBased: true)
            return "\(track.rowName)\t\(track.trackName)\t\(track.name)\t\(columns)"
        }
    }

    var testingSelectedResidue: String? {
        guard let row = selectedRowIndex,
              let column = selectedAlignmentColumn,
              alignmentRows.indices.contains(row),
              alignmentRows[row].sequence.indices.contains(column) else {
            return nil
        }
        return String(alignmentRows[row].sequence[column])
    }

    var testingSelectionContextMenuTitles: [String] {
        selectionContextMenu().items.map(\.title).filter { !$0.isEmpty }
    }

    var testingSelectedFASTARecords: [String] {
        selectedFASTARecords()
    }

    var testingAnnotationDrawerSummary: String {
        let count = annotationDrawer.displayedAnnotations.count
        return "\(count) annotation\(count == 1 ? "" : "s")"
    }

    var testingAnnotationDrawerRows: [String] {
        annotationDrawer.displayedAnnotations.map { result in
            let alignedColumns = result.attributes?["alignment_columns"] ?? "\(result.start + 1)-\(result.end)"
            return "\(result.chromosome)\t\(result.name)\t\(result.type)\t\(alignedColumns)"
        }
    }

    var testingSelectedExtractionAnnotationsByRecord: [String: [SequenceAnnotation]] {
        selectedExtractionAnnotationsByRecord()
    }

    func testingAlignmentMatrixPreview(rowCount: Int, columnCount: Int) -> [String] {
        alignmentRows.indices.prefix(rowCount).map { rowIndex in
            let sequence = displayedColumns.prefix(columnCount)
                .compactMap { displayedResidue(rowIndex: rowIndex, alignmentColumn: $0) }
                .map(String.init)
                .joined()
            return "\(alignmentRows[rowIndex].name) \(sequence)"
        }
    }

    func testingVisibleAlignmentRowsPreview(rowCount: Int, columnCount: Int) -> [String] {
        let consensus = displayedColumns.prefix(columnCount)
            .compactMap { displayedConsensusResidues()[safe: $0] }
            .map(String.init)
            .joined()
        let rows = testingAlignmentMatrixPreview(rowCount: max(0, rowCount - 1), columnCount: columnCount)
        return Array((["Consensus \(consensus)"] + rows).prefix(rowCount))
    }

    func testingDifferenceVisibilityPreview(rowCount: Int, columnCount: Int) -> [String] {
        alignmentRows.indices.prefix(rowCount).map { rowIndex in
            let markers = displayedColumns.prefix(columnCount).map { alignmentColumn -> String in
                guard let residue = alignmentRows[safe: rowIndex]?.sequence[safe: alignmentColumn] else {
                    return "."
                }
                let target: Character?
                switch residueIdentityDisplayMode {
                case .dotsToReference:
                    target = referenceRowIndex().flatMap { alignmentRows[safe: $0]?.sequence[safe: alignmentColumn] }
                case .letters, .dotsToConsensus:
                    target = displayedConsensusResidues()[safe: alignmentColumn]
                }
                guard let target else { return columnSummaries[safe: alignmentColumn]?.variable == true ? "!" : "." }
                if Self.isGap(residue), Self.isGap(target) == false {
                    return "!"
                }
                return residuesMatch(residue, target) ? "." : "!"
            }.joined()
            return "\(alignmentRows[rowIndex].name) \(markers)"
        }
    }

    func testingPerformZoomOut() {
        zoomOut()
    }

    func testingPerformZoomIn() {
        zoomIn()
    }

    func testingPerformZoomToFit() {
        zoomToFit()
    }

    func testingSetVariableSitesOnly(_ value: Bool) {
        siteModeControl.selectedSegment = value ? 1 : 0
        applySiteMode()
    }

    func testingAnnotationContextMenuTitles(named name: String) -> [String] {
        guard let annotation = annotationTracks.first(where: { $0.name == name })?.annotation else { return [] }
        return annotationContextMenu(for: annotation).items.map(\.title).filter { !$0.isEmpty }
    }

    func testingSelectAnnotationTrack(named name: String) {
        guard let annotation = annotationTracks.first(where: { $0.name == name })?.annotation else { return }
        selectAnnotation(annotation, zoom: false)
    }

    func testingZoomToAnnotationTrack(named name: String) {
        guard let annotation = annotationTracks.first(where: { $0.name == name })?.annotation else { return }
        selectAnnotation(annotation, zoom: true)
    }

    func testingSelect(row: Int, displayedColumn: Int) {
        guard displayedColumns.indices.contains(displayedColumn) else { return }
        select(row: row, alignmentColumn: displayedColumns[displayedColumn])
    }

    func testingSelectBlock(rowRange: ClosedRange<Int>, displayedColumnRange: ClosedRange<Int>) {
        guard alignmentRows.indices.contains(rowRange.lowerBound),
              alignmentRows.indices.contains(rowRange.upperBound),
              displayedColumns.indices.contains(displayedColumnRange.lowerBound),
              displayedColumns.indices.contains(displayedColumnRange.upperBound) else {
            return
        }
        let alignmentColumnRange = displayedColumns[displayedColumnRange.lowerBound]...displayedColumns[displayedColumnRange.upperBound]
        select(rowRange: rowRange, alignmentColumnRange: alignmentColumnRange)
    }

    func testingMoveActiveCell(
        _ direction: MultipleSequenceAlignmentNavigationDirection,
        extendingSelection: Bool = false
    ) {
        moveActiveCell(direction, extendingSelection: extendingSelection)
    }

    func testingSetColorScheme(_ scheme: MultipleSequenceAlignmentColorScheme) {
        colorScheme = scheme
        colorSchemeControl.selectedSegment = scheme.rawValue
        configureCanvasViews()
    }

    func testingApplyNumberingMode(_ mode: MSAAlignmentNumberingMode) {
        applyNumberingMode(mode)
    }

    func testingApplyConsensusDisplayOptions(_ options: MSAConsensusDisplayOptions) {
        applyConsensusDisplayOptions(options)
    }

    func testingSelectReferenceRow(named name: String) {
        guard let index = alignmentRows.firstIndex(where: { $0.name == name }),
              let rowID = rowIDsByIndex[safe: index] else { return }
        applyReferenceRowID(rowID)
    }

    func testingApplyResidueIdentityDisplayMode(_ mode: MSAResidueIdentityDisplayMode) {
        applyResidueIdentityDisplayMode(mode)
    }

    func testingAddAnnotationFromSelection(name: String, type: String) throws {
        _ = try addAnnotationFromSelection(name: name, type: type)
    }

    func testingApplySelectedAnnotationsToSelectedRows() throws {
        _ = try applySelectedAnnotationsToSelectedRows()
    }

    func testingCreateBundleFromSelectedSequences() {
        createBundleFromSelectedSequences()
    }

    func testingInferTreeFromAlignment() {
        inferTreeFromAlignment()
    }

    func testingSetSearchText(_ value: String) {
        searchField.stringValue = value
    }

    func testingPerformSearch() {
        performSearch()
    }
}

private final class MSAAlignmentCornerHeaderView: NSView {
    private var title = "Consensus"

    override var isFlipped: Bool { true }

    func configure(title: String) {
        self.title = title
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        drawText(
            title,
            in: NSRect(x: 10, y: 29, width: bounds.width - 18, height: 18),
            color: .secondaryLabelColor,
            font: .systemFont(ofSize: 11, weight: .semibold)
        )
        NSColor.separatorColor.setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: bounds.maxX - 0.5, y: 0), to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        NSBezierPath.strokeLine(from: NSPoint(x: 0, y: bounds.maxY - 0.5), to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
    }
}

private final class MSAAlignmentRowGutterView: NSView {
    var verticalOffset: CGFloat = 0
    var horizontalOffset: CGFloat = 0
    var selectedRowIndex: Int?
    var selectedRowRange: ClosedRange<Int>?

    private var rows: [MSAAlignmentSequence] = []
    private var rowIDsByIndex: [String] = []
    private var coordinateMapsByRowID: [String: MultipleSequenceAlignmentBundle.RowCoordinateMap] = [:]
    private var displayedColumns: [Int] = []
    private var columnWidth = MSAAlignmentCanvasMetrics.defaultColumnWidth
    private var numberingMode: MSAAlignmentNumberingMode = .both
    private var consensusResidues: [Character] = []

    override var isFlipped: Bool { true }

    func configure(
        rows: [MSAAlignmentSequence],
        rowIDsByIndex: [String],
        coordinateMapsByRowID: [String: MultipleSequenceAlignmentBundle.RowCoordinateMap],
        displayedColumns: [Int],
        consensusResidues: [Character],
        columnWidth: CGFloat,
        numberingMode: MSAAlignmentNumberingMode
    ) {
        self.rows = rows
        self.rowIDsByIndex = rowIDsByIndex
        self.coordinateMapsByRowID = coordinateMapsByRowID
        self.displayedColumns = displayedColumns
        self.consensusResidues = consensusResidues
        self.columnWidth = columnWidth
        self.numberingMode = numberingMode
        needsDisplay = true
    }

    var testingNumberingPreview: [String] {
        rows.indices.map { labelComponents(for: $0).joined(separator: "\t") }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        drawConsensusLabelIfNeeded(in: dirtyRect)

        let rowHeight = MSAAlignmentCanvasMetrics.rowHeight
        let consensusHeight = MSAAlignmentCanvasMetrics.consensusRowHeight
        let shiftedOffset = max(0, verticalOffset - consensusHeight)
        let firstRow = max(0, Int(floor(shiftedOffset / rowHeight)) - 2)
        let lastRow = min(rows.count, Int(ceil((shiftedOffset + bounds.height) / rowHeight)) + 2)
        guard firstRow < lastRow else { return }

        for rowIndex in firstRow..<lastRow {
            let y = consensusHeight + CGFloat(rowIndex) * rowHeight - verticalOffset
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            (rowIndex.isMultiple(of: 2) ? NSColor.textBackgroundColor : NSColor.controlBackgroundColor.withAlphaComponent(0.35)).setFill()
            rect.fill()
            if selectedRowRange?.contains(rowIndex) == true || selectedRowIndex == rowIndex {
                NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
                rect.fill()
            }
            drawRowLabel(rowIndex: rowIndex, in: rect)
        }

        NSColor.separatorColor.setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: bounds.maxX - 0.5, y: 0), to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
    }

    private func drawConsensusLabelIfNeeded(in dirtyRect: NSRect) {
        let rect = NSRect(
            x: 0,
            y: -verticalOffset,
            width: bounds.width,
            height: MSAAlignmentCanvasMetrics.consensusRowHeight
        )
        guard rect.intersects(dirtyRect), !consensusResidues.isEmpty else { return }
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        drawText(
            "Consensus",
            in: rect.insetBy(dx: 8, dy: 5),
            color: .labelColor,
            font: .systemFont(ofSize: 12, weight: .semibold)
        )
        NSColor.separatorColor.setStroke()
        NSBezierPath.strokeLine(
            from: NSPoint(x: 0, y: rect.maxY - 0.5),
            to: NSPoint(x: bounds.maxX, y: rect.maxY - 0.5)
        )
    }

    private func drawRowLabel(rowIndex: Int, in rect: NSRect) {
        let components = labelComponents(for: rowIndex)
        guard let name = components.drop(while: { Int($0) != nil }).first else { return }
        let inset = rect.insetBy(dx: 8, dy: 4)
        var leadingX = inset.minX
        if numberingMode.showsRowIndex {
            drawText(
                "\(rowIndex + 1)",
                in: NSRect(x: leadingX, y: inset.minY + 1, width: 24, height: inset.height),
                color: .secondaryLabelColor,
                font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                alignment: .right
            )
            leadingX += 32
        }

        let coordinateText = numberingMode.showsSourceCoordinates ? sourceCoordinateRangeText(rowIndex: rowIndex) : nil
        let coordinateWidth: CGFloat = coordinateText == nil ? 0 : 58
        drawText(
            name,
            in: NSRect(x: leadingX, y: inset.minY + 1, width: max(24, inset.maxX - leadingX - coordinateWidth - 4), height: inset.height),
            color: .labelColor,
            font: .systemFont(ofSize: 12)
        )
        if let coordinateText {
            drawText(
                coordinateText,
                in: NSRect(x: inset.maxX - coordinateWidth, y: inset.minY + 2, width: coordinateWidth, height: inset.height),
                color: .secondaryLabelColor,
                font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                alignment: .right
            )
        }
    }

    private func labelComponents(for rowIndex: Int) -> [String] {
        guard rows.indices.contains(rowIndex) else { return [] }
        var components: [String] = []
        if numberingMode.showsRowIndex {
            components.append("\(rowIndex + 1)")
        }
        components.append(rows[rowIndex].name)
        if numberingMode.showsSourceCoordinates {
            components.append(sourceCoordinateRangeText(rowIndex: rowIndex))
        }
        return components
    }

    private func sourceCoordinateRangeText(rowIndex: Int) -> String {
        guard let rowID = rowIDsByIndex[safe: rowIndex],
              let coordinateMap = coordinateMapsByRowID[rowID] else {
            return "n/a"
        }
        let coordinates = visibleAlignmentColumnsForNumbering()
            .compactMap { column -> Int? in
                guard coordinateMap.alignmentToUngapped.indices.contains(column) else { return nil }
                return coordinateMap.alignmentToUngapped[column].map { $0 + 1 }
            }
        guard let first = coordinates.min(), let last = coordinates.max() else {
            return "gap"
        }
        return first == last ? "\(first)" : "\(first)-\(last)"
    }

    private func visibleAlignmentColumnsForNumbering() -> [Int] {
        guard !displayedColumns.isEmpty else { return [] }
        guard bounds.width > 0, columnWidth > 0 else { return displayedColumns }
        let firstDisplayColumn = max(0, Int(floor(horizontalOffset / columnWidth)))
        let lastDisplayColumn = min(displayedColumns.count, Int(ceil((horizontalOffset + bounds.width) / columnWidth)))
        guard firstDisplayColumn < lastDisplayColumn else { return displayedColumns }
        return Array(displayedColumns[firstDisplayColumn..<lastDisplayColumn])
    }
}

private final class MSAAlignmentColumnHeaderView: NSView {
    var horizontalOffset: CGFloat = 0
    var selectedAlignmentColumn: Int?
    var selectedAlignmentColumnRange: ClosedRange<Int>?
    var columnWidth = MSAAlignmentCanvasMetrics.defaultColumnWidth
    var numberingMode: MSAAlignmentNumberingMode = .both

    private var columnSummaries: [MSAColumnSummary] = []
    private var consensusResidues: [Character] = []
    private var displayedColumns: [Int] = []

    override var isFlipped: Bool { true }

    func configure(
        columnSummaries: [MSAColumnSummary],
        consensusResidues: [Character],
        displayedColumns: [Int],
        columnWidth: CGFloat,
        numberingMode: MSAAlignmentNumberingMode
    ) {
        self.columnSummaries = columnSummaries
        self.consensusResidues = consensusResidues
        self.displayedColumns = displayedColumns
        self.columnWidth = columnWidth
        self.numberingMode = numberingMode
        needsDisplay = true
    }

    var testingNumberingVisible: Bool {
        numberingMode.showsAlignmentColumns
    }

    var testingNumberingPreview: [String] {
        guard numberingMode.showsAlignmentColumns else { return [] }
        return displayedColumns.map { "\($0 + 1)" }
    }

    func testingVisibleOrientationNumberingPreview(width: CGFloat) -> [String] {
        guard numberingMode.showsAlignmentColumns else { return [] }
        let visibleDisplayColumns = MSAVisibleDisplayColumns.range(
            displayedColumnCount: displayedColumns.count,
            columnWidth: columnWidth,
            minX: horizontalOffset,
            maxX: horizontalOffset + width,
            overscan: 0
        )
        return MSAOrientationNumbering.ticks(
            displayedColumns: displayedColumns,
            columnWidth: columnWidth,
            visibleDisplayColumns: visibleDisplayColumns
        ).map(\.label)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        guard !displayedColumns.isEmpty else {
            drawText("No visible sites", in: bounds.insetBy(dx: 10, dy: 20), color: .secondaryLabelColor)
            return
        }

        let visibleDisplayColumns = MSAVisibleDisplayColumns.range(
            displayedColumnCount: displayedColumns.count,
            columnWidth: columnWidth,
            minX: horizontalOffset,
            maxX: horizontalOffset + bounds.width
        )
        guard !visibleDisplayColumns.isEmpty else { return }

        for displayColumn in visibleDisplayColumns {
            let alignmentColumn = displayedColumns[displayColumn]
            let x = CGFloat(displayColumn) * columnWidth - horizontalOffset
            if selectedAlignmentColumnRange?.contains(alignmentColumn) == true || selectedAlignmentColumn == alignmentColumn {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSRect(x: x, y: 0, width: columnWidth, height: bounds.height).fill()
            }
            if numberingMode.showsAlignmentColumns,
               columnWidth >= 10,
               (alignmentColumn % 10 == 0 || displayedColumns.count <= 80) {
                drawText(
                    "\(alignmentColumn + 1)",
                    in: NSRect(x: x - 8, y: 5, width: 42, height: 14),
                    color: .secondaryLabelColor,
                    font: .monospacedSystemFont(ofSize: 9, weight: .regular)
                )
            }
            if columnSummaries[safe: alignmentColumn]?.variable == true {
                NSColor.systemPurple.withAlphaComponent(0.65).setFill()
                NSRect(
                    x: x,
                    y: bounds.height - 5,
                    width: max(1, columnWidth),
                    height: 3
                ).fill()
            }
        }

        if numberingMode.showsAlignmentColumns, columnWidth < 10 {
            drawSparseOrientationNumbering(visibleDisplayColumns: visibleDisplayColumns)
        }

        NSColor.separatorColor.setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: 0, y: bounds.maxY - 0.5), to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
    }

    private func drawSparseOrientationNumbering(visibleDisplayColumns: Range<Int>) {
        let ticks = MSAOrientationNumbering.ticks(
            displayedColumns: displayedColumns,
            columnWidth: columnWidth,
            visibleDisplayColumns: visibleDisplayColumns
        )
        guard !ticks.isEmpty else { return }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]

        for tick in ticks {
            let x = CGFloat(tick.displayColumn) * columnWidth - horizontalOffset
            NSColor.separatorColor.withAlphaComponent(0.72).setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: x, y: 0), to: NSPoint(x: x, y: bounds.height))
            NSString(string: tick.label).draw(
                in: NSRect(x: x + 3, y: 5, width: 58, height: 14),
                withAttributes: attributes
            )
        }
    }
}

private final class MSAAlignmentOverviewSignalView: NSView {
    private var columnSummaries: [MSAColumnSummary] = []
    private var displayedColumns: [Int] = []
    private var columnWidth = MSAAlignmentCanvasMetrics.defaultColumnWidth

    override var isFlipped: Bool { true }

    func configure(
        columnSummaries: [MSAColumnSummary],
        displayedColumns: [Int],
        columnWidth: CGFloat
    ) {
        self.columnSummaries = columnSummaries
        self.displayedColumns = displayedColumns
        self.columnWidth = columnWidth
        setAccessibilityHelp(summaryText)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        guard !displayedColumns.isEmpty else {
            drawText("No visible sites", in: bounds.insetBy(dx: 8, dy: 2), color: .secondaryLabelColor)
            return
        }

        let widthPerColumn = max(1, min(columnWidth, bounds.width / CGFloat(max(displayedColumns.count, 1))))
        for displayIndex in displayedColumns.indices {
            let alignmentColumn = displayedColumns[displayIndex]
            guard let summary = columnSummaries[safe: alignmentColumn] else { continue }
            overviewColor(for: summary).setFill()
            NSRect(
                x: CGFloat(displayIndex) * widthPerColumn,
                y: 4,
                width: max(1, widthPerColumn),
                height: bounds.height - 8
            ).fill()
        }

        drawText(
            summaryText,
            in: bounds.insetBy(dx: 8, dy: 2),
            color: .secondaryLabelColor,
            font: .systemFont(ofSize: 10, weight: .medium),
            alignment: .right
        )
        NSColor.separatorColor.setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: 0, y: bounds.maxY - 0.5), to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
    }

    var summaryText: String {
        let summaries = displayedColumns.compactMap { columnSummaries[safe: $0] }
        let variableCount = summaries.filter(\.variable).count
        let gapBearingCount = summaries.filter { $0.gapFraction > 0 }.count
        return "\(displayedColumns.count) columns, \(variableCount) variable, \(gapBearingCount) gap-bearing"
    }

    private func overviewColor(for summary: MSAColumnSummary) -> NSColor {
        if summary.gapFraction > 0 {
            return NSColor.systemOrange.withAlphaComponent(0.44)
        }
        if summary.variable {
            return NSColor.systemPurple.withAlphaComponent(0.42)
        }
        return NSColor.systemGreen.withAlphaComponent(max(0.18, 0.36 * summary.conservation))
    }
}

private final class MSAAlignmentOverlayView: NSButton {
    var primaryAction: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        isTransparent = true
        bezelStyle = .regularSquare
        focusRingType = .none
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        primaryAction?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Transparent accessibility target; the matrix draws the visible cell and track state.
    }
}

private final class MSAAlignmentMatrixView: NSView {
    var onSelectionChanged: ((Int, Int) -> Void)?
    var onSelectionRangeChanged: ((ClosedRange<Int>, ClosedRange<Int>) -> Void)?
    var onKeyboardNavigation: ((MultipleSequenceAlignmentNavigationDirection, Bool) -> Void)?
    var contextMenuProvider: ((Int, Int) -> NSMenu?)?
    var onAnnotationSelected: ((MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord) -> Void)?
    var annotationContextMenuProvider: ((MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord) -> NSMenu?)?
    var onMagnification: ((CGFloat) -> Void)?
    var selectedRowIndex: Int?
    var selectedAlignmentColumn: Int?
    var selectedRowRange: ClosedRange<Int>?
    var selectedAlignmentColumnRange: ClosedRange<Int>?
    var annotationTracks: [MSAAlignmentAnnotationTrack] = []
    var columnWidth = MSAAlignmentCanvasMetrics.defaultColumnWidth

    private var rows: [MSAAlignmentSequence] = []
    private var columnSummaries: [MSAColumnSummary] = []
    private var consensusResidues: [Character] = []
    private var referenceRowIndex: Int?
    private var residueIdentityDisplayMode: MSAResidueIdentityDisplayMode = .letters
    private var displayedColumns: [Int] = []
    private var colorScheme: MultipleSequenceAlignmentColorScheme = .nucleotide
    private var dragAnchor: (row: Int, alignmentColumn: Int)?
    private var selectedCellOverlay: MSAAlignmentOverlayView?
    private var annotationTrackOverlays: [MSAAlignmentOverlayView] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var testingZoomRenderingModeTitle: String {
        zoomRenderingMode.displayTitle
    }

    func testingVisibleDisplayColumnRangeDescription(for dirtyRect: NSRect) -> String {
        let range = visibleDisplayColumnRange(for: dirtyRect)
        return range.isEmpty ? "empty" : "\(range.lowerBound)-\(range.upperBound)"
    }

    private var zoomRenderingMode: MSAZoomRenderingMode {
        MSAZoomRenderingMode.forColumnWidth(columnWidth)
    }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        if let selectedCellOverlay {
            children.append(selectedCellOverlay)
        }
        children.append(contentsOf: annotationTrackOverlays)
        return children
    }

    func configure(
        rows: [MSAAlignmentSequence],
        columnSummaries: [MSAColumnSummary],
        consensusResidues: [Character],
        referenceRowIndex: Int?,
        residueIdentityDisplayMode: MSAResidueIdentityDisplayMode,
        displayedColumns: [Int],
        annotationTracks: [MSAAlignmentAnnotationTrack],
        columnWidth: CGFloat,
        colorScheme: MultipleSequenceAlignmentColorScheme
    ) {
        self.rows = rows
        self.columnSummaries = columnSummaries
        self.consensusResidues = consensusResidues
        self.referenceRowIndex = referenceRowIndex
        self.residueIdentityDisplayMode = residueIdentityDisplayMode
        self.displayedColumns = displayedColumns
        self.annotationTracks = annotationTracks
        self.columnWidth = columnWidth
        self.colorScheme = colorScheme
        let width = max(920, CGFloat(max(displayedColumns.count, 1)) * columnWidth)
        let height = max(
            420,
            MSAAlignmentCanvasMetrics.consensusRowHeight
                + CGFloat(max(rows.count, 1)) * MSAAlignmentCanvasMetrics.rowHeight
        )
        setFrameSize(NSSize(width: width, height: height))
        updateAccessibilityOverlays()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        guard !rows.isEmpty else {
            drawText("No alignment rows loaded.", in: NSRect(x: 16, y: 16, width: 320, height: 24), color: .secondaryLabelColor)
            return
        }
        guard !displayedColumns.isEmpty else {
            drawText("No variable sites in this alignment.", in: NSRect(x: 16, y: 16, width: 320, height: 24), color: .secondaryLabelColor)
            return
        }

        drawConsensusRow(in: dirtyRect)
        drawRows(in: dirtyRect)
    }

    override func keyDown(with event: NSEvent) {
        guard let direction = navigationDirection(for: event) else {
            super.keyDown(with: event)
            return
        }
        onKeyboardNavigation?(direction, event.modifierFlags.contains(.shift))
    }

    override func magnify(with event: NSEvent) {
        onMagnification?(event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let annotation = annotationTrack(at: point)?.annotation {
            onAnnotationSelected?(annotation)
            return
        }
        guard let selection = selection(at: point) else { return }
        dragAnchor = selection
        onSelectionChanged?(selection.row, selection.alignmentColumn)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchor,
              let selection = selection(at: convert(event.locationInWindow, from: nil)) else { return }
        let rowRange = min(dragAnchor.row, selection.row)...max(dragAnchor.row, selection.row)
        let columnRange = min(dragAnchor.alignmentColumn, selection.alignmentColumn)...max(dragAnchor.alignmentColumn, selection.alignmentColumn)
        onSelectionRangeChanged?(rowRange, columnRange)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragAnchor = nil }
        guard let dragAnchor,
              let selection = selection(at: convert(event.locationInWindow, from: nil)) else { return }
        let rowRange = min(dragAnchor.row, selection.row)...max(dragAnchor.row, selection.row)
        let columnRange = min(dragAnchor.alignmentColumn, selection.alignmentColumn)...max(dragAnchor.alignmentColumn, selection.alignmentColumn)
        onSelectionRangeChanged?(rowRange, columnRange)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let annotation = annotationTrack(at: point)?.annotation {
            return annotationContextMenuProvider?(annotation)
        }
        guard let selection = selection(at: point) else {
            return nil
        }
        return contextMenuProvider?(selection.row, selection.alignmentColumn)
    }

    func rectFor(row: Int, alignmentColumn: Int) -> NSRect? {
        guard rows.indices.contains(row),
              let displayColumn = displayedColumns.firstIndex(of: alignmentColumn) else {
            return nil
        }
        return NSRect(
            x: CGFloat(displayColumn) * columnWidth,
            y: MSAAlignmentCanvasMetrics.consensusRowHeight + CGFloat(row) * MSAAlignmentCanvasMetrics.rowHeight,
            width: columnWidth,
            height: MSAAlignmentCanvasMetrics.rowHeight
        )
    }

    private func selection(at point: NSPoint) -> (row: Int, alignmentColumn: Int)? {
        guard let displayColumn = displayColumnIndex(at: point.x) else { return nil }
        guard point.y >= MSAAlignmentCanvasMetrics.consensusRowHeight else { return nil }
        let row = Int((point.y - MSAAlignmentCanvasMetrics.consensusRowHeight) / MSAAlignmentCanvasMetrics.rowHeight)
        guard rows.indices.contains(row),
              displayedColumns.indices.contains(displayColumn) else {
            return nil
        }
        return (row, displayedColumns[displayColumn])
    }

    private func drawConsensusRow(in dirtyRect: NSRect) {
        let rowRect = NSRect(
            x: dirtyRect.minX,
            y: 0,
            width: dirtyRect.width,
            height: MSAAlignmentCanvasMetrics.consensusRowHeight
        )
        guard rowRect.intersects(dirtyRect), !consensusResidues.isEmpty else { return }
        NSColor.controlBackgroundColor.withAlphaComponent(0.72).setFill()
        rowRect.fill()

        let renderingMode = zoomRenderingMode
        let columnRange = visibleDisplayColumnRange(for: dirtyRect)
        guard !columnRange.isEmpty else { return }
        for displayColumn in columnRange {
            let alignmentColumn = displayedColumns[displayColumn]
            guard let residue = consensusResidues[safe: alignmentColumn] else { continue }
            let x = CGFloat(displayColumn) * columnWidth
            if selectedAlignmentColumnRange?.contains(alignmentColumn) == true || selectedAlignmentColumn == alignmentColumn {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSRect(x: x, y: 0, width: columnWidth, height: bounds.height).fill()
            }
            if columnWidth >= 10,
               (alignmentColumn % 10 == 0 || displayedColumns.count <= 80) {
                drawText(
                    "\(alignmentColumn + 1)",
                    in: NSRect(x: x - 8, y: 1, width: 42, height: 10),
                    color: .secondaryLabelColor,
                    font: .monospacedSystemFont(ofSize: 8, weight: .regular),
                    alignment: .center
                )
            }
            drawResidue(
                residue,
                rect: residueRect(x: x, y: 10, width: columnWidth, height: 15),
                isConsensus: true,
                showLetter: renderingMode == .letters
            )
        }

        if columnWidth < 10 {
            drawSparseOrientationNumbering(in: dirtyRect, visibleDisplayColumns: columnRange)
        }

        NSColor.separatorColor.setStroke()
        NSBezierPath.strokeLine(
            from: NSPoint(x: dirtyRect.minX, y: MSAAlignmentCanvasMetrics.consensusRowHeight - 0.5),
            to: NSPoint(x: dirtyRect.maxX, y: MSAAlignmentCanvasMetrics.consensusRowHeight - 0.5)
        )
    }

    private func drawRows(in dirtyRect: NSRect) {
        let columnRange = visibleDisplayColumnRange(for: dirtyRect)
        guard !columnRange.isEmpty else { return }
        if zoomRenderingMode == .aggregateDifferences {
            drawAggregateDifferenceRows(in: dirtyRect, visibleDisplayColumns: columnRange)
            return
        }

        let renderingMode = zoomRenderingMode
        let rowHeight = MSAAlignmentCanvasMetrics.rowHeight
        for rowIndex in rows.indices {
            let y = MSAAlignmentCanvasMetrics.consensusRowHeight + CGFloat(rowIndex) * rowHeight
            guard y < dirtyRect.maxY, y + rowHeight > dirtyRect.minY else { continue }
            let rowRect = NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: rowHeight)
            (rowIndex.isMultiple(of: 2) ? NSColor.textBackgroundColor : NSColor.controlBackgroundColor.withAlphaComponent(0.35)).setFill()
            rowRect.fill()

            if selectedRowRange?.contains(rowIndex) == true || selectedRowIndex == rowIndex {
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                rowRect.fill()
            }

            let row = rows[rowIndex]
            for displayColumn in columnRange {
                let alignmentColumn = displayedColumns[displayColumn]
                guard let residue = row.sequence[safe: alignmentColumn] else { continue }
                let displayedResidue = displayResidue(
                    residue,
                    rowIndex: rowIndex,
                    alignmentColumn: alignmentColumn
                )
                let x = CGFloat(displayColumn) * columnWidth
                let rect = residueRect(x: x, y: y + 3, width: columnWidth, height: rowHeight - 6)

                if selectedAlignmentColumnRange?.contains(alignmentColumn) == true || selectedAlignmentColumn == alignmentColumn {
                    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                    NSRect(x: x, y: 0, width: columnWidth, height: bounds.height).fill()
                }
                drawResidue(
                    displayedResidue,
                    rect: rect,
                    isConsensus: false,
                    showLetter: renderingMode == .letters,
                    colorScheme: colorScheme,
                    columnSummary: columnSummaries[safe: alignmentColumn]
                )
            }
            drawAnnotationTracks(
                annotationTracks.filter { $0.rowIndex == rowIndex },
                rowY: y,
                visibleDisplayColumns: columnRange
            )
        }
    }

    private func drawAggregateDifferenceRows(
        in dirtyRect: NSRect,
        visibleDisplayColumns: Range<Int>
    ) {
        let rowHeight = MSAAlignmentCanvasMetrics.rowHeight
        let displayColumnsPerBin = max(1, Int(ceil(1 / max(columnWidth, MSAAlignmentCanvasMetrics.minimumOverviewColumnWidth))))

        for rowIndex in rows.indices {
            let y = MSAAlignmentCanvasMetrics.consensusRowHeight + CGFloat(rowIndex) * rowHeight
            guard y < dirtyRect.maxY, y + rowHeight > dirtyRect.minY else { continue }
            let rowRect = NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: rowHeight)
            (rowIndex.isMultiple(of: 2) ? NSColor.textBackgroundColor : NSColor.controlBackgroundColor.withAlphaComponent(0.35)).setFill()
            rowRect.fill()

            if selectedRowRange?.contains(rowIndex) == true || selectedRowIndex == rowIndex {
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                rowRect.fill()
            }

            var binStart = visibleDisplayColumns.lowerBound
            while binStart < visibleDisplayColumns.upperBound {
                let binEnd = min(binStart + displayColumnsPerBin, visibleDisplayColumns.upperBound)
                if let color = aggregateDifferenceColor(rowIndex: rowIndex, displayColumns: binStart..<binEnd) {
                    color.setFill()
                    NSRect(
                        x: CGFloat(binStart) * columnWidth,
                        y: y + 3,
                        width: max(1, CGFloat(binEnd - binStart) * columnWidth),
                        height: rowHeight - 6
                    ).fill()
                }
                binStart = binEnd
            }

            drawAnnotationTracks(
                annotationTracks.filter { $0.rowIndex == rowIndex },
                rowY: y,
                visibleDisplayColumns: visibleDisplayColumns
            )
        }
    }

    private func aggregateDifferenceColor(
        rowIndex: Int,
        displayColumns: Range<Int>
    ) -> NSColor? {
        var residueCounts: [Character: Int] = [:]
        var gapDifferences = 0
        var differences = 0

        for displayColumn in displayColumns {
            guard let alignmentColumn = displayedColumns[safe: displayColumn],
                  let residue = rows[safe: rowIndex]?.sequence[safe: alignmentColumn],
                  aggregateResidueIsDifference(
                    residue,
                    rowIndex: rowIndex,
                    alignmentColumn: alignmentColumn
                  ) else {
                continue
            }
            differences += 1
            if Self.isGap(residue) {
                gapDifferences += 1
            } else {
                residueCounts[Character(String(residue).uppercased()), default: 0] += 1
            }
        }

        guard differences > 0 else { return nil }
        if gapDifferences >= max(1, differences - gapDifferences),
           residueCounts.isEmpty {
            return NSColor.systemOrange.withAlphaComponent(0.66)
        }
        let residue = residueCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? String(lhs.key) < String(rhs.key) : lhs.value > rhs.value
        }.first?.key ?? "N"
        let alpha = min(0.82, 0.42 + CGFloat(differences) / CGFloat(max(displayColumns.count, 1)) * 0.36)
        return residueColor(for: residue).withAlphaComponent(alpha)
    }

    private func aggregateResidueIsDifference(
        _ residue: Character,
        rowIndex: Int,
        alignmentColumn: Int
    ) -> Bool {
        let target: Character?
        switch residueIdentityDisplayMode {
        case .dotsToReference:
            target = referenceRowIndex.flatMap { rows[safe: $0]?.sequence[safe: alignmentColumn] }
        case .letters, .dotsToConsensus:
            target = consensusResidues[safe: alignmentColumn]
        }
        guard let target else {
            return columnSummaries[safe: alignmentColumn]?.variable == true
        }
        if Self.isGap(residue), Self.isGap(target) == false {
            return true
        }
        return residuesMatch(residue, target) == false
    }

    private func displayResidue(
        _ residue: Character,
        rowIndex: Int,
        alignmentColumn: Int
    ) -> Character {
        switch residueIdentityDisplayMode {
        case .letters:
            return residue
        case .dotsToConsensus:
            guard let consensus = consensusResidues[safe: alignmentColumn] else { return residue }
            return residuesMatch(residue, consensus) ? "." : residue
        case .dotsToReference:
            guard let referenceRowIndex,
                  let referenceResidue = rows[safe: referenceRowIndex]?.sequence[safe: alignmentColumn] else {
                return residue
            }
            return residuesMatch(residue, referenceResidue) ? "." : residue
        }
    }

    private func residuesMatch(_ lhs: Character, _ rhs: Character) -> Bool {
        String(lhs).uppercased() == String(rhs).uppercased()
    }

    private static func isGap(_ residue: Character) -> Bool {
        residue == "-" || residue == "."
    }

    private func drawAnnotationTracks(
        _ tracks: [MSAAlignmentAnnotationTrack],
        rowY: CGFloat,
        visibleDisplayColumns: Range<Int>
    ) {
        guard !tracks.isEmpty else { return }
        let rowHeight = MSAAlignmentCanvasMetrics.rowHeight
        let laneHeight = MSAAlignmentCanvasMetrics.annotationLaneHeight
        for track in tracks {
            annotationColor(for: track).setFill()
            for interval in track.annotation.alignedIntervals {
                let startDisplay = displayedColumns.firstIndex { $0 >= interval.start }
                let endDisplay = displayedColumns.lastIndex { $0 < interval.end }
                guard let startDisplay,
                      let endDisplay,
                      endDisplay >= startDisplay else { continue }
                let lower = max(startDisplay, visibleDisplayColumns.lowerBound)
                let upper = min(endDisplay, visibleDisplayColumns.upperBound - 1)
                guard lower <= upper else { continue }
                let rect = NSRect(
                    x: CGFloat(lower) * columnWidth,
                    y: rowY + rowHeight - laneHeight - 1,
                    width: CGFloat(upper - lower + 1) * columnWidth,
                    height: laneHeight
                ).insetBy(dx: 1, dy: 1)
                rect.fill()
            }
        }
    }

    private func annotationTrack(at point: NSPoint) -> MSAAlignmentAnnotationTrack? {
        guard point.y >= MSAAlignmentCanvasMetrics.consensusRowHeight else { return nil }
        let row = Int((point.y - MSAAlignmentCanvasMetrics.consensusRowHeight) / MSAAlignmentCanvasMetrics.rowHeight)
        let yWithinRow = point.y
            - MSAAlignmentCanvasMetrics.consensusRowHeight
            - CGFloat(row) * MSAAlignmentCanvasMetrics.rowHeight
        guard rows.indices.contains(row),
              yWithinRow >= MSAAlignmentCanvasMetrics.rowHeight - MSAAlignmentCanvasMetrics.annotationLaneHeight - 2 else {
            return nil
        }
        guard let displayColumn = displayColumnIndex(at: point.x) else { return nil }
        let alignmentColumn = displayedColumns[displayColumn]
        return annotationTracks.last { track in
            track.rowIndex == row && track.annotation.alignedIntervals.contains { interval in
                interval.start <= alignmentColumn && alignmentColumn < interval.end
            }
        }
    }

    func updateAccessibilityOverlays() {
        selectedCellOverlay?.removeFromSuperview()
        selectedCellOverlay = nil
        annotationTrackOverlays.forEach { $0.removeFromSuperview() }
        annotationTrackOverlays.removeAll()

        if let rowIndex = selectedRowIndex,
           let alignmentColumn = selectedAlignmentColumn,
           let cellRect = rectFor(row: rowIndex, alignmentColumn: alignmentColumn),
           rows.indices.contains(rowIndex),
           let residue = rows[rowIndex].sequence[safe: alignmentColumn] {
            let row = rows[rowIndex]
            let overlay = MSAAlignmentOverlayView(frame: cellRect)
            overlay.setAccessibilityRole(.cell)
            overlay.setAccessibilityIdentifier(selectedCellAccessibilityIdentifier(rowName: row.name, alignmentColumn: alignmentColumn))
            overlay.setAccessibilityLabel("\(row.name), alignment column \(alignmentColumn + 1), residue \(residue)")
            overlay.setAccessibilityHelp("Selected alignment cell. Use arrow keys or drag to adjust the selection.")
            overlay.menuProvider = { [weak self] in
                guard let self else { return nil }
                return self.contextMenuProvider?(rowIndex, alignmentColumn)
            }
            addSubview(overlay)
            selectedCellOverlay = overlay
        }

        annotationTrackOverlays = annotationTracks.compactMap { track in
            guard rows.indices.contains(track.rowIndex),
                  let frame = annotationTrackFrame(for: track) else {
                return nil
            }
            let overlay = MSAAlignmentOverlayView(frame: frame)
            overlay.setAccessibilityRole(.group)
            overlay.setAccessibilityIdentifier(annotationTrackAccessibilityIdentifier(for: track))
            overlay.setAccessibilityLabel(annotationTrackAccessibilityLabel(for: track))
            overlay.setAccessibilityHelp("Annotation track. Select or open the context menu to center or zoom to this annotation.")
            overlay.primaryAction = { [weak self] in
                self?.onAnnotationSelected?(track.annotation)
            }
            overlay.menuProvider = { [weak self] in
                self?.annotationContextMenuProvider?(track.annotation)
            }
            addSubview(overlay)
            return overlay
        }
    }

    private func annotationTrackFrame(for track: MSAAlignmentAnnotationTrack) -> NSRect? {
        let visibleDisplayIndices = displayedColumns.indices.filter { displayIndex in
            let alignmentColumn = displayedColumns[displayIndex]
            return track.annotation.alignedIntervals.contains { interval in
                interval.start <= alignmentColumn && alignmentColumn < interval.end
            }
        }
        guard let firstDisplayIndex = visibleDisplayIndices.first,
              let lastDisplayIndex = visibleDisplayIndices.last else {
            return nil
        }

        return NSRect(
            x: CGFloat(firstDisplayIndex) * columnWidth,
            y: MSAAlignmentCanvasMetrics.consensusRowHeight
                + CGFloat(track.rowIndex) * MSAAlignmentCanvasMetrics.rowHeight
                + MSAAlignmentCanvasMetrics.rowHeight
                - MSAAlignmentCanvasMetrics.annotationLaneHeight
                - 3,
            width: CGFloat(lastDisplayIndex - firstDisplayIndex + 1) * columnWidth,
            height: MSAAlignmentCanvasMetrics.annotationLaneHeight + 5
        )
    }

    private func annotationTrackAccessibilityElements() -> [Any] {
        annotationTracks.compactMap { track in
            guard rows.indices.contains(track.rowIndex) else { return nil }
            guard let frame = annotationTrackFrame(for: track) else { return nil }

            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.group)
            element.setAccessibilityIdentifier(annotationTrackAccessibilityIdentifier(for: track))
            element.setAccessibilityLabel(annotationTrackAccessibilityLabel(for: track))
            element.setAccessibilityHelp("Annotation track. Select or open the context menu to center or zoom to this annotation.")
            element.setAccessibilityFrameInParentSpace(frame)
            return element
        }
    }

    private func selectedCellAccessibilityElements() -> [Any] {
        guard let rowIndex = selectedRowIndex,
              let alignmentColumn = selectedAlignmentColumn,
              rows.indices.contains(rowIndex),
              displayedColumns.contains(alignmentColumn),
              let displayIndex = displayedColumns.firstIndex(of: alignmentColumn),
              let residue = rows[rowIndex].sequence[safe: alignmentColumn] else {
            return []
        }

        let row = rows[rowIndex]
        let element = NSAccessibilityElement()
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.cell)
        element.setAccessibilityIdentifier(selectedCellAccessibilityIdentifier(rowName: row.name, alignmentColumn: alignmentColumn))
        element.setAccessibilityLabel("\(row.name), alignment column \(alignmentColumn + 1), residue \(residue)")
        element.setAccessibilityHelp("Selected alignment cell. Use arrow keys or drag to adjust the selection.")
        element.setAccessibilityFrameInParentSpace(
            NSRect(
                x: CGFloat(displayIndex) * columnWidth,
                y: MSAAlignmentCanvasMetrics.consensusRowHeight + CGFloat(rowIndex) * MSAAlignmentCanvasMetrics.rowHeight,
                width: columnWidth,
                height: MSAAlignmentCanvasMetrics.rowHeight
            )
        )
        return [element]
    }

    private func selectedCellAccessibilityIdentifier(rowName: String, alignmentColumn: Int) -> String {
        [
            "multiple-sequence-alignment-cell",
            Self.sanitizedAccessibilityComponent(rowName),
            "column-\(alignmentColumn + 1)",
        ]
        .joined(separator: "-")
    }

    private func annotationTrackAccessibilityIdentifier(for track: MSAAlignmentAnnotationTrack) -> String {
        [
            MultipleSequenceAlignmentAccessibilityID.annotationTrackPrefix,
            Self.sanitizedAccessibilityComponent(track.rowName),
            Self.sanitizedAccessibilityComponent(track.annotation.sourceAnnotationID),
        ]
        .joined(separator: "-")
    }

    private func annotationTrackAccessibilityLabel(for track: MSAAlignmentAnnotationTrack) -> String {
        let columns = track.annotation.alignedIntervals
            .map { "\($0.start + 1)-\($0.end)" }
            .joined(separator: ", ")
        let sourceCoordinates = track.annotation.sourceIntervals
            .map { "\($0.start + 1)-\($0.end)" }
            .joined(separator: ", ")
        return [
            "Annotation \(track.name)",
            "type \(track.type)",
            "row \(track.rowName)",
            "alignment columns \(columns.isEmpty ? "none" : columns)",
            "source coordinates \(sourceCoordinates.isEmpty ? "none" : sourceCoordinates)",
        ]
        .joined(separator: ", ")
    }

    private static func sanitizedAccessibilityComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "annotation" : sanitized
    }

    private func visibleDisplayColumnRange(for dirtyRect: NSRect) -> Range<Int> {
        MSAVisibleDisplayColumns.range(
            displayedColumnCount: displayedColumns.count,
            columnWidth: columnWidth,
            minX: dirtyRect.minX,
            maxX: dirtyRect.maxX
        )
    }

    private func displayColumnIndex(at x: CGFloat) -> Int? {
        guard columnWidth.isFinite, columnWidth > 0, x.isFinite else { return nil }
        let rawDisplayColumn = floor(x / columnWidth)
        guard rawDisplayColumn >= 0,
              rawDisplayColumn < CGFloat(displayedColumns.count) else {
            return nil
        }
        return Int(rawDisplayColumn)
    }

    private func drawSparseOrientationNumbering(
        in dirtyRect: NSRect,
        visibleDisplayColumns: Range<Int>
    ) {
        let ticks = MSAOrientationNumbering.ticks(
            displayedColumns: displayedColumns,
            columnWidth: columnWidth,
            visibleDisplayColumns: visibleDisplayColumns
        )
        guard !ticks.isEmpty else { return }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]

        for tick in ticks {
            let x = CGFloat(tick.displayColumn) * columnWidth
            guard x >= dirtyRect.minX - 60, x <= dirtyRect.maxX + 4 else { continue }
            NSColor.separatorColor.withAlphaComponent(0.58).setStroke()
            NSBezierPath.strokeLine(
                from: NSPoint(x: x, y: 0),
                to: NSPoint(x: x, y: MSAAlignmentCanvasMetrics.consensusRowHeight)
            )
            NSString(string: tick.label).draw(
                in: NSRect(x: x + 3, y: 1, width: 58, height: 10),
                withAttributes: attributes
            )
        }
    }

    private func navigationDirection(for event: NSEvent) -> MultipleSequenceAlignmentNavigationDirection? {
        switch event.keyCode {
        case 126:
            return .up
        case 125:
            return .down
        case 123:
            return .left
        case 124:
            return .right
        case 115:
            return .home
        case 119:
            return .end
        case 116:
            return .pageUp
        case 121:
            return .pageDown
        default:
            return nil
        }
    }
}

private func drawResidue(
    _ residue: Character,
    rect: NSRect,
    isConsensus: Bool,
    showLetter: Bool = true,
    colorScheme: MultipleSequenceAlignmentColorScheme = .nucleotide,
    columnSummary: MSAColumnSummary? = nil
) {
    guard rect.width > 0, rect.height > 0 else { return }
    residueColor(
        for: residue,
        consensus: isConsensus,
        colorScheme: colorScheme,
        columnSummary: columnSummary
    ).setFill()
    rect.fill()
    guard showLetter, rect.width >= MSAAlignmentCanvasMetrics.letterColumnWidth - 1 else { return }
    let textColor: NSColor = residue == "-" || residue == "." ? .secondaryLabelColor : .labelColor
    drawText(
        String(residue),
        in: rect.insetBy(dx: 0, dy: 1),
        color: textColor,
        font: .monospacedSystemFont(ofSize: 11, weight: isConsensus ? .semibold : .regular),
        alignment: .center
    )
}

private func residueColor(
    for residue: Character,
    consensus: Bool = false,
    colorScheme: MultipleSequenceAlignmentColorScheme = .nucleotide,
    columnSummary: MSAColumnSummary? = nil
) -> NSColor {
    if colorScheme == .conservation {
        if residue == "-" || residue == "." {
            return NSColor.separatorColor.withAlphaComponent(0.30)
        }
        let conservation = columnSummary?.conservation ?? 0
        let alpha = max(0.16, min(0.48, CGFloat(conservation) * (consensus ? 0.34 : 0.46)))
        return NSColor.systemGreen.withAlphaComponent(alpha)
    }

    let alpha: CGFloat = consensus ? 0.22 : 0.34
    switch String(residue).uppercased() {
    case "A":
        return NSColor.systemGreen.withAlphaComponent(alpha)
    case "C":
        return NSColor.systemBlue.withAlphaComponent(alpha)
    case "G":
        return NSColor.systemOrange.withAlphaComponent(alpha)
    case "T", "U":
        return NSColor.systemRed.withAlphaComponent(alpha)
    case "-", ".":
        return NSColor.separatorColor.withAlphaComponent(0.28)
    case "N", "X", "?":
        return NSColor.systemGray.withAlphaComponent(alpha)
    default:
        return NSColor.systemTeal.withAlphaComponent(alpha)
    }
}

private func residueRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    if width >= 3 {
        return NSRect(x: x + 1, y: y, width: width - 2, height: height)
    }
    return NSRect(x: x, y: y, width: max(width, 1), height: height)
}

private func annotationColor(for track: MSAAlignmentAnnotationTrack) -> NSColor {
    let alpha: CGFloat = 0.82
    switch track.type.lowercased() {
    case "gene":
        return NSColor.systemBlue.withAlphaComponent(alpha)
    case "cds":
        return NSColor.systemPurple.withAlphaComponent(alpha)
    case "exon":
        return NSColor.systemTeal.withAlphaComponent(alpha)
    case "mrna", "transcript":
        return NSColor.systemIndigo.withAlphaComponent(alpha)
    case "primer":
        return NSColor.systemOrange.withAlphaComponent(alpha)
    default:
        return NSColor.controlAccentColor.withAlphaComponent(alpha)
    }
}

func drawText(
    _ text: String,
    in rect: NSRect,
    color: NSColor,
    font: NSFont = .systemFont(ofSize: 11),
    alignment: NSTextAlignment = .left
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
    NSAttributedString(string: text, attributes: attributes).draw(in: rect)
}
