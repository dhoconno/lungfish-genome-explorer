import CoreGraphics

@MainActor
final class WorkspaceShellLayoutCoordinator {
    enum Event {
        case shellDidResize
        case userDraggedSidebar
        case userDraggedInspector
    }

    struct ResolvedWidths: Equatable {
        var sidebarWidth: CGFloat
        var inspectorWidth: CGFloat
    }

    struct Decision: Equatable {
        var sidebarWidthToPersist: CGFloat?
        var inspectorWidthToPersist: CGFloat?
    }

    private(set) var state = WorkspaceShellLayoutState()

    private let sidebarMinWidth: CGFloat
    private let sidebarMaxWidth: CGFloat
    private let inspectorMinWidth: CGFloat
    private let inspectorMaxWidth: CGFloat
    private let viewerMinWidth: CGFloat

    init(
        sidebarMinWidth: CGFloat,
        sidebarMaxWidth: CGFloat,
        inspectorMinWidth: CGFloat,
        inspectorMaxWidth: CGFloat,
        viewerMinWidth: CGFloat
    ) {
        self.sidebarMinWidth = sidebarMinWidth
        self.sidebarMaxWidth = sidebarMaxWidth
        self.inspectorMinWidth = inspectorMinWidth
        self.inspectorMaxWidth = inspectorMaxWidth
        self.viewerMinWidth = viewerMinWidth
    }

    func recordRecommendation(_ width: CGFloat) {
        state.pendingRecommendedSidebarWidth = clampSidebarWidth(width)
    }

    func recordUserSidebarWidth(_ width: CGFloat) {
        state.lastUserSidebarWidth = clampSidebarWidth(width)
    }

    func recordUserInspectorWidth(_ width: CGFloat) {
        state.lastUserInspectorWidth = clampInspectorWidth(width)
    }

    func setSidebarVisible(_ isVisible: Bool) {
        state.isSidebarVisible = isVisible
    }

    func setInspectorVisible(_ isVisible: Bool) {
        state.isInspectorVisible = isVisible
    }

    func resolvedSidebarWidth(currentWidth: CGFloat) -> CGFloat {
        preferredSidebarWidth(currentWidth: currentWidth)
    }

    func resolvedInspectorWidth(currentWidth: CGFloat) -> CGFloat {
        preferredInspectorWidth(currentWidth: currentWidth)
    }

    func resolvedShellWidths(
        currentSidebarWidth: CGFloat,
        currentInspectorWidth: CGFloat,
        totalWidth: CGFloat
    ) -> ResolvedWidths {
        var sidebarWidth = state.isSidebarVisible ? preferredSidebarWidth(currentWidth: currentSidebarWidth) : 0
        var inspectorWidth = state.isInspectorVisible ? preferredInspectorWidth(currentWidth: currentInspectorWidth) : 0
        let availablePanelWidth = max(0, totalWidth - viewerMinWidth)

        guard sidebarWidth + inspectorWidth > availablePanelWidth else {
            return ResolvedWidths(
                sidebarWidth: sidebarWidth,
                inspectorWidth: inspectorWidth
            )
        }

        let minimumSidebarWidth = state.isSidebarVisible ? sidebarMinWidth : 0
        let minimumInspectorWidth = state.isInspectorVisible ? inspectorMinWidth : 0
        let minimumCombinedWidth = minimumSidebarWidth + minimumInspectorWidth

        if availablePanelWidth >= minimumCombinedWidth {
            let sidebarFlex = max(0, sidebarWidth - minimumSidebarWidth)
            let inspectorFlex = max(0, inspectorWidth - minimumInspectorWidth)
            let totalFlex = sidebarFlex + inspectorFlex

            if totalFlex > 0 {
                let overflow = (sidebarWidth + inspectorWidth) - availablePanelWidth
                let sidebarReduction = min(
                    sidebarFlex,
                    overflow * (sidebarFlex / totalFlex)
                )
                let inspectorReduction = min(
                    inspectorFlex,
                    overflow * (inspectorFlex / totalFlex)
                )

                sidebarWidth -= sidebarReduction
                inspectorWidth -= inspectorReduction
            }

            let remainingOverflow = max(0, (sidebarWidth + inspectorWidth) - availablePanelWidth)
            if remainingOverflow > 0 {
                let extraSidebarReduction = min(
                    max(0, sidebarWidth - minimumSidebarWidth),
                    remainingOverflow
                )
                sidebarWidth -= extraSidebarReduction
                inspectorWidth -= min(
                    max(0, inspectorWidth - minimumInspectorWidth),
                    remainingOverflow - extraSidebarReduction
                )
            }
        } else {
            let visibleTargetWidth = max(1, sidebarWidth + inspectorWidth)
            let scale = availablePanelWidth / visibleTargetWidth
            sidebarWidth *= scale
            inspectorWidth *= scale
        }

        return ResolvedWidths(
            sidebarWidth: sidebarWidth,
            inspectorWidth: inspectorWidth
        )
    }

