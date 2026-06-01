// MainSplitViewController.swift - Three-panel split view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension MainSplitViewController {
    @objc func handleSidebarPreferredWidthRecommended(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let rawWidth = notification.userInfo?["width"] as? CGFloat else { return }
        applySidebarPreferredWidth(rawWidth, allowShrink: false, isRecommendation: true)
    }

    func sidebarWidthBounds() -> (minimum: CGFloat, maximum: CGFloat)? {
        guard splitView.subviews.count >= 2 else { return nil }
        let minimum = max(sidebarMinWidth, splitView.minPossiblePositionOfDivider(at: 0))
        let maximum = min(sidebarMaxWidth, splitView.maxPossiblePositionOfDivider(at: 0))
        guard maximum >= minimum else { return nil }
        return (minimum, maximum)
    }

    func applySidebarPreferredWidth(
        _ width: CGFloat,
        allowShrink: Bool,
        scheduleAsync: Bool = true,
        isRecommendation: Bool = false
    ) {
        shellLayoutCoordinator.recordRecommendation(width)
        ensureShellWidthConstraints()
        guard sidebarContainerView != nil else { return }
        guard !sidebarItem.isCollapsed else { return }

        let applyPosition = { [weak self] in
            guard let self else { return }
            guard let sidebarContainerView = self.sidebarContainerView else { return }
            guard !self.sidebarItem.isCollapsed else { return }
            guard let widthBounds = self.sidebarWidthBounds() else { return }

            let liveCurrentWidth = sidebarContainerView.frame.width
            let resolved = self.shellLayoutCoordinator.resolvedSidebarWidth(currentWidth: liveCurrentWidth)
            guard let target = self.sidebarWidthCoordinator.recommendedWidthToApply(
                proposedWidth: resolved,
                minimumWidth: widthBounds.minimum,
                maximumWidth: widthBounds.maximum,
                currentWidth: liveCurrentWidth,
                allowShrink: allowShrink
            ) else { return }
            guard !(!allowShrink && isRecommendation && target < liveCurrentWidth) else { return }

            self.withProgrammaticShellResizeSuppression {
                self.sidebarWidthCoordinator.noteProgrammaticWidth(target)
                self.sidebarWidthConstraint?.constant = target
                self.splitView.adjustSubviews()
                self.view.layoutSubtreeIfNeeded()
            }
            self.sidebarWidthCoordinator.finishProgrammaticWidth()
        }

        if scheduleAsync {
            mainSplitPerformOnMainRunLoop {
                applyPosition()
            }
        } else {
            applyPosition()
        }
    }

    func restorePersistedShellLayout() {
        withProgrammaticShellResizeSuppression {
            ensureShellWidthConstraints()
            let resolvedWidths = shellLayoutCoordinator.resolvedShellWidths(
                currentSidebarWidth: sidebarContainerView?.frame.width ?? sidebarDefaultWidth,
                currentInspectorWidth: inspectorContainerView?.frame.width ?? inspectorDefaultWidth,
                totalWidth: currentShellContentWidth()
            )

            sidebarWidthConstraint?.constant = resolvedWidths.sidebarWidth
            inspectorWidthConstraint?.constant = resolvedWidths.inspectorWidth

            if !sidebarItem.isCollapsed {
                setShellDividerPosition(
                    resolvedWidths.sidebarWidth,
                    ofDividerAt: 0
                )
            }

            if !inspectorItem.isCollapsed {
                let inspectorDividerPosition = shellContainerWidth()
                    - resolvedWidths.inspectorWidth
                    - splitView.dividerThickness
                setShellDividerPosition(
                    inspectorDividerPosition,
                    ofDividerAt: 1
                )
            }

            splitView.adjustSubviews()
            splitView.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            lastObservedShellContentWidth = currentShellContentWidth()
        }
    }

    func mirrorLiveShellWidthsAfterOrdinaryResize(
        currentSidebarWidth: CGFloat,
        currentInspectorWidth: CGFloat
    ) {
        ensureShellWidthConstraints()
        if !sidebarItem.isCollapsed, currentSidebarWidth > 0 {
            sidebarWidthConstraint?.constant = currentSidebarWidth
        }
        if !inspectorItem.isCollapsed, currentInspectorWidth > 0 {
            inspectorWidthConstraint?.constant = currentInspectorWidth
        }
    }

    func reapplyPersistedShellLayoutForCurrentVisibility(scheduleAsync: Bool) {
        let restoreLayout = { [weak self] in
            guard let self else { return }
            self.ensureShellWidthConstraints()
            self.restorePersistedShellLayout()
            self.completePendingRevealWidthReset()
        }

        if scheduleAsync {
            mainSplitPerformOnMainRunLoop {
                restoreLayout()
            }
        } else {
            restoreLayout()
        }
    }

    func markPendingRevealRestore(sidebar: Bool = false, inspector: Bool = false) {
        pendingSidebarRevealRestore = pendingSidebarRevealRestore || sidebar
        pendingInspectorRevealRestore = pendingInspectorRevealRestore || inspector
    }

    func schedulePendingRevealRestoreIfNeeded() {
        let needsSidebarRestore = pendingSidebarRevealRestore && !sidebarItem.isCollapsed
        let needsInspectorRestore = pendingInspectorRevealRestore && !inspectorItem.isCollapsed
        guard needsSidebarRestore || needsInspectorRestore else { return }

        pendingSidebarRevealRestore = false
        pendingInspectorRevealRestore = false
        reapplyPersistedShellLayoutForCurrentVisibility(scheduleAsync: true)
    }

    func requestPendingRevealRestorePass() {
        mainSplitPerformOnMainRunLoop { [weak self] in
            self?.schedulePendingRevealRestoreIfNeeded()
        }
    }

    func queuePostVisibilityShellRestore() {
        mainSplitPerformOnMainRunLoop { [weak self] in
            self?.reapplyPersistedShellLayoutForCurrentVisibility(scheduleAsync: true)
        }
    }

    func plannedSidebarRevealWidth() -> CGFloat {
        let desiredWidth = shellLayoutCoordinator.resolvedSidebarWidth(currentWidth: sidebarDefaultWidth)
        let currentInspectorWidth = !inspectorItem.isCollapsed ? (inspectorContainerView?.frame.width ?? inspectorDefaultWidth) : 0
        let visibleShellWidth = shellContentWidth(
            sidebarVisible: true,
            inspectorVisible: !inspectorItem.isCollapsed
        )

        return shellLayoutCoordinator.resizeDecision(
            event: .userDraggedSidebar,
            currentSidebarWidth: desiredWidth,
            currentInspectorWidth: currentInspectorWidth,
            totalWidth: visibleShellWidth
        ).sidebarWidthToPersist ?? desiredWidth
    }

    func plannedInspectorRevealWidth() -> CGFloat {
        let desiredWidth = shellLayoutCoordinator.resolvedInspectorWidth(currentWidth: inspectorDefaultWidth)
        let currentSidebarWidth = !sidebarItem.isCollapsed ? (sidebarContainerView?.frame.width ?? sidebarDefaultWidth) : 0
        let visibleShellWidth = shellContentWidth(
            sidebarVisible: !sidebarItem.isCollapsed,
            inspectorVisible: true
        )

        return shellLayoutCoordinator.resizeDecision(
            event: .userDraggedInspector,
            currentSidebarWidth: currentSidebarWidth,
            currentInspectorWidth: desiredWidth,
            totalWidth: visibleShellWidth
        ).inspectorWidthToPersist ?? desiredWidth
    }

    func prepareSidebarRevealWidthIfNeeded() {
        guard sidebarItem.isCollapsed else { return }
        let revealWidth = plannedSidebarRevealWidth()
        pendingSidebarRevealWidth = revealWidth
        sidebarItem.minimumThickness = revealWidth
    }

    func prepareInspectorRevealWidthIfNeeded() {
        guard inspectorItem.isCollapsed else { return }
        let revealWidth = plannedInspectorRevealWidth()
        pendingInspectorRevealWidth = revealWidth
        inspectorItem.minimumThickness = revealWidth
    }

    func finalizeSidebarRevealWidthIfNeeded() {
        guard let pendingSidebarRevealWidth else { return }
        ensureShellWidthConstraints()
        sidebarWidthConstraint?.constant = pendingSidebarRevealWidth
    }

    func finalizeInspectorRevealWidthIfNeeded() {
        guard let pendingInspectorRevealWidth else { return }
        ensureShellWidthConstraints()
        inspectorWidthConstraint?.constant = pendingInspectorRevealWidth
    }

    func completePendingRevealWidthReset() {
        if pendingSidebarRevealWidth != nil {
            pendingSidebarRevealWidth = nil
            sidebarItem.minimumThickness = sidebarItem.isCollapsed ? 0 : sidebarMinWidth
        }

        if pendingInspectorRevealWidth != nil {
            pendingInspectorRevealWidth = nil
            inspectorItem.minimumThickness = inspectorItem.isCollapsed ? 0 : inspectorMinWidth
        }
    }

    func setShellDividerPosition(
        _ position: CGFloat,
        ofDividerAt dividerIndex: Int
    ) {
        pendingShellResizeEvent = .shellDidResize
        isApplyingProgrammaticShellDividerMove = true
        splitView.setPosition(position, ofDividerAt: dividerIndex)
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        isApplyingProgrammaticShellDividerMove = false
    }

    func restoreSidebarWidthIfNeeded(currentWidth: CGFloat) {
        guard !sidebarItem.isCollapsed else { return }
        guard currentWidth >= sidebarMinWidth - 1 else { return }
        guard let widthBounds = sidebarWidthBounds() else { return }
        guard let target = sidebarWidthCoordinator.restoredUserWidthToApply(
            currentWidth: currentWidth,
            minimumWidth: widthBounds.minimum,
            maximumWidth: widthBounds.maximum
        ) else { return }

        ensureShellWidthConstraints()
        withProgrammaticShellResizeSuppression {
            sidebarWidthCoordinator.noteProgrammaticWidth(target)
            sidebarWidthConstraint?.constant = target
            splitView.adjustSubviews()
            view.layoutSubtreeIfNeeded()
        }
        sidebarWidthCoordinator.finishProgrammaticWidth()
    }

    // MARK: - Panel State

    func savePanelState() {
        let defaults = UserDefaults.standard
        defaults.set(sidebarItem.isCollapsed, forKey: Self.sidebarCollapsedDefaultsKey)
        defaults.set(inspectorItem.isCollapsed, forKey: Self.inspectorCollapsedDefaultsKey)

        if let sidebarWidth = shellLayoutCoordinator.state.lastUserSidebarWidth {
            defaults.set(sidebarWidth, forKey: Self.sidebarWidthDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.sidebarWidthDefaultsKey)
        }

        if let inspectorWidth = shellLayoutCoordinator.state.lastUserInspectorWidth {
            defaults.set(inspectorWidth, forKey: Self.inspectorWidthDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.inspectorWidthDefaultsKey)
        }
    }

    func restorePanelState() {
        let defaults = UserDefaults.standard

        // Restore sidebar state (default: visible)
        if defaults.object(forKey: Self.sidebarCollapsedDefaultsKey) != nil {
            sidebarItem.isCollapsed = defaults.bool(forKey: Self.sidebarCollapsedDefaultsKey)
        }
        sidebarItem.minimumThickness = sidebarItem.isCollapsed ? 0 : sidebarMinWidth
        shellLayoutCoordinator.setSidebarVisible(!sidebarItem.isCollapsed)

        // Restore inspector state (default: visible)
        if defaults.object(forKey: Self.inspectorCollapsedDefaultsKey) != nil {
            inspectorItem.isCollapsed = defaults.bool(forKey: Self.inspectorCollapsedDefaultsKey)
        }
        inspectorItem.minimumThickness = inspectorItem.isCollapsed ? 0 : inspectorMinWidth
        shellLayoutCoordinator.setInspectorVisible(!inspectorItem.isCollapsed)

        if let sidebarWidth = persistedWidth(forKey: Self.sidebarWidthDefaultsKey) {
            shellLayoutCoordinator.recordUserSidebarWidth(sidebarWidth)
            sidebarWidthCoordinator.noteUserRequestedWidth(sidebarWidth)
        }

        if let inspectorWidth = persistedWidth(forKey: Self.inspectorWidthDefaultsKey) {
            shellLayoutCoordinator.recordUserInspectorWidth(inspectorWidth)
        }
    }

    func persistedWidth(forKey key: String) -> CGFloat? {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else { return nil }
        return CGFloat(number.doubleValue)
    }

    func ensureShellWidthConstraints() {
        if let sidebarContainerView {
            let currentSidebarConstraintView = sidebarWidthConstraint?.firstItem as? NSView
            if currentSidebarConstraintView !== sidebarContainerView {
                let sidebarWidth = shellLayoutCoordinator.resolvedSidebarWidth(
                    currentWidth: max(sidebarContainerView.frame.width, sidebarDefaultWidth)
                )
                sidebarWidthConstraint?.isActive = false
                let constraint = sidebarContainerView.widthAnchor.constraint(equalToConstant: sidebarWidth)
                constraint.priority = .required
                constraint.isActive = true
                sidebarWidthConstraint = constraint
            }
        }

        if let inspectorContainerView {
            let currentInspectorConstraintView = inspectorWidthConstraint?.firstItem as? NSView
            if currentInspectorConstraintView !== inspectorContainerView {
                let inspectorWidth = shellLayoutCoordinator.resolvedInspectorWidth(
                    currentWidth: max(inspectorContainerView.frame.width, inspectorDefaultWidth)
                )
                inspectorWidthConstraint?.isActive = false
                let constraint = inspectorContainerView.widthAnchor.constraint(equalToConstant: inspectorWidth)
                constraint.priority = .required
                constraint.isActive = true
                inspectorWidthConstraint = constraint
            }
        }
    }

    func currentShellContentWidth() -> CGFloat {
        shellContentWidth(
            sidebarVisible: !sidebarItem.isCollapsed,
            inspectorVisible: !inspectorItem.isCollapsed
        )
    }

    func shellContentWidth(
        sidebarVisible: Bool,
        inspectorVisible: Bool
    ) -> CGFloat {
        let visiblePaneCount = [sidebarVisible, true, inspectorVisible]
            .filter { $0 }
            .count
        let visibleDividerCount = max(0, visiblePaneCount - 1)
        let dividerWidth = CGFloat(visibleDividerCount) * splitView.dividerThickness
        return max(0, shellContainerWidth() - dividerWidth)
    }

    func shellContainerWidth() -> CGFloat {
        if splitView.bounds.width > 0 {
            return splitView.bounds.width
        }
        let enclosingWidth = view.superview?.bounds.width ?? 0
        return max(enclosingWidth, view.bounds.width)
    }

    var isSuppressingProgrammaticShellResize: Bool {
        programmaticShellResizeSuppressionDepth > 0
    }

    func beginProgrammaticShellResizeSuppression() {
        pendingShellResizeEvent = .shellDidResize
        programmaticShellResizeSuppressionDepth += 1
    }

    func endProgrammaticShellResizeSuppression(scheduleAsync: Bool = false) {
        let release = { [weak self] in
            guard let self else { return }
            self.programmaticShellResizeSuppressionDepth = max(0, self.programmaticShellResizeSuppressionDepth - 1)
        }

        if scheduleAsync {
            mainSplitPerformOnMainRunLoop {
                release()
            }
        } else {
            release()
        }
    }

    func withProgrammaticShellResizeSuppression(
        scheduleAsyncRelease: Bool = false,
        _ mutation: () -> Void
    ) {
        beginProgrammaticShellResizeSuppression()
        mutation()
        endProgrammaticShellResizeSuppression(scheduleAsync: scheduleAsyncRelease)
    }

    func releaseProgrammaticShellResizeSuppressionIfNeeded() {
        pendingShellResizeEvent = .shellDidResize
        programmaticShellResizeSuppressionDepth = max(0, programmaticShellResizeSuppressionDepth - 1)
    }

    // MARK: - Public API

    /// Toggles the sidebar visibility with animation.
    public func toggleSidebar() {
        prepareSidebarRevealWidthIfNeeded()
        beginProgrammaticShellResizeSuppression()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed.toggle()
        } completionHandler: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let isSidebarVisible = !self.sidebarItem.isCollapsed
                    self.shellLayoutCoordinator.setSidebarVisible(isSidebarVisible)
                    if isSidebarVisible {
                        self.finalizeSidebarRevealWidthIfNeeded()
                        self.markPendingRevealRestore(sidebar: true)
                        self.requestPendingRevealRestorePass()
                    } else {
                        self.sidebarItem.minimumThickness = 0
                        self.queuePostVisibilityShellRestore()
                    }
                    self.savePanelState()
                    self.endProgrammaticShellResizeSuppression(scheduleAsync: true)
                }
            }
        }
    }

    /// Toggles the inspector visibility with animation.
    public func toggleInspector(source: String = "api.toggleInspector") {
        let beforeCollapsed = inspectorItem.isCollapsed
        let targetVisible = beforeCollapsed
        mainSplitLogger.info("toggleInspector[\(source, privacy: .public)]: pressed (isCollapsed=\(beforeCollapsed), targetVisible=\(targetVisible))")
        setInspectorVisible(targetVisible, animated: false, source: source)
    }

    /// Shows or hides the sidebar.
    public func setSidebarVisible(_ visible: Bool, animated: Bool = true) {
        guard sidebarItem.isCollapsed == visible else { return }

        if animated {
            toggleSidebar()
        } else {
            if visible {
                prepareSidebarRevealWidthIfNeeded()
            }
            beginProgrammaticShellResizeSuppression()
            sidebarItem.isCollapsed = !visible
            shellLayoutCoordinator.setSidebarVisible(visible)
            if visible {
                finalizeSidebarRevealWidthIfNeeded()
                markPendingRevealRestore(sidebar: true)
                requestPendingRevealRestorePass()
            } else {
                sidebarItem.minimumThickness = 0
                queuePostVisibilityShellRestore()
            }
            savePanelState()
            endProgrammaticShellResizeSuppression()
        }
    }

    /// Shows or hides the inspector.
    public func setInspectorVisible(_ visible: Bool, animated: Bool = true, source: String = "api.setInspectorVisible") {
        let targetCollapsedState = !visible
        let now = ProcessInfo.processInfo.systemUptime
        mainSplitLogger.info(
            "setInspectorVisible[\(source, privacy: .public)]: requested visible=\(visible), animated=\(animated), currentIsCollapsed=\(self.inspectorItem.isCollapsed), targetIsCollapsed=\(targetCollapsedState), inFlight=\(self.inspectorTransitionInFlight)"
        )

        if inspectorTransitionInFlight {
            let transitionAge = now - inspectorTransitionStartTime
            if transitionAge > 0.8 {
                mainSplitLogger.error(
                    "setInspectorVisible[\(source, privacy: .public)]: stale in-flight transition detected age=\(transitionAge, privacy: .public)s target=\(String(describing: self.inspectorTransitionTargetCollapsedState), privacy: .public); forcing recovery"
                )
                inspectorTransitionInFlight = false
                inspectorTransitionTargetCollapsedState = nil
                queuedInspectorCollapsedState = nil
                releaseProgrammaticShellResizeSuppressionIfNeeded()
            } else {
            if queuedInspectorCollapsedState == targetCollapsedState {
                mainSplitLogger.info(
                    "animateInspectorCollapse[\(source, privacy: .public)]: in-flight, duplicate queued target ignored isCollapsed=\(targetCollapsedState)"
                )
            } else {
                queuedInspectorCollapsedState = targetCollapsedState
                mainSplitLogger.info(
                    "animateInspectorCollapse[\(source, privacy: .public)]: in-flight, queued target isCollapsed=\(targetCollapsedState)"
                )
            }
            return
            }
        }

        guard inspectorItem.isCollapsed != targetCollapsedState else {
            mainSplitLogger.info("setInspectorVisible[\(source, privacy: .public)]: no-op (already at target)")
            if visible {
                // Keep inspector controls and viewer state synchronized even if no
                // split-view transition was needed.
                inspectorController.inspectorVisibilityDidChange(isVisible: true)
            }
            return
        }

        if animated {
            if visible {
                prepareInspectorRevealWidthIfNeeded()
            }
            beginProgrammaticShellResizeSuppression()
            animateInspectorCollapse(to: targetCollapsedState, source: source)
        } else {
            if visible {
                prepareInspectorRevealWidthIfNeeded()
            }
            beginProgrammaticShellResizeSuppression()
            inspectorItem.isCollapsed = targetCollapsedState
            queuedInspectorCollapsedState = nil
            finalizeInspectorVisibilityChange(source: source)
        }
    }

    /// Collapses both side panes so the viewer uses the full workspace width.
    @objc public func focusViewer() {
        setSidebarVisible(false, animated: false)
        setInspectorVisible(false, animated: false, source: "api.focusViewer")
    }

    /// Restores the primary side panes after focused viewer mode.
    @objc public func restoreSidePanes() {
        setSidebarVisible(true, animated: false)
        setInspectorVisible(true, animated: false, source: "api.restoreSidePanes")
    }

    /// Runs an inspector collapse/expand animation, serializing concurrent requests.
    func animateInspectorCollapse(to targetCollapsedState: Bool, source: String) {
        inspectorTransitionInFlight = true
        inspectorTransitionSerial += 1
        inspectorTransitionStartTime = ProcessInfo.processInfo.systemUptime
        inspectorTransitionTargetCollapsedState = targetCollapsedState
        let serial = inspectorTransitionSerial

        mainSplitLogger.info(
            "animateInspectorCollapse[\(source, privacy: .public)]: start from isCollapsed=\(self.inspectorItem.isCollapsed) to isCollapsed=\(targetCollapsedState)"
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            self.inspectorItem.animator().isCollapsed = targetCollapsedState
        } completionHandler: { [weak self] in
            mainSplitLogger.info("animateInspectorCollapse[\(source, privacy: .public)]: completion callback fired for serial=\(serial)")
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.completeInspectorCollapseAnimation(serial: serial, source: "\(source).completion")
                }
            }
        }

        // Fallback finalization path for cases where AppKit doesn't invoke
        // split-view animation completion callbacks reliably.
        // Uses GCD timer (not Task.sleep) to guarantee main-thread scheduling
        // even during AppKit animation/layout cycles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                mainSplitLogger.info("animateInspectorCollapse[\(source, privacy: .public)]: fallback callback fired for serial=\(serial)")
                self?.completeInspectorCollapseAnimation(serial: serial, source: "\(source).fallback")
            }
        }
    }

    /// Completes an inspector animation exactly once for a transition serial.
    func completeInspectorCollapseAnimation(serial: Int, source: String) {
        guard serial == inspectorTransitionSerial else {
            mainSplitLogger.debug(
                "completeInspectorCollapseAnimation[\(source, privacy: .public)]: stale serial \(serial) (current=\(self.inspectorTransitionSerial)), ignoring"
            )
            return
        }

        guard inspectorTransitionInFlight else {
            mainSplitLogger.debug(
                "completeInspectorCollapseAnimation[\(source, privacy: .public)]: already finalized"
            )
            return
        }

        inspectorTransitionInFlight = false
        inspectorTransitionTargetCollapsedState = nil
        finalizeInspectorVisibilityChange(source: source)

        guard let queuedTarget = queuedInspectorCollapsedState else { return }
        queuedInspectorCollapsedState = nil

        guard queuedTarget != inspectorItem.isCollapsed else {
            mainSplitLogger.info(
                "animateInspectorCollapse[\(source, privacy: .public)]: queued target already satisfied isCollapsed=\(queuedTarget)"
            )
            return
        }

        mainSplitLogger.info(
            "animateInspectorCollapse[\(source, privacy: .public)]: applying queued target isCollapsed=\(queuedTarget)"
        )
        beginProgrammaticShellResizeSuppression()
        animateInspectorCollapse(to: queuedTarget, source: "queued")
    }

    /// Persists state and notifies inspector after visibility transitions.
    func finalizeInspectorVisibilityChange(source: String) {
        let isInspectorVisible = !inspectorItem.isCollapsed
        shellLayoutCoordinator.setInspectorVisible(isInspectorVisible)
        if isInspectorVisible {
            finalizeInspectorRevealWidthIfNeeded()
            markPendingRevealRestore(inspector: true)
            requestPendingRevealRestorePass()
        } else {
            inspectorItem.minimumThickness = 0
            queuePostVisibilityShellRestore()
        }
        savePanelState()
        endProgrammaticShellResizeSuppression(scheduleAsync: true)
        inspectorController.inspectorVisibilityDidChange(isVisible: isInspectorVisible)
        mainSplitLogger.info(
            "finalizeInspectorVisibilityChange[\(source, privacy: .public)]: isCollapsed=\(self.inspectorItem.isCollapsed), queued=\(String(describing: self.queuedInspectorCollapsedState), privacy: .public)"
        )
    }

    /// Whether the sidebar is currently visible.
    public var isSidebarVisible: Bool {
        !sidebarItem.isCollapsed
    }

    /// Whether the inspector is currently visible.
    public var isInspectorVisible: Bool {
        !inspectorItem.isCollapsed
    }

    // MARK: - NSSplitViewDelegate
    //
    // NOTE: Do NOT override canCollapseSubview, constrainMinCoordinate, or
    // constrainMaxCoordinate on NSSplitViewController — these legacy delegate
    // methods are incompatible with constraint-based layout and cause an
    // assertion failure on macOS Tahoe. Use NSSplitViewItem properties instead:
    //   - canCollapse, minimumThickness, maximumThickness (set in configureChildControllers)

    public override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView else { return proposedPosition }
        guard !isApplyingProgrammaticShellDividerMove else { return proposedPosition }
        guard !isSuppressingProgrammaticShellResize else { return proposedPosition }

        let clampedPosition = clampedShellDividerPosition(
            proposedPosition,
            ofDividerAt: dividerIndex
        )

        switch dividerIndex {
        case 0:
            pendingShellResizeEvent = .userDraggedSidebar
        case 1:
            pendingShellResizeEvent = .userDraggedInspector
            let proposedInspectorWidth = splitView.bounds.width
                - clampedPosition
                - splitView.dividerThickness
            if !inspectorItem.isCollapsed, proposedInspectorWidth > 0 {
                ensureShellWidthConstraints()
                inspectorWidthConstraint?.constant = proposedInspectorWidth
            }
        default:
            pendingShellResizeEvent = .shellDidResize
        }

        if dividerIndex == 0,
           !sidebarItem.isCollapsed,
           !sidebarWidthCoordinator.isApplyingProgrammaticWidth {
            sidebarWidthCoordinator.noteUserRequestedWidth(clampedPosition)
        }

        return clampedPosition
    }

    func clampedShellDividerPosition(
        _ proposedPosition: CGFloat,
        ofDividerAt dividerIndex: Int
    ) -> CGFloat {
        if dividerIndex == 1, !inspectorItem.isCollapsed {
            let totalWidth = splitView.bounds.width
            let viewerLeadingEdge = viewerContainerView?.frame.minX
                ?? ((sidebarContainerView?.frame.width ?? 0) + splitView.dividerThickness)
            let minimumPosition = max(
                viewerLeadingEdge + viewerMinWidth,
                totalWidth - inspectorMaxWidth - splitView.dividerThickness
            )
            let maximumPosition = totalWidth - inspectorMinWidth - splitView.dividerThickness
            return min(max(proposedPosition, minimumPosition), maximumPosition)
        }

        return min(
            max(proposedPosition, splitView.minPossiblePositionOfDivider(at: dividerIndex)),
            splitView.maxPossiblePositionOfDivider(at: dividerIndex)
        )
    }

    public override func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === splitView else { return }

        let sidebarWidth = !sidebarItem.isCollapsed ? (sidebarContainerView?.frame.width ?? 0) : 0
        let inspectorWidth = !inspectorItem.isCollapsed ? (inspectorContainerView?.frame.width ?? 0) : 0
        let totalWidth = currentShellContentWidth()
        let previousTotalWidth = lastObservedShellContentWidth
        lastObservedShellContentWidth = totalWidth
        let shellContentWidthChanged = previousTotalWidth.map { abs($0 - totalWidth) > 0.5 } ?? true
        let resizeEvent = isSuppressingProgrammaticShellResize ? .shellDidResize : pendingShellResizeEvent
        pendingShellResizeEvent = .shellDidResize
        let decision = shellLayoutCoordinator.resizeDecision(
            event: resizeEvent,
            currentSidebarWidth: sidebarWidth,
            currentInspectorWidth: inspectorWidth,
            totalWidth: totalWidth
        )

        if let sidebarWidth = decision.sidebarWidthToPersist, !sidebarItem.isCollapsed {
            shellLayoutCoordinator.recordUserSidebarWidth(sidebarWidth)
            sidebarWidthConstraint?.constant = sidebarWidth
            savePanelState()
        }

        if let inspectorWidth = decision.inspectorWidthToPersist, !inspectorItem.isCollapsed {
            shellLayoutCoordinator.recordUserInspectorWidth(inspectorWidth)
            inspectorWidthConstraint?.constant = inspectorWidth
            savePanelState()
        }

        if resizeEvent == .shellDidResize,
           !isSuppressingProgrammaticShellResize {
            if pendingSidebarRevealRestore || pendingInspectorRevealRestore {
                schedulePendingRevealRestoreIfNeeded()
                completeInspectorTransitionIfReachedTarget()
                return
            }
            if shellContentWidthChanged {
                mirrorLiveShellWidthsAfterOrdinaryResize(
                    currentSidebarWidth: sidebarWidth,
                    currentInspectorWidth: inspectorWidth
                )
            }
            if !sidebarItem.isCollapsed {
                sidebarWidthCoordinator.noteObservedWidth(sidebarWidth)
            }
            schedulePendingRevealRestoreIfNeeded()
            completeInspectorTransitionIfReachedTarget()
            return
        }

        if !sidebarItem.isCollapsed {
            sidebarWidthCoordinator.noteObservedWidth(sidebarWidth)
            restoreSidebarWidthIfNeeded(currentWidth: sidebarWidth)
        }

        schedulePendingRevealRestoreIfNeeded()
        completeInspectorTransitionIfReachedTarget()
    }

    func completeInspectorTransitionIfReachedTarget() {
        guard inspectorTransitionInFlight else { return }
        guard let targetCollapsed = inspectorTransitionTargetCollapsedState else { return }
        guard inspectorItem.isCollapsed == targetCollapsed else { return }

        mainSplitLogger.info(
            "splitViewDidResizeSubviews: transition reached target isCollapsed=\(targetCollapsed), forcing completion"
        )
        completeInspectorCollapseAnimation(
            serial: inspectorTransitionSerial,
            source: "splitViewDidResizeSubviews"
        )
    }

}
