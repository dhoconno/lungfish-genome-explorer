// EsVirituDetailPane.swift - Context-sensitive detail pane for EsViritu results
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "EsVirituDetail")

/// Flipped container so Auto Layout `topAnchor` maps to visual top in AppKit.
private final class FlippedDetailContentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - EsVirituDetailPane

/// A context-sensitive detail pane for the EsViritu result viewer.
///
/// Shows different content depending on whether a virus is selected:
///
/// - **No selection (overview)**: Summary statistics with a mini bar chart
///   of the top detected viruses by read count.
/// - **Virus selected with BAM**: Mini-BAM viewer fills the pane so it resizes
///   like the TaxTriage left pane.
/// - **Virus selected without BAM**: Full-width genome coverage plot rendered
///   with CoreGraphics, plus key metrics (reads, RPKMF, identity, Pi).
///
/// ## CoreGraphics Coverage Plot
///
/// The coverage plot renders 100-window coverage data as an area chart:
/// - X axis: genome position (0% to 100%)
/// - Y axis: mean coverage depth (log scale)
/// - Filled area with gradient from accent color
/// - Annotated with max coverage point
/// - Per-segment sub-plots for segmented viruses
@MainActor
public final class EsVirituDetailPane: NSView {

    // MARK: - State

    private enum DisplayMode {
        case overview
        case virusDetail
    }

    private var displayMode: DisplayMode = .overview

    // Overview data
    private var overviewResult: LungfishIO.EsVirituResult?

    // Virus detail data
    private var selectedAssembly: ViralAssembly?
    private var selectedCoverageWindows: [String: [ViralCoverageWindow]] = [:]
    private var bamAvailable: Bool = false

    /// The detached evidence view (child lifecycle is owned by the parent VC).
    public var alignmentEvidenceView: NSView?

    /// Compatibility seam for older layout tests. Production wiring uses
    /// `alignmentEvidenceView`; this value is never displayed by the result VC.
    @available(*, deprecated, message: "Use alignmentEvidenceView")
    public var miniBAMViewController: MiniBAMViewController?

    /// Called when the user selects a virus and BAM is available — triggers
    /// automatic alignment loading in the detail pane.
    public var onLoadAlignments: ((URL, String) -> Void)?  // bamURL, accession
    public var onDisplayAlignmentEvidence: ((String, Int) -> Void)?

    // MARK: - Subviews

    private lazy var scrollContainer = ScrollViewSplitPaneContainerView(
        scrollView: scrollView,
        documentView: contentView
    )
    private let scrollView = NSScrollView()
    private let contentView = FlippedDetailContentView()

    // Overview subviews
    private let overviewTitleLabel = NSTextField(labelWithString: "")
    private let topVirusesView = TopVirusBarChartView()

    // Detail subviews
    private let virusNameLabel = NSTextField(labelWithString: "")
    private let coveragePlotView = CoverageAreaChartView()
    private lazy var contentTypographyApplicator = ContentTypographyViewApplicator { [weak self] view in
        return view is NSButton
            || view is NSSegmentedControl
            || view is NSPopUpButton
            || view is NSSlider
            || view === self?.coveragePlotView
            || view === self?.topVirusesView
            || view is SegmentCompletenessView
            || view === self?.alignmentEvidenceView
    }
    private var contentTypographyObservation: ContentTypographyViewObservation?
    private weak var activeMetricsView: NSStackView?
    private var activeMetricWidthConstraints: [NSLayoutConstraint] = []
    #if DEBUG
    private var contentRebuildCount = 0
    #endif

    // MARK: - Init

