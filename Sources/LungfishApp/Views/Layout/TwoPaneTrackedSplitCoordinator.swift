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
        minimumExtents: (leading: CGFloat, trailing: CGFloat),
        afterApply: (() -> Void)? = nil
    ) {
        guard !didSetInitialSplitPosition, splitView.arrangedSubviews.count == 2 else { return }

        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard totalExtent > 0 else { return }
        let minimumRequiredExtent = minimumExtents.leading + minimumExtents.trailing + splitView.dividerThickness
        guard totalExtent >= minimumRequiredExtent else { return }

        let clampedPosition = SplitPaneSizing.clampedDividerPosition(
            proposed: round(totalExtent * defaultLeadingFraction),
            containerExtent: totalExtent,
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )
        splitView.setPosition(clampedPosition, ofDividerAt: 0)
        didSetInitialSplitPosition = true
        needsInitialSplitValidation = false
        afterApply?()
    }

    func scheduleInitialSplitValidationIfNeeded(
        ownerView: NSView,
        splitView: TrackedDividerSplitView,
        minimumExtents: @escaping () -> (leading: CGFloat, trailing: CGFloat),
        defaultLeadingFraction: @escaping () -> CGFloat,
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
        minimumExtents: (leading: CGFloat, trailing: CGFloat),
        isViewInWindow: Bool,
        afterApply: (() -> Void)? = nil
    ) {
        guard splitView.arrangedSubviews.count == 2 else { return }

        let currentFirstPane = splitView.arrangedSubviews[0]
        let currentSecondPane = splitView.arrangedSubviews[1]
        let currentExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let orientationChanged = splitView.isVertical != desiredIsVertical
        let currentFirstExtent = splitView.isVertical ? currentFirstPane.frame.width : currentFirstPane.frame.height
        let currentSecondExtent = max(0, currentExtent - currentFirstExtent)
        let needsRebuild = orientationChanged
            || splitView.arrangedSubviews[0] !== desiredFirstPane
            || splitView.arrangedSubviews[1] !== desiredSecondPane

        if needsRebuild {
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

        let defaultLeadingExtent = round(totalExtent * defaultLeadingFraction)
        let requestedLeadingExtent = !orientationChanged ? splitView.requestedDividerPosition(at: 0) : nil
        let leadingExtent = requestedLeadingExtent
            ?? (!orientationChanged && currentFirstExtent > 0 && currentSecondExtent > 0
                ? (desiredFirstPane === currentFirstPane ? currentFirstExtent : currentSecondExtent)
                : defaultLeadingExtent)

        let clampedPosition = SplitPaneSizing.clampedDividerPosition(
            proposed: leadingExtent,
            containerExtent: totalExtent,
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )
        splitView.setPosition(clampedPosition, ofDividerAt: 0)
        didSetInitialSplitPosition = true
        needsInitialSplitValidation = false
        afterApply?()
    }

    func splitViewDidResizeSubviews(
        _ splitView: TrackedDividerSplitView,
        minimumExtents: (leading: CGFloat, trailing: CGFloat),
        afterResize: (() -> Void)? = nil
    ) {
        if !isSynchronizingTrackedSplitPosition,
           didSetInitialSplitPosition,
           !needsInitialSplitValidation,
           let currentPosition = currentDividerPosition(in: splitView) {
            splitView.recordObservedDividerPosition(currentPosition)
        }

        afterResize?()

        if hasValidInitialSplitPosition(in: splitView, minimumExtents: minimumExtents) {
            didSetInitialSplitPosition = true
            needsInitialSplitValidation = false
        }
    }
}
