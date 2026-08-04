import AppKit
import LungfishCore
import LungfishIO

/// Window-owned, bundle-keyed presentation state. A viewer keeps one instance
/// for its lifetime and shares it with replacement result controllers.
@MainActor
public final class GenotypeManualHaplotypeBandDisclosureStore {
    private var expansionByBundlePath: [String: Bool] = [:]

    public init() {}

    public func expansion(for bundleURL: URL) -> Bool? {
        expansionByBundlePath[bundleURL.standardizedFileURL.path]
    }

    public func setExpansion(_ expanded: Bool, for bundleURL: URL) {
        expansionByBundlePath[bundleURL.standardizedFileURL.path] = expanded
    }
}

@MainActor
struct GenotypeManualHaplotypeAssignmentBandSnapshot: Equatable {
    static let loci = GenotypeManualHaplotypeLocus.allCases

    let valuesBySample: [String: [String]]
    let tooltipsBySample: [String: [String]]
    let accessibilitySummaryBySample: [String: String]

    init(index: GenotypeManualHaplotypeAssignmentIndex, samples: [String]) {
        var valuesBySample: [String: [String]] = [:]
        var tooltipsBySample: [String: [String]] = [:]
        var summaries: [String: String] = [:]
        valuesBySample.reserveCapacity(samples.count)
        summaries.reserveCapacity(samples.count)

        for sample in samples {
            var summaryParts: [String] = []
            var sampleTooltips: [String] = []
            let values = Self.loci.map { locus -> String in
                let assignments = index.assignments(sample: sample, locus: locus)
                let h1 = assignments.h1?.label
                let h2 = assignments.h2?.label
                let locusSummary = [
                    h1.map { "H1 \($0)" },
                    h2.map { "H2 \($0)" },
                ].compactMap { $0 }
                if !locusSummary.isEmpty {
                    summaryParts.append(
                        "\(locus.workbookLabel) "
                            + locusSummary.joined(separator: ", ")
                    )
                }
                sampleTooltips.append(
                    "\(locus.workbookLabel) — H1: \(h1 ?? "unassigned"); "
                        + "H2: \(h2 ?? "unassigned")"
                )
                switch (h1, h2) {
                case (.none, .none): return "—"
                case let (.some(h1), .none): return "\(h1) · —"
                case let (.none, .some(h2)): return "— · \(h2)"
                case let (.some(h1), .some(h2)): return "\(h1) · \(h2)"
                }
            }
            valuesBySample[sample] = values
            tooltipsBySample[sample] = sampleTooltips
            summaries[sample] = summaryParts.isEmpty
                ? "No manual haplotype assignments"
                : "Manual haplotypes: " + summaryParts.joined(separator: "; ")
        }
        self.valuesBySample = valuesBySample
        self.tooltipsBySample = tooltipsBySample
        self.accessibilitySummaryBySample = summaries
    }

    func changedSamples(comparedTo previous: Self) -> Set<String> {
        let samples = Set(valuesBySample.keys).union(previous.valuesBySample.keys)
        return Set(samples.filter {
            valuesBySample[$0] != previous.valuesBySample[$0]
        })
    }

    func tooltip(
        sample: String,
        locus: GenotypeManualHaplotypeLocus
    ) -> String? {
        guard let locusIndex = Self.loci.firstIndex(of: locus) else {
            return nil
        }
        return tooltipsBySample[sample]?[locusIndex]
    }
}

/// The exact visible damage caused by a manual-assignment snapshot change.
///
/// Keeping this calculation value-semantic lets the matrix invalidate only
/// affected, on-screen sample columns without coupling assignment edits to
/// projection or table reload work.
struct GenotypeManualHaplotypeBandInvalidationPlan: Equatable {
    let rects: [NSRect]

    init(
        samples: Set<String>,
        columnFrames: [String: NSRect],
        visibleBounds: NSRect
    ) {
        rects = samples.compactMap { sample in
            guard let frame = columnFrames[sample],
                  frame.intersects(visibleBounds) else {
                return nil
            }
            return frame.intersection(visibleBounds)
        }.sorted {
            if $0.minX != $1.minX { return $0.minX < $1.minX }
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            if $0.width != $1.width { return $0.width < $1.width }
            return $0.height < $1.height
        }
    }
}

