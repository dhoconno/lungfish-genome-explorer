import AppKit
import LungfishCore
import LungfishIO

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

    func effectiveValueLayout(
        sample: String,
        locus: String
    ) -> GenotypeManualHaplotypeValueLayout? {
        guard bandMode == .effectiveMiSeqCalls,
              isExpanded,
              let locusIndex = effectiveSnapshot.orderedLoci.firstIndex(
                of: locus
              ),
              let columnFrame = columnFrames[sample]
        else {
            return nil
        }
        let rowRect = NSRect(
            x: columnFrame.minX + 3,
            y: disclosureHeight + rowHeight * CGFloat(locusIndex),
            width: max(0, columnFrame.width - 6),
            height: rowHeight
        )
        return GenotypeManualHaplotypeValueLayout(
            value: effectiveSnapshot.renderedLocusValue(
                sample: sample,
                locus: locus
            ),
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
                guard let layout = effectiveValueLayout(
                    sample: sample,
                    locus: locus
                ),
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
