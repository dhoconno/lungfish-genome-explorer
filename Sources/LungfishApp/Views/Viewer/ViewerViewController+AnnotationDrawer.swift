// ViewerViewController+AnnotationDrawer.swift - Annotation drawer integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

/// Logger for annotation drawer operations
private let annotDrawerLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerAnnotationDrawer")

/// Height of the annotation drawer when open.
private let annotationDrawerHeight: CGFloat = 250

enum AnnotationDrawerSizing {
    static let dividerHeight: CGFloat = 8
    static let minimumHostHeight: CGFloat = 8

    static func clampedHeight(proposed: CGFloat, availableContentHeight: CGFloat) -> CGFloat {
        MetagenomicsPaneSizing.clampedDrawerExtent(
            proposed: proposed,
            containerExtent: availableContentHeight,
            minimumDrawerExtent: dividerHeight,
            minimumSiblingExtent: minimumHostHeight
        )
    }
}

// MARK: - ViewerViewController Annotation Drawer Extension

extension ViewerViewController: AnnotationTableDrawerDelegate {

    // MARK: - Public API

    /// Restricts annotation detail queries to the supplied reference records.
    /// `nil` means all records; an empty set intentionally yields no annotations.
    public func setAnnotationRecordScope(_ chromosomes: Set<String>?) {
        guard annotationRecordScope != chromosomes else { return }
        annotationRecordScope = chromosomes
        annotationDrawerView?.setAllowedChromosomes(chromosomes)
    }

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

        // A native bundle viewport has no annotations for the parent drawer to
        // show, and the MSA carries its own.
        if isNativeBundleViewportInstalled {
            return
        }

        if annotationDrawerView == nil {
            configureAnnotationDrawer()
        }

        guard let bottomConstraint = annotationDrawerBottomConstraint else { return }