/// Value-semantic sizing for one sample's fixed manual-haplotype header band.
///
/// Widths are measured from the complete rendered assignment strings. The
/// editor already bounds an individual label to 128 Unicode scalars, so this
/// presentation helper deliberately adds no second truncation ceiling.
struct GenotypeManualHaplotypeColumnMeasurement: Equatable {
    static func requiredWidth(
        values: [String],
        sampleTitle: String,
        retainedReadTitle: String?,
        font: NSFont,
        headerFont: NSFont,
        inset: CGFloat = 6
    ) -> CGFloat {
        let assignmentWidth = values.reduce(CGFloat.zero) { widest, value in
            max(
                widest,
                (value as NSString).size(
                    withAttributes: [.font: font]
                ).width
            )
        } + inset * 2
        let headerTextWidth = [sampleTitle, retainedReadTitle]
            .compactMap { $0 }
            .reduce(CGFloat.zero) { widest, value in
                max(
                    widest,
                    (value as NSString).size(
                        withAttributes: [.font: headerFont]
                    ).width
                )
            }
        // Ordinary sample headers reserve leading space for their selection
        // indicator in addition to the normal text inset.
        let headerWidth = headerTextWidth + max(inset * 2, 24)
        return ceil(max(assignmentWidth, headerWidth))
    }
}

struct GenotypeManualHaplotypeValueLayout: Equatable {
    static let textAlignment: NSTextAlignment = .center

    let value: String
    let rowRect: NSRect
    let textRect: NSRect
    let alignment: NSTextAlignment

    static func drawingAttributes(
        font: NSFont
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }
}

/// Value-semantic geometry for the ordinary and manual regions of a native
/// matrix table header.
struct GenotypeManualHaplotypeHeaderLayout: Equatable {
    let isEligible: Bool
    let isExpanded: Bool
    let ordinaryHeight: CGFloat
    let disclosureHeight: CGFloat
    let rowHeight: CGFloat
    let locusCount: Int

    init(
        isEligible: Bool,
        isExpanded: Bool,
        ordinaryHeight: CGFloat,
        disclosureHeight: CGFloat,
        rowHeight: CGFloat,
        locusCount: Int = 7
    ) {
        self.isEligible = isEligible
        self.isExpanded = isExpanded
        self.ordinaryHeight = ordinaryHeight
        self.disclosureHeight = disclosureHeight
        self.rowHeight = rowHeight
        self.locusCount = locusCount
    }

    var manualHeight: CGFloat {
        guard isEligible else { return 0 }
        return disclosureHeight
            + rowHeight * CGFloat(isExpanded ? locusCount : 0)
    }

    var totalHeight: CGFloat {
        ordinaryHeight + manualHeight
    }

    func ordinaryRect(in bounds: NSRect, isFlipped: Bool) -> NSRect {
        NSRect(
            x: bounds.minX,
            y: isFlipped
                ? bounds.minY
                : bounds.maxY - ordinaryHeight,
            width: bounds.width,
            height: min(max(ordinaryHeight, 0), bounds.height)
        )
    }

    func manualRect(in bounds: NSRect, isFlipped: Bool) -> NSRect {
        guard manualHeight > 0 else { return .zero }
        return NSRect(
            x: bounds.minX,
            y: isFlipped
                ? bounds.minY + ordinaryHeight
                : bounds.minY,
            width: bounds.width,
            height: min(manualHeight, max(0, bounds.height - ordinaryHeight))
        )
    }
}

@MainActor
private final class GenotypeManualHaplotypeDisclosureButton: NSButton {
    override var acceptsFirstResponder: Bool { true }

