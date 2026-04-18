import CoreGraphics

enum MetagenomicsPaneSizing {
    static func clampedDrawerExtent(
        proposed: CGFloat,
        containerExtent: CGFloat,
        minimumDrawerExtent: CGFloat,
        minimumSiblingExtent: CGFloat
    ) -> CGFloat {
        let maximumDrawerExtent = max(0, containerExtent - minimumSiblingExtent)

        // If the container is too small to satisfy both minima, preserve the
        // sibling strip and let the drawer shrink below its preferred minimum.
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
