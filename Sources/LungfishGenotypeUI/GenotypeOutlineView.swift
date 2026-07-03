import AppKit
import LungfishCore
import LungfishIO

@MainActor
final class GenotypeOutlineView: NSView {
    struct Row: Equatable {
        let animalId: String
        let gsId: String?
        let loci: [String]
        let tapeSlots: [GenotypeHaplotypeTapeView.Slot]
        let blockKind: GenotypeBlockKind
        /// Full notes text — hidden by default, surfaced as a tooltip on the
        /// progressive-disclosure alert glyph when non-empty.
        let commentSummary: String
        /// Number of distinct review-worthy notes (TMH / NO HAP / TMG /
        /// special-case). Zero means no alert glyph renders.
        let noteIssueCount: Int
        /// Per-locus haplotype call text (e.g. "M2A / M3A", "ERR: TMH (...)").
        /// Kept as row data for callers that need per-locus call text.
        let perLocusCallText: [(locus: String, h1: String, h2: String, status: GenotypeHaplotypeCallStatus)]

        init(
            animalId: String,
            gsId: String?,
            loci: [String],
            tapeSlots: [GenotypeHaplotypeTapeView.Slot],
            blockKind: GenotypeBlockKind,
            commentSummary: String,
            noteIssueCount: Int,
            perLocusCallText: [(locus: String, h1: String, h2: String, status: GenotypeHaplotypeCallStatus)] = []
        ) {
            self.animalId = animalId
            self.gsId = gsId
            self.loci = loci
            self.tapeSlots = tapeSlots
            self.blockKind = blockKind
            self.commentSummary = commentSummary
            self.noteIssueCount = noteIssueCount
            self.perLocusCallText = perLocusCallText
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.animalId == rhs.animalId && lhs.gsId == rhs.gsId &&
            lhs.loci == rhs.loci && lhs.blockKind == rhs.blockKind &&
            lhs.commentSummary == rhs.commentSummary &&
            lhs.noteIssueCount == rhs.noteIssueCount &&
            lhs.tapeSlots == rhs.tapeSlots &&
            lhs.perLocusCallText.elementsEqual(rhs.perLocusCallText, by: { lhs, rhs in
                lhs.locus == rhs.locus && lhs.h1 == rhs.h1 && lhs.h2 == rhs.h2 && lhs.status == rhs.status
            })
        }
    }

    var onRowSelected: ((String) -> Void)?
    /// Fires when the analyst clicks a single locus cell in the tape.
    /// Passes (animalId, locusName). The controller updates the persistent
    /// Review inspector with `GenotypeCallEvidenceView` for that cell.
    var onLocusCellClicked: ((String, String) -> Void)?
    private(set) var numberOfRows: Int = 0
    private var rows: [Row] = []
    private var reviewSelection = ReviewSelection()

