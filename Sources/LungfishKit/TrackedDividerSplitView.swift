import AppKit

/// `NSSplitView` does not always preserve the requested divider position across
/// subsequent constraint-based relayouts. Track the last requested divider
/// position so controllers can re-apply it when AppKit snaps back.
public final class TrackedDividerSplitView: NSSplitView {
    private var requestedDividerPositions: [Int: CGFloat] = [:]

    public override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        requestedDividerPositions[dividerIndex] = position
        super.setPosition(position, ofDividerAt: dividerIndex)
    }

    public func requestedDividerPosition(at dividerIndex: Int) -> CGFloat? {
        requestedDividerPositions[dividerIndex]
    }

    public func recordObservedDividerPosition(_ position: CGFloat, at dividerIndex: Int = 0) {
        requestedDividerPositions[dividerIndex] = position
    }

    public func clearRequestedDividerPosition(at dividerIndex: Int = 0) {
        requestedDividerPositions.removeValue(forKey: dividerIndex)
    }
}