    public override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        scrollContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollContainer)

        NSLayoutConstraint.activate([
            scrollContainer.topAnchor.constraint(equalTo: topAnchor),
            scrollContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setupOverviewSubviews()
        setupDetailSubviews()
        contentTypographyObservation = ContentTypographyViewObservation(
            applicator: contentTypographyApplicator,
            rootProvider: { [weak self] in self?.contentView },
            afterApply: { [weak self] in
                self?.updateAdaptiveMetricLayout()
            }
        )
    }

    // MARK: - Setup

    private func setupOverviewSubviews() {
        overviewTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        overviewTitleLabel.textColor = .labelColor
        overviewTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        topVirusesView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupDetailSubviews() {
        virusNameLabel.font = .systemFont(ofSize: 16, weight: .bold)
        virusNameLabel.textColor = .labelColor
        virusNameLabel.lineBreakMode = .byWordWrapping
        virusNameLabel.maximumNumberOfLines = 0
        virusNameLabel.translatesAutoresizingMaskIntoConstraints = false

        coveragePlotView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Public API

    /// Shows the overview state with a bar chart of top viruses.
    public func configureOverview(
        result: LungfishIO.EsVirituResult,
        coverageWindows: [String: [ViralCoverageWindow]],
        bamURL: URL?
    ) {
        overviewResult = result
        selectedAssembly = nil
        bamAvailable = bamURL != nil
        displayMode = .overview
        rebuildContent()
    }

    /// Shows detailed coverage and metrics for a selected virus.
    public func showVirusDetail(
        assembly: ViralAssembly,
        coverageWindows: [String: [ViralCoverageWindow]],
        bamURL: URL?,
        focusedContigAccession: String? = nil
    ) {
        selectedAssembly = assembly
        selectedCoverageWindows = coverageWindows
        bamAvailable = bamURL != nil

        let selectedContig = assembly.contigs.first { $0.accession == focusedContigAccession } ?? assembly.contigs.first

        displayMode = .virusDetail
        rebuildContent()

        // Automatically load BAM pileup for the selected contig.
        if let bamURL, let selectedContig {
            onDisplayAlignmentEvidence?(selectedContig.accession, selectedContig.length)
        } else {
            onDisplayAlignmentEvidence?("", 0)
        }
    }

    // MARK: - Content Rebuild

    private func rebuildContent() {
        #if DEBUG
        contentRebuildCount += 1
        #endif
        NSLayoutConstraint.deactivate(activeMetricWidthConstraints)
        activeMetricWidthConstraints = []
        activeMetricsView = nil
        // Remove all subviews from content
        for subview in contentView.subviews {
            subview.removeFromSuperview()
        }

        switch displayMode {
        case .overview:
            buildOverviewContent()
        case .virusDetail:
            buildDetailContent()
        }

        // Keep the primary alignment evidence visible at the top.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        contentTypographyObservation?.refresh()
    }

    // MARK: - Overview Content

    private func buildOverviewContent() {
        guard let result = overviewResult else { return }

        overviewTitleLabel.stringValue = "Detected Viruses Overview"
        contentView.addSubview(overviewTitleLabel)

        // Summary labels
        let summaryText = NSTextField(labelWithString: """
        \(result.assemblies.count) assemblies detected
        \(result.detectedFamilyCount) viral families
        \(result.detectedSpeciesCount) species
        """)
        summaryText.font = .systemFont(ofSize: 12)
        summaryText.textColor = .secondaryLabelColor
        summaryText.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(summaryText)

        // Top viruses bar chart
        topVirusesView.configure(assemblies: result.assemblies)
        contentView.addSubview(topVirusesView)

        NSLayoutConstraint.activate([
            overviewTitleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            overviewTitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            overviewTitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            summaryText.topAnchor.constraint(equalTo: overviewTitleLabel.bottomAnchor, constant: 8),
            summaryText.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            summaryText.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            topVirusesView.topAnchor.constraint(equalTo: summaryText.bottomAnchor, constant: 16),
            topVirusesView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            topVirusesView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            topVirusesView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            topVirusesView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Detail Content

    private func buildDetailContent() {
        guard let assembly = selectedAssembly else { return }
        if bamAvailable, let evidenceView = alignmentEvidenceView ?? miniBAMViewController?.view {
            buildAlignmentEvidenceOnlyDetailContent(using: evidenceView)
            return
        }

        let isSegmented = assembly.contigs.count > 1 && assembly.contigs.contains(where: { $0.segment != nil })

        // 2. Confidence badge + Virus name + Family
        let headerStack = NSView()
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let badgeView = makeConfidenceBadge(for: assembly)
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addSubview(badgeView)

        virusNameLabel.stringValue = assembly.name
        headerStack.addSubview(virusNameLabel)

        let familyLabel = NSTextField(labelWithString: assembly.family ?? "")
        familyLabel.font = .systemFont(ofSize: 11)
        familyLabel.textColor = .secondaryLabelColor
        familyLabel.lineBreakMode = .byWordWrapping
        familyLabel.maximumNumberOfLines = 0
        familyLabel.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addSubview(familyLabel)

        NSLayoutConstraint.activate([
            badgeView.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
            badgeView.topAnchor.constraint(equalTo: headerStack.topAnchor, constant: 2),
            badgeView.widthAnchor.constraint(equalToConstant: 18),
            badgeView.heightAnchor.constraint(equalToConstant: 18),
            virusNameLabel.leadingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: 6),
            virusNameLabel.topAnchor.constraint(equalTo: headerStack.topAnchor),
            virusNameLabel.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),
            familyLabel.leadingAnchor.constraint(equalTo: virusNameLabel.leadingAnchor),
            familyLabel.topAnchor.constraint(equalTo: virusNameLabel.bottomAnchor, constant: 2),
            familyLabel.bottomAnchor.constraint(equalTo: headerStack.bottomAnchor),
        ])
        contentView.addSubview(headerStack)

        // 3. Metrics pills
        let metricsView = buildMetricsView(for: assembly)
        contentView.addSubview(metricsView)

        // Track the last view in the vertical chain for constraint anchoring
        var lastView: NSView = metricsView
        var lastBottomConstant: CGFloat = 8

        // 4. Segment completeness strip (segmented viruses only)
        if isSegmented {
            let strip = SegmentCompletenessView()
            strip.configure(assembly: assembly)
            strip.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(strip)

            NSLayoutConstraint.activate([
                strip.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 12),
                strip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                strip.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            ])

            lastView = strip
            lastBottomConstant = 8
        }

        // 5. Per-segment coverage chart (ONLY for segmented viruses)
        //    For non-segmented viruses, the alignment evidence depth track
        //    already shows coverage, so the separate chart is redundant.
        if isSegmented {
            coveragePlotView.configure(
                assembly: assembly,
                coverageWindows: selectedCoverageWindows
            )
            contentView.addSubview(coveragePlotView)

            NSLayoutConstraint.activate([
                coveragePlotView.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 12),
                coveragePlotView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                coveragePlotView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                coveragePlotView.heightAnchor.constraint(equalToConstant: 120),
            ])

            lastView = coveragePlotView
            lastBottomConstant = 16
        }

        // Main layout constraints
        let constraints = [
            headerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            headerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            metricsView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            metricsView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            metricsView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            lastView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -lastBottomConstant),
        ]

        NSLayoutConstraint.activate(constraints)
    }

    private func buildAlignmentEvidenceOnlyDetailContent(using evidenceView: NSView) {
        evidenceView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(evidenceView)

        NSLayoutConstraint.activate([
            evidenceView.topAnchor.constraint(equalTo: contentView.topAnchor),
            evidenceView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            evidenceView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            evidenceView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func buildMetricsView(for assembly: ViralAssembly) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .top
        container.distribution = .fillEqually
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let metrics: [(String, String)] = [
            ("Reads", formatNumber(assembly.totalReads)),
            ("RPKMF", String(format: "%.1f", assembly.rpkmf)),
            ("Coverage", String(format: "%.1fx", assembly.meanCoverage)),
            ("Identity", String(format: "%.1f%%", assembly.avgReadIdentity * 100)),
            ("Family", assembly.family ?? "Unknown"),
        ]

        activeMetricWidthConstraints = []
        for (label, value) in metrics {
            let metricView = makeMetricPill(label: label, value: value)
            container.addArrangedSubview(metricView)
            activeMetricWidthConstraints.append(
                metricView.widthAnchor.constraint(equalTo: container.widthAnchor)
            )
        }

        activeMetricsView = container
        return container
    }

    private func makeMetricPill(label: String, value: String) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 9, weight: .medium)
        labelField.textColor = .tertiaryLabelColor
        labelField.alignment = .center
        labelField.lineBreakMode = .byWordWrapping
        labelField.maximumNumberOfLines = 0
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let valueField = NSTextField(labelWithString: value)
        valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueField.textColor = .labelColor
        valueField.alignment = .center
        valueField.lineBreakMode = .byCharWrapping
        valueField.maximumNumberOfLines = 0
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueField.translatesAutoresizingMaskIntoConstraints = false

        pill.addSubview(labelField)
        pill.addSubview(valueField)

        NSLayoutConstraint.activate([
            labelField.topAnchor.constraint(equalTo: pill.topAnchor),
            labelField.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            labelField.trailingAnchor.constraint(equalTo: pill.trailingAnchor),

            valueField.topAnchor.constraint(equalTo: labelField.bottomAnchor, constant: 2),
            valueField.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            valueField.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            valueField.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])

        return pill
    }

    private func updateAdaptiveMetricLayout() {
        guard let metrics = activeMetricsView else { return }
        let shouldStack = AppSettings.shared.contentTextSizePreference.normalized.scaleFactor >= 1.5
            || scrollView.contentView.bounds.width < 420
        let orientation: NSUserInterfaceLayoutOrientation = shouldStack ? .vertical : .horizontal
        guard metrics.orientation != orientation else { return }
        if shouldStack {
            NSLayoutConstraint.activate(activeMetricWidthConstraints)
        } else {
            NSLayoutConstraint.deactivate(activeMetricWidthConstraints)
        }
        metrics.orientation = orientation
        metrics.alignment = shouldStack ? .width : .top
        metrics.distribution = shouldStack ? .fill : .fillEqually
        contentView.needsLayout = true
    }

    public override func layout() {
        super.layout()
        updateAdaptiveMetricLayout()
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Confidence Badge

    /// Creates a confidence badge icon for the given assembly.
    ///
    /// Confidence tiers (from EsViritu research):
    /// - **High** (green ✓): ≥500 reads AND ≥95% identity AND ≥50% coverage
    /// - **Medium** (yellow △): ≥50 reads AND ≥90% identity AND ≥10% coverage
    /// - **Low** (red !): everything else (<50 reads, OR <90% identity, OR <10% coverage)
    ///
    /// All three conditions must be met for High/Medium. This prevents a 1-read
    /// detection with 100% identity from being rated "medium".
    private func makeConfidenceBadge(for assembly: ViralAssembly) -> NSView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown

        let reads = assembly.totalReads
        let identity = assembly.avgReadIdentity
        let coverage = assembly.meanCoverage

        if reads >= 500 && identity >= 0.95 && coverage >= 0.5 {
            // High confidence — strong detection
            imageView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "High confidence")
            imageView.contentTintColor = .systemGreen
        } else if reads >= 50 && identity >= 0.90 && coverage >= 0.1 {
            // Medium confidence — needs review
            imageView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Medium confidence")
            imageView.contentTintColor = .systemYellow
        } else {
            // Low confidence — likely noise, crosstalk, or very weak signal
            imageView.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Low confidence")
            imageView.contentTintColor = .lungfishDanger
        }

        return imageView
    }

    // MARK: - Testing Accessors

    var testIsShowingOverview: Bool {
        if case .overview = displayMode {
            return true
        }
        return false
    }

    #if DEBUG
    struct TestingTypographyMetrics: Equatable {
        let titlePointSize: CGFloat
        let summaryPointSize: CGFloat
        let metricOrientation: NSUserInterfaceLayoutOrientation?
        let metricFieldsAreContained: Bool
    }

    var testingTypographyMetrics: TestingTypographyMetrics {
        let summary = allTextFields(in: contentView).first {
            $0.stringValue.contains("assemblies detected")
        }
        return TestingTypographyMetrics(
            titlePointSize: overviewTitleLabel.font?.pointSize ?? 0,
            summaryPointSize: summary?.font?.pointSize ?? 0,
            metricOrientation: activeMetricsView?.orientation,
            metricFieldsAreContained: activeMetricsView.map { metrics in
                metrics.layoutSubtreeIfNeeded()
                let fields = allTextFields(in: metrics)
                return !fields.isEmpty && fields.allSatisfy { field in
                    guard let parent = field.superview else { return false }
                    return field.frame.width > 0
                        && field.frame.height > 0
                        && parent.bounds.insetBy(dx: -2, dy: -2).contains(field.frame)
                }
            } ?? true
        )
    }

    var testingContentRebuildCount: Int {
        contentRebuildCount
    }

    var testingScientificViewIdentities: [ObjectIdentifier] {
        [ObjectIdentifier(topVirusesView), ObjectIdentifier(coveragePlotView)]
    }

    var testingMetricFrameDescription: String {
        guard let metrics = activeMetricsView else { return "no metrics" }
        return allTextFields(in: metrics).map {
            "\($0.stringValue): frame=\(NSStringFromRect($0.frame)) parent=\(NSStringFromRect($0.superview?.bounds ?? .zero))"
        }.joined(separator: " | ")
    }

    var testingFullTextAccessibility: [(String, String?, String?)] {
        allTextFields(in: contentView).map {
            (
                $0.stringValue,
                $0.toolTip,
                $0.accessibilityValue()
            )
        }
    }

    private func allTextFields(in root: NSView) -> [NSTextField] {
        root.subviews.flatMap { view -> [NSTextField] in
            let own = (view as? NSTextField).map { [$0] } ?? []
            return own + allTextFields(in: view)
        }
    }
    #endif
}