    // MARK: Virtualized surface
    //
    // A single-column `NSTableView` backs the sample list. AppKit only
    // instantiates cell views for rows that are visible in the clip view, so a
    // 300-sample cohort no longer builds 300 full row view-trees up front —
    // only the visible window is materialized, and off-screen rows are built
    // (and recycled) lazily as the analyst scrolls. The per-sample content,
    // selection highlighting, haplotype tape, click-to-select, per-swatch
    // accessibility, and both callbacks are identical to the previous
    // `NSStackView`-per-sample layout; only the container that owns the rows
    // changed.
    private let scrollView = NSScrollView()
    private let tableView = SampleTableView()
    private let sampleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sample"))
    /// The pinned header row (block-glyph spacer + "Animal" + locus columns).
    /// Lives in the scroll view's header, not in the virtualized rows, so it
    /// stays fixed while the sample rows scroll under it.
    private let headerContainer = NSView()
    private var headerView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildSubviews()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); buildSubviews() }

    private func buildSubviews() {
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        // Fixed row height keeps the table deterministic (and lets AppKit
        // compute the visible-row window without a full auto-height pass): the
        // per-sample content is a 26pt tape inside 4pt top/bottom insets.
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.allowsColumnResizing = false
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sampleColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(sampleColumn)
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        addSubview(headerContainer)
        addSubview(scrollView)

        headerContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(rows: [Row]) {
        self.rows = rows
        numberOfRows = rows.count
        rebuildHeader()
        tableView.reloadData()
    }

    func setReviewSelection(sample: String?, locus: String?) {
        let selection = ReviewSelection(sample: sample, locus: locus)
        guard selection != reviewSelection else { return }
        reviewSelection = selection
        rebuildHeader()
        // Reload just the visible rows so selection highlighting + the tape's
        // selected-locus state refresh. Off-screen rows pick up the new
        // selection when they scroll into view.
        tableView.reloadData()
    }

    /// Fixed-width gutter for the leading fixed widgets (block glyph +
    /// animal label). All rows + the header share this so
    /// the locus columns align vertically across the whole table.
    private static let leadingGutter: CGFloat = 16 + 6 + 80
    /// Fixed per-sample row height: 26pt tape + 4pt top/bottom content insets.
    private static let rowHeight: CGFloat = 34

    private func rebuildHeader() {
        headerView?.removeFromSuperview()
        headerView = nil
        guard let first = rows.first, !first.loci.isEmpty else { return }
        let header = makeHeaderRow(loci: first.loci)
        header.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            header.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
        ])
        headerView = header
    }

    private func makeHeaderRow(loci: [String]) -> NSView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

        // Single fixed-width leading container holding block-glyph spacer +
        // "Animal" label. Using one container keeps the gutter width
        // identical across rows.
        let leading = NSStackView()
        leading.orientation = .horizontal
        leading.spacing = 6
        leading.alignment = .centerY
        let blockSpacer = NSTextField(labelWithString: " ")
        blockSpacer.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let animalHeader = NSTextField(labelWithString: "Animal")
        animalHeader.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        animalHeader.textColor = .secondaryLabelColor
        animalHeader.widthAnchor.constraint(equalToConstant: 80).isActive = true
        leading.addArrangedSubview(blockSpacer)
        leading.addArrangedSubview(animalHeader)
        leading.widthAnchor.constraint(equalToConstant: Self.leadingGutter).isActive = true

        // Locus header columns — one label per locus, evenly distributed
        // across whatever horizontal space the row gets. The tape view
        // in each row uses the exact same column layout so the swatches
        // line up under the headers. Each label is wrapped in an NSView
        // so .fillEqually distributes the wrappers (not the intrinsic
        // text size) and the label centers inside its column.
        let lociHeader = NSStackView()
        lociHeader.translatesAutoresizingMaskIntoConstraints = false
        lociHeader.orientation = .horizontal
        lociHeader.distribution = .fillEqually
        lociHeader.spacing = 0
        for locus in loci {
            let column = NSView()
            column.translatesAutoresizingMaskIntoConstraints = false
            let shortLabel = shortLocusLabel(locus)
            let label = NSTextField(labelWithString: shortLabel)
            let isSelected = reviewSelection.locus == locus
            let font = NSFont.systemFont(ofSize: 10, weight: isSelected ? .bold : .semibold)
            label.font = font
            label.textColor = isSelected ? .controlAccentColor : .secondaryLabelColor
            if isSelected {
                label.attributedStringValue = NSAttributedString(
                    string: shortLabel,
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.controlAccentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                )
                label.setAccessibilityLabel("\(locus) selected")
            }
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = isSelected ? "\(locus) selected for review" : locus
            label.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: column.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: column.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor, constant: -2),
            ])
            lociHeader.addArrangedSubview(column)
        }

        container.addArrangedSubview(leading)
        container.addArrangedSubview(lociHeader)
        // Let the locus header expand to consume all leftover width so
        // the columns line up edge-to-edge with the tape below.
        lociHeader.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lociHeader.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return container
    }

    private func shortLocusLabel(_ locus: String) -> String {
        // Strip the leading "MHC-" prefix; otherwise return the locus name.
        if locus.hasPrefix("MHC-") {
            return String(locus.dropFirst("MHC-".count))
        }
        return locus
    }

    /// Builds the per-sample content view. Called by AppKit only for rows that
    /// become visible — this is where virtualization pays off.
    private func makeRowContent(_ row: Row) -> NSView {
        #if DEBUG
        Self.rowViewConstructionCount += 1
        #endif
        // Outer vertical container so selection highlighting and row sizing
        // stay consistent with other outline rows.
        let outer = NSStackView()
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 2
        outer.identifier = NSUserInterfaceItemIdentifier(row.animalId)

        let container = SelectionRowStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let isSelectedSample = reviewSelection.sample == row.animalId
        container.isReviewSelected = isSelectedSample

        // Fixed-width leading gutter so every row's locus columns start at
        // the same x-coordinate as the header. Block glyph + animal label
        // live inside one width-anchored NSStackView.
        let leading = NSStackView()
        leading.orientation = .horizontal
        leading.spacing = 6
        leading.alignment = .centerY
        let blockGlyph = NSTextField(labelWithString: blockGlyphSymbol(row.blockKind))
        blockGlyph.font = NSFont.systemFont(ofSize: 11)
        blockGlyph.textColor = blockGlyphColor(row.blockKind)
        blockGlyph.toolTip = blockGlyphTooltip(row.blockKind)
        blockGlyph.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let animalLabel = NSTextField(labelWithString: row.animalId)
        animalLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: isSelectedSample ? .bold : .semibold)
        animalLabel.textColor = .labelColor
        animalLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        animalLabel.lineBreakMode = .byTruncatingTail
        leading.addArrangedSubview(blockGlyph)
        leading.addArrangedSubview(animalLabel)
        leading.widthAnchor.constraint(equalToConstant: Self.leadingGutter).isActive = true

        let tape = GenotypeHaplotypeTapeView()
        tape.translatesAutoresizingMaskIntoConstraints = false
        tape.configure(loci: row.loci, slots: row.tapeSlots)
        tape.sampleAccessibilityLabel = row.animalId
        tape.isReviewSelected = isSelectedSample
        tape.selectedLocus = isSelectedSample ? reviewSelection.locus : nil
        // No fixed width — let the tape expand to consume all available
        // horizontal space so locus columns line up under the headers.
        // The tape draws columns as `bounds.width / slots.count`, so wider
        // frames produce proportionally wider swatches.
        tape.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tape.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            tape.heightAnchor.constraint(equalToConstant: 26),
        ])

        container.addArrangedSubview(leading)
        container.addArrangedSubview(tape)

        // Row-level click selects the row; cell-level click on the tape
        // opens a per-locus evidence popover so the analyst can inspect
        // a call without going through the Selection tab.
        let rowClick = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        leading.addGestureRecognizer(rowClick)
        let tapeClick = TapeClickRecognizer(
            target: self,
            action: #selector(handleTapeClick(_:))
        )
        tapeClick.loci = row.loci
        tapeClick.animalId = row.animalId
        tape.addGestureRecognizer(tapeClick)
        container.identifier = NSUserInterfaceItemIdentifier(row.animalId)

        outer.addArrangedSubview(container)
        // Pin the container's width to the outer's so the row fills the
        // table's column width. Without this the inner container shrinks
        // to its intrinsic content.
        container.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true

        return outer
    }

    @objc private func handleTapeClick(_ recognizer: NSClickGestureRecognizer) {
        guard let recognizer = recognizer as? TapeClickRecognizer,
              let tape = recognizer.view as? GenotypeHaplotypeTapeView,
              !recognizer.loci.isEmpty else { return }
        let location = recognizer.location(in: tape)
        let columnWidth = tape.bounds.width / CGFloat(recognizer.loci.count)
        guard columnWidth > 0 else { return }
        let index = max(0, min(recognizer.loci.count - 1, Int(location.x / columnWidth)))
        let locus = recognizer.loci[index]
        onLocusCellClicked?(recognizer.animalId, locus)
    }

    /// Specialised gesture recognizer that carries the row's locus list
    /// and animal id, so the handler can compute which cell was clicked
    /// without storing per-tape state.
    private final class TapeClickRecognizer: NSClickGestureRecognizer {
        var loci: [String] = []
        var animalId: String = ""
    }

    private struct ReviewSelection: Equatable {
        var sample: String?
        var locus: String?
    }

    /// Table view flipped so rows lay out top-to-bottom. Selection background is
    /// suppressed via `selectionHighlightStyle = .none` on the instance (review
    /// selection is drawn inside the row content instead).
    private final class SampleTableView: NSTableView {
        override var isFlipped: Bool { true }
    }

    private final class SelectionRowStackView: NSStackView {
        var isReviewSelected: Bool = false {
            didSet {
                guard oldValue != isReviewSelected else { return }
                needsDisplay = true
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            if isReviewSelected {
                let active = window?.isKeyWindow ?? true
                let base = active
                    ? NSColor.selectedContentBackgroundColor
                    : NSColor.unemphasizedSelectedContentBackgroundColor
                base.withAlphaComponent(0.14).setFill()
                let rect = bounds.insetBy(dx: 2, dy: 1)
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            super.draw(dirtyRect)
        }
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let view = recognizer.view,
              let id = view.identifier?.rawValue else { return }
        onRowSelected?(id)
    }

    private func blockGlyphSymbol(_ kind: GenotypeBlockKind) -> String {
        switch kind {
        case .blockCoherent:        return "\u{25AE}"
        case .regionalRecombinant:  return "\u{25B0}\u{25B1}"
        case .atypical:             return "\u{25B1}\u{25B0}\u{25B1}"
        case .unknown:              return "\u{00B7}"
        }
    }
    private func blockGlyphColor(_ kind: GenotypeBlockKind) -> NSColor {
        switch kind {
        case .blockCoherent:       return NSColor.systemGreen
        case .regionalRecombinant: return NSColor.lungfishDanger
        case .atypical:            return NSColor.lungfishDanger
        case .unknown:             return NSColor.secondaryLabelColor
        }
    }
    private func blockGlyphTooltip(_ kind: GenotypeBlockKind) -> String {
        switch kind {
        case .blockCoherent:       return "Block coherent"
        case .regionalRecombinant: return "Regional recombinant"
        case .atypical:            return "Atypical"
        case .unknown:             return "Unknown"
        }
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension GenotypeOutlineView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count else { return nil }
        // Each sample rebuilds its content fresh (cheap; only visible rows are
        // asked). We do not reuse via makeView(withIdentifier:) because the
        // per-row gesture recognizers carry row-specific locus/animal state.
        let cell = NSTableCellView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        let content = makeRowContent(rows[row])
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: cell.topAnchor),
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        return cell
    }

    // Non-nil row views are opt-in so the table has a place to hang each
    // sample; selection highlighting is drawn by the content, not the row.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        NSTableRowView()
    }
}

