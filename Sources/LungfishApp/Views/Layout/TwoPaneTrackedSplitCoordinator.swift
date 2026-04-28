import AppKit

@MainActor
final class TwoPaneTrackedSplitCoordinator {
    private(set) var didSetInitialSplitPosition = false
    private(set) var needsInitialSplitValidation = true

    private var pendingInitialSplitValidation = false
    private var pendingInitialValidationLeadingExtent: CGFloat?
    private var isSynchronizingTrackedSplitPosition = false

    func invalidateInitialSplitPosition() {
        didSetInitialSplitPosition = false
        needsInitialSplitValidation = true
    }

    func currentDividerPosition(in splitView: NSSplitView) -> CGFloat? {
        guard splitView.arrangedSubviews.count == 2 else { return nil }
        return splitView.isVertical
            ? splitView.arrangedSubviews[0].frame.width
            : splitView.arrangedSubviews[0].frame.height
    }

    func resetInitialSplitPositionIfNeeded(
        in splitView: NSSplitView,
        minimumExtents: (leading: CGFloat, trailing: CGFloat)
    ) {
        guard didSetInitialSplitPosition, splitView.arrangedSubviews.count == 2 else { return }

        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let minimumRequiredExtent = minimumExtents.leading + minimumExtents.trailing + splitView.dividerThickness
        guard totalExtent >= minimumRequiredExtent else { return }

        let leadingExtent = splitView.isVertical
            ? splitView.arrangedSubviews[0].frame.width
            : splitView.arrangedSubviews[0].frame.height
        let trailingExtent = splitView.isVertical
            ? splitView.arrangedSubviews[1].frame.width
            : splitView.arrangedSubviews[1].frame.height

        if leadingExtent < minimumExtents.leading || trailingExtent < minimumExtents.trailing {
            didSetInitialSplitPosition = false
        }
    }

    func hasValidInitialSplitPosition(
        in splitView: NSSplitView,
        minimumExtents: (leading: CGFloat, trailing: CGFloat)
    ) -> Bool {
        guard splitView.arrangedSubviews.count == 2 else { return false }

        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard totalExtent > 0 else { return false }

        let minimumRequiredExtent = minimumExtents.leading + minimumExtents.trailing + splitView.dividerThickness
        guard totalExtent >= minimumRequiredExtent else { return false }

        let leadingExtent = splitView.isVertical
            ? splitView.arrangedSubviews[0].frame.width
            : splitView.arrangedSubviews[0].frame.height
        let trailingExtent = splitView.isVertical
            ? splitView.arrangedSubviews[1].frame.width
            : splitView.arrangedSubviews[1].frame.height

        return leadingExtent >= minimumExtents.leading && trailingExtent >= minimumExtents.trailing
    }

    func applyInitialSplitPositionIfNeeded(
        to splitView: TrackedDividerSplitView,
        defaultLeadingFraction: CGFloat,
        defaultLeadingExtent: CGFloat? = nil,
        minimumExtents: (leading: CGFloat, trailing: CGFloat),
        afterApply: (() -> Void)? = nil
    ) {
        guard !didSetInitialSplitPosition, splitView.arrangedSubviews.count == 2 else { return }

        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard totalExtent > 0 else { return }
        let minimumRequiredExtent = minimumExtents.leading + minimumExtents.trailing + splitView.dividerThickness
        guard totalExtent >= minimumRequiredExtent else { return }

        let clampedPosition = clampedLeadingExtent(
            in: splitView,
            proposed: defaultLeadingExtent ?? round(totalExtent * defaultLeadingFraction),
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )
        splitView.setPosition(clampedPosition, ofDividerAt: 0)
        applySplitFrames(in: splitView, leadingExtent: clampedPosition)
        didSetInitialSplitPosition = true
        needsInitialSplitValidation = false
        afterApply?()
    }

