import CoreGraphics

@MainActor
final class WorkspaceShellLayoutCoordinator {
    enum Event {
        case shellDidResize
        case recommendationArrived
        case userDraggedSidebar
        case userDraggedInspector
    }

    struct Decision: Equatable {
        var shouldSetSidebarDividerSynchronously: Bool
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
        state.lastUserSidebarWidth
            ?? state.pendingRecommendedSidebarWidth
            ?? clampSidebarWidth(currentWidth)
    }

    func resizeDecision(
        event: Event,
        currentSidebarWidth: CGFloat,
        currentInspectorWidth: CGFloat,
        totalWidth: CGFloat
    ) -> Decision {
        switch event {
        case .shellDidResize, .recommendationArrived:
            return Decision(
                shouldSetSidebarDividerSynchronously: false,
                sidebarWidthToPersist: nil,
                inspectorWidthToPersist: nil
            )

        case .userDraggedSidebar:
            return Decision(
                shouldSetSidebarDividerSynchronously: false,
                sidebarWidthToPersist: clampSidebarWidth(
                    currentSidebarWidth,
                    totalWidth: totalWidth,
                    currentInspectorWidth: currentInspectorWidth
                ),
                inspectorWidthToPersist: nil
            )

        case .userDraggedInspector:
            return Decision(
                shouldSetSidebarDividerSynchronously: false,
                sidebarWidthToPersist: nil,
                inspectorWidthToPersist: clampInspectorWidth(
                    currentInspectorWidth,
                    totalWidth: totalWidth,
                    currentSidebarWidth: currentSidebarWidth
                )
            )
        }
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
