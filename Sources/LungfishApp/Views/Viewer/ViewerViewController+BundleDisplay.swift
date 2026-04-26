// ViewerViewController+BundleDisplay.swift - Reference bundle display for ViewerViewController
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds reference genome bundle display capabilities to ViewerViewController,
// including chromosome navigation, on-demand data fetching, and bundle-specific layout.

import AppKit
import LungfishCore
import LungfishIO
import os.log

/// Logger for bundle display operations
private let bundleLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerBundleDisplay")

/// Width of the chromosome navigator drawer.
private let navigatorWidth: CGFloat = 240

// MARK: - ViewerViewController Bundle Display Extension

extension ViewerViewController: ChromosomeNavigatorDelegate {

    // MARK: - Bundle Display

    private struct BundleDisplayContext {
        let url: URL
        let manifest: BundleManifest
        let bundle: ReferenceBundle
        let provider: BundleDataProvider
        let viewState: BundleViewState
        let chromosomes: [ChromosomeInfo]
    }

    /// Displays a reference genome bundle using the harmonized reference viewport.
    ///
    /// - Parameter url: URL of the `.lungfishref` bundle directory
    /// - Throws: Error if the manifest cannot be loaded or the bundle is invalid
    public func displayBundle(at url: URL) throws {
        try displayBundle(at: url, mode: .browse)
    }

    /// Displays a reference genome bundle using the harmonized viewport or direct sequence mode.
    public func displayBundle(at url: URL, mode: BundleDisplayMode) throws {
        saveCurrentViewState()
        let context = try loadBundleDisplayContext(at: url)

        switch mode {
        case .browse:
            try displayReferenceBundleViewport(.directBundle(bundleURL: context.url, manifest: context.manifest))
            (parent as? MainSplitViewController)?.wireDirectReferenceViewportInspectorUpdates()
        case .sequence(let name, let restoreViewState):
            activateBundleDisplayContext(context)
            try displayBundleSequence(
                preferredSequenceName: name,
                context: context,
                installChromosomeNavigator: false,
                restoreViewState: restoreViewState
            )
        }
    }

    private func loadBundleDisplayContext(at url: URL) throws -> BundleDisplayContext {
        bundleLogger.info("displayBundle: Opening bundle at '\(url.lastPathComponent, privacy: .public)'")

        let manifest = try BundleManifest.load(from: url)
        let validationErrors = manifest.validate()
        if !validationErrors.isEmpty {
            let messages = validationErrors.map(\.localizedDescription).joined(separator: "; ")
            bundleLogger.error("displayBundle: Manifest validation failed: \(messages, privacy: .public)")
            throw DocumentLoadError.parseError("Bundle validation failed: \(messages)")
        }

        let provider = BundleDataProvider(bundleURL: url, manifest: manifest)

        let viewStateURL = url.appendingPathComponent(BundleViewState.filename)
        let viewState = FileManager.default.fileExists(atPath: viewStateURL.path)
            ? BundleViewState.load(from: url)
            : Self.defaultBundleViewStateFromAppSettings()
        bundleLogger.info(
            "displayBundle: Loaded view state (overrides=\(viewState.typeColorOverrides.count), chrom=\(viewState.lastChromosome ?? "none", privacy: .public))"
        )

        let bundle = ReferenceBundle(url: url, manifest: manifest)
        let chromosomes = resolvedChromosomes(for: manifest, bundle: bundle)

        return BundleDisplayContext(
            url: url,
            manifest: manifest,
            bundle: bundle,
            provider: provider,
            viewState: viewState,
            chromosomes: chromosomes
        )
    }

    private func activateBundleDisplayContext(_ context: BundleDisplayContext) {
        contentMode = .genomics
        currentBundleDataProvider = context.provider
        currentBundleURL = context.url
        currentBundleViewState = context.viewState
        applyBundleHorizontalScrollDirectionPreference()
        showAnnotations = context.viewState.showAnnotations
        annotationDisplayHeight = CGFloat(context.viewState.annotationHeight)
        annotationDisplaySpacing = CGFloat(context.viewState.annotationSpacing)
        visibleAnnotationTypes = context.viewState.visibleAnnotationTypes
        isRNAMode = context.viewState.isRNAMode
    }

    private func resolvedChromosomes(for manifest: BundleManifest, bundle: ReferenceBundle) -> [ChromosomeInfo] {
        var chromosomes = manifest.genome?.chromosomes ?? []
        if chromosomes.isEmpty && !manifest.variants.isEmpty {
            chromosomes = Self.synthesizeChromosomesFromVariants(bundle: bundle)
            bundleLogger.info("displayBundle: Synthesized \(chromosomes.count) chromosomes from variant data")
        }
        return chromosomes
    }

