import AppKit

/// Hosts sample-level curation controls without taking ownership of scrolling.
@MainActor
public final class GenotypeSampleCurationWorkbenchView: NSView {
    public enum LayoutMode: Equatable {
        case stacked
        case sideBySide
    }

    public let headerView: NSView
    public let assignmentView: NSView
    public let evidenceView: NSView

    public private(set) var layoutMode: LayoutMode = .stacked

    private let typographyScale: CGFloat
    private let rootStack = NSStackView()
    private let bodyStack = NSStackView()
    private var sideBySideConstraints: [NSLayoutConstraint] = []

    public init(
        headerView: NSView,
        assignmentView: NSView,
        evidenceView: NSView,
        typographyScale: CGFloat = 1
    ) {
        self.headerView = headerView
        self.assignmentView = assignmentView
        self.evidenceView = evidenceView
        self.typographyScale = max(1, typographyScale.isFinite ? typographyScale : 1)
        super.init(frame: .zero)

        configureViewHierarchy()
        configureSideBySideConstraints()
        applyLayoutMode(.stacked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayoutMode(for: newSize.width)
    }

    private func configureViewHierarchy() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        assignmentView.translatesAutoresizingMaskIntoConstraints = false
        evidenceView.translatesAutoresizingMaskIntoConstraints = false
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.distribution = .fill
        rootStack.spacing = 12

        bodyStack.distribution = .fill
        bodyStack.spacing = 16
        bodyStack.addArrangedSubview(assignmentView)
        bodyStack.addArrangedSubview(evidenceView)

        rootStack.addArrangedSubview(headerView)
        rootStack.addArrangedSubview(bodyStack)
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureSideBySideConstraints() {
        let preferredEditorWidth = assignmentView.widthAnchor.constraint(
            equalTo: bodyStack.widthAnchor,
            multiplier: 0.62
        )
        preferredEditorWidth.priority = .defaultHigh

        sideBySideConstraints = [
            assignmentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            assignmentView.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            evidenceView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            preferredEditorWidth,
        ]
    }

    private func updateLayoutMode(for width: CGFloat) {
        switch layoutMode {
        case .stacked where width >= sideBySideEntryWidth:
            applyLayoutMode(.sideBySide)
        case .sideBySide where width < stackedEntryWidth:
            applyLayoutMode(.stacked)
        default:
            break
        }
    }

    private func applyLayoutMode(_ newMode: LayoutMode) {
        NSLayoutConstraint.deactivate(sideBySideConstraints)
        layoutMode = newMode

        switch newMode {
        case .stacked:
            bodyStack.orientation = .vertical
            bodyStack.alignment = .width
        case .sideBySide:
            bodyStack.orientation = .horizontal
            bodyStack.alignment = .height
            NSLayoutConstraint.activate(sideBySideConstraints)
        }
    }

    private var breakpointAdjustment: CGFloat {
        min(240, max(0, (typographyScale - 1) * 240))
    }

    private var sideBySideEntryWidth: CGFloat {
        840 + breakpointAdjustment
    }

    private var stackedEntryWidth: CGFloat {
        780 + breakpointAdjustment
    }
}
