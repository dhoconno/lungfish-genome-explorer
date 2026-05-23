import AppKit
import LungfishCore
import LungfishIO

@MainActor
final class GenotypeResultViewController: NSViewController {
    typealias Lens = GenotypeResultViewportLens

    var onSelectionStateChanged: ((GenotypeResultSelectionState?) -> Void)?
    var onDisplaySummaryChanged: ((Int, Int, Int) -> Void)?
    var onDisplayStateChanged: ((GenotypeResultDisplayState) -> Void)?

    private let summaryStrip = NSStackView()
    private let lensControl = NSSegmentedControl(
        labels: Lens.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let contentHost = NSView()

    private let splitView = TrackedDividerSplitView()
    private let sampleContainer = NSView()
    private let detailContainer = NSView()
    private let comparisonMatrix = GenotypeComparisonMatrixView()
    private let outlineView = GenotypeOutlineView()
    private let cohortSummaryPanel = GenotypeCohortSummaryPanelView()
    private let detailScrollView = NSScrollView()
    private let detailDocumentView = FlippedDocumentView()
    private let detailStack = NSStackView()

    private let haplotypeScrollView = NSScrollView()
    private let haplotypeStack = NSStackView()
    private let consumerScrollView = NSScrollView()
    private let consumerStack = NSStackView()
    private let anchorScrollView = NSScrollView()
    private let anchorStack = NSStackView()
    private let artifactScrollView = NSScrollView()
    private let artifactStack = NSStackView()

    private let splitCoordinator = TwoPaneTrackedSplitCoordinator()

    private var result: ONTGenotypeResultBundleData?
    private var sampleMetadataStore: SampleMetadataStore?
    private var selectedLens: Lens = .summary
    private var displayState = GenotypeResultDisplayState()
    private var currentSharedCall: ONTGenotypeSharedCall?
    private var currentSelectedSample: String?
    private var currentSelectionState: GenotypeResultSelectionState?
    private var activeContentView: NSView?
    private var activeContentConstraints: [NSLayoutConstraint] = []
    private var haplotypeSampleActionTags: [Int: String] = [:]
    private var nextHaplotypeSampleActionTag = 1
    private var outlineRowsBySample: [String: GenotypeOutlineView.Row] = [:]

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Genotype result viewport")
        root.setAccessibilityIdentifier("genotype-result-view")
        view = root

        configureSummaryStrip()
        configureLensControl()
        configureContentHost()
        configureSplitView()
        configureDetailPane()
        configureScrollLens(haplotypeScrollView, stack: haplotypeStack, identifier: "genotype-haplotype-lens")
        configureScrollLens(anchorScrollView, stack: anchorStack, identifier: "genotype-anchor-lens")
        configureScrollLens(consumerScrollView, stack: consumerStack, identifier: "genotype-consumer-lens")
        configureScrollLens(artifactScrollView, stack: artifactStack, identifier: "genotype-artifacts-lens")
        layout()
        wireCallbacks()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard selectedLens == .summary, splitView.arrangedSubviews.count == 2 else { return }
        if view.window == nil {
            applySplitPositionIfNeeded()
        } else if splitCoordinator.needsInitialSplitValidation {
            scheduleInitialSplitValidationIfNeeded()
        }
    }

    func configure(result: ONTGenotypeResultBundleData) {
        self.result = result
        let knownSampleIDs = Set(result.samples.map(\.sample) + result.calls.map(\.sample))
        sampleMetadataStore = SampleMetadataStore.load(from: result.bundleURL, knownSampleIds: knownSampleIDs)
        comparisonMatrix.configure(result: result, metadataStore: sampleMetadataStore)
        rebuildSummary()
        rebuildHaplotypeLens()
        rebuildAnchorLens()
        rebuildConsumerLens()
        rebuildArtifactLens()
        rebuildOutline()
        rebuildCohortSummary()
        showLens(.summary)
        comparisonMatrix.selectFirstSharedCall()
    }

    func applySampleMetadataStore(_ store: SampleMetadataStore?) {
        sampleMetadataStore = store
        comparisonMatrix.applyMetadataStore(store)
        rebuildConsumerLens()
        if let currentSharedCall {
            showSharedCall(currentSharedCall, sample: currentSelectedSample)
        }
    }

    func notifySelectionStateIfAvailable() {
        onSelectionStateChanged?(currentSelectionState)
    }

    func applyDisplayState(_ state: GenotypeResultDisplayState) {
        let previousViewMode = displayState.summaryViewMode
        displayState = state
        if selectedLens != state.viewportLens {
            showLens(state.viewportLens)
        } else {
            lensControl.selectedSegment = segmentIndex(for: state.viewportLens)
            if selectedLens == .summary {
                applySummaryViewModeVisibility()
            }
        }
        comparisonMatrix.applyDisplayState(state)
        rebuildAnchorLens()
        rebuildConsumerLens()
        if previousViewMode != state.summaryViewMode {
            rebuildOutline()
            rebuildCohortSummary()
        }
        applyLayoutPreference()
        if let currentSharedCall {
            showSharedCall(currentSharedCall, sample: currentSelectedSample)
        }
    }

    func applyHighlight(_ request: GenotypeResultHighlightRequest) {
        let previousColor = previousHighlightColor(for: request)
        comparisonMatrix.applyHighlight(request)
        registerUndo(for: request, previousColor: previousColor)
        if let currentSharedCall {
            showSharedCall(currentSharedCall, sample: currentSelectedSample)
        }
    }

    private func applyHighlightWithoutUndo(_ request: GenotypeResultHighlightRequest) {
        comparisonMatrix.applyHighlight(request)
        if let currentSharedCall {
            showSharedCall(currentSharedCall, sample: currentSelectedSample)
        }
    }

