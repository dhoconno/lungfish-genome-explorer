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

    var manualHeight: CGFloat {
        guard isEligible else { return 0 }
        return disclosureHeight
            + rowHeight * CGFloat(isExpanded ? 7 : 0)
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
final class GenotypeManualHaplotypePinnedBandView: NSView {
    static let disclosureTitle = "Manual haplotypes (7 loci)"
    static let disclosureHorizontalTextAllowance: CGFloat = 40
    static let disclosureVerticalPadding: CGFloat = 4

    static func requiredDisclosureHeight(
        font: NSFont,
        availableWidth: CGFloat,
        minimumHeight: CGFloat
    ) -> CGFloat {
        let attributedTitle = NSAttributedString(
            string: disclosureTitle,
            attributes: [.font: font]
        )
        let bounds = attributedTitle.boundingRect(
            with: NSSize(
                width: max(
                    1,
                    availableWidth
                        - disclosureHorizontalTextAllowance
                ),
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(
            max(
                minimumHeight,
                bounds.height + disclosureVerticalPadding
            )
        )
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

    private let disclosureButton = GenotypeManualHaplotypeDisclosureButton(
        title: disclosureTitle,
        target: nil,
        action: nil
    )

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure(_:))
        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.bezelStyle = .disclosure
        disclosureButton.font = font
        disclosureButton.cell?.lineBreakMode = .byWordWrapping
        disclosureButton.cell?.usesSingleLineMode = false
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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        disclosureButton.frame = NSRect(
            x: 6,
            y: 0,
            width: max(
                0,
                min(bounds.width, availableDisclosureWidth) - 12
            ),
            height: min(disclosureHeight, bounds.height)
        )
    }

    @objc private func toggleDisclosure(_ sender: NSButton) {
        let expanded = sender.state == .on
        isExpanded = expanded
        onDisclosureChanged?(expanded)
    }

    var disclosureLabel: String { disclosureButton.title }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isExpanded else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (index, locus) in GenotypeManualHaplotypeAssignmentBandSnapshot.loci.enumerated() {
            let rowRect = NSRect(
                x: 6,
                y: disclosureHeight + rowHeight * CGFloat(index),
                width: max(0, bounds.width - 12),
                height: rowHeight
            )
            guard rowRect.intersects(dirtyRect) else { continue }
            locus.workbookLabel.draw(
                in: rowRect.insetBy(dx: 0, dy: max(1, (rowHeight - font.boundingRectForFont.height) / 2)),
                withAttributes: attributes
            )
        }
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
        }
    }
    var font = NSFont.systemFont(ofSize: 11)
    var rowHeight: CGFloat = 22
    var disclosureHeight: CGFloat = 22
    var isExpanded = true {
        didSet {
            refreshToolTipRegistration()
        }
    }
    private var tooltipTag: NSView.ToolTipTag?
    private var tooltipTrackingRect: NSRect?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        refreshToolTipRegistration()
    }

    private func refreshToolTipRegistration() {
        if let tooltipTag {
            removeToolTip(tooltipTag)
        }
        tooltipTrackingRect = isExpanded
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
        guard row >= 0,
              row < GenotypeManualHaplotypeAssignmentBandSnapshot.loci.count
        else {
            return ""
        }
        return snapshot.tooltip(
            sample: sample,
            locus: GenotypeManualHaplotypeAssignmentBandSnapshot.loci[row]
        ) ?? ""
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isExpanded else { return }
        let attributes =
            GenotypeManualHaplotypeValueLayout.drawingAttributes(
                font: font
            )
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
}