    func scheduleInitialSplitValidationIfNeeded(
        ownerView: NSView,
        splitView: TrackedDividerSplitView,
        minimumExtents: @escaping () -> (leading: CGFloat, trailing: CGFloat),
        defaultLeadingFraction: @escaping () -> CGFloat,
        defaultLeadingExtent: (() -> CGFloat?)? = nil,
        afterApply: (() -> Void)? = nil
    ) {
        guard needsInitialSplitValidation, ownerView.window != nil, !pendingInitialSplitValidation else { return }
        pendingInitialSplitValidation = true
        pendingInitialValidationLeadingExtent = currentDividerPosition(in: splitView)

        DispatchQueue.main.async { [weak self, weak ownerView, weak splitView] in
            guard let self, let ownerView, let splitView else { return }
            self.pendingInitialSplitValidation = false

            let scheduledLeadingExtent = self.pendingInitialValidationLeadingExtent
            self.pendingInitialValidationLeadingExtent = nil
            let requestedDividerPosition = splitView.requestedDividerPosition(at: 0)

            guard ownerView.window != nil else { return }
            guard self.needsInitialSplitValidation else { return }

            if let requestedDividerPosition,
               let scheduledLeadingExtent,
               abs(requestedDividerPosition - scheduledLeadingExtent) > 2,
               splitView.arrangedSubviews.count == 2 {
                let currentLeadingExtent = self.currentDividerPosition(in: splitView) ?? 0
                if abs(currentLeadingExtent - scheduledLeadingExtent) > 2 {
                    self.didSetInitialSplitPosition = true
                    self.needsInitialSplitValidation = false
                    return
                }
            }

            let extents = minimumExtents()
            self.resetInitialSplitPositionIfNeeded(in: splitView, minimumExtents: extents)
            self.applyInitialSplitPositionIfNeeded(
                to: splitView,
                defaultLeadingFraction: defaultLeadingFraction(),
                defaultLeadingExtent: defaultLeadingExtent?(),
                minimumExtents: extents,
                afterApply: afterApply
            )
            self.needsInitialSplitValidation = !self.hasValidInitialSplitPosition(
                in: splitView,
                minimumExtents: minimumExtents()
            )
        }
    }

    func applyLayoutPreference(
        to splitView: TrackedDividerSplitView,
        desiredIsVertical: Bool,
        desiredFirstPane: NSView,
        desiredSecondPane: NSView,
        defaultLeadingFraction: CGFloat,
        defaultLeadingExtent: CGFloat? = nil,
        minimumExtents: (leading: CGFloat, trailing: CGFloat),
        isViewInWindow: Bool,
        afterApply: (() -> Void)? = nil
    ) {
        guard splitView.arrangedSubviews.count == 2 else { return }

        let currentFirstPane = splitView.arrangedSubviews[0]
        let currentSecondPane = splitView.arrangedSubviews[1]
        let currentExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let orientationChanged = splitView.isVertical != desiredIsVertical
        let paneOrderChanged = splitView.arrangedSubviews[0] !== desiredFirstPane
            || splitView.arrangedSubviews[1] !== desiredSecondPane
        let currentFirstExtent = splitView.isVertical ? currentFirstPane.frame.width : currentFirstPane.frame.height
        let currentSecondExtent = max(0, currentExtent - currentFirstExtent)
        let needsRebuild = orientationChanged || paneOrderChanged

        if needsRebuild {
            splitView.clearRequestedDividerPosition()
            splitView.removeArrangedSubview(currentFirstPane)
            splitView.removeArrangedSubview(currentSecondPane)
            currentFirstPane.removeFromSuperview()
            currentSecondPane.removeFromSuperview()

            splitView.isVertical = desiredIsVertical
            splitView.addArrangedSubview(desiredFirstPane)
            splitView.addArrangedSubview(desiredSecondPane)
        } else {
            splitView.isVertical = desiredIsVertical
        }

        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard totalExtent > 0, isViewInWindow else {
            invalidateInitialSplitPosition()
            return
        }

        let resolvedDefaultLeadingExtent = defaultLeadingExtent ?? round(totalExtent * defaultLeadingFraction)
        let shouldHonorRequestedExtent = !needsRebuild && didSetInitialSplitPosition && !needsInitialSplitValidation
        let requestedLeadingExtent = shouldHonorRequestedExtent ? splitView.requestedDividerPosition(at: 0) : nil
        let shouldPreserveCurrentExtent = !needsRebuild && didSetInitialSplitPosition && !needsInitialSplitValidation
        let leadingExtent = requestedLeadingExtent
            ?? (shouldPreserveCurrentExtent && currentFirstExtent > 0 && currentSecondExtent > 0
                ? (desiredFirstPane === currentFirstPane ? currentFirstExtent : currentSecondExtent)
                : resolvedDefaultLeadingExtent)

        let clampedPosition = clampedLeadingExtent(
            in: splitView,
            proposed: leadingExtent,
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )
        isSynchronizingTrackedSplitPosition = true
        defer { isSynchronizingTrackedSplitPosition = false }
        splitView.setPosition(clampedPosition, ofDividerAt: 0)
        applySplitFrames(in: splitView, leadingExtent: clampedPosition)
        splitView.recordObservedDividerPosition(clampedPosition)
        didSetInitialSplitPosition = true
        needsInitialSplitValidation = false
        afterApply?()
    }

