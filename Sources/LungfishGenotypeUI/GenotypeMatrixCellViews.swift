import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

private extension GenotypeCandidateMatrixRowID {
    var accessibilityIdentifierComponent: String {
        switch self {
        case let .known(locus, genotype):
            return "known:\(locus):\(genotype)"
        case let .candidate(stableClusterID):
            return "candidate:\(stableClusterID)"
        }
    }
}

final class GenotypeMatrixTableView: NSTableView {
    var onCellClick: ((Int, Int, NSEvent.ModifierFlags) -> Bool)?
    var onContextMenuRequest: ((Int, Int) -> NSMenu?)?
    private var hasExplicitAccessibilityFocus = false

#if DEBUG
    private(set) var testingFullReloadCount = 0
    private(set) var testingPartialReloadCount = 0
    private(set) var testingPartialReloadedCellCount = 0
    private(set) var testingReloadedRowCount = 0

    func testingResetReloadCounters() {
        testingFullReloadCount = 0
        testingPartialReloadCount = 0
        testingPartialReloadedCellCount = 0
        testingReloadedRowCount = 0
    }

#endif

    override func isAccessibilityFocused() -> Bool {
        hasExplicitAccessibilityFocus || super.isAccessibilityFocused()
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        hasExplicitAccessibilityFocus = focused
    }