// MARK: - TopVirusBarChartView

/// A horizontal bar chart showing the top detected viruses by read count.
///
/// Renders up to 15 bars using CoreGraphics with the phylum-based color
/// palette from ``TaxonomyPhylumPalette``.
@MainActor
final class TopVirusBarChartView: NSView {

    private var assemblies: [ViralAssembly] = []
    private let maxBars = 15

    func configure(assemblies: [ViralAssembly]) {
        self.assemblies = Array(assemblies.sorted { $0.totalReads > $1.totalReads }.prefix(maxBars))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !assemblies.isEmpty else { return }

        let maxReads = assemblies.map(\.totalReads).max() ?? 1
        let barHeight: CGFloat = 18
        let gap: CGFloat = 3
        let labelWidth: CGFloat = min(bounds.width * 0.45, 160)
        let barAreaWidth = bounds.width - labelWidth - 8

        for (i, assembly) in assemblies.enumerated() {
            let y = bounds.height - CGFloat(i + 1) * (barHeight + gap)
            guard y >= 0 else { break }

            // Bar
            let barWidth = barAreaWidth * CGFloat(assembly.totalReads) / CGFloat(max(1, maxReads))
            let barRect = NSRect(x: labelWidth + 4, y: y, width: max(2, barWidth), height: barHeight)
            let color = NSColor.controlAccentColor.withAlphaComponent(0.7)
            color.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3).fill()

            // Read count on bar
            let countStr = "\(assembly.totalReads)" as NSString
            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let countSize = countStr.size(withAttributes: countAttrs)
            if countSize.width + 6 < barWidth {
                countStr.draw(
                    at: NSPoint(x: labelWidth + 8, y: y + (barHeight - countSize.height) / 2),
                    withAttributes: countAttrs
                )
            }

            // Label
            let name = (assembly.species ?? assembly.name).replacingOccurrences(of: "s__", with: "") as NSString
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ]
            let nameRect = NSRect(x: 4, y: y, width: labelWidth - 4, height: barHeight)
            name.draw(with: nameRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: nameAttrs)
        }
    }

    override var intrinsicContentSize: NSSize {
        let h = CGFloat(min(assemblies.count, maxBars)) * 21 + 4
        return NSSize(width: NSView.noIntrinsicMetric, height: max(100, h))
    }
}

