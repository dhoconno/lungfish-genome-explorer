// MSADistanceMatrixPaneView.swift - The Distances pane: header bar, grid, headers, legend, footer, status
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The self-contained Distances pane of the MSA viewport.
///
/// LungfishApp hosts it in the MSA bottom pane and wires the callbacks.
/// Every control maps to a `lungfish-cli msa distance` flag.
@MainActor
public final class MSADistanceMatrixPaneView: NSView {
    // MARK: Outward interface

    /// Input record indices of the sequences the alignment should select.
    public var onSequencesSelected: ((IndexSet) -> Void)?
    /// Input record indices of the pair to show in the alignment.
    public var onRevealPair: ((Int, Int) -> Void)?
    /// Export Matrix as TSV… with the options on screen.
    public var onExportRequested: ((MSADistanceOptions) -> Void)?
    /// Focused pair breakdown for the Inspector: detail, row name, column name.
    public var onFocusedPairChanged: ((MSAPairDetail?, String, String) -> Void)?

    public var maxRowsForInlineMatrix: Int {
        get { model.maxRowsForInlineMatrix }
        set { model.maxRowsForInlineMatrix = newValue }
    }

    public let model: MSADistanceMatrixPaneModel
    public let gridView: MSADistanceMatrixGridView

    // MARK: Subviews

    let rowHeaderView = MSADistanceMatrixRowHeaderView(frame: .zero)
    let columnHeaderView = MSADistanceMatrixColumnHeaderView(frame: .zero)
    let cornerView = NSView(frame: .zero)
    let scrollView = NSScrollView(frame: .zero)
    let headerBar = NSStackView(frame: .zero)
    let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let gapsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let orderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let fixedRangeCheckbox = NSButton(checkboxWithTitle: "Fixed 0-1", target: nil, action: nil)
    let showValuesCheckbox = NSButton(checkboxWithTitle: "Show Values", target: nil, action: nil)
    let copyMatrixButton = NSButton(title: "Copy Matrix", target: nil, action: nil)
    let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    let legendView = MSADistanceMatrixLegendView(frame: .zero)
    let statusStack = NSStackView(frame: .zero)
    let spinner = NSProgressIndicator(frame: .zero)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let statusExportButton = NSButton(title: "Export…", target: nil, action: nil)
    let footerLabel = NSTextField(labelWithString: "")

    static let fixedRangeUnavailableHelp =
        "Fixed 0-1 applies to identity and p-distance. Corrected distances have no upper bound."

    var contentPreferredFontProvider: any ContentPreferredFontProviding = AppKitContentPreferredFontProvider()
    private(set) var typographyApplicationCount = 0

    // MARK: Init

