import CoreGraphics

enum SplitPaneSizing {
    static func clampedDrawerExtent(
        proposed: CGFloat,
        containerExtent: CGFloat,
        minimumDrawerExtent: CGFloat,
        minimumSiblingExtent: CGFloat
    ) -> CGFloat {
        let maximumDrawerExtent = max(0, containerExtent - minimumSiblingExtent)

        if maximumDrawerExtent < minimumDrawerExtent {
            return min(max(proposed, 0), maximumDrawerExtent)
        }

        return min(max(proposed, minimumDrawerExtent), maximumDrawerExtent)
    }

    static func clampedDividerPosition(
        proposed: CGFloat,
        containerExtent: CGFloat,
        minimumLeadingExtent: CGFloat,
        minimumTrailingExtent: CGFloat
    ) -> CGFloat {
        let maximumDividerPosition = max(minimumLeadingExtent, containerExtent - minimumTrailingExtent)
        return min(max(proposed, minimumLeadingExtent), maximumDividerPosition)
    }
}
