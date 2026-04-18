// ViewerViewController+AnnotationDrawer.swift - Annotation drawer integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

/// Logger for annotation drawer operations
private let annotDrawerLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerAnnotationDrawer")

/// Height of the annotation drawer when open.
private let annotationDrawerHeight: CGFloat = 250

/// Minimum visible content left above the annotation drawer during resize.
private let annotationDrawerVisibleHostStrip: CGFloat = 80

// MARK: - ViewerViewController Annotation Drawer Extension

extension ViewerViewController: AnnotationTableDrawerDelegate {

    // MARK: - Public API

    /// Toggles the annotation drawer open/closed with animation.
    public func toggleAnnotationDrawer() {
        if isDisplayingFASTQDataset {
            toggleFASTQMetadataDrawer()
            return
        }

        // When the taxonomy classification view is active, toggle its
        // collections/BLAST drawer instead of the annotation drawer.
        if taxonomyViewController != nil {
            taxonomyViewController?.toggleTaxaCollectionsDrawer()
            return
        }

        // When TaxTriage is active, toggle its BLAST results drawer.
        if let taxTriageVC = taxTriageViewController {
            taxTriageVC.toggleBlastDrawer()
            return
        }

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
        // Don't create the annotation drawer while the taxonomy view is active —
        // it uses its own collections/BLAST drawer.
        if taxonomyViewController != nil { return }

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

        let navigationChromosome = result.isVariant
            ? viewerView.referenceChromosomeName(forVariantDBChromosome: result.chromosome)
            : result.chromosome
        let annotationSpan = max(1, result.end - result.start)
        let desiredSpan = max(annotationSpan + 2_000, 3_000)

        // Clear any previous sequence fetch error so the new region can be fetched
        viewerView.clearSequenceFetchError()

        // Log current viewer state before navigation
        let currentChrom = referenceFrame?.chromosome ?? "nil"
        let currentScale = referenceFrame?.scale ?? 0
        annotDrawerLogger.info("annotationDrawer: Pre-nav state: currentChrom=\(currentChrom, privacy: .public), scale=\(currentScale, format: .fixed(precision: 2)) bp/px")

        if let provider = currentBundleDataProvider,
           let chromInfo = provider.chromosomeInfo(named: navigationChromosome) {
            annotDrawerLogger.info("annotationDrawer: Using bundle provider, chromLength=\(chromInfo.length)")
            let clampedWindow = centeredWindow(
                center: (result.start + result.end) / 2,
                span: desiredSpan,
                chromosomeLength: Int(chromInfo.length)
            )
            navigateToChromosomeAndPosition(
                chromosome: chromInfo.name,
                chromosomeLength: Int(chromInfo.length),
                start: clampedWindow.start,
                end: clampedWindow.end
            )
        } else {
            annotDrawerLogger.info("annotationDrawer: No bundle provider, using navigateToPosition")
            let seqLength = referenceFrame?.sequenceLength ?? Int.max
            let clampedWindow = centeredWindow(
                center: (result.start + result.end) / 2,
                span: desiredSpan,
                chromosomeLength: seqLength
            )
            navigateToPosition(
                chromosome: navigationChromosome,
                start: clampedWindow.start,
                end: clampedWindow.end
            )
        }

        // Guard against transient state races where immediate redraw restores stale extents.
        let expectedCenter = Double((result.start + result.end) / 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let frame = self.referenceFrame else { return }
                let isSameChrom = frame.chromosome == navigationChromosome
                let currentCenter = (frame.start + frame.end) / 2.0
                let isCentered = abs(currentCenter - expectedCenter) <= 2.0
                guard !(isSameChrom && isCentered) else { return }

                if let provider = self.currentBundleDataProvider,
                   let chromInfo = provider.chromosomeInfo(named: navigationChromosome) {
                    let clampedWindow = self.centeredWindow(
                        center: Int(expectedCenter.rounded()),
                        span: desiredSpan,
                        chromosomeLength: Int(chromInfo.length)
                    )
                    self.navigateToChromosomeAndPosition(
                        chromosome: chromInfo.name,
                        chromosomeLength: Int(chromInfo.length),
                        start: clampedWindow.start,
                        end: clampedWindow.end
                    )
                } else {
                    let seqLength = self.referenceFrame?.sequenceLength ?? Int.max
                    let clampedWindow = self.centeredWindow(
                        center: Int(expectedCenter.rounded()),
                        span: desiredSpan,
                        chromosomeLength: seqLength
                    )
                    _ = self.navigateToPosition(
                        chromosome: navigationChromosome,
                        start: clampedWindow.start,
                        end: clampedWindow.end
                    )
                }
            }
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

    private func centeredWindow(center: Int, span: Int, chromosomeLength: Int) -> (start: Int, end: Int) {
        let clampedLength = max(1, chromosomeLength)
        let clampedSpan = max(1, min(clampedLength, span))
        let half = clampedSpan / 2
        var start = max(0, center - half)
        var end = min(clampedLength, start + clampedSpan)
        if end - start < clampedSpan {
            start = max(0, end - clampedSpan)
        }
        if end <= start {
            end = min(clampedLength, start + 1)
        }
        return (start, end)
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

    public func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        fallbackConsequenceFor result: AnnotationSearchIndex.SearchResult
    ) -> (consequence: String?, aaChange: String?) {
        guard result.isVariant,
              let ref = result.ref, !ref.isEmpty,
              let alt = result.alt, !alt.isEmpty else {
            return (nil, nil)
        }
        return viewerView.fallbackConsequenceForTableVariant(
            chromosome: result.chromosome,
            position: result.start,
            ref: ref,
            alt: alt
        )
    }

    public func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {
        guard let heightConstraint = annotationDrawerHeightConstraint else { return }
        let newHeight = MetagenomicsPaneSizing.clampedDrawerExtent(
            proposed: heightConstraint.constant + deltaY,
            containerExtent: view.bounds.height,
            minimumDrawerExtent: 100,
            minimumSiblingExtent: annotationDrawerVisibleHostStrip
        )
        heightConstraint.constant = newHeight
        annotationDrawerBottomConstraint?.constant = 0  // Keep visible while dragging
        view.layoutSubtreeIfNeeded()
        // Defer UserDefaults write — mouseDragged fires at 60+ Hz
        _drawerHeightSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let height = self.annotationDrawerHeightConstraint?.constant ?? 250
                UserDefaults.standard.set(Double(height), forKey: "annotationDrawerHeight")
            }
        }
        _drawerHeightSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    public func annotationDrawerDidFinishDraggingDivider(_ drawer: AnnotationTableDrawerView) {
        // Flush the debounced save immediately on drag end
        _drawerHeightSaveWorkItem?.cancel()
        _drawerHeightSaveWorkItem = nil
        if let height = annotationDrawerHeightConstraint?.constant {
            UserDefaults.standard.set(Double(height), forKey: "annotationDrawerHeight")
        }
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
