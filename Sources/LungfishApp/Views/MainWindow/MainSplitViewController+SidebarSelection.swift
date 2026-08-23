// MainSplitViewController+SidebarSelection.swift - Sidebar selection handling
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishEsVirituUI
import LungfishGenotypeUI
import LungfishIO
import LungfishWorkflow
import os.log

// MARK: - SidebarSelectionDelegate

extension MainSplitViewController: SidebarSelectionDelegate {
    public func sidebarShouldDeferSelectionTransition(
        _ transition: SidebarSelectionTransition,
        commit: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let genotypeController =
                viewerController.genotypeResultViewController else {
            return false
        }
        let draftTransition:
            GenotypeManualHaplotypeDraftCoordinator.Transition =
                transition == .refresh ? .reload : .bundleSwitch
        return genotypeController.deferManualHaplotypeTransition(
            draftTransition,
            mutation: commit
        )
    }

    func recordUITestEvent(_ event: String) {
        AppUITestConfiguration.current.appendEvent(event)
    }

    func invalidatePendingSelectionDebounce(reason: String) {
        guard selectionDebounceWorkItem != nil else { return }
        mainSplitLogger.info("invalidatePendingSelectionDebounce: cancelling pending selection work (\(reason, privacy: .public))")
        selectionDebounceWorkItem?.cancel()
        selectionDebounceWorkItem = nil
        selectionGeneration &+= 1
    }

    func cancelMultiDocumentLoadIfNeeded(hideProgress: Bool, reason: String) {
        if multiDocumentLoadTask != nil {
            mainSplitLogger.info("cancelMultiDocumentLoadIfNeeded: cancelling multi-document load (\(reason, privacy: .public))")
            multiDocumentLoadTask?.cancel()
            multiDocumentLoadTask = nil
        }
        if hideProgress {
            viewerController.hideProgress()
        }
    }

    /// Cancels any in-flight FASTQ dashboard load and optionally clears progress UI.
    func cancelFASTQLoadIfNeeded(hideProgress: Bool, reason: String) {
        if fastqLoadTask != nil {
            mainSplitLogger.info("cancelFASTQLoadIfNeeded: cancelling FASTQ load (\(reason, privacy: .public))")
            fastqLoadTask?.cancel()
            fastqLoadTask = nil
        }
        fastqLoadGeneration &+= 1
        activeFASTQLoadURL = nil
        activeFASTQSourceURL = nil
        if hideProgress {
            viewerController.hideProgress()
        }
    }

    /// Whether the currently displayed content's backing file no longer exists.
    ///
    /// Used to distinguish a real deletion (blank the viewport, and drop any
    /// overlay belonging to that item) from transient selection churn during a
    /// filesystem refresh.
    var displayedContentWasRemovedFromDisk: Bool {
        guard let path = activeContentSelectionIdentity?.standardizedURLPath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    func contentSelectionIdentity(for item: SidebarItem) -> ContentSelectionIdentity {
        ContentSelectionIdentity(
            url: item.url,
            kind: item.type.description,
            resultID: item.title,
            windowID: windowStateScope.id
        )
    }

    func contentSelectionIdentity(
        url: URL,
        kind: String,
        resultID: String? = nil
    ) -> ContentSelectionIdentity {
        ContentSelectionIdentity(
            url: url,
            kind: kind,
            resultID: resultID,
            windowID: windowStateScope.id
        )
    }

    @discardableResult
    func beginDisplayRequest(
        identity: ContentSelectionIdentity
    ) -> AsyncRequestToken<ContentSelectionIdentity> {
        // Any change of displayed content invalidates transient overlays that
        // belonged to the previously displayed result.
        if activeContentSelectionIdentity != identity {
            clearTransientViewportState()
        }
        genotypeResultLoadTask?.cancel()
        genotypeResultLoadTask = nil
        activeContentSelectionIdentity = identity
        return displayRequestGate.begin(identity: identity)
    }

    func invalidateDisplayRequest() {
        clearTransientViewportState()
        genotypeResultLoadTask?.cancel()
        genotypeResultLoadTask = nil
        activeContentSelectionIdentity = nil
        displayRequestGate.invalidate()
    }

    func canCommitDisplayRequest(
        _ token: AsyncRequestToken<ContentSelectionIdentity>,
        identity: ContentSelectionIdentity
    ) -> Bool {
        activeContentSelectionIdentity == identity
            && displayRequestGate.isCurrent(token, expectedIdentity: identity)
    }

    /// Returns true when a non-genomics child controller currently owns the viewport.
    var hasActiveSidebarChildViewport: Bool {
        viewerController.taxTriageViewController != nil
            || viewerController.esVirituViewController != nil
            || viewerController.taxonomyViewController != nil
            || viewerController.fastqDatasetController != nil
            || viewerController.assemblyResultController != nil
            || viewerController.activeMappingViewportController != nil
    }

    /// Heuristic for whether the current sidebar selection callback was user-initiated.
    ///
    /// Filesystem refreshes and other programmatic updates can also trigger selection
    /// churn. We only want "selection cleared" to blank the viewport when the user
    /// actually interacted with the sidebar.
    func isLikelyUserDrivenSidebarSelectionChange() -> Bool {
        let firstResponder = view.window?.firstResponder
        guard sidebarController.outlineViewIsFirstResponder(firstResponder) else { return false }
        guard let event = NSApp.currentEvent, event.window === view.window else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp,
             .keyDown:
            return true
        default:
            return false
        }
    }