    override func reloadData() {
#if DEBUG
        testingFullReloadCount += 1
        testingReloadedRowCount += numberOfRows
#endif
        super.reloadData()
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
#if DEBUG
        testingPartialReloadCount += 1
        testingPartialReloadedCellCount += rowIndexes.count * columnIndexes.count
        testingReloadedRowCount += rowIndexes.count
#endif
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    override func mouseDown(with event: NSEvent) {
        // NSTableView.mouseDown gives a table the keyboard focus before it acts
        // on a click, and a click that onCellClick handles never reaches it.
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if onCellClick?(row(at: point), column(at: point), event.modifierFlags) == true { return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let menu = onContextMenuRequest?(row(at: point), column(at: point)) {
            return menu
        }
        return super.menu(for: event)
    }
}

final class GenotypeMatrixStyledCellView: NSTableCellView {
    private var chromeBackgroundColor: NSColor?
    private var decorativeBorderColor: NSColor?
    private var decorativeBorderWidth: CGFloat = 0
    private var previewBorderColor: NSColor?
    private var previewBorderWidth: CGFloat = 0
    private var semanticInnerFrameColor: NSColor?
    private var semanticInnerFrameWidth: CGFloat = 0
    private var selectionAccentColor: NSColor?
    private var selectionCornerBracketWidth: CGFloat = 0
    private var selectionCornerBracketLength: CGFloat = 0
    private var commentFoldColor: NSColor?
    private var commentFoldSize: CGFloat = 0

#if DEBUG
    var testingChromeBackgroundColor: NSColor? {
        chromeBackgroundColor
    }
#endif

    /// Positions `textField` by frame (inset 4pt on each side, vertically centered) instead of
    /// Auto Layout constraints — see the comment in `makeCellView(identifier:)` for why. Called
    /// once at construction and again from `layout()` on every subsequent resize (column resize,
    /// row height change), so it must stay cheap: no constraint solving, just arithmetic on the
    /// already-known bounds.
    func layoutTextFieldFrame() {
        guard let field = textField else { return }
        let inset: CGFloat = 4
        let fieldHeight = min(bounds.height, field.intrinsicContentSize.height.isFinite
            ? max(field.intrinsicContentSize.height, 1)
            : bounds.height)
        let originY = ((bounds.height - fieldHeight) / 2).rounded()
        field.frame = NSRect(
            x: inset,
            y: originY,
            width: max(0, bounds.width - inset * 2),
            height: fieldHeight
        )
    }

    override func layout() {
        super.layout()
        layoutTextFieldFrame()
    }

    func configureChrome(
        backgroundColor: NSColor?,
        decorativeBorderColor: NSColor?,
        decorativeBorderWidth: CGFloat,
        previewBorderColor: NSColor?,
        previewBorderWidth: CGFloat,
        semanticInnerFrameColor: NSColor?,
        semanticInnerFrameWidth: CGFloat,
        selectionAccentColor: NSColor?,
        selectionCornerBracketWidth: CGFloat,
        selectionCornerBracketLength: CGFloat,
        commentFoldColor: NSColor?,
        commentFoldSize: CGFloat
    ) {
        chromeBackgroundColor = backgroundColor
        self.decorativeBorderColor = decorativeBorderColor
        self.decorativeBorderWidth = decorativeBorderWidth
        self.previewBorderColor = previewBorderColor
        self.previewBorderWidth = previewBorderWidth
        self.semanticInnerFrameColor = semanticInnerFrameColor
        self.semanticInnerFrameWidth = semanticInnerFrameWidth
        self.selectionAccentColor = selectionAccentColor
        self.selectionCornerBracketWidth = selectionCornerBracketWidth
        self.selectionCornerBracketLength = selectionCornerBracketLength
        self.commentFoldColor = commentFoldColor
        self.commentFoldSize = commentFoldSize
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let maximumStroke = max(
            max(decorativeBorderWidth, previewBorderWidth),
            max(semanticInnerFrameWidth, selectionCornerBracketWidth)
        )
        let inset = max(maximumStroke / 2, 0.5)
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if let chromeBackgroundColor {
            chromeBackgroundColor.setFill()
            path.fill()
        }
        if let decorativeBorderColor, decorativeBorderWidth > 0 {
            decorativeBorderColor.setStroke()
            path.lineWidth = decorativeBorderWidth
            path.stroke()
        }
        if let previewBorderColor, previewBorderWidth > 0 {
            previewBorderColor.setStroke()
            path.lineWidth = previewBorderWidth
            path.stroke()
        }
        if let semanticInnerFrameColor, semanticInnerFrameWidth > 0 {
            let semanticInset = max(3, semanticInnerFrameWidth + 1)
            let semanticRect = bounds.insetBy(dx: semanticInset, dy: semanticInset)
            if semanticRect.width > 0, semanticRect.height > 0 {
                let semanticPath = NSBezierPath(roundedRect: semanticRect, xRadius: 2, yRadius: 2)
                semanticInnerFrameColor.setStroke()
                semanticPath.lineWidth = semanticInnerFrameWidth
                semanticPath.stroke()
            }
        }
        if let selectionAccentColor, selectionCornerBracketWidth > 0 {
            drawSelectionCornerBrackets(
                in: rect,
                color: selectionAccentColor,
                width: selectionCornerBracketWidth,
                length: selectionCornerBracketLength
            )
        }
        if let commentFoldColor, commentFoldSize > 0 {
            drawCommentFold(color: commentFoldColor, size: commentFoldSize)
        }
    }

    private func drawSelectionCornerBrackets(
        in rect: NSRect,
        color: NSColor,
        width: CGFloat,
        length: CGFloat
    ) {
        let length = min(length, min(rect.width, rect.height) / 2)
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        for (corner, horizontal, vertical) in [
            (NSPoint(x: rect.minX, y: rect.minY), CGFloat(1), CGFloat(1)),
            (NSPoint(x: rect.maxX, y: rect.minY), CGFloat(-1), CGFloat(1)),
            (NSPoint(x: rect.minX, y: rect.maxY), CGFloat(1), CGFloat(-1)),
            (NSPoint(x: rect.maxX, y: rect.maxY), CGFloat(-1), CGFloat(-1)),
        ] {
            path.move(to: NSPoint(x: corner.x + horizontal * length, y: corner.y))
            path.line(to: corner)
            path.line(to: NSPoint(x: corner.x, y: corner.y + vertical * length))
        }
        color.setStroke()
        path.stroke()
    }

    private func drawCommentFold(color: NSColor, size: CGFloat) {
        let top = isFlipped ? bounds.minY : bounds.maxY
        let inwardY: CGFloat = isFlipped ? size : -size
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.maxX - size, y: top))
        path.line(to: NSPoint(x: bounds.maxX, y: top))
        path.line(to: NSPoint(x: bounds.maxX, y: top + inwardY))
        path.close()
        color.setFill()
        path.fill()
    }
}

