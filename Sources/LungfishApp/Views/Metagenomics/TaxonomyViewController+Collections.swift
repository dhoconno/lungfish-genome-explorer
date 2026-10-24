// TaxonomyViewController+Collections.swift - Taxa collections drawer integration
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let collectionsLogger = Logger(subsystem: LogSubsystem.app, category: "TaxonomyCollections")

/// The seams of the Collections drawer's Extract. A test binds them to hold the load open, to record the
/// alert and to keep the drawer's height and open state out of the standard defaults. The live values
/// are the app's own.
@MainActor
enum TaxaCollectionsDrawerSeams {
    /// Loads the classification result of one sample. The drawer calls it off the main thread (SWIFT 2).
    static var loadSampleResult: @Sendable (URL) throws -> ClassificationResult = {
        try ClassificationResult.load(from: $0)
    }

    /// Shows the refusal of Extract as a sheet on `window`, or application-modal with none, as
    /// ``LiveNoProjectAlertPresenter`` does, since the project rules forbid `runModal`.
    static var presentRefusal: @MainActor (_ title: String, _ text: String, _ window: NSWindow?) -> Void = { title, text, window in
        if let window {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(NSError(
                domain: "org.lungfish.taxonomy-extract", code: 1,
                userInfo: [NSLocalizedDescriptionKey: title, NSLocalizedRecoverySuggestionErrorKey: text]
            ))
        }
    }

    /// Where the drawer keeps its height and its open state.
    static var defaults: UserDefaults = .standard
}

// MARK: - TaxonomyViewController Collections Extension

extension TaxonomyViewController: TaxaCollectionsDrawerDelegate {

    // MARK: - Drawer State

    /// Default height for the taxa collections drawer.
    static let defaultTaxaDrawerHeight: CGFloat = 220

    /// Minimum height for the taxa collections drawer.
    static let minTaxaDrawerHeight: CGFloat = 140

    /// Minimum visible host area left above the drawer during resizing.
    static let minVisibleViewportHeight: CGFloat = 120

    /// UserDefaults key for persisted drawer height.
    static let taxaDrawerHeightKey = "taxaCollectionsDrawerHeight"

    /// UserDefaults key for persisted drawer open/closed state.
    static let taxaDrawerOpenKey = "taxaCollectionsDrawerOpen"

    // MARK: - Public API

    /// Toggles the taxa collections drawer open or closed with animation.
    ///
    /// On first invocation, lazily creates the drawer and inserts it into the
    /// view hierarchy between the split view and the action bar. Subsequent
    /// calls animate the split view's bottom constraint to show or hide the
    /// drawer.
    ///
    /// Animation follows the same 0.25s ease-in-ease-out pattern used by the
    /// annotation drawer in ``ViewerViewController``.
    func toggleTaxaCollectionsDrawer() {
        if taxaCollectionsDrawerView == nil {
            configureTaxaCollectionsDrawer()
        }

        guard let bottomConstraint = taxaCollectionsDrawerBottomConstraint else { return }

        let isOpen = isTaxaCollectionsDrawerOpen
        let currentHeight = taxaCollectionsDrawerHeightConstraint?.constant ?? Self.defaultTaxaDrawerHeight

        // When closing, set the constraint to push the drawer offscreen.
        // When opening, set it to 0 so the drawer sits flush above the action bar.
        let targetConstant: CGFloat = isOpen ? currentHeight : 0

        let shouldReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if shouldReduceMotion {
            bottomConstraint.constant = targetConstant
            view.layoutSubtreeIfNeeded()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true

                bottomConstraint.animator().constant = targetConstant
                self.view.layoutSubtreeIfNeeded()
            }
        }

        isTaxaCollectionsDrawerOpen = !isOpen
        TaxaCollectionsDrawerSeams.defaults.set(isTaxaCollectionsDrawerOpen, forKey: Self.taxaDrawerOpenKey)

