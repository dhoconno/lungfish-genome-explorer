import AppKit

/// A split-pane host that keeps a scroll view filling the pane bounds and can
/// optionally constrain the document view to the clip-view width/height.
final class ScrollViewSplitPaneContainerView: SplitPaneFillContainerView {
    let scrollView: NSScrollView
    let documentView: NSView

    init(
        scrollView: NSScrollView,
        documentView: NSView,
        trackDocumentWidth: Bool = true,
        ensureMinimumDocumentHeight: Bool = true
    ) {
        self.scrollView = scrollView
        self.documentView = documentView
        super.init(frame: .zero)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.autoresizingMask = [.width, .height]

        documentView.translatesAutoresizingMaskIntoConstraints = false

        if trackDocumentWidth {
            documentView.widthAnchor.constraint(
                equalTo: scrollView.contentView.widthAnchor
            ).isActive = true
        }

        if ensureMinimumDocumentHeight {
            let minHeight = documentView.heightAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.heightAnchor
            )
            minHeight.priority = .defaultHigh
            minHeight.isActive = true
        }

        addSubview(scrollView)
        fillSubview = scrollView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { true }
}