    public func sidebarDidSelectItem(_ item: SidebarItem?) {
        // Cancel any pending debounced selection
        selectionDebounceWorkItem?.cancel()
        selectionDebounceWorkItem = nil

        // Increment generation counter to invalidate any in-flight background loads
        selectionGeneration &+= 1

        // If a metagenomics/FASTQ child VC is actively displayed, only process
        // selection changes when the sidebar outline view is the actual first
        // responder (i.e., the user clicked in the sidebar). Ignore spurious
        // selection changes from focus shifts, filesystem refreshes, etc.
        if hasActiveSidebarChildViewport {
            let firstResponder = view.window?.firstResponder
            let sidebarHasFocus = sidebarController.outlineViewIsFirstResponder(firstResponder)
            if !sidebarHasFocus {
                mainSplitLogger.debug("sidebarDidSelectItem: Ignoring selection change — sidebar not focused, active child VC displayed")
                return
            }
        }
        let userInitiatedInSidebar = isLikelyUserDrivenSidebarSelectionChange()

        // Debounce ALL selection changes (including nil/clear) to avoid
        // flickering when NSOutlineView fires deselect + reselect in quick
        // succession.
        let generation = selectionGeneration
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard self.selectionGeneration == generation else {
                    return
                }

                if let item {
                    self.displayContent(for: item)
                } else {
                    // A programmatic clear caused by the displayed item being
                    // deleted must still blank the viewport; only transient
                    // selection churn is ignored.
                    if self.hasActiveSidebarChildViewport
                        && !userInitiatedInSidebar
                        && !self.displayedContentWasRemovedFromDisk {
                        mainSplitLogger.debug("sidebarDidSelectItem: Ignoring non-user selection clear while active child VC is displayed")
                        return
                    }
                    mainSplitLogger.info("sidebarDidSelectItem: Selection cleared, clearing viewer and inspector")
                    self.invalidateDisplayRequest()
                    self.cancelFASTQLoadIfNeeded(hideProgress: true, reason: "selection cleared")
                    self.viewerController.clearViewport(statusMessage: "No sequence selected")
                    self.inspectorController.clearSelection()
                }
            }
        }
        selectionDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    public func sidebarDidSelectItems(_ items: [SidebarItem]) {
        // Cancel any pending debounced selection
        selectionDebounceWorkItem?.cancel()
        selectionDebounceWorkItem = nil

        // Increment generation counter
        selectionGeneration &+= 1

        // Filter to displayable items
        let displayableItems = items.filter { item in
            item.type != .folder && item.type != .project && item.type != .group
        }

        // Debounce all paths (including empty) to match sidebarDidSelectItem behavior
        let generation = selectionGeneration
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.selectionGeneration == generation else { return }

                guard !displayableItems.isEmpty else {
                    self.invalidateDisplayRequest()
                    self.cancelFASTQLoadIfNeeded(hideProgress: true, reason: "multi-select containers only")
                    self.viewerController.clearViewport(statusMessage: "No sequence selected")
                    self.inspectorController.clearSelection()
                    return
                }

                if displayableItems.count == 1 {
                    self.displayContent(for: displayableItems[0])
                } else {
                    self.handleMultipleItemsSelected(displayableItems)
                }
            }
        }
        selectionDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    public func sidebarDidRefreshSelectedItems(_ items: [SidebarItem]) {
        selectionDebounceWorkItem?.cancel()
        selectionDebounceWorkItem = nil
        selectionGeneration &+= 1

        let displayableItems = items.filter { item in
            item.type != .folder && item.type != .project && item.type != .group
        }
        guard !displayableItems.isEmpty else { return }

        if displayableItems.count == 1 {
            displayContent(for: displayableItems[0])
        } else {
            handleMultipleItemsSelected(displayableItems)
        }
    }

    /// Unified content dispatch - synchronous for reliability.
    ///
    /// This method handles all content display decisions synchronously,
    /// avoiding Swift Task issues that occur when called from notification handlers.
}