        // Update the toggle button states
        collectionsToggleButton.state = isTaxaCollectionsDrawerOpen ? .on : .off
        if !isTaxaCollectionsDrawerOpen {
            blastResultsToggleButton.state = .off
        } else if taxaCollectionsDrawerView?.selectedTab == .blastResults {
            blastResultsToggleButton.state = .on
        }

        collectionsLogger.info("toggleTaxaCollectionsDrawer: Drawer now \(self.isTaxaCollectionsDrawerOpen ? "open" : "closed")")

        // Update match status when opening
        if isTaxaCollectionsDrawerOpen {
            taxaCollectionsDrawerView?.setTree(tree)
        }
    }

    // MARK: - Configuration

    /// Creates the drawer view, divider, and constraints on first use.
    ///
    /// The drawer is positioned below the split view using a bottom constraint
    /// that starts offset by the drawer height (hidden). Calling
    /// ``toggleTaxaCollectionsDrawer()`` animates this constraint to 0 (visible).
    private func configureTaxaCollectionsDrawer() {
        guard taxaCollectionsDrawerView == nil else { return }

        let drawer = TaxaCollectionsDrawerView()
        drawer.translatesAutoresizingMaskIntoConstraints = false
        drawer.delegate = self
        view.addSubview(drawer)

        // Load persisted height or use default
        let persistedHeight = TaxaCollectionsDrawerSeams.defaults.double(forKey: Self.taxaDrawerHeightKey)
        let drawerHeight = persistedHeight > 0 ? CGFloat(persistedHeight) : Self.defaultTaxaDrawerHeight

        // Bottom constraint: distance from drawer bottom to action bar top.
        // Starts at drawerHeight (hidden below), animated to 0 (visible).
        let bottomConstraint = drawer.bottomAnchor.constraint(
            equalTo: actionBar.topAnchor,
            constant: drawerHeight
        )
        let heightConstraint = drawer.heightAnchor.constraint(equalToConstant: drawerHeight)

        NSLayoutConstraint.activate([
            drawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heightConstraint,
            bottomConstraint,
        ])

        // Re-pin the split view bottom to the drawer's divider top
        updateSplitViewBottomConstraint(drawer: drawer)

        // Wire the batch extraction callback. This closure is the drawer's
        // only extraction path; the delegate protocol covers resizing alone.
        drawer.onBatchExtract = { [weak self] collection in
            self?.extractCollectionFromDrawer(collection)
        }

        taxaCollectionsDrawerView = drawer
        taxaCollectionsDrawerBottomConstraint = bottomConstraint
        taxaCollectionsDrawerHeightConstraint = heightConstraint
        isTaxaCollectionsDrawerOpen = false

        // Wire BLAST drawer tab callbacks (rerun, open in browser, cancel)
        wireBlastDrawerCallbacks()

        // Set initial tree for match status
        drawer.setTree(tree)

        collectionsLogger.info("configureTaxaCollectionsDrawer: Created drawer, height=\(drawerHeight)")
    }

    /// Updates the split view bottom constraint to sit above the drawer.
    ///
    /// Finds the existing `splitView.bottomAnchor == actionBar.topAnchor`
    /// constraint and replaces it with `splitView.bottomAnchor == drawer.dividerView.topAnchor`.
    private func updateSplitViewBottomConstraint(drawer: TaxaCollectionsDrawerView) {
        for constraint in view.constraints {
            if constraint.firstItem === splitView,
               constraint.firstAttribute == .bottom,
               constraint.secondItem === actionBar,
               constraint.secondAttribute == .top {
                constraint.isActive = false
                splitView.bottomAnchor.constraint(equalTo: drawer.dividerView.topAnchor).isActive = true
                return
            }
        }
    }

    // MARK: - Extract

    /// Why the drawer's Extract cannot start. The words are the alert's (row 69).
    enum ExtractRefusal {
        /// The shown sample's result is not on disk, or the table shows nothing to extract from.
        case resultNotFound
        /// The table shows several samples, so no one sample is the one to extract.
        case chooseOneSample

        static let title = "Could not extract reads"

        var text: String {
            switch self {
            case .resultNotFound:
                "Lungfish could not find the classification result for the sample shown. Open the result again from the sidebar, then choose Extract."
            case .chooseOneSample:
                "Choose one sample, then choose Extract."
            }
        }
    }

    /// Starts the extraction of `collection` over the one result the table shows.
    ///
    /// A result displayed alone hands its result to ``onBatchExtract``. A database-backed display holds no
    /// result, so Extract finds the sample the table shows alone, which is the one picked sample, resolves
    /// its folder the way the BLAST callback does (`kraken2SampleResultDirectory`), loads its
    /// ``ClassificationResult`` off the main thread and hands that to ``onBatchExtract`` back on the main
    /// actor. Several samples shown together name no one sample, so Extract says so and starts nothing,
    /// since one output would mix samples a scientist keeps apart. A refusal shows the alert (row 69).
    func extractCollectionFromDrawer(_ collection: TaxaCollection) {
        if let result = classificationResult {
            onBatchExtract?(collection, result)
            return
        }
        guard isBatchMode, let resultURL = batchURL else {
            refuseExtraction(.resultNotFound)
            return
        }
        guard let picker = samplePickerState, picker.selectedSamples.count == 1,
              let sampleId = picker.selectedSamples.first else {
            refuseExtraction(.chooseOneSample)
            return
        }
        guard let sampleDirectory = kraken2SampleResultDirectory(
            resultURL: resultURL, sampleId: sampleId, fallsBackToResultFolder: sampleEntries.count == 1
        ) else {
            refuseExtraction(.resultNotFound)
            return
        }
        let load = TaxaCollectionsDrawerSeams.loadSampleResult
        Task { [weak self] in
            let loaded = await Task.detached { try? load(sampleDirectory) }.value
            guard let self else { return }
            guard let result = loaded else {
                collectionsLogger.warning("Cannot extract: no classification result loaded for \(sampleId, privacy: .public)")
                self.refuseExtraction(.resultNotFound)
                return
            }
            self.onBatchExtract?(collection, result)
        }
    }

    private func refuseExtraction(_ refusal: ExtractRefusal) {
        collectionsLogger.warning("Cannot extract: \(refusal.text, privacy: .public)")
        TaxaCollectionsDrawerSeams.presentRefusal(ExtractRefusal.title, refusal.text, view.window)
    }

    // MARK: - TaxaCollectionsDrawerDelegate

    public func taxaCollectionsDrawerDidDragDivider(_ drawer: TaxaCollectionsDrawerView, deltaY: CGFloat) {
        guard let heightConstraint = taxaCollectionsDrawerHeightConstraint else { return }
        let newHeight = MetagenomicsPaneSizing.clampedDrawerExtent(
            proposed: heightConstraint.constant + deltaY,
            containerExtent: view.bounds.height,
            minimumDrawerExtent: Self.minTaxaDrawerHeight,
            minimumSiblingExtent: Self.minVisibleViewportHeight
        )
        heightConstraint.constant = newHeight
        taxaCollectionsDrawerBottomConstraint?.constant = 0  // Keep visible while dragging
        view.layoutSubtreeIfNeeded()

        // Defer UserDefaults write -- mouseDragged fires at 60+ Hz
        _taxaDrawerHeightSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let height = self.taxaCollectionsDrawerHeightConstraint?.constant ?? Self.defaultTaxaDrawerHeight
                TaxaCollectionsDrawerSeams.defaults.set(Double(height), forKey: Self.taxaDrawerHeightKey)
            }
        }
        _taxaDrawerHeightSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    public func taxaCollectionsDrawerDidFinishDraggingDivider(_ drawer: TaxaCollectionsDrawerView) {
        // Flush the debounced save immediately on drag end
        _taxaDrawerHeightSaveWorkItem?.cancel()
        _taxaDrawerHeightSaveWorkItem = nil
        if let height = taxaCollectionsDrawerHeightConstraint?.constant {
            TaxaCollectionsDrawerSeams.defaults.set(Double(height), forKey: Self.taxaDrawerHeightKey)
        }
    }
}