    public init(
        pasteboard: PasteboardWriting = DefaultPasteboard(),
        model: MSADistanceMatrixPaneModel = MSADistanceMatrixPaneModel()
    ) {
        self.model = model
        self.gridView = MSADistanceMatrixGridView(pasteboard: pasteboard)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        clipsToBounds = true
        setAccessibilityElement(false)
        buildHeaderBar()
        buildContent()
        wireModel()
        applyTypography()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentTextSizeDidChange(_:)),
            name: .contentTextSizeDidChange,
            object: nil
        )
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override var isFlipped: Bool { true }

    @objc private func contentTextSizeDidChange(_ notification: Notification) {
        applyTypography()
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        syncHeadersToScroll()
    }

    // MARK: Public API

    public func load(bundleURL: URL, alphabet: MSASequenceAlphabet) {
        model.load(bundleURL: bundleURL, alphabet: alphabet)
    }

    public func load(records: [MSAAlignedRecord], alphabet: MSASequenceAlphabet) {
        model.load(records: records, alphabet: alphabet)
    }

    /// Reverse sync (ruling U7): the alignment's row selection, as input
    /// record indices, clears cells and bolds the matching headers.
    /// The selection is kept, so a matrix that becomes ready later, on first
    /// show or after a recompute, shows it too (review S5).
    public func reflectAlignmentSelection(_ recordIndices: IndexSet) {
        alignmentSelection = recordIndices
        guard let matrix = model.matrix else { return }
        var positions = IndexSet()
        for (position, record) in matrix.recordIndices.enumerated() where recordIndices.contains(record) {
            positions.insert(position)
        }
        gridView.reflectSequences(positions)
    }

    /// The alignment's row selection as input record indices, last reported
    /// by the alignment or made from the matrix.
    public private(set) var alignmentSelection = IndexSet()

    /// Shows an error in place of the matrix when the alignment cannot be
    /// read, such as a manifest with no readable alphabet.
    public func showLoadFailure(_ message: String) {
        model.fail(message)
    }

    /// The first and last views of the pane's key view chain, for the host
    /// to link into the window's loop (review S3).
    public var firstKeyView: NSView { modelPopup }
    public var lastKeyView: NSView { gridView }

    /// The matrix TSV for the current options, byte-identical to the CLI.
    public var matrixTSV: String? { model.matrix?.tsv }

    // MARK: Building

    private func buildHeaderBar() {
        headerBar.orientation = .horizontal
        headerBar.spacing = 8
        headerBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        headerBar.alignment = .centerY
        headerBar.clipsToBounds = true
        // The pane lays the bar out by frame, and its frame starts empty, so
        // the stack clips its controls instead of breaking its own required
        // spacing (orchestrator item b, "Conflicting constraints detected").
        headerBar.setClippingResistancePriority(.defaultHigh, for: .horizontal)
        headerBar.setClippingResistancePriority(.defaultHigh, for: .vertical)

        modelPopup.setAccessibilityLabel("Distance model")
        modelPopup.toolTip = "Distance model (--model)"
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))

        for policy in MSAGapPolicy.allCases {
            gapsPopup.addItem(withTitle: policy.displayName)
            gapsPopup.lastItem?.representedObject = policy.rawValue
        }
        gapsPopup.setAccessibilityLabel("Gaps")
        gapsPopup.toolTip = "Gap handling (--gaps)"
        gapsPopup.target = self
        gapsPopup.action = #selector(gapsChanged(_:))

        for order in MSADistanceOrder.allCases {
            orderPopup.addItem(withTitle: order.displayName)
            orderPopup.lastItem?.representedObject = order.rawValue
        }
        orderPopup.setAccessibilityLabel("Order")
        orderPopup.toolTip = "Row and column order (--order)"
        orderPopup.target = self
        orderPopup.action = #selector(orderChanged(_:))

        fixedRangeCheckbox.target = self
        fixedRangeCheckbox.action = #selector(fixedRangeChanged(_:))
        showValuesCheckbox.target = self
        showValuesCheckbox.action = #selector(showValuesChanged(_:))
        copyMatrixButton.bezelStyle = .push
        copyMatrixButton.target = self
        copyMatrixButton.action = #selector(copyMatrixPressed(_:))
        copyMatrixButton.toolTip = "Copy the whole matrix as TSV"
        exportButton.bezelStyle = .push
        exportButton.target = self
        exportButton.action = #selector(exportPressed(_:))
        exportButton.toolTip = "Export Matrix as TSV…"
        exportButton.setAccessibilityLabel("Export Matrix as TSV")

        let spacer = NSView(frame: .zero)
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        for view in [modelPopup, gapsPopup, orderPopup, fixedRangeCheckbox, showValuesCheckbox,
                     copyMatrixButton, exportButton, spacer, legendView] as [NSView] {
            headerBar.addArrangedSubview(view)
        }
        legendView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(headerBar)
    }

    private func buildContent() {
        scrollView.documentView = gridView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        gridView.rowHeaderView = rowHeaderView
        gridView.columnHeaderView = columnHeaderView
        cornerView.clipsToBounds = true

        statusStack.orientation = .vertical
        statusStack.alignment = .centerX
        statusStack.spacing = 8
        statusStack.clipsToBounds = true
        statusStack.setClippingResistancePriority(.defaultHigh, for: .horizontal)
        statusStack.setClippingResistancePriority(.defaultHigh, for: .vertical)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = true
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusExportButton.target = self
        statusExportButton.action = #selector(exportPressed(_:))
        statusExportButton.setAccessibilityLabel("Export Matrix as TSV")
        for view in [spinner, statusLabel, statusExportButton] { statusStack.addArrangedSubview(view) }

        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.setAccessibilityLabel("Focused pair")

        for view in [cornerView, columnHeaderView, rowHeaderView, scrollView, statusStack, footerLabel] {
            addSubview(view)
        }

        // Key view order follows the header bar, then the grid (ux memo section 5).
        let chain: [NSView] = [modelPopup, gapsPopup, orderPopup, fixedRangeCheckbox, showValuesCheckbox,
                               copyMatrixButton, exportButton, statusExportButton, gridView]
        for (view, next) in zip(chain, chain.dropFirst()) { view.nextKeyView = next }
    }

    private func wireModel() {
        model.onChange = { [weak self] in self?.render() }

        gridView.onSelectionChanged = { [weak self] selection in
            guard let self, let matrix = self.model.matrix else { return }
            let records = IndexSet(selection.sequenceIndices.compactMap {
                matrix.recordIndices.indices.contains($0) ? matrix.recordIndices[$0] : nil
            })
            self.alignmentSelection = records
            self.onSequencesSelected?(records)
        }
        gridView.onFocusChanged = { [weak self] focus in self?.focusChanged(focus) }
        gridView.onReveal = { [weak self] cell in
            guard let self, let matrix = self.model.matrix else { return }
            self.onRevealPair?(matrix.recordIndices[cell.row], matrix.recordIndices[cell.column])
        }
        gridView.onCopyMatrix = { [weak self] in self?.copyMatrixPressed(nil) }
        gridView.onExport = { [weak self] in self?.exportPressed(nil) }
        gridView.isExportAvailable = { [weak self] in self?.model.canExport ?? false }
        gridView.onDisplayOptionsChanged = { [weak self] in
            self?.legendView.needsDisplay = true
            self?.needsLayout = true
        }

        let headerClick: (Int, NSEvent.ModifierFlags) -> Void = { [weak self] index, flags in
            guard let self else { return }
            self.window?.makeFirstResponder(self.gridView)
            self.gridView.headerClicked(index, modifiers: flags)
        }
        rowHeaderView.onHeaderClick = headerClick
        columnHeaderView.onHeaderClick = headerClick
    }

    // MARK: Rendering

    private var shownMatrix: MSADistanceMatrix?

    /// Pushes model state into the controls and the grid.
    func render() {
        refreshModelPopup()
        selectItem(in: gapsPopup, rawValue: model.gaps.rawValue)
        selectItem(in: orderPopup, rawValue: model.order.rawValue)
        fixedRangeCheckbox.state = model.usesFixedUnitRange ? .on : .off
        fixedRangeCheckbox.isEnabled = model.isFixedUnitRangeAvailable
        fixedRangeCheckbox.toolTip = model.isFixedUnitRangeAvailable
            ? "Colour the scale from 0 to 1 instead of the data range"
            : Self.fixedRangeUnavailableHelp
        fixedRangeCheckbox.setAccessibilityHelp(fixedRangeCheckbox.toolTip)
        showValuesCheckbox.state = model.showsValues ? .on : .off

        let matrix = model.matrix
        if matrix != shownMatrix {
            shownMatrix = matrix
            gridView.setMatrix(matrix)
            rowHeaderView.names = matrix?.names ?? []
            columnHeaderView.names = matrix?.names ?? []
            focusChanged(nil)
            if matrix != nil, !alignmentSelection.isEmpty {
                reflectAlignmentSelection(alignmentSelection)
            }
        }
        gridView.colorScale = model.colorScale
        gridView.showsValues = model.showsValues
        copyMatrixButton.isEnabled = matrix != nil
        exportButton.isEnabled = model.canExport

        legendView.update(
            modelName: model.effectiveModel.rawValue,
            scale: model.colorScale,
            isEmpty: matrix == nil
        )

        switch model.status {
        case .idle:
            showStatus(text: "No alignment loaded.", spinning: false, export: false)
        case .computing:
            showStatus(text: "Computing…", spinning: true, export: false)
        case .tooManyRows(let count):
            showStatus(text: MSADistanceMatrixText.tooManyRows(count, limit: model.maxRowsForInlineMatrix), spinning: false, export: true)
        case .failed(let message):
            showStatus(text: "The distance matrix could not be computed. \(message)", spinning: false, export: false)
        case .ready:
            statusStack.isHidden = true
            spinner.stopAnimation(nil)
            scrollView.isHidden = false
            rowHeaderView.isHidden = false
            columnHeaderView.isHidden = false
        }
        needsLayout = true
    }

    private func showStatus(text: String, spinning: Bool, export: Bool) {
        statusStack.isHidden = false
        statusLabel.stringValue = text
        spinner.isHidden = !spinning
        if spinning && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        statusExportButton.isHidden = !export
        scrollView.isHidden = true
        rowHeaderView.isHidden = true
        columnHeaderView.isHidden = true
        NSAccessibility.post(element: statusLabel, notification: .valueChanged)
    }

    private func refreshModelPopup() {
        let models = model.availableModels
        let titles = models.map(\.displayName)
        if modelPopup.itemTitles != titles {
            modelPopup.removeAllItems()
            for entry in models {
                modelPopup.addItem(withTitle: entry.displayName)
                modelPopup.lastItem?.representedObject = entry.rawValue
            }
        }
        selectItem(in: modelPopup, rawValue: model.effectiveModel.rawValue)
    }

    private func selectItem(in popup: NSPopUpButton, rawValue: String) {
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == rawValue }) {
            popup.select(item)
        }
    }

    private func focusChanged(_ focus: MSADistanceCell?) {
        guard let focus, let matrix = model.matrix,
              matrix.names.indices.contains(focus.row), matrix.names.indices.contains(focus.column)
        else {
            footerLabel.stringValue = ""
            onFocusedPairChanged?(nil, "", "")
            return
        }
        let detail = matrix.detail(row: focus.row, column: focus.column)
        let rowName = matrix.names[focus.row]
        let columnName = matrix.names[focus.column]
        footerLabel.stringValue = MSADistanceMatrixText.footer(
            rowName: rowName,
            columnName: columnName,
            modelName: matrix.options.model.rawValue,
            value: detail.value,
            comparableSites: detail.comparableSites,
            differences: detail.differences,
            gapSkipped: detail.gapSkipped,
            ambiguitySkipped: detail.ambiguitySkipped
        )
        footerLabel.toolTip = footerLabel.stringValue
        onFocusedPairChanged?(detail, rowName, columnName)
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let barHeight = ceil(max(28, headerBar.fittingSize.height))
        headerBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let footerHeight = ceil(max(20, footerLabel.fittingSize.height + 4))
        footerLabel.frame = NSRect(x: 8, y: bounds.height - footerHeight + 2, width: max(0, bounds.width - 16), height: footerHeight - 4)
        let content = NSRect(x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight - footerHeight))

        let gutter = rowHeaderView.names.isEmpty ? 0 : rowHeaderView.preferredWidth()
        let headerHeight = columnHeaderView.names.isEmpty ? 0 : columnHeaderView.preferredHeight()
        rowHeaderView.cellSide = gridView.cellSide
        columnHeaderView.cellSide = gridView.cellSide
        cornerView.frame = NSRect(x: content.minX, y: content.minY, width: gutter, height: headerHeight)
        columnHeaderView.frame = NSRect(x: content.minX + gutter, y: content.minY, width: max(0, content.width - gutter), height: headerHeight)
        rowHeaderView.frame = NSRect(x: content.minX, y: content.minY + headerHeight, width: gutter, height: max(0, content.height - headerHeight))
        scrollView.frame = NSRect(
            x: content.minX + gutter,
            y: content.minY + headerHeight,
            width: max(0, content.width - gutter),
            height: max(0, content.height - headerHeight)
        )
        let statusSize = NSSize(width: min(content.width - 32, 420), height: statusStack.fittingSize.height)
        statusLabel.preferredMaxLayoutWidth = max(0, statusSize.width)
        statusStack.frame = NSRect(
            x: content.midX - statusSize.width / 2,
            y: content.midY - statusSize.height / 2,
            width: max(0, statusSize.width),
            height: statusSize.height
        )
        syncHeadersToScroll()
    }

    private func syncHeadersToScroll() {
        let origin = scrollView.contentView.bounds.origin
        rowHeaderView.scrollOffset = origin.y
        columnHeaderView.scrollOffset = origin.x
    }

    // MARK: Typography

    func applyTypography() {
        let typography = ContentTypography.current(preferredFontProvider: contentPreferredFontProvider)
        gridView.typography = typography
        let headerFont = NSFontManager.shared.convert(typography.font(for: .tableHeader), toNotHaveTrait: .boldFontMask)
        rowHeaderView.font = headerFont
        columnHeaderView.font = headerFont
        legendView.font = typography.font(for: .caption)
        footerLabel.font = typography.font(for: .caption)
        statusLabel.font = typography.font(for: .body)
        typographyApplicationCount += 1
        needsLayout = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    // MARK: Actions

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let value = MSADistanceModel(rawValue: raw) else { return }
        model.model = value
    }

    @objc private func gapsChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let value = MSAGapPolicy(rawValue: raw) else { return }
        model.gaps = value
    }

    @objc private func orderChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let value = MSADistanceOrder(rawValue: raw) else { return }
        model.order = value
    }

    @objc private func fixedRangeChanged(_ sender: NSButton) {
        model.fixedUnitRange = sender.state == .on
    }

    @objc private func showValuesChanged(_ sender: NSButton) {
        model.showsValues = sender.state == .on
    }

    @objc func copyMatrixPressed(_ sender: Any?) {
        guard let tsv = model.matrix?.tsv else { return }
        gridView.pasteboard.setString(tsv)
    }

    @objc func exportPressed(_ sender: Any?) {
        guard model.canExport else { return }
        onExportRequested?(model.options)
    }
}