        let isOpen = isAnnotationDrawerOpen
        let currentHeight = annotationDrawerHeightConstraint?.constant ?? annotationDrawerHeight
        let target: CGFloat = isOpen ? currentHeight : 0
        // Layout during the animation must clamp against the destination state.
        isAnnotationDrawerOpen = !isOpen

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            bottomConstraint.animator().constant = target
            self.view.layoutSubtreeIfNeeded()
        }

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

    func selectAnnotationInDrawer(_ annotation: SequenceAnnotation) {
        guard let drawer = annotationDrawerView else { return }
        if !drawer.selectAnnotation(matching: annotation) {
            drawer.clearAnnotationSelection()
        }
    }

    // MARK: - Configuration

    /// Creates and configures the annotation drawer, inserting it into the view hierarchy.
    private func configureAnnotationDrawer() {
        guard annotationDrawerView == nil else { return }

        let drawer = AnnotationTableDrawerView()
        drawer.translatesAutoresizingMaskIntoConstraints = false
        drawer.delegate = self
        drawer.windowStateScope = windowStateScope
        drawer.setViewportSyncSource(viewerView)
        drawer.setSampleDisplayState(viewerView.sampleDisplayState)
        drawer.setHiddenVariantTrackIDs(viewerView.hiddenVariantTrackIDs)
        drawer.setAllowedChromosomes(annotationRecordScope)
        view.addSubview(drawer)

        // The drawer sits between the viewer content area and the status bar.
        // We constrain its bottom to be just above the status bar, and use
        // a height constraint. The bottom offset starts at drawerHeight (hidden below view).
        let persistedHeight = UserDefaults.standard.double(forKey: "annotationDrawerHeight")
        let drawerHeight = persistedHeight > 0 ? CGFloat(persistedHeight) : annotationDrawerHeight
        let bottomConstraint = drawer.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: drawerHeight)
        let heightConstraint = drawer.heightAnchor.constraint(equalToConstant: drawerHeight)
        // A stale persisted height must never impose a minimum on an enclosing
        // split pane while its layout callback reconciles the new available space.
        heightConstraint.priority = NSLayoutConstraint.Priority(999)

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
        handleAnnotationDrawerSelection(result, from: drawer, navigate: true)
    }

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didHighlightVariant result: AnnotationSearchIndex.SearchResult) {
        handleAnnotationDrawerSelection(result, from: drawer, navigate: false)
    }

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didHighlightVariants entries: [VariantSelectionEntry]) {
        viewerView.selectedAnnotation = nil
        NotificationCenter.default.post(
            name: .annotationSelected,
            object: viewerView,
            userInfo: windowScopedUserInfo()
        )
        NotificationCenter.default.post(
            name: .variantSelectionChanged,
            object: drawer,
            userInfo: windowScopedUserInfo([NotificationUserInfoKey.variantSelectionEntries: entries])
        )
        viewerView.setNeedsDisplay(viewerView.bounds)
    }

    private func handleAnnotationDrawerSelection(
        _ result: AnnotationSearchIndex.SearchResult,
        from drawer: AnnotationTableDrawerView,
        navigate: Bool
    ) {
        annotDrawerLogger.info("annotationDrawer: Selecting '\(result.name, privacy: .public)' type=\(result.type, privacy: .public) at \(result.chromosome, privacy: .public):\(result.start)-\(result.end) strand=\(result.strand, privacy: .public), navigate=\(navigate)")

        let navigationChromosome = result.isVariant
            ? viewerView.referenceChromosomeName(forVariantDBChromosome: result.chromosome)
            : result.chromosome
        let annotationSpan = max(1, result.end - result.start)
        let desiredSpan = max(annotationSpan + 2_000, 3_000)

        if navigate {
            // Clear any previous sequence fetch error so the new region can be fetched.
            viewerView.clearSequenceFetchError()
        }

        if navigate, activeMappingViewportController?.currentResult == nil {
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
            let scheduledFrame = referenceFrame
            let scheduledStart = scheduledFrame?.start
            let scheduledEnd = scheduledFrame?.end
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let frame = self.referenceFrame else { return }
                    guard frame === scheduledFrame,
                          frame.start == scheduledStart,
                          frame.end == scheduledEnd else { return }
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
        viewerView.postAnnotationSelectedNotification(annotation, postVariantSelection: false)
        if navigate, activeMappingViewportController?.currentResult != nil {
            zoomToMappingAnnotation(annotation)
        }
        if result.isVariant {
            NotificationCenter.default.post(
                name: .variantSelected,
                object: drawer,
                userInfo: windowScopedUserInfo([
                    NotificationUserInfoKey.searchResult: result,
                    NotificationUserInfoKey.variantInspectorFields: drawer.variantInspectorFields(for: result),
                ])
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

    public func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestExtract annotations: [SequenceAnnotation]) {
        viewerView.presentAnnotationSequenceExtractionDialog(annotations)
    }

    func annotationDrawerSelectedSequenceRegion(_ drawer: AnnotationTableDrawerView) -> AnnotationTableDrawerSelectionRegion? {
        guard viewerView.isUserColumnSelection,
              let range = viewerView.selectionRange,
              let frame = referenceFrame else {
            return nil
        }
        return AnnotationTableDrawerSelectionRegion(
            chromosome: frame.chromosome,
            start: range.lowerBound,
            end: range.upperBound
        )
    }

    public func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleVariantRenderKeys keys: Set<String>?) {
        viewerView.setLocalVariantRenderFilterKeys(keys)
        viewerView.setNeedsDisplay(viewerView.bounds)
    }

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleAnnotationRenderKeys keys: Set<String>?) {
        viewerView.setLocalAnnotationRenderFilterKeys(keys)
        viewerView.invalidateAnnotationTile()
        viewerView.setNeedsDisplay(viewerView.bounds)
    }

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateAnnotationTrackDisplayState state: AnnotationTrackDisplayState) {
        viewerView.setAnnotationTrackDisplayState(state)
        viewerView.setNeedsDisplay(viewerView.bounds)
    }

    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        didRequestDeleteAnnotations annotations: [AnnotationSearchIndex.SearchResult]
    ) {
        let editable = annotations.filter { $0.annotationRowId != nil }
        guard !editable.isEmpty else {
            NSSound.beep()
            return
        }
        guard Set(editable.map(\.trackId)).count == 1 else {
            let alert = NSAlert()
            alert.messageText = "Choose One Annotation Track"
            alert.informativeText = "Delete annotations from one annotation track at a time."
            alert.alertStyle = .warning
            presentAnnotationDrawerAlert(alert)
            return
        }
        guard let bundleURL = currentBundleURL ?? viewerView.currentReferenceBundle?.url else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = editable.count == 1 ? "Delete Annotation?" : "Delete Annotations?"
        let itemCount = editable.count == 1 ? "1 annotation" : "\(editable.count) annotations"
        alert.informativeText = "This will permanently remove \(itemCount) from the reference bundle. Empty annotation tracks will also be removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: editable.count == 1 ? "Delete Annotation" : "Delete Annotations")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.applyLungfishDestructiveStyle()

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.runAnnotationRowDeletion(bundleURL: bundleURL, annotations: editable)
            }}
        }
    }

    private func runAnnotationRowDeletion(
        bundleURL: URL,
        annotations: [AnnotationSearchIndex.SearchResult]
    ) {
        let rowIDsByTrack = Dictionary(grouping: annotations, by: \.trackId).mapValues { rows in
            rows.compactMap(\.annotationRowId).sorted()
        }.filter { !$0.value.isEmpty }
        guard !rowIDsByTrack.isEmpty else {
            NSSound.beep()
            return
        }
        guard rowIDsByTrack.count == 1,
              let group = rowIDsByTrack.first else {
            let alert = NSAlert()
            alert.messageText = "Choose One Annotation Track"
            alert.informativeText = "Delete annotations from one annotation track at a time."
            alert.alertStyle = .warning
            presentAnnotationDrawerAlert(alert)
            return
        }
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            let alert = NSAlert()
            alert.messageText = "Bundle Busy"
            alert.informativeText = "Another operation is already modifying this reference bundle. Wait for it to finish before deleting annotations."
            alert.alertStyle = .warning
            presentAnnotationDrawerAlert(alert)
            return
        }

        func makeArguments(trackID: String, rowIDs: [Int64]) -> [String] {
            var values = [
                "sequence",
                "delete-annotations",
                bundleURL.path,
                "--track-id",
                trackID,
            ]
            for rowID in rowIDs {
                values.append("--row-id")
                values.append(String(rowID))
            }
            values.append("--quiet")
            return values
        }

        let arguments = makeArguments(trackID: group.key, rowIDs: group.value)
        let command = ([CLICommandIdentity.executableName] + arguments).map(shellEscape).joined(separator: " ")
        let deletedCount = group.value.count
        let opID = OperationCenter.shared.start(
            title: deletedCount == 1 ? "Delete Annotation" : "Delete Annotations",
            detail: "Deleting \(deletedCount) annotation\(deletedCount == 1 ? "" : "s")...",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: command
        )

        let cliCancellation = LungfishCLIRunner.CancellationHandle()
        let task = Task.detached { [weak self] in
            do {
                let output = try LungfishCLIRunner.run(arguments: arguments, cancellation: cliCancellation)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    if !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        OperationCenter.shared.log(id: opID, level: .info, message: output.stdout)
                    }
                    if !output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        OperationCenter.shared.log(id: opID, level: .warning, message: output.stderr)
                    }
                }}
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard OperationCenter.shared.complete(
                        id: opID,
                        detail: "Deleted \(deletedCount) annotation\(deletedCount == 1 ? "" : "s")"
                    ) else { return }
                    do {
                        try self?.reloadReferenceBundleAfterAnnotationTrackMutation(bundleURL: bundleURL)
                    } catch {
                        self?.presentAnnotationTrackDeletionFailure(error, title: "Reload Failed")
                    }
                }}
            } catch LungfishCLIRunner.RunError.cancelled {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    OperationCenter.shared.log(id: opID, level: .info, message: "Delete Annotations cancelled")
                    OperationCenter.shared.acknowledgeCancellation(id: opID)
                }}
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard OperationCenter.shared.fail(
                        id: opID,
                        detail: "Delete Annotations failed",
                        errorMessage: error.localizedDescription
                    ) else { return }
                    self?.presentAnnotationTrackDeletionFailure(error, title: "Delete Annotations Failed")
                }}
            }
        }
        OperationCenter.shared.setCancelCallback(for: opID) {
            task.cancel()
            cliCancellation.cancel()
        }
    }

    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        didRequestDeleteAnnotationTrack trackID: String,
        trackName: String
    ) {
        guard let bundleURL = currentBundleURL ?? viewerView.currentReferenceBundle?.url else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete Annotation Track?"
        alert.informativeText = "This will permanently remove the annotation track \"\(trackName)\" and its stored annotations from the reference bundle."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Track")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.applyLungfishDestructiveStyle()

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.runAnnotationTrackDeletion(bundleURL: bundleURL, trackID: trackID, trackName: trackName)
                }
            }
        }
    }

    private func runAnnotationTrackDeletion(bundleURL: URL, trackID: String, trackName: String) {
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            let alert = NSAlert()
            alert.messageText = "Bundle Busy"
            alert.informativeText = "Another operation is already modifying this reference bundle. Wait for it to finish before deleting an annotation track."
            alert.alertStyle = .warning
            presentAnnotationDrawerAlert(alert)
            return
        }

        let arguments = [
            "sequence",
            "delete-annotation-track",
            bundleURL.path,
            "--track-id",
            trackID,
            "--quiet",
        ]
        let command = ([CLICommandIdentity.executableName] + arguments).map(shellEscape).joined(separator: " ")
        let opID = OperationCenter.shared.start(
            title: "Delete Annotation Track",
            detail: "Deleting \(trackName)...",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: command
        )

        let cliCancellation = LungfishCLIRunner.CancellationHandle()
        let task = Task.detached { [weak self] in
            do {
                let output = try LungfishCLIRunner.run(arguments: arguments, cancellation: cliCancellation)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    if !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        OperationCenter.shared.log(id: opID, level: .info, message: output.stdout)
                    }
                    if !output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        OperationCenter.shared.log(id: opID, level: .warning, message: output.stderr)
                    }
                    guard OperationCenter.shared.complete(
                        id: opID,
                        detail: "Deleted annotation track \(trackName)"
                    ) else { return }
                    do {
                        try self?.reloadReferenceBundleAfterAnnotationTrackMutation(bundleURL: bundleURL)
                    } catch {
                        self?.presentAnnotationTrackDeletionFailure(error, title: "Reload Failed")
                    }
                }}
            } catch LungfishCLIRunner.RunError.cancelled {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    OperationCenter.shared.log(id: opID, level: .info, message: "Delete Annotation Track cancelled")
                    OperationCenter.shared.acknowledgeCancellation(id: opID)
                }}
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard OperationCenter.shared.fail(
                        id: opID,
                        detail: "Delete Annotation Track failed",
                        errorMessage: error.localizedDescription
                    ) else { return }
                    self?.presentAnnotationTrackDeletionFailure(error, title: "Delete Annotation Track Failed")
                }}
            }
        }
        OperationCenter.shared.setCancelCallback(for: opID) {
            task.cancel()
            cliCancellation.cancel()
        }
    }

    private func presentAnnotationTrackDeletionFailure(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        presentAnnotationDrawerAlert(alert)
    }

    private func presentAnnotationDrawerAlert(_ alert: NSAlert) {
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(AnnotationDrawerWarning(title: alert.messageText, message: alert.informativeText))
        }
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

    func annotationDrawerAdditionalExportSources(_ drawer: AnnotationTableDrawerView) throws -> [URL] {
        guard let bundle = viewerView.currentReferenceBundle else { return [] }
        // Track metadata and chromosome aliases always come from the manifest. Local
        // consequence predictions additionally depend on the reference when present.
        var sources = [bundle.url.appendingPathComponent(BundleManifest.filename)]
        if let genome = bundle.manifest.genome {
            sources.append(try bundle.memberURL(for: genome.path, field: "genome.path"))
        }
        return sources
    }

    func annotationDrawerVariantExportResolverSnapshot(
        _ drawer: AnnotationTableDrawerView
    ) -> VariantTableExportResolverSnapshot {
        viewerView.variantTableExportResolverSnapshot()
    }

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, codingFeatureFor result: AnnotationSearchIndex.SearchResult) -> String? {
        viewerView.codingFeatureText(chromosome: result.chromosome, position: result.start, referenceLength: result.ref?.count ?? 1)
    }

    public func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {
        guard let heightConstraint = annotationDrawerHeightConstraint else { return }
        view.layoutSubtreeIfNeeded()
        let newHeight = AnnotationDrawerSizing.clampedHeight(
            proposed: heightConstraint.constant + deltaY,
            availableContentHeight: annotationDrawerAvailableContentHeight
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

    /// Keeps a persisted height valid as the window or its enclosing pane shrinks.
    func clampAnnotationDrawerHeightToAvailableContent() {
        guard view.window != nil, view.bounds.height > 0,
              annotationDrawerView != nil,
              let heightConstraint = annotationDrawerHeightConstraint else { return }

        let clampedHeight = AnnotationDrawerSizing.clampedHeight(
            proposed: heightConstraint.constant,
            availableContentHeight: annotationDrawerAvailableContentHeight
        )
        guard clampedHeight != heightConstraint.constant else { return }

        heightConstraint.constant = clampedHeight
        if !isAnnotationDrawerOpen {
            annotationDrawerBottomConstraint?.constant = clampedHeight
        }
    }

    private var annotationDrawerAvailableContentHeight: CGFloat {
        max(
            0,
            view.bounds.height
                - view.safeAreaInsets.top
                - enhancedRulerView.bounds.height
                - geneTabBarView.bounds.height
                - statusBar.bounds.height
        )
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

private struct AnnotationDrawerWarning: LocalizedError {
    let title: String
    let message: String

    var errorDescription: String? { title }
    var recoverySuggestion: String? { message }
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
