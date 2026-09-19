import CoreGraphics

public enum SplitPaneSizing {
    public static func clampedDrawerExtent(
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

    public static func clampedDividerPosition(
        proposed: CGFloat,
        containerExtent: CGFloat,
        minimumLeadingExtent: CGFloat,
        minimumTrailingExtent: CGFloat
    ) -> CGFloat {
        let available = max(0, containerExtent)
        let leading = max(0, minimumLeadingExtent)
        let trailing = max(0, minimumTrailingExtent)
        // When the host shrinks below both minimums, share the remaining space
        // instead of placing the divider outside the container.
        let scale = leading + trailing > available ? available / max(1, leading + trailing) : 1
        let minimum = leading * scale
        let maximum = max(minimum, available - trailing * scale)
        return min(max(proposed, minimum), maximum)
    }
}