#if DEBUG
extension GenotypeOutlineView {
    /// Counts how many per-sample row view-trees have been instantiated since
    /// the last reset. With NSTableView virtualization this stays bounded by
    /// the visible window rather than the cohort size.
    nonisolated(unsafe) static var rowViewConstructionCount: Int = 0
    static var testingRowViewConstructionCount: Int { rowViewConstructionCount }
    static func testingResetRowViewConstructionCount() { rowViewConstructionCount = 0 }

    func testingScrollToRow(_ index: Int) {
        tableView.scrollRowToVisible(index)
        // Force AppKit to materialize the newly-visible rows synchronously.
        tableView.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        testingForceRowMaterialization()
    }

    /// Drives a synchronous draw pass so the backing table prepares (builds)
    /// the cell views for its currently-visible window. AppKit normally does
    /// this during the next display cycle, which never runs in a headless
    /// XCTest — so tests call this to observe the virtualized rows.
    func testingForceRowMaterialization() {
        tableView.tile()
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            _ = tableView.rowView(atRow: row, makeIfNecessary: true)
            _ = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
    }

    /// Sample ids whose row views are currently materialized (visible window).
    func testingVisibleSampleIds() -> [String] {
        var ids: [String] = []
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else {
            // No clip geometry yet (unlaid-out test view): fall back to the
            // model so callers can still assert reachability.
            return rows.map(\.animalId)
        }
        for index in range.location..<(range.location + range.length) where index < rows.count {
            ids.append(rows[index].animalId)
        }
        return ids
    }

