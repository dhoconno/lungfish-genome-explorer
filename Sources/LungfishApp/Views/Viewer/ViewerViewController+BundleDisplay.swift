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
private let bundleLogger = Logger(subsystem: "com.lungfish.browser", category: "ViewerBundleDisplay")

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

        // Create reference bundle with pre-loaded manifest (synchronous)
        let bundle = ReferenceBundle(url: url, manifest: manifest)

        // Hide any QuickLook preview and ensure genomics viewer is visible
        hideQuickLookPreview()

        // Set up chromosome navigator
        configureChromosomeNavigator(with: manifest.genome.chromosomes)

        // Force layout for valid bounds
        view.layoutSubtreeIfNeeded()
        let effectiveWidth = max(800, Int(viewerView.bounds.width))

        // Set up the viewer with bundle
        viewerView.setReferenceBundle(bundle)

        // Navigate to the first chromosome (in natural sort order)
        let sortedChroms = naturalChromosomeSort(manifest.genome.chromosomes)
        guard let firstChrom = sortedChroms.first else {
            bundleLogger.error("displayBundle: No chromosomes in bundle")
            showNoSequenceSelected()
            return
        }

        let chromLength = Int(firstChrom.length)
        bundleLogger.info("displayBundle: Navigating to first chromosome '\(firstChrom.name, privacy: .public)' length=\(chromLength)")

        // Create reference frame showing the full chromosome
        referenceFrame = ReferenceFrame(
            chromosome: firstChrom.name,
            start: 0,
            end: Double(chromLength),
            pixelWidth: effectiveWidth,
            sequenceLength: chromLength
        )

        // Update header with track names
        let trackNames = [firstChrom.name] + manifest.annotations.map { "Annotations: \($0.name)" }
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
            guard let self else { return }

            if let frame = self.referenceFrame, self.viewerView.bounds.width > 0 {
                frame.pixelWidth = Int(self.viewerView.bounds.width)
            }

            self.viewerView.needsDisplay = true
            self.enhancedRulerView.needsDisplay = true
            self.headerView.needsDisplay = true
        }

        // Notify that bundle has been loaded (for annotation search index building, toolbar updates)
        NotificationCenter.default.post(
            name: .bundleDidLoad,
            object: self,
            userInfo: [
                NotificationUserInfoKey.bundleURL: url,
                NotificationUserInfoKey.chromosomes: manifest.genome.chromosomes,
            ]
        )

        bundleLogger.info("displayBundle: Bundle displayed successfully with \(manifest.genome.chromosomes.count) chromosomes")
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

        // Create the leading constraint (start open)
        let leadingConstraint = navigator.leadingAnchor.constraint(equalTo: view.leadingAnchor)

        let constraints = [
            navigator.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            leadingConstraint,
            navigator.widthAnchor.constraint(equalToConstant: navigatorWidth),
            navigator.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        chromosomeNavigatorConstraints = constraints
        chromosomeDrawerLeadingConstraint = leadingConstraint

        // Store the header leading constraint for animation
        findAndStoreHeaderLeadingConstraint()

        // Adjust existing views: push headerView to the right
        headerLeadingConstraint?.constant = navigatorWidth

        view.layoutSubtreeIfNeeded()
        isChromosomeDrawerOpen = true
        chromosomeNavigatorView = navigator

        bundleLogger.info("configureChromosomeNavigator: Created navigator with \(chromosomes.count) chromosomes")
    }

    /// Finds and caches the header view's leading constraint for drawer animation.
    private func findAndStoreHeaderLeadingConstraint() {
        if headerLeadingConstraint != nil { return }

        for constraint in view.constraints {
            if constraint.firstItem === headerView,
               constraint.firstAttribute == .leading,
               constraint.secondItem === view,
               constraint.secondAttribute == .leading {
                headerLeadingConstraint = constraint
                return
            }
        }
    }

    // MARK: - Drawer Toggle

    /// Toggles the chromosome drawer open/closed with animation.
    public func toggleChromosomeDrawer() {
        guard let leadingConstraint = chromosomeDrawerLeadingConstraint else { return }
        findAndStoreHeaderLeadingConstraint()

        let isOpen = isChromosomeDrawerOpen
        let drawerTarget: CGFloat = isOpen ? -navigatorWidth : 0
        let headerTarget: CGFloat = isOpen ? 0 : navigatorWidth

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            leadingConstraint.animator().constant = drawerTarget
            self.headerLeadingConstraint?.animator().constant = headerTarget
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
        chromosomeDrawerLeadingConstraint = nil

        navigator.removeFromSuperview()
        chromosomeNavigatorView = nil

        headerLeadingConstraint?.constant = 0
        isChromosomeDrawerOpen = false

        view.layoutSubtreeIfNeeded()
        bundleLogger.info("removeChromosomeNavigator: Navigator removed from view hierarchy")
    }

    // MARK: - ChromosomeNavigatorDelegate

    public func chromosomeNavigator(_ navigator: ChromosomeNavigatorView, didSelectChromosome chromosome: ChromosomeInfo) {
        bundleLogger.info("chromosomeNavigator: Navigating to '\(chromosome.name, privacy: .public)' length=\(chromosome.length)")

        // Clear sequence fetch error for the new chromosome
        viewerView.clearSequenceFetchError()

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

        let effectiveWidth = max(800, Int(viewerView.bounds.width))
        let clampedStart = max(0, start)
        let clampedEnd = min(chromosomeLength, end)
        let span = clampedEnd - clampedStart
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
    public func clearBundleDisplay() {
        bundleLogger.info("clearBundleDisplay: Clearing bundle state")
        currentBundleDataProvider = nil
        removeChromosomeNavigator()
    }
}

// MARK: - ViewerViewController Stored Properties for Bundle Display

extension ViewerViewController {

    private static var chromosomeNavigatorKey: UInt8 = 0
    private static var chromosomeNavigatorConstraintsKey: UInt8 = 0
    private static var bundleDataProviderKey: UInt8 = 0
    private static var drawerLeadingConstraintKey: UInt8 = 0
    private static var headerLeadingConstraintKey: UInt8 = 0
    private static var drawerOpenKey: UInt8 = 0

    var chromosomeNavigatorView: ChromosomeNavigatorView? {
        get { objc_getAssociatedObject(self, &Self.chromosomeNavigatorKey) as? ChromosomeNavigatorView }
        set { objc_setAssociatedObject(self, &Self.chromosomeNavigatorKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var chromosomeNavigatorConstraints: [NSLayoutConstraint]? {
        get { objc_getAssociatedObject(self, &Self.chromosomeNavigatorConstraintsKey) as? [NSLayoutConstraint] }
        set { objc_setAssociatedObject(self, &Self.chromosomeNavigatorConstraintsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    public var currentBundleDataProvider: BundleDataProvider? {
        get { objc_getAssociatedObject(self, &Self.bundleDataProviderKey) as? BundleDataProvider }
        set { objc_setAssociatedObject(self, &Self.bundleDataProviderKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var chromosomeDrawerLeadingConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &Self.drawerLeadingConstraintKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &Self.drawerLeadingConstraintKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var headerLeadingConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &Self.headerLeadingConstraintKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &Self.headerLeadingConstraintKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var isChromosomeDrawerOpen: Bool {
        get { (objc_getAssociatedObject(self, &Self.drawerOpenKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &Self.drawerOpenKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