/// Gradient legend with min and max, the model name and the two pattern
/// swatches. VoiceOver reads it as one static text (ux memo section 3).
@MainActor
public final class MSADistanceMatrixLegendView: NSView {
    public var font = NSFont.preferredFont(forTextStyle: .caption1) {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private(set) var modelName = ""
    private(set) var scale = MSADistanceColorScale(lower: 0, upper: 1)
    private(set) var isEmpty = true

    public override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    func update(modelName: String, scale: MSADistanceColorScale, isEmpty: Bool) {
        self.modelName = modelName
        self.scale = scale
        self.isEmpty = isEmpty
        isHidden = isEmpty
        setAccessibilityLabel(MSADistanceMatrixText.legendLabel(modelName: modelName, lower: scale.lower, upper: scale.upper))
        toolTip = accessibilityLabel()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var pieces: (min: String, max: String, nan: String, inf: String) {
        (MSADistanceValueFormat.cell(scale.lower), MSADistanceValueFormat.cell(scale.upper), "n/a", "∞")
    }

    private func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static let barWidth: CGFloat = 64
    static let swatch: CGFloat = 12

    public override var intrinsicContentSize: NSSize {
        let p = pieces
        let total = width(modelName) + 6 + width(p.min) + 4 + Self.barWidth + 4 + width(p.max)
            + 10 + Self.swatch + 3 + width(p.nan) + 8 + Self.swatch + 3 + width(p.inf)
        return NSSize(width: total, height: max(Self.swatch, ceil(font.ascender - font.descender)) + 4)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !isEmpty else { return }
        let appearanceKind = MSADistanceAppearance(effectiveAppearance)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let lineHeight = font.ascender - font.descender
        let textY = bounds.midY - lineHeight / 2
        var x: CGFloat = 0
        func text(_ string: String) {
            (string as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: attributes)
            x += width(string)
        }
        let p = pieces
        text(modelName); x += 6
        text(p.min); x += 4
        let bar = NSRect(x: x, y: bounds.midY - Self.swatch / 2, width: Self.barWidth, height: Self.swatch)
        let steps = 32
        for step in 0..<steps {
            let colour = MSADistanceColorScale.rampColor(at: Double(step) / Double(steps - 1), appearance: appearanceKind)
            colour.nsColor.setFill()
            NSRect(x: bar.minX + bar.width * CGFloat(step) / CGFloat(steps), y: bar.minY,
                   width: ceil(bar.width / CGFloat(steps)), height: bar.height).fill()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bar.insetBy(dx: 0.5, dy: 0.5)).stroke()
        x = bar.maxX + 4
        text(p.max); x += 10
        let nanBox = NSRect(x: x, y: bounds.midY - Self.swatch / 2, width: Self.swatch, height: Self.swatch)
        NSBezierPath(rect: nanBox.insetBy(dx: 0.5, dy: 0.5)).stroke()
        MSADistanceMatrixGridView.drawNotDefinedMark(in: nanBox)
        x = nanBox.maxX + 3
        text(p.nan); x += 8
        let infBox = NSRect(x: x, y: bounds.midY - Self.swatch / 2, width: Self.swatch, height: Self.swatch)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: infBox).addClip()
        let hatch = NSBezierPath()
        var offset: CGFloat = -infBox.height
        while offset < infBox.width {
            hatch.move(to: NSPoint(x: infBox.minX + offset, y: infBox.maxY))
            hatch.line(to: NSPoint(x: infBox.minX + offset + infBox.height, y: infBox.minY))
            offset += 4
        }
        NSColor.tertiaryLabelColor.setStroke()
        hatch.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: infBox.insetBy(dx: 0.5, dy: 0.5)).stroke()
        x = infBox.maxX + 3
        text(p.inf)
    }
}