// MARK: - CoverageAreaChartView

/// A CoreGraphics area chart showing genome coverage depth across 100 windows.
///
/// For segmented viruses, draws one sub-chart per segment with labels.
/// Uses a gradient fill from accent color (bottom) to transparent (top).
@MainActor
final class CoverageAreaChartView: NSView {

    private var segments: [(accession: String, segment: String?, windows: [ViralCoverageWindow])] = []

    func configure(assembly: ViralAssembly, coverageWindows: [String: [ViralCoverageWindow]]) {
        segments = assembly.contigs.compactMap { contig in
            guard let windows = coverageWindows[contig.accession], !windows.isEmpty else { return nil }
            let sorted = windows.sorted { $0.windowIndex < $1.windowIndex }
            return (accession: contig.accession, segment: contig.segment, windows: sorted)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !segments.isEmpty else {
            drawEmptyState()
            return
        }

        let segmentCount = segments.count
        let segmentHeight = (bounds.height - 4) / CGFloat(max(1, segmentCount))

        for (i, seg) in segments.enumerated() {
            let y = bounds.height - CGFloat(i + 1) * segmentHeight
            let rect = NSRect(x: 0, y: y + 2, width: bounds.width, height: segmentHeight - 4)
            drawCoverageChart(windows: seg.windows, in: rect, label: seg.segment)
        }
    }

    private func drawCoverageChart(windows: [ViralCoverageWindow], in rect: NSRect, label: String?) {
        guard !windows.isEmpty else { return }

        let maxCov = windows.map(\.averageCoverage).max() ?? 1
        let n = windows.count

        // Build path
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))

