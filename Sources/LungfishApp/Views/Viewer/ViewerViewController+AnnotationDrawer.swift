// ViewerViewController+AnnotationDrawer.swift - Annotation drawer integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

/// Logger for annotation drawer operations
private let annotDrawerLogger = Logger(subsystem: "com.lungfish.browser", category: "ViewerAnnotationDrawer")

/// Height of the annotation drawer when open.
private let annotationDrawerHeight: CGFloat = 250

// MARK: - ViewerViewController Annotation Drawer Extension

extension ViewerViewController: AnnotationTableDrawerDelegate {

    // MARK: - Public API

    /// Toggles the annotation drawer open/closed with animation.
    public func toggleAnnotationDrawer() {
        if annotationDrawerView == nil {
            configureAnnotationDrawer()
        }

        guard let bottomConstraint = annotationDrawerBottomConstraint else { return }

        let isOpen = isAnnotationDrawerOpen
        let currentHeight = annotationDrawerHeightConstraint?.constant ?? annotationDrawerHeight
        let target: CGFloat = isOpen ? currentHeight : 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            bottomConstraint.animator().constant = target
            self.view.layoutSubtreeIfNeeded()
        }

        isAnnotationDrawerOpen = !isOpen
        annotDrawerLogger.info("toggleAnnotationDrawer: Drawer now \(self.isAnnotationDrawerOpen ? "open" : "closed")")