final class GenotypeMatrixSelectorButton: NSButton {
    enum Identity: Equatable {
        case row(GenotypeCandidateMatrixRowID)
        case column(String)
        case selectAll
    }

    var selectorIdentity: Identity?
    var onPress: ((NSEvent.ModifierFlags) -> Bool)?
    var onAccessibilityValueChanged: (() -> Void)?
    var onAccessibilityFocusChanged:
        ((GenotypeMatrixSelectorButton, Bool) -> Void)?
    private var hasConfiguredSelectionState = false
    private var hasExplicitAccessibilityFocus = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    private func buildView() {
        setButtonType(.switch)
        title = ""
        image = nil
        isBordered = false
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        target = self
        action = #selector(pressed(_:))
    }

    func configure(
        identity: Identity,
        label: String,
        identifier: String,
        isSelected: Bool,
        onPress: @escaping (NSEvent.ModifierFlags) -> Bool
    ) {
        let previousIdentity = selectorIdentity
        let changed = hasConfiguredSelectionState
            && previousIdentity == identity
            && ((state == .on) != isSelected)
        if previousIdentity != identity, hasExplicitAccessibilityFocus {
            setAccessibilityFocused(false)
        }
        selectorIdentity = identity
        self.onPress = onPress
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        state = isSelected ? .on : .off
        hasConfiguredSelectionState = true
        if changed {
            NSAccessibility.post(element: self, notification: .valueChanged)
            onAccessibilityValueChanged?()
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        _ = performPress(modifiers: NSApp.currentEvent?.modifierFlags ?? [])
    }

    @discardableResult
    private func performPress(modifiers: NSEvent.ModifierFlags) -> Bool {
        return onPress?(modifiers) == true
    }

    override func accessibilityPerformPress() -> Bool {
        performPress(modifiers: [])
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: state == .on ? 1 : 0)
    }

    override func accessibilityValueDescription() -> String? {
        state == .on ? "Selected" : "Not selected"
    }

    override func isAccessibilityFocused() -> Bool {
        hasExplicitAccessibilityFocus || super.isAccessibilityFocused()
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard hasExplicitAccessibilityFocus != focused else { return }
        hasExplicitAccessibilityFocus = focused
        onAccessibilityFocusChanged?(self, focused)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Visuals are drawn by the established matrix chiclet beneath this
        // transparent native checkbox. The real control supplies keyboard,
        // focus, and accessibility behavior without changing matrix density.
        if window?.firstResponder === self {
            NSFocusRingPlacement.only.set()
            bounds.fill()
        }
    }
}

final class GenotypeMatrixRowSelectorCellView: NSTableCellView {
    private let chiclet = GenotypeMatrixRowSelectorChicletView()
    private let selectorButton = GenotypeMatrixSelectorButton()
    private var commentFoldSize: CGFloat?

    /// Computes the row's accessibility actions when an AX client asks.
    var accessibilityActionsProvider: (() -> [NSAccessibilityCustomAction])?

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let actions = accessibilityActionsProvider?() ?? []
        return actions.isEmpty ? nil : actions
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    func configure(
        rowID: GenotypeCandidateMatrixRowID,
        label: String,
        isSelected: Bool,
        commentFoldSize: CGFloat?,
        onAccessibilityValueChanged: @escaping () -> Void,
        onAccessibilityFocusChanged:
            @escaping (GenotypeMatrixSelectorButton, Bool) -> Void,
        onPress: @escaping (GenotypeCandidateMatrixRowID, NSEvent.ModifierFlags) -> Bool
    ) {
        chiclet.configure(isSelected: isSelected)
        selectorButton.onAccessibilityValueChanged = onAccessibilityValueChanged
        selectorButton.onAccessibilityFocusChanged = onAccessibilityFocusChanged
        selectorButton.configure(
            identity: .row(rowID),
            label: label,
            identifier: "genotype-row-selector.\(rowID.accessibilityIdentifierComponent)",
            isSelected: isSelected,
            onPress: { modifiers in onPress(rowID, modifiers) }
        )
        self.commentFoldSize = commentFoldSize
        needsDisplay = true
    }

