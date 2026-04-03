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

    /// Displays a reference genome bundle in the viewer with a chromosome navigator.
    ///
    /// - Parameter url: URL of the `.lungfishref` bundle directory
    /// - Throws: Error if the manifest cannot be loaded or the bundle is invalid
    public func displayBundle(at url: URL) throws {
        // Save current bundle's view state before switching (flushes color overrides, nav state, etc.)
        saveCurrentViewState()
        contentMode = .genomics

        bundleLogger.info("displayBundle: Opening bundle at '\(url.lastPathComponent, privacy: .public)'")

        // Load and validate manifest
        let manifest = try BundleManifest.load(from: url)
        let validationErrors = manifest.validate()
        if !validationErrors.isEmpty {
            let messages = validationErrors.map { $0.localizedDescription }.joined(separator: "; ")
            bundleLogger.error("displayBundle: Manifest validation failed: \(messages, privacy: .public)")
            throw DocumentLoadError.parseError("Bundle validation failed: \(messages)")
        }

        // Create data provider
        let provider = BundleDataProvider(bundleURL: url, manifest: manifest)
        currentBundleDataProvider = provider
        currentBundleURL = url

        // Load persisted view state. If missing, seed from app-level defaults.
        let viewStateURL = url.appendingPathComponent(BundleViewState.filename)
        let hasPersistedViewState = FileManager.default.fileExists(atPath: viewStateURL.path)
        let viewState = hasPersistedViewState
            ? BundleViewState.load(from: url)
            : Self.defaultBundleViewStateFromAppSettings()
        currentBundleViewState = viewState
        bundleLogger.info("displayBundle: Loaded view state (overrides=\(viewState.typeColorOverrides.count), chrom=\(viewState.lastChromosome ?? "none", privacy: .public))")

        // Apply persisted annotation display settings
        showAnnotations = viewState.showAnnotations
        annotationDisplayHeight = CGFloat(viewState.annotationHeight)
        annotationDisplaySpacing = CGFloat(viewState.annotationSpacing)
        visibleAnnotationTypes = viewState.visibleAnnotationTypes
        isRNAMode = viewState.isRNAMode

        // Create reference bundle with pre-loaded manifest (synchronous)
        let bundle = ReferenceBundle(url: url, manifest: manifest)

        // Hide any non-bundle views and ensure genomics viewer is visible
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()

        // Get chromosome list: from genome if available, otherwise synthesize from variant databases
        var chromosomes = manifest.genome?.chromosomes ?? []
        if chromosomes.isEmpty && !manifest.variants.isEmpty {
            chromosomes = Self.synthesizeChromosomesFromVariants(bundle: bundle)
            bundleLogger.info("displayBundle: Synthesized \(chromosomes.count) chromosomes from variant data")
        }

        // Set up chromosome navigator (only when multiple chromosomes)
        if chromosomes.count > 1 {
            configureChromosomeNavigator(with: chromosomes)
        } else {
            removeChromosomeNavigator()
        }

        // Force layout for valid bounds
        view.layoutSubtreeIfNeeded()
        let effectiveWidth = max(800, Int(viewerView.bounds.width))

        // Show loading indicator and flush layout before synchronous bundle setup.
        showProgress("Loading genome\u{2026}")
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        // Set up the viewer with bundle and apply view state
        viewerView.setReferenceBundle(bundle)
        viewerView.showAnnotations = viewState.showAnnotations
        viewerView.annotationHeight = CGFloat(viewState.annotationHeight)
        viewerView.annotationRowSpacing = CGFloat(viewState.annotationSpacing)
        viewerView.visibleAnnotationTypes = viewState.visibleAnnotationTypes
        viewerView.translationColorScheme = viewState.translationColorScheme
        viewerView.showVariants = viewState.showVariants
        if let variantTypes = viewState.visibleVariantTypes {
            viewerView.visibleVariantTypes = variantTypes
        }

        // Apply per-type color overrides
        if !viewState.typeColorOverrides.isEmpty {
            viewerView.applyTypeColorOverrides(viewState.typeColorOverrides)
        }

        // Navigate to saved chromosome/position or first chromosome
        let sortedChroms = naturalChromosomeSort(chromosomes)
        guard let firstChrom = sortedChroms.first else {
            bundleLogger.error("displayBundle: No chromosomes in bundle")
            hideProgress()
            showNoSequenceSelected()
            return
        }

        let targetChrom: ChromosomeInfo
        if let savedChrom = viewState.lastChromosome,
           let found = sortedChroms.first(where: { $0.name == savedChrom }) {
            targetChrom = found
        } else {
            targetChrom = firstChrom
        }

        let chromLength = Int(targetChrom.length)
        bundleLogger.info("displayBundle: Navigating to chromosome '\(targetChrom.name, privacy: .public)' length=\(chromLength)")

        // Restore zoom/scroll if saved, otherwise show full chromosome
        let startPos: Double
        let endPos: Double
        if let savedOrigin = viewState.lastOrigin, let savedScale = viewState.lastScale,
           viewState.lastChromosome == targetChrom.name {
            startPos = max(0, savedOrigin)
            let span = savedScale * Double(effectiveWidth)
            endPos = min(Double(chromLength), startPos + span)
        } else {
            startPos = 0
            endPos = Double(chromLength)
        }

        referenceFrame = ReferenceFrame(
            chromosome: targetChrom.name,
            start: startPos,
            end: endPos,
            pixelWidth: effectiveWidth,
            sequenceLength: chromLength
        )

        // Select the correct chromosome in the navigator
        chromosomeNavigatorView?.selectChromosome(named: targetChrom.name)

        // Update header with track names
        let trackNames = [targetChrom.name]
            + manifest.annotations.map { "Annotations: \($0.name)" }
            + manifest.alignments.map { "Reads: \($0.name)" }
        headerView.setTrackNames(trackNames)

        // Update ruler
        enhancedRulerView.referenceFrame = referenceFrame

        // Update status bar
        updateStatusBar()

        // Trigger redraw
        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        headerView.needsDisplay = true

        // Schedule delayed redraw for layout timing
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

        // Hide loading indicator
        hideProgress()

        // Notify that bundle has been loaded (for annotation search index building, toolbar updates, inspector)
        NotificationCenter.default.post(
            name: .bundleDidLoad,
            object: self,
            userInfo: [
                NotificationUserInfoKey.bundleURL: url,
                NotificationUserInfoKey.chromosomes: chromosomes,
                NotificationUserInfoKey.manifest: manifest,
                NotificationUserInfoKey.referenceBundle: bundle,
            ]
        )

        // Open the bottom drawer by default for bundles with annotation/variant/sample data.
        openAnnotationDrawerIfBundleHasData(manifest: manifest)

        // Sync inspector to restored view state
        let savedState = viewState
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
                    if let vtypes = savedState.visibleVariantTypes {
                        annotVM.visibleVariantTypes = vtypes
                    }
                }
            }
        }

        bundleLogger.info("displayBundle: Bundle displayed successfully with \(chromosomes.count) chromosomes")
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

    /// Configures the chromosome navigator drawer on the left side of the viewer.
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
        currentBundleDataProvider = nil
        currentBundleViewState = nil
        currentBundleURL = nil
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