        // Connect to search index if opening and index is available
        if isAnnotationDrawerOpen, let index = annotationSearchIndex {
            if !index.isBuilding {
                annotationDrawerView?.setSearchIndex(index)
            }
        }
    }

    /// Opens the annotation drawer by default when the selected bundle has table data.
    /// Data criteria: at least one annotation or variant track in the manifest.
    public func openAnnotationDrawerIfBundleHasData(manifest: BundleManifest? = nil) {
        let effectiveManifest = manifest ?? currentReferenceBundle?.manifest
        guard let effectiveManifest else { return }

        let hasDrawerData = !effectiveManifest.annotations.isEmpty || !effectiveManifest.variants.isEmpty
        guard hasDrawerData else { return }

        if !isAnnotationDrawerOpen {
            toggleAnnotationDrawer()
        } else if let index = annotationSearchIndex, !index.isBuilding {
            annotationDrawerView?.setSearchIndex(index)
        }
    }

    // MARK: - Configuration

    /// Creates and configures the annotation drawer, inserting it into the view hierarchy.
    private func configureAnnotationDrawer() {
        guard annotationDrawerView == nil else { return }

        let drawer = AnnotationTableDrawerView()
        drawer.translatesAutoresizingMaskIntoConstraints = false
        drawer.delegate = self
        drawer.setViewportSyncSource(viewerView)
        drawer.setSampleDisplayState(viewerView.sampleDisplayState)
        view.addSubview(drawer)

        // The drawer sits between the viewer content area and the status bar.
        // We constrain its bottom to be just above the status bar, and use
        // a height constraint. The bottom offset starts at drawerHeight (hidden below view).
        let persistedHeight = UserDefaults.standard.double(forKey: "annotationDrawerHeight")
        let drawerHeight = persistedHeight > 0 ? CGFloat(persistedHeight) : annotationDrawerHeight
        let bottomConstraint = drawer.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: drawerHeight)
        let heightConstraint = drawer.heightAnchor.constraint(equalToConstant: drawerHeight)

        NSLayoutConstraint.activate([
            drawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heightConstraint,
            bottomConstraint,
        ])

        annotationDrawerView = drawer
        annotationDrawerBottomConstraint = bottomConstraint
        annotationDrawerHeightConstraint = heightConstraint
        isAnnotationDrawerOpen = false

        // Update the viewer and header bottom constraints to sit above the drawer
        // We need to find and update the existing bottom constraints
        updateViewerBottomConstraints()

        // Populate if index is ready, otherwise drawer defaults to loading state
        if let index = annotationSearchIndex, !index.isBuilding {
            drawer.setSearchIndex(index)
        }

        annotDrawerLogger.info("configureAnnotationDrawer: Created annotation drawer")
    }

    /// Updates the viewer/header bottom constraints to account for the drawer.
    private func updateViewerBottomConstraints() {
        guard let drawer = annotationDrawerView else { return }

        // Find and update constraints that pin views to statusBar.topAnchor
        for constraint in view.constraints {
            // Update viewerView.bottomAnchor == statusBar.topAnchor
            if constraint.firstItem === viewerView,
               constraint.firstAttribute == .bottom,
               constraint.secondItem === statusBar,
               constraint.secondAttribute == .top {
                constraint.isActive = false
                viewerView.bottomAnchor.constraint(equalTo: drawer.topAnchor).isActive = true
                continue
            }
            // Update headerView.bottomAnchor == statusBar.topAnchor
            if constraint.firstItem === headerView,
               constraint.firstAttribute == .bottom,
               constraint.secondItem === statusBar,
               constraint.secondAttribute == .top {
                constraint.isActive = false
                headerView.bottomAnchor.constraint(equalTo: drawer.topAnchor).isActive = true
                continue
            }
        }
    }

    // MARK: - AnnotationTableDrawerDelegate

    public func annotationDrawer(_ drawer: AnnotationTableDrawerView, didSelectAnnotation result: AnnotationSearchIndex.SearchResult) {
        annotDrawerLogger.info("annotationDrawer: Navigating to '\(result.name, privacy: .public)' type=\(result.type, privacy: .public) at \(result.chromosome, privacy: .public):\(result.start)-\(result.end) strand=\(result.strand, privacy: .public)")

        let buffer = 1000 // 1kb buffer on each side
        let navigationChromosome = result.isVariant
            ? viewerView.referenceChromosomeName(forVariantDBChromosome: result.chromosome)
            : result.chromosome

        // Clear any previous sequence fetch error so the new region can be fetched
        viewerView.clearSequenceFetchError()

        // Log current viewer state before navigation
        let currentChrom = referenceFrame?.chromosome ?? "nil"
        let currentScale = referenceFrame?.scale ?? 0
        annotDrawerLogger.info("annotationDrawer: Pre-nav state: currentChrom=\(currentChrom, privacy: .public), scale=\(currentScale, format: .fixed(precision: 2)) bp/px")

        if let provider = currentBundleDataProvider,
           let chromInfo = provider.chromosomeInfo(named: navigationChromosome) {
            annotDrawerLogger.info("annotationDrawer: Using bundle provider, chromLength=\(chromInfo.length)")
            navigateToChromosomeAndPosition(
                chromosome: chromInfo.name,
                chromosomeLength: Int(chromInfo.length),
                start: max(0, result.start - buffer),
                end: min(Int(chromInfo.length), result.end + buffer)
            )
        } else {
            annotDrawerLogger.info("annotationDrawer: No bundle provider, using navigateToPosition")
            navigateToPosition(
                chromosome: navigationChromosome,
                start: max(0, result.start - buffer),
                end: result.end + buffer
            )
        }

        // Look up the full annotation record from SQLite (preserves BED12 exon blocks).
        // Falls back to a flat single-interval annotation if the database lookup fails.
        let annotation: SequenceAnnotation
        if let record = annotationSearchIndex?.lookupAnnotation(for: result) {
            annotation = record.toAnnotation()
        } else {
            let strand: Strand = switch result.strand {
            case "+": .forward
            case "-": .reverse
            default: .unknown
            }
            let annotationType = AnnotationType.from(rawString: result.type) ?? .gene
            annotation = SequenceAnnotation(
                type: annotationType,
                name: result.name,
                chromosome: navigationChromosome,
                intervals: [AnnotationInterval(start: result.start, end: result.end)],
                strand: strand
            )
        }
        viewerView.selectedAnnotation = annotation
        viewerView.postAnnotationSelectedNotification(annotation)
        if result.isVariant {
            NotificationCenter.default.post(
                name: .variantSelected,
                object: self,
                userInfo: [NotificationUserInfoKey.searchResult: result]
            )
        }
        viewerView.setNeedsDisplay(viewerView.bounds)
    }

    public func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int) {
        annotDrawerLogger.info("annotationDrawer: \(count) variants deleted, clearing cached variants and refreshing")
        syncVariantCountsToManifest()
        // Clear cached variant annotations so the viewer re-fetches from the (now updated) database
        viewerView.clearCachedVariants()
        viewerView.setNeedsDisplay(viewerView.bounds)
    }

    public func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleVariantRenderKeys keys: Set<String>?) {
        viewerView.setLocalVariantRenderFilterKeys(keys)
        viewerView.setNeedsDisplay(viewerView.bounds)
    }

    public func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {
        guard let heightConstraint = annotationDrawerHeightConstraint else { return }
        let maxHeight = view.bounds.height * 0.7
        let newHeight = max(100, min(maxHeight, heightConstraint.constant + deltaY))
        heightConstraint.constant = newHeight
        annotationDrawerBottomConstraint?.constant = 0  // Keep visible while dragging
        view.layoutSubtreeIfNeeded()
        UserDefaults.standard.set(Double(newHeight), forKey: "annotationDrawerHeight")
    }

    public func annotationDrawer(_ drawer: AnnotationTableDrawerView, didResolveGeneRegions regions: [GeneRegion]) {
        let wasVisible = !geneTabBarView.isHidden

        if regions.isEmpty {
            geneTabBarView.setGeneRegions([])
            lastSelectedGeneTabSelection = nil
            return
        }

        let preferredRegion = lastSelectedGeneTabSelection.map {
            GeneRegion(name: $0.name, chromosome: $0.chromosome, start: $0.start, end: $0.end)
        }
        geneTabBarView.setGeneRegions(regions, preferredRegion: preferredRegion, preferredGeneName: lastSelectedGeneTabSelection?.name)

        // Auto-navigate only when the tab bar first appears.
        if !wasVisible, let selected = geneTabBarView.selectedGeneRegion {
            geneTabBar(geneTabBarView, didSelectGene: selected)
        }
    }

    /// Recomputes per-track variant counts from the already-open SQLite handles
    /// and persists them into manifest.json on a background queue.
    private func syncVariantCountsToManifest() {
        guard let bundleURL = currentBundleURL,
              let searchIndex = annotationSearchIndex else { return }

        // Build a snapshot of live counts from the existing read-only handles
        // (no new DB connections needed — these are already open).
        let liveCounts = Dictionary(
            uniqueKeysWithValues: searchIndex.variantDatabaseHandles.map { ($0.trackId, $0.db.totalVariantCount()) }
        )

        // Dispatch manifest load + save off the main thread to avoid blocking UI.
        DispatchQueue.global(qos: .utility).async {
            do {
                let manifest = try BundleManifest.load(from: bundleURL)
                var changed = false
                let updatedTracks = manifest.variants.map { track -> VariantTrackInfo in
                    guard let liveCount = liveCounts[track.id],
                          liveCount != track.variantCount else {
                        return track
                    }
                    changed = true
                    return VariantTrackInfo(
                        id: track.id,
                        name: track.name,
                        description: track.description,
                        path: track.path,
                        indexPath: track.indexPath,
                        databasePath: track.databasePath,
                        variantType: track.variantType,
                        variantCount: liveCount,
                        source: track.source
                    )
                }
                guard changed else { return }
                let updatedManifest = BundleManifest(
                    formatVersion: manifest.formatVersion,
                    name: manifest.name,
                    identifier: manifest.identifier,
                    description: manifest.description,
                    createdDate: manifest.createdDate,
                    modifiedDate: Date(),
                    source: manifest.source,
                    genome: manifest.genome,
                    annotations: manifest.annotations,
                    variants: updatedTracks,
                    tracks: manifest.tracks,
                    metadata: manifest.metadata
                )
                try updatedManifest.save(to: bundleURL)
                annotDrawerLogger.info("syncVariantCountsToManifest: Persisted updated variant counts")
            } catch {
                annotDrawerLogger.error("syncVariantCountsToManifest: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - ViewerViewController Stored Properties for Annotation Drawer

extension ViewerViewController {

    private static var annotationDrawerViewKey: UInt8 = 0
    private static var annotationDrawerBottomKey: UInt8 = 0
    private static var annotationDrawerHeightKey: UInt8 = 0
    private static var annotationDrawerOpenKey: UInt8 = 0
    private static var annotationSearchIndexKey: UInt8 = 0
    private static var lastSelectedGeneTabSelectionKey: UInt8 = 0

    var annotationDrawerView: AnnotationTableDrawerView? {
        get { objc_getAssociatedObject(self, &Self.annotationDrawerViewKey) as? AnnotationTableDrawerView }
        set { objc_setAssociatedObject(self, &Self.annotationDrawerViewKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var annotationDrawerBottomConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &Self.annotationDrawerBottomKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &Self.annotationDrawerBottomKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var annotationDrawerHeightConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &Self.annotationDrawerHeightKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &Self.annotationDrawerHeightKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var isAnnotationDrawerOpen: Bool {
        get { (objc_getAssociatedObject(self, &Self.annotationDrawerOpenKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &Self.annotationDrawerOpenKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    public var annotationSearchIndex: AnnotationSearchIndex? {
        get { objc_getAssociatedObject(self, &Self.annotationSearchIndexKey) as? AnnotationSearchIndex }
        set {
            objc_setAssociatedObject(self, &Self.annotationSearchIndexKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // If the drawer exists and index is ready, populate it
            if let index = newValue, !index.isBuilding, let drawer = annotationDrawerView {
                drawer.setSearchIndex(index)
            }
        }
    }

    var lastSelectedGeneTabSelection: (name: String, chromosome: String, start: Int, end: Int)? {
        get {
            guard let dict = objc_getAssociatedObject(self, &Self.lastSelectedGeneTabSelectionKey) as? [String: Any],
                  let name = dict["name"] as? String,
                  let chromosome = dict["chromosome"] as? String,
                  let start = dict["start"] as? Int,
                  let end = dict["end"] as? Int else {
                return nil
            }
            return (name: name, chromosome: chromosome, start: start, end: end)
        }
        set {
            if let newValue {
                let payload: [String: Any] = [
                    "name": newValue.name,
                    "chromosome": newValue.chromosome,
                    "start": newValue.start,
                    "end": newValue.end,
                ]
                objc_setAssociatedObject(self, &Self.lastSelectedGeneTabSelectionKey, payload, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            } else {
                objc_setAssociatedObject(self, &Self.lastSelectedGeneTabSelectionKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }
}

// MARK: - GeneTabBarDelegate

extension ViewerViewController: GeneTabBarDelegate {

    func geneTabBar(_ tabBar: GeneTabBarView, didSelectGene region: GeneRegion) {
        lastSelectedGeneTabSelection = (
            name: region.name,
            chromosome: region.chromosome,
            start: region.start,
            end: region.end
        )
        let buffer = 1000
        viewerView.clearSequenceFetchError()

        if let provider = currentBundleDataProvider,
           let chromInfo = provider.chromosomeInfo(named: region.chromosome) {
            navigateToChromosomeAndPosition(
                chromosome: chromInfo.name,
                chromosomeLength: Int(chromInfo.length),
                start: max(0, region.start - buffer),
                end: min(Int(chromInfo.length), region.end + buffer)
            )
        } else {
            navigateToPosition(
                chromosome: region.chromosome,
                start: max(0, region.start - buffer),
                end: region.end + buffer
            )
        }
        annotDrawerLogger.info("Gene tab navigated to \(region.name, privacy: .public) at \(region.chromosome, privacy: .public):\(region.start)-\(region.end)")
    }

    func geneTabBarDidRequestDismiss(_ tabBar: GeneTabBarView) {
        lastSelectedGeneTabSelection = nil
        geneTabBarView.setGeneRegions([])
    }
}