    override func isAccessibilityExpanded() -> Bool {
        state == .on
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: state == .on)
    }

    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers
        if event.keyCode == 36
            || event.keyCode == 76
            || event.keyCode == 49
            || characters == "\r"
            || characters == "\n"
            || characters == " " {
            performClick(nil)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class GenotypeHaplotypeBandTargetButton: NSButton {
    let haplotypeTarget: GenotypeHaplotypeBandTarget
    var onActivate: ((GenotypeHaplotypeBandTarget) -> Void)?

    init(target: GenotypeHaplotypeBandTarget) {
        haplotypeTarget = target
        super.init(frame: .zero)
        self.target = self
        action = #selector(activate(_:))
        title = ""
        isBordered = false
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers
        if event.keyCode == 36
            || event.keyCode == 76
            || event.keyCode == 49
            || characters == "\r"
            || characters == "\n"
            || characters == " " {
            performClick(nil)
            return
        }
        super.keyDown(with: event)
    }

    @objc private func activate(_ sender: NSButton) {
        onActivate?(haplotypeTarget)
    }
}

@MainActor
final class GenotypeManualHaplotypePinnedBandView: NSView {
    static let disclosureTitle = "Manual haplotypes (7 loci)"

    static func requiredDisclosureHeight(
        font _: NSFont,
        availableWidth _: CGFloat,
        minimumHeight: CGFloat
    ) -> CGFloat {
        ceil(minimumHeight)
    }

    var font = NSFont.systemFont(ofSize: 11) {
        didSet {
            disclosureButton.font = font
            needsLayout = true
            needsDisplay = true
        }
    }
    var rowHeight: CGFloat = 22 {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }
    var disclosureHeight: CGFloat = 22 {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }
    var availableDisclosureWidth: CGFloat = 360 {
        didSet {
            needsLayout = true
        }
    }
    var isExpanded = true {
        didSet {
            disclosureButton.state = isExpanded ? .on : .off
            needsDisplay = true
        }
    }
    var onDisclosureChanged: ((Bool) -> Void)?
    private(set) var bandMode: GenotypeHaplotypeBandMode = .manualAssignments
    private var locusLabels = GenotypeManualHaplotypeAssignmentBandSnapshot.loci
        .map(\.workbookLabel)
    private var currentDisclosureTitle = disclosureTitle

    private let disclosureButton = GenotypeManualHaplotypeDisclosureButton(
        title: "Haplotypes",
        target: nil,
        action: nil
    )

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure(_:))
        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.isBordered = false
        disclosureButton.image = Self.makeDisclosureIcon(
            expanded: false
        )
        disclosureButton.alternateImage = Self.makeDisclosureIcon(
            expanded: true
        )
        disclosureButton.imagePosition = .imageLeading
        disclosureButton.imageScaling = .scaleProportionallyDown
        disclosureButton.toolTip = Self.disclosureTitle
        disclosureButton.font = font
        disclosureButton.cell?.lineBreakMode = .byTruncatingTail
        disclosureButton.cell?.usesSingleLineMode = true
        disclosureButton.state = .on
        disclosureButton.setAccessibilityElement(true)
        disclosureButton.setAccessibilityRole(.button)
        disclosureButton.setAccessibilityLabel(
            "Manual haplotypes (7 loci)"
        )
        disclosureButton.setAccessibilityHelp(
            "Shows seven locus-level manual haplotype assignment rows below the sample names."
        )
        disclosureButton.setAccessibilityIdentifier(
            "manual-haplotype-band-disclosure"
        )
        addSubview(disclosureButton)
    }

    func setHaplotypeBand(
        mode: GenotypeHaplotypeBandMode,
        snapshot: GenotypeHaplotypeCallBandSnapshot?
    ) {
        bandMode = mode
        switch mode {
        case .none:
            locusLabels = []
            currentDisclosureTitle = "Haplotypes"
            disclosureButton.setAccessibilityHelp(nil)
        case .manualAssignments:
            locusLabels = GenotypeManualHaplotypeAssignmentBandSnapshot.loci
                .map(\.workbookLabel)
            currentDisclosureTitle = Self.disclosureTitle
            disclosureButton.setAccessibilityHelp(
                "Shows seven locus-level manual haplotype assignment rows below the sample names."
            )
        case .effectiveMiSeqCalls:
            let snapshot = snapshot ?? .empty
            locusLabels = snapshot.orderedLoci
            currentDisclosureTitle = snapshot.disclosureTitle
            disclosureButton.setAccessibilityHelp(
                "Shows effective H1 and H2 haplotype calls for each included locus below the sample names."
            )
        }
        disclosureButton.title = mode == .effectiveMiSeqCalls
            ? currentDisclosureTitle
            : "Haplotypes"
        disclosureButton.toolTip = currentDisclosureTitle
        disclosureButton.setAccessibilityLabel(currentDisclosureTitle)
        disclosureButton.setAccessibilityIdentifier(
            mode == .effectiveMiSeqCalls
                ? "haplotype-call-band-disclosure"
                : "manual-haplotype-band-disclosure"
        )
        needsLayout = true
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let intrinsicWidth = disclosureButton.cell?.cellSize.width
            ?? disclosureButton.intrinsicContentSize.width
        disclosureButton.frame = NSRect(
            x: 0,
            y: 0,
            width: max(
                0,
                min(
                    bounds.width,
                    availableDisclosureWidth,
                    ceil(intrinsicWidth + 6)
                )
            ),
            height: min(disclosureHeight, bounds.height)
        )
    }

    @objc private func toggleDisclosure(_ sender: NSButton) {
        let expanded = sender.state == .on
        isExpanded = expanded
        onDisclosureChanged?(expanded)
    }

    var disclosureLabel: String { currentDisclosureTitle }