    private func hideNonBundleViews() {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideAssemblyView()
        hideMappingView()
    }

    private func displayBundleSequence(
        preferredSequenceName: String?,
        context: BundleDisplayContext,
        installChromosomeNavigator: Bool,
        restoreViewState: Bool
    ) throws {
        hideNonBundleViews()
        hideCollectionBackButton()
        annotationDrawerView?.isHidden = false
        fastqMetadataDrawerView?.isHidden = false

        if installChromosomeNavigator, context.chromosomes.count > 1 {
            configureChromosomeNavigator(with: context.chromosomes)
        } else {
            removeChromosomeNavigator()
        }

        view.layoutSubtreeIfNeeded()
        let effectiveWidth = max(800, Int(viewerView.bounds.width))

        showProgress("Loading genome\u{2026}")
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        viewerView.setReferenceBundle(context.bundle)
        viewerView.showAnnotations = context.viewState.showAnnotations
        viewerView.annotationHeight = CGFloat(context.viewState.annotationHeight)
        viewerView.annotationRowSpacing = CGFloat(context.viewState.annotationSpacing)
        viewerView.visibleAnnotationTypes = context.viewState.visibleAnnotationTypes
        viewerView.translationColorScheme = context.viewState.translationColorScheme
        viewerView.showVariants = context.viewState.showVariants
        if let variantTypes = context.viewState.visibleVariantTypes {
            viewerView.visibleVariantTypes = variantTypes
        }
        if !context.viewState.typeColorOverrides.isEmpty {
            viewerView.applyTypeColorOverrides(context.viewState.typeColorOverrides)
        }

        let sortedChromosomes = naturalChromosomeSort(context.chromosomes)
        guard let firstChromosome = sortedChromosomes.first else {
            bundleLogger.error("displayBundle: No chromosomes in bundle")
            hideProgress()
            showNoSequenceSelected()
            return
        }

        let targetChromosome: ChromosomeInfo
        if let preferredSequenceName,
           let matchingChromosome = sortedChromosomes.first(where: { $0.name == preferredSequenceName }) {
            targetChromosome = matchingChromosome
        } else if restoreViewState,
                  let savedChromosome = context.viewState.lastChromosome,
                  let matchingChromosome = sortedChromosomes.first(where: { $0.name == savedChromosome }) {
            targetChromosome = matchingChromosome
        } else {
            targetChromosome = firstChromosome
        }

        let chromosomeLength = Int(targetChromosome.length)
        bundleLogger.info(
            "displayBundle: Navigating to chromosome '\(targetChromosome.name, privacy: .public)' length=\(chromosomeLength)"
        )

        let startPosition: Double
        let endPosition: Double
        if restoreViewState,
           let savedOrigin = context.viewState.lastOrigin,
           let savedScale = context.viewState.lastScale,
           context.viewState.lastChromosome == targetChromosome.name {
            startPosition = max(0, savedOrigin)
            let span = savedScale * Double(effectiveWidth)
            endPosition = min(Double(max(1, chromosomeLength)), startPosition + span)
        } else {
            startPosition = 0
            endPosition = Double(max(1, chromosomeLength))
        }

        referenceFrame = ReferenceFrame(
            chromosome: targetChromosome.name,
            start: startPosition,
            end: endPosition,
            pixelWidth: effectiveWidth,
            sequenceLength: chromosomeLength
        )

        chromosomeNavigatorView?.selectChromosome(named: targetChromosome.name)

        let trackNames = [targetChromosome.name]
            + context.manifest.annotations.map { "Annotations: \($0.name)" }
            + context.manifest.alignments.map { "Reads: \($0.name)" }
        headerView.setTrackNames(trackNames)

        enhancedRulerView.referenceFrame = referenceFrame
        updateStatusBar()

        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        headerView.isHidden = false
        statusBar.isHidden = false
        geneTabBarView.isHidden = true

        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        headerView.needsDisplay = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }

                if let frame = self.referenceFrame, self.viewerView.bounds.width > 0 {
                    frame.pixelWidth = Int(self.viewerView.bounds.width)
                }