    func resizeSubviewsWithOldSize(
        _ splitView: TrackedDividerSplitView,
        oldSize: NSSize,
        defaultLeadingFraction: CGFloat,
        defaultLeadingExtent: CGFloat? = nil,
        minimumExtents: (leading: CGFloat, trailing: CGFloat),
        afterResize: (() -> Void)? = nil
    ) {
        _ = oldSize
        guard splitView.arrangedSubviews.count == 2 else { return }

        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard totalExtent > 0 else { return }

        let proposedLeadingExtent = splitView.requestedDividerPosition(at: 0)
            ?? currentDividerPosition(in: splitView)
            ?? defaultLeadingExtent
            ?? round(totalExtent * defaultLeadingFraction)
        let targetLeadingExtent = clampedLeadingExtent(
            in: splitView,
            proposed: proposedLeadingExtent,
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )

        applySplitFrames(in: splitView, leadingExtent: targetLeadingExtent)
        afterResize?()
    }

    func splitViewDidResizeSubviews(
        _ splitView: TrackedDividerSplitView,
        minimumExtents: (leading: CGFloat, trailing: CGFloat),
        afterResize: (() -> Void)? = nil
    ) {
        if !isSynchronizingTrackedSplitPosition,
           didSetInitialSplitPosition,
           !needsInitialSplitValidation,
           let requestedPosition = splitView.requestedDividerPosition(at: 0),
           let currentPosition = currentDividerPosition(in: splitView),
           abs(currentPosition - requestedPosition) > 2 {
            let clampedPosition = clampedLeadingExtent(
                in: splitView,
                proposed: requestedPosition,
                minimumLeadingExtent: minimumExtents.leading,
                minimumTrailingExtent: minimumExtents.trailing
            )
            isSynchronizingTrackedSplitPosition = true
            splitView.setPosition(clampedPosition, ofDividerAt: 0)
            applySplitFrames(in: splitView, leadingExtent: clampedPosition)
            isSynchronizingTrackedSplitPosition = false
            afterResize?()
            return
        }

        if !isSynchronizingTrackedSplitPosition,
           didSetInitialSplitPosition,
           !needsInitialSplitValidation,
           let currentPosition = currentDividerPosition(in: splitView) {
            splitView.recordObservedDividerPosition(currentPosition)
        }

        afterResize?()

        if hasValidInitialSplitPosition(in: splitView, minimumExtents: minimumExtents) {
            if didSetInitialSplitPosition {
                needsInitialSplitValidation = false
            } else {
                needsInitialSplitValidation = true
            }
            return
        }

        guard didSetInitialSplitPosition, !pendingInitialSplitValidation else { return }
        needsInitialSplitValidation = true
    }

    private func applySplitFrames(in splitView: NSSplitView, leadingExtent: CGFloat) {
        guard splitView.arrangedSubviews.count == 2 else { return }

        let dividerThickness = splitView.dividerThickness
        let firstView = splitView.arrangedSubviews[0]
        let secondView = splitView.arrangedSubviews[1]

        if splitView.isVertical {
            let totalWidth = splitView.bounds.width
            let trailingWidth = max(0, totalWidth - leadingExtent - dividerThickness)
            firstView.frame = NSRect(x: 0, y: 0, width: leadingExtent, height: splitView.bounds.height)
            secondView.frame = NSRect(
                x: leadingExtent + dividerThickness,
                y: 0,
                width: trailingWidth,
                height: splitView.bounds.height
            )
        } else {
            let totalHeight = splitView.bounds.height
            let trailingHeight = max(0, totalHeight - leadingExtent - dividerThickness)
            firstView.frame = NSRect(x: 0, y: 0, width: splitView.bounds.width, height: leadingExtent)
            secondView.frame = NSRect(
                x: 0,
                y: leadingExtent + dividerThickness,
                width: splitView.bounds.width,
                height: trailingHeight
            )
        }
    }

    private func clampedLeadingExtent(
        in splitView: NSSplitView,
        proposed: CGFloat,
        minimumLeadingExtent: CGFloat,
        minimumTrailingExtent: CGFloat
    ) -> CGFloat {
        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let availablePaneExtent = max(0, totalExtent - splitView.dividerThickness)
        return SplitPaneSizing.clampedDividerPosition(
            proposed: proposed,
            containerExtent: availablePaneExtent,
            minimumLeadingExtent: minimumLeadingExtent,
            minimumTrailingExtent: minimumTrailingExtent
        )
    }
}
