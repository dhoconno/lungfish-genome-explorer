import CoreGraphics

@MainActor
final class SplitShellWidthCoordinator {
    private(set) var lastObservedWidth: CGFloat?
    private(set) var hasExplicitUserResize = false

    private(set) var isApplyingProgrammaticWidth = false
    private var pendingProgrammaticWidth: CGFloat?
    private var explicitUserWidth: CGFloat?

    func noteProgrammaticWidth(_ width: CGFloat) {
        isApplyingProgrammaticWidth = true
        pendingProgrammaticWidth = width
        lastObservedWidth = width
    }

    func finishProgrammaticWidth() {
        isApplyingProgrammaticWidth = false
    }

    func noteUserRequestedWidth(_ width: CGFloat) {
        explicitUserWidth = width
        hasExplicitUserResize = true
        lastObservedWidth = width
    }

    func noteObservedWidth(_ width: CGFloat) {
        if let pendingProgrammaticWidth,
           abs(width - pendingProgrammaticWidth) < 4 {
            lastObservedWidth = width
            self.pendingProgrammaticWidth = nil
            return
        }

        lastObservedWidth = width
    }

    func recommendedWidthToApply(
        proposedWidth: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat,
        currentWidth: CGFloat,
        allowShrink: Bool
    ) -> CGFloat? {
        guard !hasExplicitUserResize else { return nil }

        let clamped = min(max(proposedWidth, minimumWidth), maximumWidth)
        let target = allowShrink ? clamped : max(currentWidth, clamped)
        return abs(target - currentWidth) >= 1 ? target : nil
    }

    func restoredUserWidthToApply(
        currentWidth: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> CGFloat? {
        guard let explicitUserWidth else { return nil }

        let clamped = min(max(explicitUserWidth, minimumWidth), maximumWidth)
        return abs(clamped - currentWidth) >= 2 ? clamped : nil
    }
}
