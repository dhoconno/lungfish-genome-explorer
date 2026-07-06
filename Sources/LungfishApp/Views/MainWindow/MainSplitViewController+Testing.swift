// MainSplitViewController+Testing.swift - Test support hooks for MainSplitViewController
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import LungfishKit

extension MainSplitViewController {
    var testingShellLayoutState: WorkspaceShellLayoutState {
        shellLayoutCoordinator.state
    }

    var testingSidebarWidth: CGFloat {
        sidebarContainerView?.frame.width ?? 0
    }

    var testingInspectorWidth: CGFloat {
        inspectorContainerView?.frame.width ?? 0
    }

    var testingSidebarConstraintWidth: CGFloat {
        sidebarWidthConstraint?.constant ?? 0
    }

    var testingInspectorConstraintWidth: CGFloat {
        inspectorWidthConstraint?.constant ?? 0
    }

    var testingWindowStateScope: WindowStateScope {
        windowStateScope
    }

    func testingSetShellFrames(
        sidebarWidth: CGFloat,
        inspectorWidth: CGFloat,
        totalWidth: CGFloat,
        height: CGFloat = 900
    ) {
        guard let sidebarContainerView, let viewerContainerView, let inspectorContainerView else { return }

        let dividerThickness = splitView.dividerThickness
        let viewerWidth = totalWidth - sidebarWidth - inspectorWidth - (dividerThickness * 2)
        let resolvedViewerWidth = max(viewerWidth, viewerMinWidth)
        let resolvedTotalWidth = sidebarWidth + resolvedViewerWidth + inspectorWidth + (dividerThickness * 2)
        view.frame = NSRect(x: 0, y: 0, width: resolvedTotalWidth, height: height)
        splitView.frame = view.bounds
        splitView.bounds = view.bounds
        sidebarContainerView.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: height)
        viewerContainerView.frame = NSRect(
            x: sidebarWidth + dividerThickness,
            y: 0,
            width: resolvedViewerWidth,
            height: height
        )
        inspectorContainerView.frame = NSRect(
            x: resolvedTotalWidth - inspectorWidth,
            y: 0,
            width: inspectorWidth,
            height: height
        )
    }

    func testingProcessShellResize() {
        splitViewDidResizeSubviews(Notification(name: Notification.Name("WorkspaceShellLayoutTests.Resize"), object: splitView))
    }

    func testingRestorePersistedShellLayout() {
        restorePanelState()
        restorePersistedShellLayout()
    }

    func testingForceStaleInspectorTransitionSuppression() {
        inspectorTransitionInFlight = true
        inspectorTransitionStartTime = ProcessInfo.processInfo.systemUptime - 1.0
        inspectorTransitionTargetCollapsedState = inspectorItem.isCollapsed
        queuedInspectorCollapsedState = nil
        programmaticShellResizeSuppressionDepth = 1
    }

    func testingBeginDisplayRequest(
        identity: ContentSelectionIdentity
    ) -> AsyncRequestToken<ContentSelectionIdentity> {
        beginDisplayRequest(identity: identity)
    }

    func testingCanCommitDisplayRequest(
        _ token: AsyncRequestToken<ContentSelectionIdentity>,
        identity: ContentSelectionIdentity
    ) -> Bool {
        canCommitDisplayRequest(token, identity: identity)
    }

    func testingCommitDisplayRequest(
        _ token: AsyncRequestToken<ContentSelectionIdentity>,
        identity: ContentSelectionIdentity,
        commit: () -> Void
    ) {
        guard canCommitDisplayRequest(token, identity: identity) else { return }
        commit()
    }

    func testingBeginDatabaseBuildRequest(
        tool: String,
        resultURL: URL
    ) -> (identity: ContentSelectionIdentity, token: AsyncRequestToken<ContentSelectionIdentity>) {
        beginDatabaseBuildRequest(tool: tool, resultURL: resultURL)
    }

    func testingCommitDatabaseBuildCompletion(
        _ request: (identity: ContentSelectionIdentity, token: AsyncRequestToken<ContentSelectionIdentity>),
        commit: () -> Void
    ) {
        commitDatabaseBuildCompletion(request, commit: commit)
    }

    func testingRequestInspectorDocumentModeAfterDownload() {
        requestInspectorDocumentModeAfterDownload()
    }

    func testingDisplayImportedProjectFile(_ url: URL) {
        displayImportedProjectFile(at: url)
    }

    func testingDisplayGenotypeResultBundle(_ url: URL) {
        displayGenotypeResultBundleFromSidebar(at: url)
    }

    /// Drives the non-FASTQ import routing used by sidebar drops so the classification
    /// branches (standalone reference, annotation track, `.lungfishmhcref` bundle,
    /// generic copy) can be exercised deterministically without a drag session.
    func testingImportNonFASTQFile(
        url: URL,
        projectURL: URL?,
        targetDir: URL
    ) async {
        await importNonFASTQFile(
            url: url,
            projectURL: projectURL,
            targetDir: targetDir,
            destinationItem: nil,
            requestID: nil,
            displayAfterImport: false
        )
    }
}
