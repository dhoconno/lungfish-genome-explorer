import AppKit

/// A split-pane container that keeps a header view above a fill content view
/// using frame-based layout, so content fitting widths do not fight the parent
/// split view's divider math.
final class SplitPaneHeaderContainerView: NSView {
    let headerView: NSView
    let contentView: NSView

    var topInset: CGFloat
    var sideInset: CGFloat
    var bottomInset: CGFloat
    var spacing: CGFloat

    init(
        headerView: NSView,
        contentView: NSView,
        topInset: CGFloat = 6,
        sideInset: CGFloat = 6,
        bottomInset: CGFloat = 0,
        spacing: CGFloat = 6
    ) {
        self.headerView = headerView
        self.contentView = contentView
        self.topInset = topInset
        self.sideInset = sideInset
        self.bottomInset = bottomInset
        self.spacing = spacing
        super.init(frame: .zero)

        addSubview(headerView)
        addSubview(contentView)
        layoutPaneSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutPaneSubviews()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutPaneSubviews()
    }

    private func layoutPaneSubviews() {
        let contentWidth = max(0, bounds.width - (sideInset * 2))
        let headerHeight = max(0, headerView.fittingSize.height)
        headerView.frame = NSRect(x: sideInset, y: topInset, width: contentWidth, height: headerHeight)

        let contentY = topInset + headerHeight + spacing
        let contentHeight = max(0, bounds.height - contentY - bottomInset)
        contentView.frame = NSRect(x: 0, y: contentY, width: bounds.width, height: contentHeight)
    }
}