        for (i, w) in windows.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(max(1, n - 1))
            let normalizedCov = maxCov > 0 ? CGFloat(w.averageCoverage / maxCov) : 0
            let y = rect.minY + rect.height * normalizedCov
            path.line(to: NSPoint(x: x, y: y))
        }

        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.close()

        // Fill with gradient
        let accentColor = NSColor.controlAccentColor
        accentColor.withAlphaComponent(0.3).setFill()
        path.fill()

        // Stroke the top edge
        let strokePath = NSBezierPath()
        for (i, w) in windows.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(max(1, n - 1))
            let normalizedCov = maxCov > 0 ? CGFloat(w.averageCoverage / maxCov) : 0
            let y = rect.minY + rect.height * normalizedCov
            if i == 0 {
                strokePath.move(to: NSPoint(x: x, y: y))
            } else {
                strokePath.line(to: NSPoint(x: x, y: y))
            }
        }
        accentColor.withAlphaComponent(0.8).setStroke()
        strokePath.lineWidth = 1.5
        strokePath.stroke()

        // Max coverage annotation
        if let maxWindow = windows.max(by: { $0.averageCoverage < $1.averageCoverage }) {
            let maxIdx = windows.firstIndex(where: { $0.windowIndex == maxWindow.windowIndex }) ?? 0
            let x = rect.minX + rect.width * CGFloat(maxIdx) / CGFloat(max(1, n - 1))
            let normalizedCov = maxCov > 0 ? CGFloat(maxWindow.averageCoverage / maxCov) : 0
            let y = rect.minY + rect.height * normalizedCov

            // Draw dot at max
            let dotRect = NSRect(x: x - 3, y: y - 3, width: 6, height: 6)
            accentColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            // Label
            let maxLabel = String(format: "%.0fx", maxWindow.averageCoverage) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: accentColor,
            ]
            maxLabel.draw(at: NSPoint(x: x + 5, y: y - 4), withAttributes: attrs)
        }

        // Segment label
        if let label {
            let segLabel = "Seg \(label)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            segLabel.draw(at: NSPoint(x: rect.minX + 4, y: rect.maxY - 12), withAttributes: attrs)
        }
    }

    private func drawEmptyState() {
        let text = "No coverage data" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }
}