                self.viewerView.needsDisplay = true
                self.enhancedRulerView.needsDisplay = true
                self.headerView.needsDisplay = true
            }
        }

        hideProgress()

        publishBundleDidLoadNotification(
            userInfo: [
                NotificationUserInfoKey.bundleURL: context.url,
                NotificationUserInfoKey.chromosomes: context.chromosomes,
                NotificationUserInfoKey.manifest: context.manifest,
                NotificationUserInfoKey.referenceBundle: context.bundle,
            ]
        )

        openAnnotationDrawerIfBundleHasData(manifest: context.manifest)
        syncInspectorForBundleViewState(context.viewState)

        bundleLogger.info(
            "displayBundle: Bundle displayed successfully with \(context.chromosomes.count) chromosomes"
        )
    }

    private func syncInspectorForBundleViewState(_ savedState: BundleViewState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if let splitVC = self.parent as? MainSplitViewController {
                    let annotVM = splitVC.inspectorController.annotationSectionViewModel
                    annotVM.showAnnotations = savedState.showAnnotations
                    annotVM.annotationHeight = savedState.annotationHeight
                    annotVM.annotationSpacing = savedState.annotationSpacing
                    if let types = savedState.visibleAnnotationTypes {
                        annotVM.visibleTypes = types
                    } else {
                        annotVM.visibleTypes = Set(AnnotationType.allCases)
                    }
                    annotVM.showVariants = savedState.showVariants
                    if let variantTypes = savedState.visibleVariantTypes {
                        annotVM.visibleVariantTypes = variantTypes
                    }
                }
            }
        }
    }

    // MARK: - Variant-Only Chromosome Synthesis

    /// Synthesizes chromosome info from variant database max positions.
    /// Used for variant-only bundles that have no genome info.
    static func synthesizeChromosomesFromVariants(bundle: ReferenceBundle) -> [ChromosomeInfo] {
        var chromosomes: [ChromosomeInfo] = []

        for trackInfo in bundle.manifest.variants {
            guard let dbPath = trackInfo.databasePath else { continue }
            let dbURL = bundle.url.appendingPathComponent(dbPath)
            guard FileManager.default.fileExists(atPath: dbURL.path),
                  let db = try? VariantDatabase(url: dbURL) else { continue }

            let maxPositions = db.chromosomeMaxPositions()

            for (name, maxPos) in maxPositions {
                // Use max position + 10% padding as estimated length
                let estimatedLength = Int64(Double(maxPos) * 1.1)
                if !chromosomes.contains(where: { $0.name == name }) {
                    chromosomes.append(ChromosomeInfo(
                        name: name,
                        length: max(estimatedLength, 1000),
                        offset: 0,
                        lineBases: 80,
                        lineWidth: 81
                    ))
                }
            }
        }

        return chromosomes
    }

    // MARK: - Chromosome Navigator

    /// Configures the legacy chromosome navigator drawer for sequence-detail mode.
    private func configureChromosomeNavigator(with chromosomes: [ChromosomeInfo]) {
        if let existing = chromosomeNavigatorView {
            existing.chromosomes = chromosomes
            existing.selectedChromosomeIndex = 0
            existing.isHidden = false
            // Ensure drawer is open
            if !isChromosomeDrawerOpen {
                toggleChromosomeDrawer()
            }
            bundleLogger.debug("configureChromosomeNavigator: Updated existing navigator with \(chromosomes.count) chromosomes")
            return
        }

        // Create new navigator
        let navigator = ChromosomeNavigatorView()
        navigator.translatesAutoresizingMaskIntoConstraints = false
        navigator.delegate = self
        navigator.chromosomes = chromosomes
        navigator.selectedChromosomeIndex = 0

        view.addSubview(navigator)

        let constraints = [
            navigator.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navigator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigator.widthAnchor.constraint(equalToConstant: navigatorWidth),
            // Pin to viewer bottom so navigator automatically stops at drawer top
            // when the annotation drawer is open (viewer bottom is re-targeted).
            navigator.bottomAnchor.constraint(equalTo: viewerView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        chromosomeNavigatorConstraints = constraints

        // Push content to the right
        for constraint in contentLeadingConstraints {
            constraint.constant = navigatorWidth
        }

        view.layoutSubtreeIfNeeded()
        isChromosomeDrawerOpen = true
        chromosomeNavigatorView = navigator

        bundleLogger.info("configureChromosomeNavigator: Created navigator with \(chromosomes.count) chromosomes")
    }

    // MARK: - Drawer Toggle

    /// Toggles the chromosome drawer open/closed with animation.
    public func toggleChromosomeDrawer() {
        guard chromosomeNavigatorView != nil else { return }

        let isOpen = isChromosomeDrawerOpen
        let contentTarget: CGFloat = isOpen ? 0 : navigatorWidth

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            for constraint in self.contentLeadingConstraints {
                constraint.animator().constant = contentTarget
            }
            self.chromosomeNavigatorView?.animator().isHidden = isOpen
            self.view.layoutSubtreeIfNeeded()
        }

        isChromosomeDrawerOpen = !isOpen
        bundleLogger.info("toggleChromosomeDrawer: Drawer now \(self.isChromosomeDrawerOpen ? "open" : "closed")")
    }

    // MARK: - Hide / Remove

    /// Hides the chromosome navigator panel, restoring the default viewer layout.
    public func hideChromosomeNavigator() {
        guard chromosomeNavigatorView != nil else { return }
        if isChromosomeDrawerOpen {
            toggleChromosomeDrawer()
        }
    }

    /// Removes the chromosome navigator from the view hierarchy entirely.
    public func removeChromosomeNavigator() {
        guard let navigator = chromosomeNavigatorView else { return }

        if let constraints = chromosomeNavigatorConstraints {
            NSLayoutConstraint.deactivate(constraints)
        }
        chromosomeNavigatorConstraints = nil

        navigator.removeFromSuperview()
        chromosomeNavigatorView = nil

        // Reset content leading constraints
        for constraint in contentLeadingConstraints {
            constraint.constant = 0
        }

        isChromosomeDrawerOpen = false

        view.layoutSubtreeIfNeeded()
        bundleLogger.info("removeChromosomeNavigator: Navigator removed from view hierarchy")
    }

    // MARK: - ChromosomeNavigatorDelegate

    public func chromosomeNavigator(_ navigator: ChromosomeNavigatorView, didSelectChromosome chromosome: ChromosomeInfo) {
        bundleLogger.info("chromosomeNavigator: Navigating to '\(chromosome.name, privacy: .public)' length=\(chromosome.length)")

        // Clear sequence fetch error for the new chromosome
        viewerView.clearSequenceFetchError()
        // Translation overlays are coordinate/chromosome-specific.
        viewerView.hideTranslation()

        let chromLength = Int(chromosome.length)
        let effectiveWidth = max(800, Int(viewerView.bounds.width))

        referenceFrame = ReferenceFrame(
            chromosome: chromosome.name,
            start: 0,
            end: Double(chromLength),
            pixelWidth: effectiveWidth,
            sequenceLength: chromLength
        )

        if let provider = currentBundleDataProvider {
            let trackNames = [chromosome.name] + provider.annotationTrackIds.map { "Annotations: \($0)" }
            headerView.setTrackNames(trackNames)
        } else {
            headerView.setTrackNames([chromosome.name])
        }

        enhancedRulerView.referenceFrame = referenceFrame
        updateStatusBar()

        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        headerView.needsDisplay = true

        // Update Inspector with the newly selected chromosome (without switching tabs)
        NotificationCenter.default.post(
            name: .chromosomeInspectorRequested,
            object: self,
            userInfo: [NotificationUserInfoKey.chromosome: chromosome]
        )

        // Persist navigation state
        scheduleViewStateSave()

        bundleLogger.info("chromosomeNavigator: Navigation to '\(chromosome.name, privacy: .public)' complete")
    }

    // MARK: - Cross-Chromosome Navigation

    /// Navigates to a specific position on a specific chromosome.
    ///
    /// Creates a new reference frame for the target chromosome and zooms to the
    /// specified region. Also updates the chromosome navigator selection.
    ///
    /// - Parameters:
    ///   - chromosome: Target chromosome name
    ///   - chromosomeLength: Length of the target chromosome in base pairs
    ///   - start: Start position (0-based)
    ///   - end: End position (0-based, exclusive)
    public func navigateToChromosomeAndPosition(chromosome: String, chromosomeLength: Int, start: Int, end: Int) {
        bundleLogger.info("navigateToChromosomeAndPosition: \(chromosome, privacy: .public):\(start)-\(end) (chromLen=\(chromosomeLength))")

        // Clear sequence fetch error for the new position
        viewerView.clearSequenceFetchError()

        // Only hide translation when navigating to a different chromosome.
        // Within same chromosome, CDS and frame translations persist at their genomic coordinates.
        if let currentChrom = referenceFrame?.chromosome, currentChrom != chromosome {
            viewerView.hideTranslation()
        }

        let effectiveWidth = max(800, Int(viewerView.bounds.width))
        var clampedStart = max(0, start)
        var clampedEnd = min(chromosomeLength, end)
        let span = max(1, clampedEnd - clampedStart)
        let leadingInsetPx = Double(viewerView.navigationLeadingInsetPixels)
        if leadingInsetPx > 0 {
            let shiftBP = Int((Double(span) * leadingInsetPx / Double(effectiveWidth)).rounded())
            if shiftBP > 0 {
                clampedStart = max(0, clampedStart - shiftBP)
                clampedEnd = min(chromosomeLength, clampedStart + span)
                if clampedEnd - clampedStart < span {
                    clampedStart = max(0, clampedEnd - span)
                }
            }
        }
        let scale = Double(span) / Double(effectiveWidth)

        bundleLogger.info("navigateToChromosomeAndPosition: Creating frame span=\(span) bp, pixelWidth=\(effectiveWidth), scale=\(scale, format: .fixed(precision: 2)) bp/px")

        referenceFrame = ReferenceFrame(
            chromosome: chromosome,
            start: Double(clampedStart),
            end: Double(clampedEnd),
            pixelWidth: effectiveWidth,
            sequenceLength: chromosomeLength
        )

        // Update chromosome navigator selection
        chromosomeNavigatorView?.selectChromosome(named: chromosome)

        // Update header
        if let provider = currentBundleDataProvider {
            let trackNames = [chromosome] + provider.annotationTrackIds.map { "Annotations: \($0)" }
            headerView.setTrackNames(trackNames)
        } else {
            headerView.setTrackNames([chromosome])
        }

        enhancedRulerView.referenceFrame = referenceFrame
        updateStatusBar()

        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        headerView.needsDisplay = true

        bundleLogger.info("navigateToChromosomeAndPosition: Complete, display invalidated")
    }

    // MARK: - Bundle State Management

    /// Clears all bundle display state, removing the navigator and data provider.
    ///
    /// Saves the current view state to the bundle before clearing so that
    /// settings persist when the user navigates away.
    public func clearBundleDisplay() {
        // Save view state before clearing
        saveCurrentViewState()

        bundleLogger.info("clearBundleDisplay: Clearing bundle state")
        hideBundleBackNavigationButton()
        currentBundleDataProvider = nil
        currentBundleViewState = nil
        currentBundleURL = nil
        viewerView.horizontalScrollDirectionOverride = nil
        viewerView.clearReferenceBundle()
        removeChromosomeNavigator()
    }

    private static func defaultBundleViewStateFromAppSettings() -> BundleViewState {
        let settings = AppSettings.shared
        return BundleViewState(
            typeColorOverrides: [:],
            annotationColorOverrides: [:],
            annotationHeight: settings.defaultAnnotationHeight,
            annotationSpacing: settings.defaultAnnotationSpacing,
            showAnnotations: true,
            visibleAnnotationTypes: nil,
            showVariants: true,
            visibleVariantTypes: nil,
            translationColorScheme: .zappo,
            isRNAMode: false,
            lastChromosome: nil,
            lastOrigin: nil,
            lastScale: nil
        )
    }
}