    private func configureSummaryStrip() {
        summaryStrip.translatesAutoresizingMaskIntoConstraints = false
        summaryStrip.orientation = .horizontal
        summaryStrip.alignment = .centerY
        summaryStrip.spacing = 10
        summaryStrip.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        summaryStrip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryStrip.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configureLensControl() {
        lensControl.translatesAutoresizingMaskIntoConstraints = false
        lensControl.target = self
        lensControl.action = #selector(lensChanged(_:))
        lensControl.selectedSegment = segmentIndex(for: .summary)
        lensControl.setAccessibilityIdentifier("genotype-result-lens-control")
    }

    private func configureContentHost() {
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configureSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        splitView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sampleContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        sampleContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sampleContainer.addSubview(comparisonMatrix)
        sampleContainer.addSubview(outlineView)
        outlineView.isHidden = true
        outlineView.onRowSelected = { [weak self] animalId in
            self?.handleOutlineRowSelected(animalId)
        }

        splitView.addArrangedSubview(sampleContainer)
        splitView.addArrangedSubview(detailContainer)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        NSLayoutConstraint.activate([
            comparisonMatrix.topAnchor.constraint(equalTo: sampleContainer.topAnchor),
            comparisonMatrix.leadingAnchor.constraint(equalTo: sampleContainer.leadingAnchor),
            comparisonMatrix.trailingAnchor.constraint(equalTo: sampleContainer.trailingAnchor),
            comparisonMatrix.bottomAnchor.constraint(equalTo: sampleContainer.bottomAnchor),
            outlineView.topAnchor.constraint(equalTo: sampleContainer.topAnchor),
            outlineView.leadingAnchor.constraint(equalTo: sampleContainer.leadingAnchor),
            outlineView.trailingAnchor.constraint(equalTo: sampleContainer.trailingAnchor),
            outlineView.bottomAnchor.constraint(equalTo: sampleContainer.bottomAnchor),
        ])
    }

    private func configureDetailPane() {
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.hasVerticalScroller = true
        detailScrollView.hasHorizontalScroller = false
        detailScrollView.autohidesScrollers = true
        detailScrollView.borderType = .noBorder
        detailScrollView.drawsBackground = false
        detailDocumentView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.documentView = detailDocumentView
        detailScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailContainer.addSubview(detailScrollView)
        detailContainer.addSubview(cohortSummaryPanel)
        cohortSummaryPanel.isHidden = true

        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.orientation = .vertical
        detailStack.alignment = .width
        detailStack.spacing = 8
        detailStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        detailStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailDocumentView.addSubview(detailStack)

        NSLayoutConstraint.activate([
            detailScrollView.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailScrollView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailScrollView.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detailScrollView.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            detailDocumentView.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor),
            detailDocumentView.heightAnchor.constraint(greaterThanOrEqualTo: detailScrollView.contentView.heightAnchor),
            detailStack.topAnchor.constraint(equalTo: detailDocumentView.topAnchor, constant: 8),
            detailStack.leadingAnchor.constraint(equalTo: detailDocumentView.leadingAnchor, constant: 10),
            detailStack.trailingAnchor.constraint(equalTo: detailDocumentView.trailingAnchor, constant: -10),
            detailStack.bottomAnchor.constraint(lessThanOrEqualTo: detailDocumentView.bottomAnchor, constant: -8),
            cohortSummaryPanel.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            cohortSummaryPanel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            cohortSummaryPanel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            cohortSummaryPanel.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
    }

    private func configureScrollLens(_ scrollView: NSScrollView, stack: NSStackView, identifier: String) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = stack
        scrollView.setAccessibilityIdentifier(identifier)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
    }

    private func layout() {
        view.addSubview(summaryStrip)
        view.addSubview(lensControl)
        view.addSubview(contentHost)

        NSLayoutConstraint.activate([
            summaryStrip.topAnchor.constraint(equalTo: view.topAnchor),
            summaryStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryStrip.trailingAnchor.constraint(lessThanOrEqualTo: lensControl.leadingAnchor, constant: -12),
            summaryStrip.heightAnchor.constraint(equalToConstant: 48),

            lensControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            lensControl.centerYAnchor.constraint(equalTo: summaryStrip.centerYAnchor),

            contentHost.topAnchor.constraint(equalTo: summaryStrip.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func wireCallbacks() {
        comparisonMatrix.onSharedCallSelected = { [weak self] sharedCall, sample in
            self?.showSharedCall(sharedCall, sample: sample)
        }
        comparisonMatrix.onSelectionCleared = { [weak self] in
            self?.showEmptySelection()
        }
        comparisonMatrix.onDisplaySummaryChanged = { [weak self] visibleRows, totalRows, hiddenCells in
            self?.onDisplaySummaryChanged?(visibleRows, totalRows, hiddenCells)
        }
    }

    @objc private func lensChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0,
              sender.selectedSegment < Lens.allCases.count else { return }
        let lens = Lens.allCases[sender.selectedSegment]
        showLens(lens)
        onDisplayStateChanged?(displayState)
    }

    private func showLens(_ lens: Lens) {
        selectedLens = lens
        displayState.viewportLens = lens
        lensControl.selectedSegment = segmentIndex(for: lens)
        switch lens {
        case .summary:
            installContentView(splitView)
            applySummaryViewModeVisibility()
            scheduleInitialSplitValidationIfNeeded()
            applyLayoutPreference()
        case .review:
            installContentView(haplotypeScrollView)
        case .audit:
            installContentView(artifactScrollView)
        }
    }

    private func applySummaryViewModeVisibility() {
        let showOutline = displayState.summaryViewMode == .outline
        outlineView.isHidden = !showOutline
        comparisonMatrix.isHidden = showOutline
        cohortSummaryPanel.isHidden = !showOutline
        detailScrollView.isHidden = showOutline
    }

    private func segmentIndex(for lens: Lens) -> Int {
        Lens.allCases.firstIndex(of: lens) ?? 0
    }

    private func installContentView(_ contentView: NSView) {
        guard activeContentView !== contentView else { return }
        NSLayoutConstraint.deactivate(activeContentConstraints)
        activeContentConstraints = []
        activeContentView?.removeFromSuperview()

        contentHost.addSubview(contentView)
        activeContentView = contentView
        activeContentConstraints = [
            contentView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ]
        NSLayoutConstraint.activate(activeContentConstraints)
    }

    private func applySplitPositionIfNeeded() {
        splitCoordinator.applyInitialSplitPositionIfNeeded(
            to: splitView,
            defaultLeadingFraction: defaultLeadingFraction(for: displayState.layout),
            defaultLeadingExtent: defaultLeadingExtent(for: displayState.layout),
            minimumExtents: minimumSplitExtents()
        )
    }

    private func scheduleInitialSplitValidationIfNeeded() {
        splitCoordinator.scheduleInitialSplitValidationIfNeeded(
            ownerView: view,
            splitView: splitView,
            minimumExtents: { [weak self] in
                self?.minimumSplitExtents() ?? (360, 280)
            },
            defaultLeadingFraction: { [weak self] in
                self?.defaultLeadingFraction(for: self?.displayState.layout ?? .listLeading) ?? 0.62
            },
            defaultLeadingExtent: { [weak self] in
                self?.defaultLeadingExtent(for: self?.displayState.layout ?? .listLeading)
            }
        )
    }

    private func minimumSplitExtents() -> (leading: CGFloat, trailing: CGFloat) {
        switch displayState.layout {
        case .listLeading, .listTrailing:
            return (leading: 520, trailing: 300)
        case .listTop:
            return (leading: 220, trailing: 180)
        }
    }

    private func defaultLeadingFraction(for layout: GenotypeResultPanelLayout) -> CGFloat {
        switch layout {
        case .listLeading:
            return 0.68
        case .listTrailing:
            return 0.32
        case .listTop:
            return 0.58
        }
    }

    private func defaultLeadingExtent(for layout: GenotypeResultPanelLayout) -> CGFloat? {
        switch layout {
        case .listLeading:
            return 720
        case .listTrailing:
            return 360
        case .listTop:
            return nil
        }
    }

    private func applyLayoutPreference() {
        guard splitView.arrangedSubviews.count > 1 else { return }
        let listFirst = displayState.layout != .listTrailing
        splitCoordinator.applyLayoutPreference(
            to: splitView,
            desiredIsVertical: displayState.layout != .listTop,
            desiredFirstPane: listFirst ? sampleContainer : detailContainer,
            desiredSecondPane: listFirst ? detailContainer : sampleContainer,
            defaultLeadingFraction: defaultLeadingFraction(for: displayState.layout),
            defaultLeadingExtent: defaultLeadingExtent(for: displayState.layout),
            minimumExtents: minimumSplitExtents(),
            isViewInWindow: view.window != nil
        )
    }

    private func rebuildSummary() {
        removeArrangedSubviews(from: summaryStrip)
        guard let result else { return }
        let qcCounts = result.qcStatusCounts
        [
            ("Samples", "\(result.sampleCount)"),
            ("Calls", "\(result.callCount)"),
            ("Genotypes", "\(result.locusSummaries.reduce(0) { $0 + $1.callCount })"),
            ("Loci", "\(result.locusSummaries.count)"),
            ("OK", "\(qcCounts[.ok, default: 0])"),
            ("Review", "\(qcCounts[.review, default: 0])"),
        ].forEach { label, value in
            summaryStrip.addArrangedSubview(summaryPill(label: label, value: value))
        }
    }

    private func summaryPill(label: String, value: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.usesSingleLineMode = true

        let keyLabel = NSTextField(labelWithString: label)
        keyLabel.font = .systemFont(ofSize: 10)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.lineBreakMode = .byTruncatingTail
        keyLabel.usesSingleLineMode = true

        stack.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(keyLabel)
        return stack
    }

    private func showSharedCall(_ sharedCall: ONTGenotypeSharedCall, sample: String? = nil) {
        currentSharedCall = sharedCall
        currentSelectedSample = sample
        removeArrangedSubviews(from: detailStack)

        detailStack.addArrangedSubview(sectionTitle("Selected Genotype"))
        detailStack.addArrangedSubview(wrappingText(sharedCall.genotype, weight: .medium, maximumLines: 3))
        detailStack.addArrangedSubview(caption(sharedCallMeaning(for: sharedCall)))
        detailStack.addArrangedSubview(sectionTitle("Support Summary"))
        detailStack.addArrangedSubview(detailRows([
            ("Locus", sharedCall.locus),
            ("Samples", "\(sharedCall.sampleCount)"),
            ("Unique Reads", integer(sharedCall.totalUniqueReads)),
            ("Alignments", integer(sharedCall.totalAlignments)),
            ("Top Sample", sharedCall.topSupport.map { "\($0.sample) - \(integer($0.passedUniqueReads)) unique" } ?? "Unavailable"),
            ("Support Metric", supportMetricLabel),
        ]))

        if let sample,
           let support = sharedCall.support(for: sample) {
            detailStack.addArrangedSubview(sectionTitle("Selected Cell"))
            detailStack.addArrangedSubview(detailRows([
                ("Sample", sample),
                ("Unique Reads", integer(support.passedUniqueReads)),
                ("Alignments", integer(support.passedAlignments)),
                ("Support", supportFractionLabel(genotype: sharedCall.genotype, sample: sample)),
            ]))
        }

        if let aliases = sharedCall.aliasDisplay {
            detailStack.addArrangedSubview(sectionTitle("Ambiguous Alleles"))
            detailStack.addArrangedSubview(wrappingText(aliases, maximumLines: 5))
        }

        if let anchorSummary = anchorSummary(for: sharedCall) {
            detailStack.addArrangedSubview(sectionTitle("Anchor Evidence"))
            detailStack.addArrangedSubview(detailRows([
                ("Anchor", anchorSummary.label),
                ("Source", anchorSummary.source.displayName),
                ("Loci", anchorSummary.loci.joined(separator: ", ")),
                ("Samples", "\(anchorSummary.sampleCount)"),
                ("Unique Reads", integer(anchorSummary.totalUniqueReads)),
            ]))
            detailStack.addArrangedSubview(caption(anchorSummary.caveat))
        }

        let coOccurrences = sameLocusCoOccurrences(for: sharedCall)
        if !coOccurrences.isEmpty {
            detailStack.addArrangedSubview(sectionTitle("Same-Locus Co-occurrence"))
            detailStack.addArrangedSubview(caption("These values show sample-level co-observation within \(sharedCall.locus). They are not phase, haplotype, zygosity, copy-number, or absence calls."))
            detailStack.addArrangedSubview(coOccurrenceTable(Array(coOccurrences.prefix(8))))
        }

        detailStack.addArrangedSubview(sectionTitle("Supporting Samples"))
        if sharedCall.sampleSupport.isEmpty {
            detailStack.addArrangedSubview(caption("No assigned samples support this genotype."))
        } else {
            detailStack.addArrangedSubview(sampleSupportTable(Array(sharedCall.sampleSupport.prefix(24))))
            if sharedCall.sampleSupport.count > 24 {
                detailStack.addArrangedSubview(caption("\(sharedCall.sampleSupport.count - 24) additional samples are visible in the matrix."))
            }
        }

        publishSelectionState(selectionState(for: sharedCall, sample: sample))
    }

    private func showEmptySelection() {
        currentSharedCall = nil
        currentSelectedSample = nil
        removeArrangedSubviews(from: detailStack)
        detailStack.addArrangedSubview(caption("Select a genotype row to review shared support."))
        publishSelectionState(nil)
    }

    private func selectionState(for sharedCall: ONTGenotypeSharedCall, sample: String?) -> GenotypeResultSelectionState {
        var rows: [(String, String)] = [
            ("Meaning", sharedCallMeaning(for: sharedCall)),
            ("Locus", sharedCall.locus),
            ("Samples", "\(sharedCall.sampleCount)"),
            ("Unique Reads", integer(sharedCall.totalUniqueReads)),
            ("Alignments", integer(sharedCall.totalAlignments)),
            ("Support Metric", supportMetricLabel),
        ]
        if let sample,
           let support = sharedCall.support(for: sample) {
            rows.append(("Selected Sample", sample))
            rows.append(("Selected Unique", integer(support.passedUniqueReads)))
            rows.append(("Selected Support", supportFractionLabel(genotype: sharedCall.genotype, sample: sample)))
        }
        if let topSupport = sharedCall.topSupport {
            rows.append(("Top Sample", "\(topSupport.sample) - \(integer(topSupport.passedUniqueReads)) unique"))
        }
        if let aliases = sharedCall.aliasDisplay {
            rows.append(("Aliases", aliases))
        }
        let target = GenotypeResultHighlightTarget(
            genotype: sharedCall.genotype,
            locus: sharedCall.locus,
            sample: sample
        )
        let style = comparisonMatrix.highlightStyle(for: target)
        return GenotypeResultSelectionState(
            title: sharedCall.genotype,
            subtitle: "\(sharedCall.locus) - \(sharedCall.sampleCount) samples",
            detailRows: rows,
            highlightTarget: target,
            highlightStyle: style
        )
    }

    private func publishSelectionState(_ state: GenotypeResultSelectionState?) {
        currentSelectionState = state
        onSelectionStateChanged?(state)
    }

    private func rebuildHaplotypeLens() {
        removeArrangedSubviews(from: haplotypeStack)
        haplotypeSampleActionTags.removeAll()
        nextHaplotypeSampleActionTag = 1
        guard let result else { return }
        haplotypeStack.addArrangedSubview(sectionTitle("Deterministic Haplotype Review"))
        guard let analysis = result.haplotypeAnalysis else {
            haplotypeStack.addArrangedSubview(caption("No haplotype definition was selected for this genotype result. Deterministic haplotyping is not inferred automatically."))
            return
        }

        let reviewSamples = analysis.samples.filter(haplotypeSampleNeedsReview)
        haplotypeStack.addArrangedSubview(detailRows([
            ("Definition", analysis.definitionSetName),
            ("Assay", analysis.assayID),
            ("Samples", "\(analysis.samples.count)"),
            ("Review", "\(reviewSamples.count)"),
        ]))
        haplotypeStack.addArrangedSubview(caption("Calls are deterministic matches against the selected assay definition. Review samples are those with too many haplotypes/genotypes, no matching definition, or extra observed genotype labels."))

        if analysis.samples.isEmpty {
            haplotypeStack.addArrangedSubview(caption("No assigned samples were available for haplotype review."))
            return
        }

        let sortedSamples = analysis.samples.sorted { lhs, rhs in
            let lhsNeedsReview = haplotypeSampleNeedsReview(lhs)
            let rhsNeedsReview = haplotypeSampleNeedsReview(rhs)
            if lhsNeedsReview != rhsNeedsReview {
                return lhsNeedsReview && !rhsNeedsReview
            }
            return lhs.sample.localizedStandardCompare(rhs.sample) == .orderedAscending
        }

        for sample in sortedSamples.prefix(80) {
            haplotypeStack.addArrangedSubview(haplotypeSampleRow(sample))
        }
        if analysis.samples.count > 80 {
            haplotypeStack.addArrangedSubview(caption("\(analysis.samples.count - 80) additional samples are hidden in this summary."))
        }
    }

    private func rebuildConsumerLens() {
        removeArrangedSubviews(from: consumerStack)
        guard let result else { return }
        let qcCounts = result.qcStatusCounts

        consumerStack.addArrangedSubview(sectionTitle("Run Summary"))
        consumerStack.addArrangedSubview(detailRows([
            ("Run", result.manifest.analysisName),
            ("Samples", "\(result.sampleCount)"),
            ("Usable", "\(qcCounts[.ok, default: 0])"),
            ("Needs Review", "\(qcCounts[.review, default: 0] + qcCounts[.lowSupport, default: 0])"),
            ("Retained Reads", integer(result.stats.retainedUniqueReads)),
            ("Assigned Retained", integer(result.stats.assignedUniqueRetainedReads)),
        ]))

        consumerStack.addArrangedSubview(sectionTitle("Locus Summary"))
        if result.locusSummaries.isEmpty {
            consumerStack.addArrangedSubview(caption("No assigned genotype calls were found in this bundle."))
        } else {
            for summary in result.locusSummaries {
                consumerStack.addArrangedSubview(locusSummaryRow(summary))
            }
        }

        consumerStack.addArrangedSubview(sectionTitle("Interpretation"))
        consumerStack.addArrangedSubview(caption("Shared rows indicate shared support for the same reference label. They do not by themselves prove phased haplotypes, zygosity, copy number, allele absence, or inherited identity."))
    }

    private func rebuildAnchorLens() {
        removeArrangedSubviews(from: anchorStack)
        guard let result else { return }
        let anchors = result.anchorSummaries(
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        )
        anchorStack.addArrangedSubview(sectionTitle("Anchor-Oriented Review"))
        anchorStack.addArrangedSubview(caption("Anchor groups are derived from source labels and sample-level co-observation. They are not phased haplotype calls, zygosity calls, copy-number calls, absence calls, or inheritance assertions."))
        if anchors.isEmpty {
            anchorStack.addArrangedSubview(caption("No genotype calls are available for anchor review."))
            return
        }
        for anchor in anchors.prefix(40) {
            anchorStack.addArrangedSubview(anchorSummaryRow(anchor))
        }
        if anchors.count > 40 {
            anchorStack.addArrangedSubview(caption("\(anchors.count - 40) additional anchors are hidden in this summary. Use the Analyst matrix for full row-level review."))
        }
    }

    private func rebuildArtifactLens() {
        removeArrangedSubviews(from: artifactStack)
        guard let result else { return }
        artifactStack.addArrangedSubview(sectionTitle("Share View"))
        artifactStack.addArrangedSubview(exportViewButton())
        artifactStack.addArrangedSubview(sectionTitle("Bundle Artifacts"))
        [
            ("Workbook", result.artifacts.workbookURL),
            ("Long Summary CSV", result.artifacts.longSummaryCSVURL),
            ("Sample Summary CSV", result.artifacts.sampleSummaryCSVURL),
            ("Run Stats JSON", result.artifacts.statsJSONURL),
            ("Provenance", result.artifacts.provenanceURL),
        ].forEach { artifactStack.addArrangedSubview(artifactRow(label: $0.0, url: $0.1)) }
        if let haplotypeAnalysisURL = result.artifacts.haplotypeAnalysisURL {
            artifactStack.addArrangedSubview(artifactRow(label: "Haplotype Analysis", url: haplotypeAnalysisURL))
        }
    }

    private func rebuildOutline() {
        outlineRowsBySample.removeAll()
        guard let result, let analysis = result.haplotypeAnalysis, !analysis.samples.isEmpty else {
            outlineView.configure(rows: [])
            return
        }
        let loci = orderedLoci(from: analysis)
        var rows: [GenotypeOutlineView.Row] = []
        for sample in analysis.samples {
            let tapeSlots = outlineTapeSlots(for: sample, loci: loci)
            let blockKind = GenotypeBlockClassifier.classify(
                calls: sample.calls.map { (locus: $0.locus, h1: $0.haplotype1, h2: $0.haplotype2) }
            )
            let comment = outlineCommentSummary(for: sample)
            let row = GenotypeOutlineView.Row(
                animalId: sample.sample,
                gsId: nil,
                loci: loci,
                tapeSlots: tapeSlots,
                blockKind: blockKind,
                commentSummary: comment
            )
            rows.append(row)
            outlineRowsBySample[sample.sample] = row
        }
        outlineView.configure(rows: rows)
    }

    private func rebuildCohortSummary() {
        guard let result else {
            cohortSummaryPanel.configure(summary: .init(
                sampleCount: 0,
                qcCounts: [],
                errorTypeCounts: [],
                blockCounts: [],
                readBudget: ("Unavailable", "Unavailable"),
                annotationCounts: []
            ))
            return
        }
        let qcRaw = result.qcStatusCounts
        let qcCounts: [(String, Int)] = [
            ("OK", qcRaw[.ok, default: 0]),
            ("Low support", qcRaw[.lowSupport, default: 0]),
            ("Needs review", qcRaw[.review, default: 0]),
        ]
        let errorTypeCounts = cohortErrorTypeCounts(for: result)
        let blockCounts = cohortBlockCounts(for: result)
        let readBudget = cohortReadBudget(for: result)
        let annotationCounts = cohortAnnotationCounts(for: result)
        cohortSummaryPanel.configure(summary: .init(
            sampleCount: result.sampleCount,
            qcCounts: qcCounts,
            errorTypeCounts: errorTypeCounts,
            blockCounts: blockCounts,
            readBudget: readBudget,
            annotationCounts: annotationCounts
        ))
    }

    private func orderedLoci(from analysis: GenotypeHaplotypeAnalysis) -> [String] {
        guard let firstSample = analysis.samples.first else { return [] }
        return firstSample.calls.map(\.locus)
    }

    private func outlineTapeSlots(
        for sample: GenotypeHaplotypeSampleAnalysis,
        loci: [String]
    ) -> [GenotypeHaplotypeTapeView.Slot] {
        let callsByLocus = Dictionary(uniqueKeysWithValues: sample.calls.map { ($0.locus, $0) })
        return loci.map { locus -> GenotypeHaplotypeTapeView.Slot in
            guard let call = callsByLocus[locus] else {
                return GenotypeHaplotypeTapeView.Slot(locus: locus, h1: .empty, h2: .empty)
            }
            let h1 = outlineCell(for: call.haplotype1, status: call.status)
            let h2 = outlineCell(for: call.haplotype2, status: call.status)
            return GenotypeHaplotypeTapeView.Slot(locus: locus, h1: h1, h2: h2)
        }
    }

    private func outlineCell(
        for name: String,
        status: GenotypeHaplotypeCallStatus
    ) -> GenotypeHaplotypeTapeView.Cell {
        if name == "-" || name.isEmpty {
            return .empty
        }
        if status != .called && status != .specialCase {
            return .error(label: name)
        }
        let token = HaplotypeColorToken.assigned(forName: name)
        return .reference(tokenIndex: token.canonicalIndex, label: name)
    }

    private func outlineCommentSummary(for sample: GenotypeHaplotypeSampleAnalysis) -> String {
        let reviewCalls = sample.calls.filter { haplotypeCallNeedsReview($0) }
        if !reviewCalls.isEmpty {
            return reviewCalls.map { "\($0.locus): \(haplotypeStatusLabel($0.status))" }
                .joined(separator: "; ")
        }
        if let firstSpecial = sample.calls.first(where: { $0.status == .specialCase }) {
            return "\(firstSpecial.locus): special case"
        }
        return ""
    }

    private func cohortErrorTypeCounts(for result: ONTGenotypeResultBundleData) -> [(String, Int)] {
        guard let analysis = result.haplotypeAnalysis else { return [] }
        var tmh = 0
        var noHap = 0
        var tmg = 0
        for sample in analysis.samples {
            for call in sample.calls {
                switch call.status {
                case .tooManyHaplotypes: tmh += 1
                case .noHaplotype: noHap += 1
                case .tooManyGenotypes: tmg += 1
                case .called, .specialCase: break
                }
            }
        }
        return [
            ("TMH", tmh),
            ("NO HAP", noHap),
            ("TMG", tmg),
        ]
    }

    private func cohortBlockCounts(for result: ONTGenotypeResultBundleData) -> [(String, Int)] {
        guard let analysis = result.haplotypeAnalysis else {
            return [
                ("Block coherent", 0),
                ("Recombinant", 0),
                ("Atypical", 0),
            ]
        }
        var coherent = 0
        var recombinant = 0
        var atypical = 0
        for sample in analysis.samples {
            let kind = GenotypeBlockClassifier.classify(
                calls: sample.calls.map { (locus: $0.locus, h1: $0.haplotype1, h2: $0.haplotype2) }
            )
            switch kind {
            case .blockCoherent: coherent += 1
            case .regionalRecombinant: recombinant += 1
            case .atypical: atypical += 1
            case .unknown: break
            }
        }
        return [
            ("Block coherent", coherent),
            ("Recombinant", recombinant),
            ("Atypical", atypical),
        ]
    }

    private func cohortReadBudget(
        for result: ONTGenotypeResultBundleData
    ) -> (median: String, belowThreshold: String) {
        let perSampleReads = result.samples.map(\.passedUniqueReads).sorted()
        let medianText: String
        if perSampleReads.isEmpty {
            medianText = "Unavailable"
        } else {
            let mid = perSampleReads.count / 2
            let median: Double
            if perSampleReads.count.isMultiple(of: 2) {
                median = (Double(perSampleReads[mid - 1]) + Double(perSampleReads[mid])) / 2.0
            } else {
                median = Double(perSampleReads[mid])
            }
            medianText = formatReadCount(median) + " median"
        }
        let threshold = 5_000
        let below = perSampleReads.filter { $0 < threshold }.count
        let belowText = "Below \(formatReadCount(Double(threshold))): \(below) samples"
        return (median: medianText, belowThreshold: belowText)
    }

    private func formatReadCount(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return String(format: "%.0f", value)
    }

    private func cohortAnnotationCounts(for result: ONTGenotypeResultBundleData) -> [(String, Int)] {
        let sidecar = (try? ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: result.bundleURL))
            ?? GenotypeAnnotationSidecar.empty(generatedAt: "")
        return [
            ("Overrides", sidecar.callOverrides.count),
            ("Comments", sidecar.cellComments.count + sidecar.sampleNotes.count),
            ("Highlights", sidecar.cellHighlights.count + sidecar.rowHighlights.count),
        ]
    }

    private func handleOutlineRowSelected(_ animalId: String) {
        guard let row = outlineRowsBySample[animalId] else { return }
        let detailRows: [(String, String)] = [
            ("Animal", animalId),
            ("Loci", row.loci.joined(separator: ", ")),
            ("Block", outlineBlockLabel(row.blockKind)),
            ("Notes", row.commentSummary.isEmpty ? "None" : row.commentSummary),
        ]
        let state = GenotypeResultSelectionState(
            title: animalId,
            subtitle: "Outline sample",
            detailRows: detailRows,
            highlightTarget: nil,
            highlightColor: nil,
            highlightStyle: .default
        )
        publishSelectionState(state)
    }

    private func outlineBlockLabel(_ kind: GenotypeBlockKind) -> String {
        switch kind {
        case .blockCoherent: return "Block coherent"
        case .regionalRecombinant: return "Regional recombinant"
        case .atypical: return "Atypical"
        case .unknown: return "Unknown"
        }
    }

    private func exportViewButton() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        let button = NSButton(title: "Export Excel View...", target: self, action: #selector(exportExcelView(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = "Export the current genotype matrix view, including viewport colors, into a provenance-tracked Excel package."
        stack.addArrangedSubview(button)
        stack.addArrangedSubview(caption("Exports visible matrix rows, support filters, and viewport fill/border colors."))
        return stack
    }

    @objc private func exportExcelView(_ sender: Any?) {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.title = "Export Genotype View"
        panel.nameFieldStringValue = "\(result.manifest.outputName)-genotype-view.lungfishexport"
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let snapshot = self.comparisonMatrix.exportSnapshot(
                        bundleURL: result.bundleURL,
                        analysisName: result.manifest.analysisName,
                        lens: self.selectedLens.identifier
                    )
                    let export = try GenotypeViewportExcelExportService().export(snapshot: snapshot, to: url)
                    NSWorkspace.shared.activateFileViewerSelecting([export.workbookURL])
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    private func locusSummaryRow(_ summary: ONTGenotypeLocusSummary) -> NSView {
        let topCall = summary.sharedCalls.first
        return detailRows([
            ("Locus", summary.locus),
            ("Genotypes", "\(summary.callCount)"),
            ("Samples", "\(summary.sampleCount)"),
            ("Unique Reads", integer(summary.totalUniqueReads)),
            ("Top Shared", topCall.map { "\($0.genotype) (\($0.sampleCount) samples)" } ?? "None"),
        ])
    }

    private func anchorSummaryRow(_ anchor: ONTGenotypeAnchorSummary) -> NSView {
        detailRows([
            ("Anchor", anchor.label),
            ("Source", anchor.source.displayName),
            ("Loci", anchor.loci.joined(separator: ", ")),
            ("Genotypes", "\(anchor.sharedCalls.count)"),
            ("Samples", "\(anchor.sampleCount)"),
            ("Unique Reads", integer(anchor.totalUniqueReads)),
        ])
    }

    private func haplotypeSampleRow(_ sample: GenotypeHaplotypeSampleAnalysis) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reviewCalls = sample.calls.filter { haplotypeCallNeedsReview($0) }
        stack.addArrangedSubview(detailRows([
            ("Sample", sample.sample),
            ("Status", reviewCalls.isEmpty ? "Simple" : "Review"),
            ("Loci", "\(sample.calls.count)"),
            ("Issues", reviewCalls.isEmpty ? "None" : reviewCalls.map(\.locus).joined(separator: ", ")),
        ]))

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        let button = NSButton(title: "Review in Analyst", target: self, action: #selector(reviewHaplotypeSample(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = nextHaplotypeSampleActionTag
        nextHaplotypeSampleActionTag += 1
        haplotypeSampleActionTags[button.tag] = sample.sample
        button.toolTip = "Switch to the genotype matrix filtered to this sample."
        actionRow.addArrangedSubview(button)
        actionRow.addArrangedSubview(caption(reviewCalls.isEmpty ? "Called haplotypes follow the selected deterministic definition." : "Review the retained genotype evidence for this sample."))
        stack.addArrangedSubview(actionRow)

        let calls = sample.calls.map { call in
            "\(call.locus) \(call.haplotype1)/\(call.haplotype2)"
        }.joined(separator: "; ")
        stack.addArrangedSubview(wrappingText(calls, maximumLines: 4))
        if !reviewCalls.isEmpty {
            stack.addArrangedSubview(caption(reviewCalls.map { call in
                "\(call.locus): \(haplotypeStatusLabel(call.status))"
            }.joined(separator: "; ")))
        }
        return stack
    }

    private func haplotypeSampleNeedsReview(_ sample: GenotypeHaplotypeSampleAnalysis) -> Bool {
        sample.calls.contains { haplotypeCallNeedsReview($0) }
    }

    @objc private func reviewHaplotypeSample(_ sender: NSButton) {
        guard let sample = haplotypeSampleActionTags[sender.tag] else { return }
        showAnalystCalls(forHaplotypeSample: sample)
    }

    private func showAnalystCalls(forHaplotypeSample sample: String) {
        showLens(.summary)
        comparisonMatrix.setFilterText(sample)
        comparisonMatrix.selectFirstSharedCall()
        onDisplayStateChanged?(displayState)
    }

    private func haplotypeCallNeedsReview(_ call: GenotypeHaplotypeLocusCall) -> Bool {
        if call.status != .called && call.status != .specialCase {
            return true
        }
        if call.haplotype1.localizedCaseInsensitiveContains("ERR")
            || call.haplotype2.localizedCaseInsensitiveContains("ERR") {
            return true
        }
        return call.observedGenotypeCount > 2
    }

    private func haplotypeStatusLabel(_ status: GenotypeHaplotypeCallStatus) -> String {
        switch status {
        case .called:
            return "called"
        case .specialCase:
            return "special case"
        case .noHaplotype:
            return "no matching haplotype"
        case .tooManyHaplotypes:
            return "too many matching haplotypes"
        case .tooManyGenotypes:
            return "too many genotype labels"
        }
    }

    private func sampleSupportTable(_ supports: [ONTGenotypeSampleSupport]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(sampleSupportTableRow(
            sample: "Sample",
            uniqueReads: "Unique",
            alignments: "Alignments",
            isHeader: true
        ))
        for support in supports {
            stack.addArrangedSubview(sampleSupportTableRow(
                sample: support.sample,
                uniqueReads: integer(support.passedUniqueReads),
                alignments: integer(support.passedAlignments),
                isHeader: false
            ))
        }
        return stack
    }

    private func sampleSupportTableRow(
        sample: String,
        uniqueReads: String,
        alignments: String,
        isHeader: Bool
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10

        let sampleField = tableField(sample, width: 92, alignment: .left, isHeader: isHeader)
        let uniqueField = tableField(uniqueReads, width: 72, alignment: .right, isHeader: isHeader)
        let alignmentField = tableField(alignments, width: 76, alignment: .right, isHeader: isHeader)
        row.addArrangedSubview(sampleField)
        row.addArrangedSubview(uniqueField)
        row.addArrangedSubview(alignmentField)
        return row
    }

    private func coOccurrenceTable(_ coOccurrences: [ONTGenotypeCoOccurrence]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(coOccurrenceTableRow(
            genotype: "Genotype",
            probability: "P(Y|X)",
            shared: "Shared",
            isHeader: true
        ))
        for item in coOccurrences {
            stack.addArrangedSubview(coOccurrenceTableRow(
                genotype: compactGenotypeLabel(item.candidateGenotype),
                probability: percent(item.probabilityCandidateGivenSelected),
                shared: "\(item.sharedSampleCount)/\(item.selectedSampleCount)",
                isHeader: false
            ))
        }
        return stack
    }

    private func coOccurrenceTableRow(
        genotype: String,
        probability: String,
        shared: String,
        isHeader: Bool
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.addArrangedSubview(tableField(genotype, width: 220, alignment: .left, isHeader: isHeader))
        row.addArrangedSubview(tableField(probability, width: 60, alignment: .right, isHeader: isHeader))
        row.addArrangedSubview(tableField(shared, width: 58, alignment: .right, isHeader: isHeader))
        return row
    }

    private func tableField(
        _ text: String,
        width: CGFloat,
        alignment: NSTextAlignment,
        isHeader: Bool
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = isHeader
            ? .systemFont(ofSize: 11, weight: .medium)
            : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = isHeader ? .secondaryLabelColor : .labelColor
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.toolTip = text
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func detailRows(_ rows: [(String, String)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (label, value) in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let labelField = NSTextField(labelWithString: label)
            labelField.font = .systemFont(ofSize: 11)
            labelField.textColor = .secondaryLabelColor
            labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
            labelField.widthAnchor.constraint(equalToConstant: 92).isActive = true

            let valueField = NSTextField(labelWithString: value)
            valueField.font = .systemFont(ofSize: 11)
            valueField.lineBreakMode = .byTruncatingMiddle
            valueField.usesSingleLineMode = true
            valueField.toolTip = value
            valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)

            row.addArrangedSubview(labelField)
            row.addArrangedSubview(valueField)
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func artifactRow(label: String, url: URL) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 11, weight: .medium)
        labelField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let pathField = NSTextField(labelWithString: url.path)
        pathField.font = .systemFont(ofSize: 11)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.usesSingleLineMode = true
        pathField.toolTip = url.path
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusField = NSTextField(labelWithString: artifactStatus(url))
        statusField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusField.textColor = .secondaryLabelColor
        statusField.widthAnchor.constraint(equalToConstant: 82).isActive = true

        let button = GenotypeArtifactButton(title: "Reveal", target: self, action: #selector(openArtifact(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.artifactURL = url
        button.toolTip = url.path

        stack.addArrangedSubview(labelField)
        stack.addArrangedSubview(pathField)
        stack.addArrangedSubview(statusField)
        stack.addArrangedSubview(button)
        return stack
    }

    @objc private func openArtifact(_ sender: NSButton) {
        guard let url = (sender as? GenotypeArtifactButton)?.artifactURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func wrappingText(
        _ text: String,
        weight: NSFont.Weight = .regular,
        maximumLines: Int = 0
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: weight)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = maximumLines
        field.toolTip = text
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = wrappingText(text)
        field.textColor = .secondaryLabelColor
        return field
    }

    private var supportMetricLabel: String {
        switch displayState.supportDenominator {
        case .viewedLocus:
            return "Unique reads / viewed-locus unique reads"
        case .sampleRetained:
            return "Unique reads / sample retained unique reads"
        }
    }

    private func supportFractionLabel(genotype: String, sample: String) -> String {
        guard let result,
              let call = result.calls.first(where: { $0.sample == sample && $0.genotype == genotype }),
              let fraction = result.supportFraction(for: call, denominator: displayState.supportDenominator) else {
            return "Unavailable"
        }
        return percent(fraction)
    }

    private func sameLocusCoOccurrences(for sharedCall: ONTGenotypeSharedCall) -> [ONTGenotypeCoOccurrence] {
        result?.sameLocusCoOccurrences(
            for: sharedCall.genotype,
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        ) ?? []
    }

    private func anchorSummary(for sharedCall: ONTGenotypeSharedCall) -> ONTGenotypeAnchorSummary? {
        result?.anchorSummaries(
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        ).first { anchor in
            anchor.sharedCalls.contains { $0.genotype == sharedCall.genotype && $0.locus == sharedCall.locus }
        }
    }

    private func compactGenotypeLabel(_ genotype: String) -> String {
        guard genotype.count > 42 else { return genotype }
        let prefix = genotype.prefix(22)
        let suffix = genotype.suffix(14)
        return "\(prefix)...\(suffix)"
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func sharedCallMeaning(for sharedCall: ONTGenotypeSharedCall) -> String {
        "This row is one exact reference genotype label observed in \(sharedCall.sampleCount) assigned samples. Counts summarize retained unique-read support for this label, not phased haplotypes or allele absence."
    }

    private func artifactStatus(_ url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "Missing" }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return byteCount(size)
        }
        return "Present"
    }

    private func byteCount(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func integer(_ value: Int?) -> String {
        value.map { $0.formatted(.number) } ?? "Unavailable"
    }

    private func removeArrangedSubviews(from stack: NSStackView) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func previousHighlightColor(for request: GenotypeResultHighlightRequest) -> AnnotationColor? {
        guard request.scope != .clear else { return nil }
        return comparisonMatrix.highlightStyle(for: request.target).color(for: request.channel)
    }

    private func registerUndo(for request: GenotypeResultHighlightRequest, previousColor: AnnotationColor?) {
        guard request.scope != .clear,
              previousColor != request.color,
              let undoManager = view.window?.undoManager else {
            return
        }
        let inverse = GenotypeResultHighlightRequest(
            target: request.target,
            scope: request.scope,
            channel: request.channel,
            color: previousColor
        )
        undoManager.registerUndo(withTarget: self) { target in
            target.applyHighlight(inverse)
        }
        undoManager.setActionName(request.color == nil ? "Clear Genotype \(request.channel.displayName)" : "Change Genotype \(request.channel.displayName)")
    }
}

private final class GenotypeArtifactButton: NSButton {
    var artifactURL: URL?
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

extension GenotypeResultViewController: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        splitCoordinator.splitViewDidResizeSubviews(
            splitView,
            minimumExtents: minimumSplitExtents()
        )
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        splitCoordinator.resizeSubviewsWithOldSize(
            self.splitView,
            oldSize: oldSize,
            defaultLeadingFraction: defaultLeadingFraction(for: displayState.layout),
            defaultLeadingExtent: defaultLeadingExtent(for: displayState.layout),
            minimumExtents: minimumSplitExtents()
        )
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        minimumSplitExtents().leading
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return max(minimumSplitExtents().leading, extent - minimumSplitExtents().trailing)
    }
}

#if DEBUG
extension GenotypeResultViewController {
    func testingSelectFirstSharedCall() {
        comparisonMatrix.selectFirstSharedCall()
    }

    func testingSelectLens(_ lens: Lens) {
        showLens(lens)
    }

    func testingReviewHaplotypeSample(_ sample: String) {
        showAnalystCalls(forHaplotypeSample: sample)
    }

    var testingVisibleLensIdentifier: String {
        selectedLens.identifier
    }

    var testingAnchorLensText: String {
        textContent(in: anchorStack).joined(separator: "\n")
    }

    var testingHaplotypeLensText: String {
        textContent(in: haplotypeStack).joined(separator: "\n")
    }

    var testingSamplePaneWidth: CGFloat {
        sampleContainer.frame.width
    }

    var testingDetailPaneWidth: CGFloat {
        detailContainer.frame.width
    }

    var testingLocusFilterTitles: [String] {
        comparisonMatrix.testingLocusFilterTitles
    }

    func testingApplyDisplayState(_ state: GenotypeResultDisplayState) {
        applyDisplayState(state)
    }

    var testingSplitIsVertical: Bool {
        splitView.isVertical
    }

    var testingFirstPaneIsMatrix: Bool {
        splitView.arrangedSubviews.first === sampleContainer
    }

    var testingVisibleGenotypes: [String] {
        comparisonMatrix.testingVisibleGenotypes
    }

    func testingSelectFirstSampleCell(sample: String) {
        comparisonMatrix.testingSelectFirstSampleCell(sample: sample)
    }

    var testingHighlightedCellCount: Int {
        comparisonMatrix.testingHighlightedCellCount
    }

    var testingBorderedCellCount: Int {
        comparisonMatrix.testingBorderedCellCount
    }

    var testingCurrentSelectionStyle: GenotypeResultHighlightStyle {
        guard let target = currentSelectionState?.highlightTarget else { return .default }
        return comparisonMatrix.testingHighlightStyle(for: target)
    }

    func testingBackgroundColor(genotype: String, sample: String) -> NSColor? {
        comparisonMatrix.testingBackgroundColor(genotype: genotype, sample: sample)
    }

    var testingDetailContentTopInset: CGFloat {
        detailStack.frame.minY
    }

    func testingRenderVisibleCells(rowLimit: Int) {
        comparisonMatrix.testingRenderVisibleCells(rowLimit: rowLimit)
    }

    func testingSetComparisonFilter(_ text: String) {
        comparisonMatrix.testingSetFilter(text)
    }

    private func textContent(in view: NSView) -> [String] {
        var values: [String] = []
        if let field = view as? NSTextField {
            values.append(field.stringValue)
        }
        if let button = view as? NSButton {
            values.append(button.title)
        }
        for subview in view.subviews {
            values.append(contentsOf: textContent(in: subview))
        }
        return values
    }
}
#endif