    private func buildView() {
        setAccessibilityElement(false)
        chiclet.setAccessibilityElement(false)
        chiclet.translatesAutoresizingMaskIntoConstraints = false
        selectorButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chiclet)
        addSubview(selectorButton)
        NSLayoutConstraint.activate([
            chiclet.widthAnchor.constraint(equalToConstant: 12),
            chiclet.heightAnchor.constraint(equalToConstant: 12),
            chiclet.centerXAnchor.constraint(equalTo: centerXAnchor),
            chiclet.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectorButton.widthAnchor.constraint(equalToConstant: 16),
            selectorButton.heightAnchor.constraint(equalToConstant: 16),
            selectorButton.centerXAnchor.constraint(equalTo: chiclet.centerXAnchor),
            selectorButton.centerYAnchor.constraint(equalTo: chiclet.centerYAnchor),
        ])
    }

    var accessibilitySelectorButton: GenotypeMatrixSelectorButton {
        selectorButton
    }

#if DEBUG
    var accessibilityTreeSnapshot:
        GenotypeMatrixRowSelectorAccessibilityTreeSnapshot {
        return GenotypeMatrixRowSelectorAccessibilityTreeSnapshot(
            cellIsAccessibilityElement: isAccessibilityElement(),
            chicletIsAccessibilityElement: chiclet.isAccessibilityElement(),
            actionableDescendantCount:
                selectorButton.isAccessibilityElement() ? 1 : 0
        )
    }
#endif

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let size = commentFoldSize else { return }
        let top = isFlipped ? bounds.minY : bounds.maxY
        let inwardY: CGFloat = isFlipped ? size : -size
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.maxX - size, y: top))
        path.line(to: NSPoint(x: bounds.maxX, y: top))
        path.line(to: NSPoint(x: bounds.maxX, y: top + inwardY))
        path.close()
        NSColor.controlAccentColor.setFill()
        path.fill()
    }
}

private final class GenotypeMatrixRowSelectorChicletView: NSView {
    private var fillColor = NSColor.clear
    private var strokeColor = NSColor.tertiaryLabelColor
    private var strokeWidth: CGFloat = 1

    func configure(isSelected: Bool) {
        fillColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.24) : .clear
        strokeColor = isSelected ? .controlAccentColor : .tertiaryLabelColor
        strokeWidth = isSelected ? 1.5 : 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = max(strokeWidth / 2, 0.5)
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = strokeWidth
        path.stroke()
    }
}

final class GenotypeMatrixHeaderView: NSTableHeaderView {
    var isColumnSelectable: ((Int) -> Bool)?
    var isColumnSelected: ((Int) -> Bool)?
    var selectorIdentityForColumn: ((Int) -> GenotypeMatrixSelectorButton.Identity?)?
    var selectorLabelForColumn: ((Int) -> String?)?
    var onSelectorAccessibilityValueChanged: (() -> Void)?
    var onSelectorAccessibilityFocusChanged:
        ((GenotypeMatrixSelectorButton, Bool) -> Void)?
    var onColumnChicletClick: ((Int, NSEvent.ModifierFlags) -> Bool)?
    var readTitleForColumn: ((Int) -> String?)?
    var hasCommentForColumn: ((Int) -> Bool)?
    var commentFoldSize: (() -> CGFloat)?
    var titleFont: (() -> NSFont)?
    var readFont: (() -> NSFont)?
    var chicletSize: (() -> CGFloat)?
    var onContextMenuRequest: ((Int) -> NSMenu?)?
    var headerLayout = GenotypeManualHaplotypeHeaderLayout(
        isEligible: false,
        isExpanded: false,
        ordinaryHeight: 34,
        disclosureHeight: 22,
        rowHeight: 22
    ) {
        didSet {
            if frame.height != headerLayout.totalHeight {
                frame.size.height = headerLayout.totalHeight
            }
            needsLayout = true
            needsDisplay = true
        }
    }
    var manualContentView: NSView? {
        didSet {
            guard oldValue !== manualContentView else { return }
            oldValue?.removeFromSuperview()
            if let manualContentView {
                addSubview(manualContentView)
            }
            needsLayout = true
        }
    }
    private var selectorButtons:
        [NSUserInterfaceItemIdentifier: GenotypeMatrixSelectorButton] = [:]