    func testingSimulateRowClick(sample: String) {
        onRowSelected?(sample)
    }

    func testingSimulateTapeClick(sample: String, locus: String) {
        onLocusCellClicked?(sample, locus)
    }

    var testingVisibleText: String {
        textContent(in: self).joined(separator: "\n")
    }

    var testingReviewSelectedSample: String? {
        reviewSelection.sample
    }

    var testingReviewSelectedLocus: String? {
        reviewSelection.locus
    }

    func testingSelectedTapeLocus(sample: String) -> String? {
        tapeViews(in: self)
            .first { $0.sampleAccessibilityLabel == sample && $0.testingIsReviewSelected }?
            .testingSelectedLocus
    }

    func testingHeaderIsSelected(locus: String) -> Bool {
        reviewSelection.locus == locus
    }

    private func textContent(in view: NSView) -> [String] {
        var values: [String] = []
        if let textField = view as? NSTextField {
            values.append(textField.stringValue)
        }
        for subview in view.subviews {
            values.append(contentsOf: textContent(in: subview))
        }
        return values
    }

    private func tapeViews(in view: NSView) -> [GenotypeHaplotypeTapeView] {
        var values: [GenotypeHaplotypeTapeView] = []
        if let tape = view as? GenotypeHaplotypeTapeView {
            values.append(tape)
        }
        for subview in view.subviews {
            values.append(contentsOf: tapeViews(in: subview))
        }
        return values
    }
}
#endif
