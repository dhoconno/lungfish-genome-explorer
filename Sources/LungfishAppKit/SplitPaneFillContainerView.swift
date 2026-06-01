import AppKit

/// A frame-managed split-pane host that keeps one designated subview filling the
/// pane bounds even when the parent `NSSplitView` performs direct frame updates.
open class SplitPaneFillContainerView: NSView {
    public var fillSubview: NSView? {
        didSet {
            syncFillSubviewFrameIfNeeded()
        }
    }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncFillSubviewFrameIfNeeded()
    }

    open override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        syncFillSubviewFrameIfNeeded()
    }

    open override func layout() {
        super.layout()
        syncFillSubviewFrameIfNeeded()
    }

    open override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        syncFillSubviewFrameIfNeeded()
    }

    public func syncFillSubviewFrameIfNeeded() {
        guard let fillSubview else { return }
        guard abs(fillSubview.frame.width - bounds.width) > 0.5
                || abs(fillSubview.frame.height - bounds.height) > 0.5
        else { return }
        fillSubview.frame = bounds
        fillSubview.needsLayout = true
        fillSubview.layoutSubtreeIfNeeded()
    }
}

/// Flipped variant of ``SplitPaneFillContainerView`` for top-anchored AppKit layouts.
public final class FlippedSplitPaneFillContainerView: SplitPaneFillContainerView {
    public override var isFlipped: Bool { true }
}