extension ViewerViewController {
    func publishBundleDidLoadNotification(userInfo: [AnyHashable: Any]) {
        guard publishesGlobalViewportNotifications else { return }
        NotificationCenter.default.post(
            name: .bundleDidLoad,
            object: self,
            userInfo: userInfo
        )
    }
}

// MARK: - ViewerViewController View State Persistence

extension ViewerViewController {

    // MARK: - View State Persistence

    /// Schedules a debounced save of the current view state to the bundle directory.
    ///
    /// Cancels any pending save and schedules a new one 500ms in the future.
    /// This prevents writes on every slider tick while still saving promptly after changes stop.
    public func scheduleViewStateSave() {
        viewStateSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.saveCurrentViewState()
            }
        }
        viewStateSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Captures the current in-memory view state and writes it to the bundle.
    public func saveCurrentViewState() {
        guard let bundleURL = currentBundleURL else { return }

        var state = currentBundleViewState ?? .default

        state.annotationHeight = Double(annotationDisplayHeight)
        state.annotationSpacing = Double(annotationDisplaySpacing)
        state.showAnnotations = showAnnotations
        state.visibleAnnotationTypes = visibleAnnotationTypes
        state.isRNAMode = isRNAMode
        state.translationColorScheme = viewerView.translationColorScheme
        state.showVariants = viewerView.showVariants
        state.visibleVariantTypes = viewerView.visibleVariantTypes

        // Navigation state
        if let frame = referenceFrame {
            state.lastChromosome = frame.chromosome
            state.lastOrigin = frame.start
            state.lastScale = frame.scale
        }

        currentBundleViewState = state
        state.save(to: bundleURL)
    }
}