    func resizeDecision(
        event: Event,
        currentSidebarWidth: CGFloat,
        currentInspectorWidth: CGFloat,
        totalWidth: CGFloat
    ) -> Decision {
        switch event {
        case .shellDidResize:
            return Decision(
                sidebarWidthToPersist: nil,
                inspectorWidthToPersist: nil
            )

        case .userDraggedSidebar:
            return Decision(
                sidebarWidthToPersist: clampSidebarWidth(
                    currentSidebarWidth,
                    totalWidth: totalWidth,
                    currentInspectorWidth: currentInspectorWidth
                ),
                inspectorWidthToPersist: nil
            )

        case .userDraggedInspector:
            return Decision(
                sidebarWidthToPersist: nil,
                inspectorWidthToPersist: clampInspectorWidth(
                    currentInspectorWidth,
                    totalWidth: totalWidth,
                    currentSidebarWidth: currentSidebarWidth
                )
            )
        }
    }

    private func preferredSidebarWidth(currentWidth: CGFloat) -> CGFloat {
        clampSidebarWidth(
            state.lastUserSidebarWidth
                ?? state.pendingRecommendedSidebarWidth
                ?? currentWidth
        )
    }

    private func preferredInspectorWidth(currentWidth: CGFloat) -> CGFloat {
        clampInspectorWidth(
            state.lastUserInspectorWidth
                ?? currentWidth
        )
    }

    private func clampSidebarWidth(
        _ width: CGFloat,
        totalWidth: CGFloat? = nil,
        currentInspectorWidth: CGFloat? = nil
    ) -> CGFloat {
        let constrainedMaxWidth: CGFloat
        if let totalWidth {
            let visibleInspectorWidth = state.isInspectorVisible ? (currentInspectorWidth ?? 0) : 0
            let availableWidth = totalWidth - viewerMinWidth - visibleInspectorWidth
            constrainedMaxWidth = min(sidebarMaxWidth, availableWidth)
        } else {
            constrainedMaxWidth = sidebarMaxWidth
        }

        let maxWidth = max(sidebarMinWidth, constrainedMaxWidth)
        return min(max(width, sidebarMinWidth), maxWidth)
    }

    private func clampInspectorWidth(
        _ width: CGFloat,
        totalWidth: CGFloat? = nil,
        currentSidebarWidth: CGFloat? = nil
    ) -> CGFloat {
        let constrainedMaxWidth: CGFloat
        if let totalWidth {
            let visibleSidebarWidth = state.isSidebarVisible ? (currentSidebarWidth ?? 0) : 0
            let availableWidth = totalWidth - viewerMinWidth - visibleSidebarWidth
            constrainedMaxWidth = min(inspectorMaxWidth, availableWidth)
        } else {
            constrainedMaxWidth = inspectorMaxWidth
        }

        let maxWidth = max(inspectorMinWidth, constrainedMaxWidth)
        return min(max(width, inspectorMinWidth), maxWidth)
    }
}