    var ordinaryHeaderHeight: CGFloat {
        headerLayout.ordinaryHeight
    }

    var ordinaryHeaderBounds: NSRect {
        headerLayout.ordinaryRect(in: bounds, isFlipped: isFlipped)
    }

    var manualHeaderBounds: NSRect {
        headerLayout.manualRect(in: bounds, isFlipped: isFlipped)
    }

    func ordinaryHeaderRect(ofColumn column: Int) -> NSRect {
        let columnRect = headerRect(ofColumn: column)
        let ordinaryBounds = ordinaryHeaderBounds
        return NSRect(
            x: columnRect.minX,
            y: ordinaryBounds.minY,
            width: columnRect.width,
            height: ordinaryBounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tableView else { return }
        synchronizeSelectorButtons()
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        for column in 0..<tableView.numberOfColumns {
            let rect = ordinaryHeaderRect(ofColumn: column)
            guard rect.intersects(dirtyRect) else { continue }
            drawHeaderCell(
                in: rect,
                title: tableView.tableColumns[column].title,
                readTitle: readTitleForColumn?(column),
                selectable: isColumnSelectable?(column) == true,
                selected: isColumnSelected?(column) == true,
                hasComment: hasCommentForColumn?(column) == true
            )
        }
    }

    override func layout() {
        super.layout()
        manualContentView?.frame = manualHeaderBounds
        synchronizeSelectorButtons()
    }

    func refreshSelectorButtons() {
        synchronizeSelectorButtons()
    }

    func selectorButton(
        matching identity: GenotypeMatrixSelectorButton.Identity
    ) -> GenotypeMatrixSelectorButton? {
        synchronizeSelectorButtons()
        return selectorButtons.values.first { $0.selectorIdentity == identity }
    }

    private func synchronizeSelectorButtons() {
        guard let tableView else { return }
        var activeIdentifiers: Set<NSUserInterfaceItemIdentifier> = []
        for column in tableView.tableColumns.indices
        where isColumnSelectable?(column) == true {
            let tableColumn = tableView.tableColumns[column]
            let identifier = tableColumn.identifier
            guard let identity = selectorIdentityForColumn?(column),
                  let label = selectorLabelForColumn?(column) else {
                continue
            }
            activeIdentifiers.insert(identifier)
            let button: GenotypeMatrixSelectorButton
            if let existing = selectorButtons[identifier] {
                button = existing
            } else {
                button = GenotypeMatrixSelectorButton()
                button.translatesAutoresizingMaskIntoConstraints = true
                selectorButtons[identifier] = button
                addSubview(button)
            }
            let accessibilityIdentifier: String
            switch identity {
            case .selectAll:
                accessibilityIdentifier = "genotype-matrix-select-all"
            case let .column(sample):
                accessibilityIdentifier = "genotype-column-selector.\(sample)"
            case let .row(rowID):
                accessibilityIdentifier =
                    "genotype-row-selector.\(rowID.accessibilityIdentifierComponent)"
            }
            button.onAccessibilityValueChanged = onSelectorAccessibilityValueChanged
            button.onAccessibilityFocusChanged = onSelectorAccessibilityFocusChanged
            button.configure(
                identity: identity,
                label: label,
                identifier: accessibilityIdentifier,
                isSelected: isColumnSelected?(column) == true,
                onPress: { [weak self] modifiers in
                    guard let self,
                          let tableView = self.tableView,
                          let currentColumn = tableView.tableColumns.firstIndex(
                              where: { $0.identifier == identifier }
                          ) else {
                        return false
                    }
                    return self.onColumnChicletClick?(currentColumn, modifiers) == true
                }
            )
            button.frame = chicletRect(forColumn: column).insetBy(dx: -2, dy: -2)
        }
        for identifier in Set(selectorButtons.keys).subtracting(activeIdentifiers) {
            selectorButtons.removeValue(forKey: identifier)?.removeFromSuperview()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard ordinaryHeaderBounds.contains(point) else { return }
        let column = self.column(at: point)
        if column >= 0,
           isColumnSelectable?(column) == true,
           chicletRect(forColumn: column).contains(point),
           onColumnChicletClick?(column, event.modifierFlags) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard ordinaryHeaderBounds.contains(point) else {
            return super.menu(for: event)
        }
        let column = self.column(at: point)
        if column >= 0, let menu = onContextMenuRequest?(column) {
            return menu
        }
        return super.menu(for: event)
    }

    private func chicletRect(forColumn column: Int) -> NSRect {
        chicletRect(in: ordinaryHeaderRect(ofColumn: column))
    }

    private func drawHeaderCell(
        in rect: NSRect,
        title: String,
        readTitle: String?,
        selectable: Bool,
        selected: Bool,
        hasComment: Bool
    ) {
        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: rect.maxX - 0.5, y: rect.minY))
        divider.line(to: NSPoint(x: rect.maxX - 0.5, y: rect.maxY))
        divider.stroke()

        if selectable {
            drawChiclet(in: chicletRect(in: rect), selected: selected)
        }

        let leftInset: CGFloat = selectable ? 20 : 6
        let bands = textBandRects(in: rect, leftInset: leftInset)
        let titleRect = bands.title
        let readRect = bands.read
        drawText(
            title,
            in: titleRect,
            font: titleFont?() ?? .systemFont(ofSize: 11, weight: .semibold),
            alignment: .left,
            color: .labelColor
        )
        if let readTitle {
            drawText(
                readTitle,
                in: readRect,
                font: readFont?() ?? .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                alignment: .right,
                color: .secondaryLabelColor
            )
        }
        if hasComment {
            drawCommentFold(in: rect, size: commentFoldSize?() ?? 7)
        }
    }

