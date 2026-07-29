import AppKit

@MainActor
final class GenotypeSampleCurationHeaderView: NSView {
    enum LayoutMode: Equatable {
        case sideBySide
        case stacked
    }

    struct Metric: Equatable {
        let label: String
        let value: String
        var emphasized = false
    }

    private(set) var layoutMode: LayoutMode = .stacked
    let metricViews: [NSView]
    let metricFields: [(label: NSTextField, value: NSTextField)]

    private var typographyScale: CGFloat
    private let rootStack = NSStackView()
    private let statsStack = NSStackView()
    private var stackedConstraints: [NSLayoutConstraint] = []

    init(metrics: [Metric], typographyScale: CGFloat) {
        precondition(!metrics.isEmpty)
        self.typographyScale = max(1, typographyScale)
        let content = metrics.map(Self.makeMetricView)
        metricViews = content.map(\.view)
        metricFields = content.map { ($0.label, $0.value) }
        super.init(frame: .zero)
        configure()
        apply(.stacked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayoutMode(for: newSize.width)
    }

    func updateContentTypographyScale(_ scale: CGFloat) {
        let normalized = max(1, scale.isFinite ? scale : 1)
        guard normalized != typographyScale else { return }
        typographyScale = normalized
        updateLayoutMode(for: bounds.width)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        statsStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        statsStack.spacing = 16

        let sampleMetric = metricViews[0]
        rootStack.addArrangedSubview(sampleMetric)
        for metric in metricViews.dropFirst() {
            statsStack.addArrangedSubview(metric)
        }
        if metricViews.count > 1 {
            rootStack.addArrangedSubview(statsStack)
        }
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            sampleMetric.widthAnchor.constraint(
                equalTo: rootStack.widthAnchor
            ),
        ])
        if metricViews.count > 1 {
            statsStack.widthAnchor.constraint(
                equalTo: rootStack.widthAnchor
            ).isActive = true
            stackedConstraints = metricViews.dropFirst().map {
                $0.widthAnchor.constraint(
                    equalTo: statsStack.widthAnchor
                )
            }
        }
    }

    private func updateLayoutMode(for width: CGFloat) {
        let adjustment = min(
            320,
            max(0, typographyScale - 1) * 320
        )
        let enterWide = 700 + adjustment
        let leaveWide = 640 + adjustment
        switch layoutMode {
        case .stacked where width >= enterWide:
            apply(.sideBySide)
        case .sideBySide where width < leaveWide:
            apply(.stacked)
        default:
            break
        }
    }

    private func apply(_ mode: LayoutMode) {
        NSLayoutConstraint.deactivate(stackedConstraints)
        layoutMode = mode
        switch mode {
        case .sideBySide:
            statsStack.orientation = .horizontal
            statsStack.alignment = .top
            statsStack.distribution = .fillEqually
        case .stacked:
            statsStack.orientation = .vertical
            statsStack.alignment = .leading
            statsStack.distribution = .fill
            NSLayoutConstraint.activate(stackedConstraints)
        }
    }

    private static func makeMetricView(
        _ metric: Metric
    ) -> (
        view: NSView,
        label: NSTextField,
        value: NSTextField
    ) {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let label = NSTextField(wrappingLabelWithString: metric.label)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.setAccessibilityElement(false)
        label.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let value = NSTextField(wrappingLabelWithString: metric.value)
        value.font = .systemFont(
            ofSize: 11,
            weight: metric.emphasized ? .semibold : .regular
        )
        value.maximumNumberOfLines = 0
        value.lineBreakMode = .byWordWrapping
        value.usesSingleLineMode = false
        value.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        value.setAccessibilityElement(true)
        value.setAccessibilityLabel(
            "\(metric.label): \(metric.value)"
        )

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(value)
        return (stack, label, value)
    }
}

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

    private var typographyScale: CGFloat
    private let rootStack = NSStackView()
    private let bodyStack = NSStackView()
    private var stackedConstraints: [NSLayoutConstraint] = []
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
        self.typographyScale = Self.normalizedTypographyScale(typographyScale)
        super.init(frame: .zero)

        configureViewHierarchy()
        configureWidthConstraints()
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

    public func updateContentTypographyScale(_ newScale: CGFloat) {
        let normalizedScale = Self.normalizedTypographyScale(newScale)
        guard normalizedScale != typographyScale else { return }

        typographyScale = normalizedScale
        (headerView as? GenotypeSampleCurationHeaderView)?
            .updateContentTypographyScale(normalizedScale)
        updateLayoutMode(for: bounds.width)
    }

    private func configureViewHierarchy() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        assignmentView.translatesAutoresizingMaskIntoConstraints = false
        evidenceView.translatesAutoresizingMaskIntoConstraints = false
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
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

    private func configureWidthConstraints() {
        let headerWidth = headerView.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        headerWidth.identifier = "GenotypeSampleCurationWorkbench.headerWidth"
        let bodyWidth = bodyStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        bodyWidth.identifier = "GenotypeSampleCurationWorkbench.bodyWidth"
        NSLayoutConstraint.activate([headerWidth, bodyWidth])

        let assignmentWidth = assignmentView.widthAnchor.constraint(
            equalTo: bodyStack.widthAnchor
        )
        assignmentWidth.identifier = "GenotypeSampleCurationWorkbench.assignmentWidth"
        let evidenceWidth = evidenceView.widthAnchor.constraint(equalTo: bodyStack.widthAnchor)
        evidenceWidth.identifier = "GenotypeSampleCurationWorkbench.evidenceWidth"
        stackedConstraints = [assignmentWidth, evidenceWidth]

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
        NSLayoutConstraint.deactivate(stackedConstraints)
        NSLayoutConstraint.deactivate(sideBySideConstraints)
        layoutMode = newMode

        switch newMode {
        case .stacked:
            bodyStack.orientation = .vertical
            bodyStack.alignment = .leading
            NSLayoutConstraint.activate(stackedConstraints)
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

    private static func normalizedTypographyScale(_ scale: CGFloat) -> CGFloat {
        max(1, scale.isFinite ? scale : 1)
    }
}
