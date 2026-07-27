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

@MainActor
final class GenotypeManualHaplotypePinnedBandView: NSView {
    var font = NSFont.systemFont(ofSize: 11)
    var rowHeight: CGFloat = 22
    var isExpanded = true {
        didSet {
            disclosureButton.state = isExpanded ? .on : .off
            needsDisplay = true
        }
    }
    var onDisclosureChanged: ((Bool) -> Void)?

    private let disclosureButton = NSButton(
        title: "Haplotype Assignments",
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
        disclosureButton.state = .on
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
            y: 1,
            width: max(0, bounds.width - 12),
            height: rowHeight
        )
    }

    @objc private func toggleDisclosure(_ sender: NSButton) {
        onDisclosureChanged?(sender.state == .on)
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
                y: rowHeight * CGFloat(index + 1),
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
    var columnFrames: [String: NSRect] = [:]
    var font = NSFont.systemFont(ofSize: 11)
    var rowHeight: CGFloat = 22
    var isExpanded = true
    private var tooltipTag: NSView.ToolTipTag?

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
        if let tooltipTag {
            removeToolTip(tooltipTag)
        }
        tooltipTag = isExpanded && !bounds.isEmpty
            ? addToolTip(bounds, owner: self, userData: nil)
            : nil
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
        let row = Int(floor(point.y / max(rowHeight, 1))) - 1
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

    func invalidate(samples: Set<String>) {
        for sample in samples {
            guard let frame = columnFrames[sample],
                  frame.intersects(bounds) else {
                continue
            }
            setNeedsDisplay(frame.intersection(bounds))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isExpanded else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        for (sample, columnFrame) in columnFrames
        where columnFrame.intersects(dirtyRect) {
            let values = snapshot.valuesBySample[sample]
                ?? Array(repeating: "—", count: 7)
            for (index, value) in values.enumerated() {
                let rowRect = NSRect(
                    x: columnFrame.minX + 3,
                    y: rowHeight * CGFloat(index + 1),
                    width: max(0, columnFrame.width - 6),
                    height: rowHeight
                )
                guard rowRect.intersects(dirtyRect) else { continue }
                value.draw(
                    in: rowRect.insetBy(
                        dx: 0,
                        dy: max(
                            1,
                            (rowHeight - font.boundingRectForFont.height) / 2
                        )
                    ),
                    withAttributes: attributes
                )
            }
        }
    }
}