#if DEBUG
    var testingDisclosureFrame: NSRect { disclosureButton.frame }
    var testingDisclosureIsBordered: Bool { disclosureButton.isBordered }
    var testingStripBackgroundColor: NSColor { .windowBackgroundColor }
    var testingStripSeparatorColor: NSColor { .separatorColor }
#endif

    private static func makeDisclosureIcon(
        expanded: Bool
    ) -> NSImage {
        let size = NSSize(width: 26, height: 12)
        let image = NSImage(
            size: size,
            flipped: false
        ) { _ in
            let chevron = NSBezierPath()
            if expanded {
                chevron.move(to: NSPoint(x: 0.5, y: 7.5))
                chevron.line(to: NSPoint(x: 3.25, y: 4.5))
                chevron.line(to: NSPoint(x: 6, y: 7.5))
            } else {
                chevron.move(to: NSPoint(x: 1.5, y: 10))
                chevron.line(to: NSPoint(x: 4.5, y: 6))
                chevron.line(to: NSPoint(x: 1.5, y: 2))
            }
            chevron.lineWidth = 1.5
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor.black.setStroke()
            chevron.stroke()

            NSColor.black.setFill()
            let segmentWidth: CGFloat = 5
            let segmentHeight: CGFloat = 4.5
            let horizontalGap: CGFloat = 1.5
            let verticalGap: CGFloat = 1.5
            let segmentOriginX: CGFloat = 8
            let lowerY = (size.height
                - segmentHeight * 2
                - verticalGap) / 2
            for row in 0..<2 {
                for column in 0..<3 {
                    let rect = NSRect(
                        x: segmentOriginX
                            + CGFloat(column)
                            * (segmentWidth + horizontalGap),
                        y: lowerY
                            + CGFloat(row)
                            * (segmentHeight + verticalGap),
                        width: segmentWidth,
                        height: segmentHeight
                    )
                    NSBezierPath(
                        roundedRect: rect,
                        xRadius: segmentHeight / 2,
                        yRadius: segmentHeight / 2
                    ).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawStripChrome(in: dirtyRect)
        guard isExpanded else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (index, locus) in locusLabels.enumerated() {
            let rowRect = NSRect(
                x: 6,
                y: disclosureHeight + rowHeight * CGFloat(index),
                width: max(0, bounds.width - 12),
                height: rowHeight
            )
            guard rowRect.intersects(dirtyRect) else { continue }
            locus.draw(
                in: rowRect.insetBy(dx: 0, dy: max(1, (rowHeight - font.boundingRectForFont.height) / 2)),
                withAttributes: attributes
            )
        }
    }

    private func drawStripChrome(in dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        let separatorRect = NSRect(
            x: bounds.minX,
            y: max(bounds.minY, bounds.maxY - 1),
            width: bounds.width,
            height: 1
        )
        guard separatorRect.intersects(dirtyRect) else { return }
        NSColor.separatorColor.setFill()
        separatorRect.fill()
    }
}

@MainActor
final class GenotypeManualHaplotypeSampleBandView:
    NSView, NSViewToolTipOwner {
    var snapshot = GenotypeManualHaplotypeAssignmentBandSnapshot(
        index: GenotypeManualHaplotypeAssignmentIndex(assignments: []),
        samples: []
    )
    var columnFrames: [String: NSRect] = [:] {
        didSet {
            refreshToolTipRegistration()
            refreshEffectiveHitTargets()
        }
    }
    var font = NSFont.systemFont(ofSize: 11) {
        didSet { needsDisplay = true }
    }
    var rowHeight: CGFloat = 22 {
        didSet {
            refreshEffectiveHitTargets()
            needsDisplay = true
        }
    }
    var disclosureHeight: CGFloat = 22 {
        didSet {
            refreshEffectiveHitTargets()
            needsDisplay = true
        }
    }
    var isExpanded = true {
        didSet {
            refreshToolTipRegistration()
            refreshEffectiveHitTargets()
        }
    }
    private(set) var bandMode: GenotypeHaplotypeBandMode = .manualAssignments
    private var effectiveSnapshot = GenotypeHaplotypeCallBandSnapshot.empty
    var onTargetSelected: ((GenotypeHaplotypeBandTarget) -> Void)?
    private var tooltipTag: NSView.ToolTipTag?
    private var tooltipTrackingRect: NSRect?
    private var effectiveHitTargets:
        [GenotypeHaplotypeBandTarget: GenotypeHaplotypeBandTargetButton] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        refreshToolTipRegistration()
        refreshEffectiveHitTargets()
    }

    func setHaplotypeBand(
        mode: GenotypeHaplotypeBandMode,
        snapshot: GenotypeHaplotypeCallBandSnapshot?,
        invalidateAll: Bool = true
    ) {
        bandMode = mode
        effectiveSnapshot = snapshot ?? .empty
        refreshToolTipRegistration()
        refreshEffectiveHitTargets()
        if invalidateAll {
            needsDisplay = true
        }
    }

    var focusedEffectiveTarget: GenotypeHaplotypeBandTarget? {
        (window?.firstResponder as? GenotypeHaplotypeBandTargetButton)?
            .haplotypeTarget
    }

    @discardableResult
    func restoreFocus(
        to target: GenotypeHaplotypeBandTarget?
    ) -> Bool {
        guard let target,
              let button = effectiveHitTargets[target],
              let window else {
            return false
        }
        return window.makeFirstResponder(button)
    }

#if DEBUG
    var testingStripBackgroundColor: NSColor { .windowBackgroundColor }
    var testingStripSeparatorColor: NSColor { .separatorColor }
#endif

    private func refreshToolTipRegistration() {
        if let tooltipTag {
            removeToolTip(tooltipTag)
        }
        tooltipTrackingRect = isExpanded && bandMode == .manualAssignments
            ? columnFrames.values.reduce(nil) { result, frame in
                result.map { $0.union(frame) } ?? frame
            }
            : nil
        tooltipTag = tooltipTrackingRect.map {
            addToolTip($0, owner: self, userData: nil)
        }
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard isExpanded,
              let sample = columnFrames.first(where: {
                  $0.value.contains(point)
              })?.key else {
            return ""
        }
        let row = Int(
            floor(
                (point.y - disclosureHeight)
                    / max(rowHeight, 1)
            )
        )
        guard row >= 0 else {
            return ""
        }
        switch bandMode {
        case .manualAssignments:
            guard row < GenotypeManualHaplotypeAssignmentBandSnapshot.loci.count else {
                return ""
            }
            return snapshot.tooltip(
                sample: sample,
                locus: GenotypeManualHaplotypeAssignmentBandSnapshot.loci[row]
            ) ?? ""
        case .effectiveMiSeqCalls:
            guard effectiveSnapshot.orderedLoci.indices.contains(row),
                  let frame = columnFrames[sample] else {
                return ""
            }
            let slot: HaplotypeSlot = point.x < frame.midX ? .h1 : .h2
            return effectiveSnapshot.tooltip(
                sample: sample,
                locus: effectiveSnapshot.orderedLoci[row],
                slot: slot
            ) ?? ""
        case .none:
            return ""
        }
    }

#if DEBUG
    func testingRegisteredToolTip(at point: NSPoint) -> String? {
        guard let tooltipTag,
              tooltipTrackingRect?.contains(point) == true else {
            return nil
        }
        return view(
            self,
            stringForToolTip: tooltipTag,
            point: point,
            userData: nil
        )
    }

    func testingHitTarget(
        _ target: GenotypeHaplotypeBandTarget
    ) -> NSButton? {
        refreshEffectiveHitTargets()
        return effectiveHitTargets[target]
    }
#endif

    func invalidate(samples: Set<String>) {
        let plan = GenotypeManualHaplotypeBandInvalidationPlan(
            samples: samples,
            columnFrames: columnFrames,
            visibleBounds: visibleRect
        )
        for rect in plan.rects {
            setNeedsDisplay(rect)
        }
    }

    func valueLayout(
        sample: String,
        locusIndex: Int
    ) -> GenotypeManualHaplotypeValueLayout? {
        guard isExpanded,
              GenotypeManualHaplotypeAssignmentBandSnapshot.loci.indices
                .contains(locusIndex),
              let columnFrame = columnFrames[sample]
        else {
            return nil
        }
        let values = snapshot.valuesBySample[sample]
            ?? Array(repeating: "—", count: 7)
        let rowRect = NSRect(
            x: columnFrame.minX + 3,
            y: disclosureHeight + rowHeight * CGFloat(locusIndex),
            width: max(0, columnFrame.width - 6),
            height: rowHeight
        )
        return GenotypeManualHaplotypeValueLayout(
            value: values[locusIndex],
            rowRect: rowRect,
            textRect: rowRect.insetBy(
                dx: 0,
                dy: max(
                    1,
                    (
                        rowHeight
                            - font.boundingRectForFont.height
                    ) / 2
                )
            ),
            alignment: GenotypeManualHaplotypeValueLayout
                .textAlignment
        )
    }

    func valueLayout(
        target: GenotypeHaplotypeBandTarget
    ) -> GenotypeManualHaplotypeValueLayout? {
        guard bandMode == .effectiveMiSeqCalls,
              isExpanded,
              let locusIndex = effectiveSnapshot.orderedLoci.firstIndex(
                of: target.locus
              ),
              let columnFrame = columnFrames[target.sample],
              let value = effectiveSnapshot.renderedValue(for: target)
        else {
            return nil
        }
        let halfWidth = columnFrame.width / 2
        let slotOffset = target.slot == .h1 ? CGFloat.zero : halfWidth
        let rowRect = NSRect(
            x: columnFrame.minX + slotOffset + 2,
            y: disclosureHeight + rowHeight * CGFloat(locusIndex),
            width: max(0, halfWidth - 4),
            height: rowHeight
        )
        return GenotypeManualHaplotypeValueLayout(
            value: value,
            rowRect: rowRect,
            textRect: rowRect.insetBy(
                dx: 1,
                dy: max(
                    1,
                    (rowHeight - font.boundingRectForFont.height) / 2
                )
            ),
            alignment: GenotypeManualHaplotypeValueLayout.textAlignment
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawStripChrome(in: dirtyRect)
        guard isExpanded else { return }
        let attributes =
            GenotypeManualHaplotypeValueLayout.drawingAttributes(
                font: font
            )
        if bandMode == .effectiveMiSeqCalls {
            drawEffectiveValues(in: dirtyRect, attributes: attributes)
            return
        }
        guard bandMode == .manualAssignments else { return }
        for (sample, columnFrame) in columnFrames
        where columnFrame.intersects(dirtyRect) {
            for locusIndex in
                GenotypeManualHaplotypeAssignmentBandSnapshot.loci.indices {
                guard let layout = valueLayout(
                    sample: sample,
                    locusIndex: locusIndex
                ),
                      layout.rowRect.intersects(dirtyRect)
                else {
                    continue
                }
                layout.value.draw(
                    in: layout.textRect,
                    withAttributes: attributes
                )
            }
        }
    }

    private func drawEffectiveValues(
        in dirtyRect: NSRect,
        attributes: [NSAttributedString.Key: Any]
    ) {
        for (sample, columnFrame) in columnFrames
        where columnFrame.intersects(dirtyRect) {
            for locus in effectiveSnapshot.orderedLoci {
                for slot in HaplotypeSlot.allCases {
                    let target = GenotypeHaplotypeBandTarget(
                        sample: sample,
                        locus: locus,
                        slot: slot
                    )
                    guard let layout = valueLayout(target: target),
                          layout.rowRect.intersects(dirtyRect) else {
                        continue
                    }
                    layout.value.draw(
                        in: layout.textRect,
                        withAttributes: attributes
                    )
                }
            }
        }
    }

    private func refreshEffectiveHitTargets() {
        guard bandMode == .effectiveMiSeqCalls, isExpanded else {
            for button in effectiveHitTargets.values {
                button.removeFromSuperview()
            }
            effectiveHitTargets.removeAll()
            return
        }

        var activeTargets = Set<GenotypeHaplotypeBandTarget>()
        for (sample, columnFrame) in columnFrames {
            for (locusIndex, locus) in effectiveSnapshot.orderedLoci.enumerated() {
                for slot in HaplotypeSlot.allCases {
                    let target = GenotypeHaplotypeBandTarget(
                        sample: sample,
                        locus: locus,
                        slot: slot
                    )
                    guard effectiveSnapshot.value(for: target) != nil else {
                        continue
                    }
                    activeTargets.insert(target)
                    let button: GenotypeHaplotypeBandTargetButton
                    if let existing = effectiveHitTargets[target] {
                        button = existing
                    } else {
                        button = GenotypeHaplotypeBandTargetButton(target: target)
                        button.onActivate = { [weak self] target in
                            self?.onTargetSelected?(target)
                        }
                        effectiveHitTargets[target] = button
                        addSubview(button)
                    }
                    let halfWidth = columnFrame.width / 2
                    button.frame = NSRect(
                        x: columnFrame.minX
                            + (slot == .h1 ? 0 : halfWidth),
                        y: disclosureHeight
                            + rowHeight * CGFloat(locusIndex),
                        width: halfWidth,
                        height: rowHeight
                    )
                    button.toolTip = effectiveSnapshot.tooltip(for: target)
                    button.setAccessibilityLabel(
                        effectiveSnapshot.accessibilityLabel(for: target)
                    )
                    let editable = effectiveSnapshot.value(for: target)?
                        .isEditable == true
                    button.setAccessibilityHelp(
                        editable
                            ? "Opens call evidence and override editing."
                            : "Opens call evidence. This call is read only."
                    )
                    button.setAccessibilityIdentifier(
                        "haplotype-band-\(sample)-\(locus)-\(slot.rawValue)"
                    )
                }
            }
        }
        for target in Set(effectiveHitTargets.keys).subtracting(activeTargets) {
            effectiveHitTargets.removeValue(forKey: target)?.removeFromSuperview()
        }
    }

    private func drawStripChrome(in dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        let separatorRect = NSRect(
            x: bounds.minX,
            y: max(bounds.minY, bounds.maxY - 1),
            width: bounds.width,
            height: 1
        )
        guard separatorRect.intersects(dirtyRect) else { return }
        NSColor.separatorColor.setFill()
        separatorRect.fill()
    }
}
