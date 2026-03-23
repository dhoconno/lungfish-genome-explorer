// TaxonomyViewController+Collections.swift - Taxa collections drawer integration
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

private let collectionsLogger = Logger(subsystem: LogSubsystem.app, category: "TaxonomyCollections")

// MARK: - TaxonomyViewController Collections Extension

extension TaxonomyViewController: TaxaCollectionsDrawerDelegate {

    // MARK: - Drawer State

    /// Default height for the taxa collections drawer.
    static let defaultTaxaDrawerHeight: CGFloat = 220

    /// Minimum height for the taxa collections drawer.
    static let minTaxaDrawerHeight: CGFloat = 140

    /// Maximum fraction of parent height the drawer may occupy.
    static let maxTaxaDrawerFraction: CGFloat = 0.5

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
        UserDefaults.standard.set(isTaxaCollectionsDrawerOpen, forKey: Self.taxaDrawerOpenKey)

        // Update the action bar toggle button state
        actionBar.setCollectionsDrawerOpen(isTaxaCollectionsDrawerOpen)

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
        let persistedHeight = UserDefaults.standard.double(forKey: Self.taxaDrawerHeightKey)
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

        // Wire the batch extraction callback
        drawer.onBatchExtract = { [weak self] collection in
            guard let self, let result = self.classificationResult else { return }
            self.onBatchExtract?(collection, result)
        }

        taxaCollectionsDrawerView = drawer
        taxaCollectionsDrawerBottomConstraint = bottomConstraint
        taxaCollectionsDrawerHeightConstraint = heightConstraint
        isTaxaCollectionsDrawerOpen = false

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

    // MARK: - TaxaCollectionsDrawerDelegate

    public func taxaCollectionsDrawerDidDragDivider(_ drawer: TaxaCollectionsDrawerView, deltaY: CGFloat) {
        guard let heightConstraint = taxaCollectionsDrawerHeightConstraint else { return }
        let maxHeight = view.bounds.height * Self.maxTaxaDrawerFraction
        let newHeight = max(Self.minTaxaDrawerHeight, min(maxHeight, heightConstraint.constant + deltaY))
        heightConstraint.constant = newHeight
        taxaCollectionsDrawerBottomConstraint?.constant = 0  // Keep visible while dragging
        view.layoutSubtreeIfNeeded()

        // Defer UserDefaults write -- mouseDragged fires at 60+ Hz
        _taxaDrawerHeightSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let height = self.taxaCollectionsDrawerHeightConstraint?.constant ?? Self.defaultTaxaDrawerHeight
                UserDefaults.standard.set(Double(height), forKey: Self.taxaDrawerHeightKey)
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
            UserDefaults.standard.set(Double(height), forKey: Self.taxaDrawerHeightKey)
        }
    }

    public func taxaCollectionsDrawer(_ drawer: TaxaCollectionsDrawerView, didRequestExtractFor collection: TaxaCollection) {
        guard let result = classificationResult else {
            collectionsLogger.warning("Cannot extract: no classification result")
            return
        }
        onBatchExtract?(collection, result)
    }
}
