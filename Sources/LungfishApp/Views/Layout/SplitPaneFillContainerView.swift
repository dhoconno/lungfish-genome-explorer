import AppKit

/// A frame-managed split-pane host that keeps one designated subview filling the
/// pane bounds even when the parent `NSSplitView` performs direct frame updates.
class SplitPaneFillContainerView: NSView {
    var fillSubview: NSView? {
        didSet {
            syncFillSubviewFrameIfNeeded()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncFillSubviewFrameIfNeeded()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        syncFillSubviewFrameIfNeeded()
    }

    override func layout() {
        super.layout()
        syncFillSubviewFrameIfNeeded()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        syncFillSubviewFrameIfNeeded()
    }

    func syncFillSubviewFrameIfNeeded() {
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
final class FlippedSplitPaneFillContainerView: SplitPaneFillContainerView {
    override var isFlipped: Bool { true }
}