    private func drawCommentFold(in rect: NSRect, size: CGFloat) {
        let top = isFlipped ? rect.minY : rect.maxY
        let inwardY: CGFloat = isFlipped ? size : -size
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.maxX - size, y: top))
        path.line(to: NSPoint(x: rect.maxX, y: top))
        path.line(to: NSPoint(x: rect.maxX, y: top + inwardY))
        path.close()
        NSColor.controlAccentColor.setFill()
        path.fill()
    }

    func textBandRects(
        in rect: NSRect,
        leftInset: CGFloat
    ) -> (title: NSRect, read: NSRect) {
        let titleHeight = ceil(
            (titleFont?() ?? .systemFont(ofSize: 11, weight: .semibold))
                .boundingRectForFont.height
        )
        let readHeight = ceil(
            (readFont?() ?? .monospacedDigitSystemFont(ofSize: 10, weight: .regular))
                .boundingRectForFont.height
        )
        let gap: CGFloat = 2
        let totalHeight = titleHeight + gap + readHeight
        let lowerY = rect.midY - totalHeight / 2
        let readRect = NSRect(
            x: rect.minX + 6,
            y: lowerY,
            width: max(0, rect.width - 10),
            height: readHeight
        )
        let titleRect = NSRect(
            x: rect.minX + leftInset,
            y: readRect.maxY + gap,
            width: max(0, rect.width - leftInset - 4),
            height: titleHeight
        )
        return (titleRect, readRect)
    }

    private func chicletRect(in rect: NSRect) -> NSRect {
        let size = min(chicletSize?() ?? 11, max(11, rect.height - 6))
        return NSRect(
            x: rect.minX + 5,
            y: rect.midY - size / 2,
            width: size,
            height: size
        )
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        alignment: NSTextAlignment,
        color: NSColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func drawChiclet(in rect: NSRect, selected: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let fillColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.24)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.70)
        fillColor.setFill()
        path.fill()
        (selected ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.lineWidth = selected ? 1.5 : 1
        path.stroke()
    }
}
