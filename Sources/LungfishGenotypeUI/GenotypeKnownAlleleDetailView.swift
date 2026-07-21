import AppKit
import LungfishIO

/// Standalone detail component for a known MHC reference allele.
@MainActor
final class GenotypeKnownAlleleDetailView: NSView {
    enum Mode: Int {
        case overview
        case genBank
        case fasta
    }

    private(set) var currentMode: Mode = .overview

    private let alleleLabel = NSTextField(labelWithString: "")
    private let rawReferenceIDLabel = NSTextField(labelWithString: "")
    private let modeSelector = NSStackView()
    private let modeOverviewButton = NSButton(title: "Overview", target: nil, action: nil)
    private let modeGenBankButton = NSButton(title: "GenBank", target: nil, action: nil)
    private let modeFASTAButton = NSButton(title: "FASTA", target: nil, action: nil)
    private let contentHost = NSView()

    private let overviewView = GenotypeKnownAlleleOverviewView()
    private let overviewContent = NSView()
    private let factsRail = NSView()
    private let locusValue = NSTextField(labelWithString: "")
    private let lengthValue = NSTextField(labelWithString: "")
    private let rolesValue = NSTextField(labelWithString: "")
    private let observedSampleValue = NSTextField(labelWithString: "")
    private let showGenBankButton = NSButton(title: "View GenBank", target: nil, action: nil)
    private let showFASTAButton = NSButton(title: "View FASTA", target: nil, action: nil)

    private let genBankScrollView: NSScrollView
    private let genBankTextView: NSTextView
    private let fastaScrollView: NSScrollView
    private let fastaTextView: NSTextView

    private let fallbackView = NSView()
    private let fallbackFieldsStack = NSStackView()
    private let fallbackObservedSample = NSTextField(labelWithString: "")
    private let fallbackNote = NSTextField(
        wrappingLabelWithString: "A fresh analysis is required to generate graphical reference records."
    )

    private var activeContent: NSView?
    private var activeContentConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        (genBankScrollView, genBankTextView) = Self.makeTextHost(
            identifier: "knownAlleleGenBankTextView",
            label: "GenBank record"
        )
        (fastaScrollView, fastaTextView) = Self.makeTextHost(
            identifier: "knownAlleleFASTATextView",
            label: "FASTA record"
        )
        super.init(frame: frameRect)
        buildHierarchy()
    }

    required init?(coder: NSCoder) {
        (genBankScrollView, genBankTextView) = Self.makeTextHost(
            identifier: "knownAlleleGenBankTextView",
            label: "GenBank record"
        )
        (fastaScrollView, fastaTextView) = Self.makeTextHost(
            identifier: "knownAlleleFASTATextView",
            label: "FASTA record"
        )
        super.init(coder: coder)
        buildHierarchy()
    }

    func configure(record: ONTMHCReferenceVisualizationRecord, observedSample: String?) {
        alleleLabel.stringValue = record.alleleName
        rawReferenceIDLabel.stringValue = record.rawReferenceID
        locusValue.stringValue = record.locus ?? "—"
        lengthValue.stringValue = "\(record.sequence.count) bp"
        rolesValue.stringValue = Self.roleText(record.roles)
        observedSampleValue.stringValue = Self.observedSampleText(observedSample)
        observedSampleValue.isHidden = observedSampleValue.stringValue.isEmpty

        overviewView.configure(record: record)
        genBankTextView.string = record.genBankText
        fastaTextView.string = record.fastaText

        modeSelector.isHidden = false
        show(mode: .overview)
    }

    func configureFallback(
        alleleName: String,
        rawReferenceID: String,
        fields: [(String, String)],
        observedSample: String?
    ) {
        alleleLabel.stringValue = alleleName
        rawReferenceIDLabel.stringValue = rawReferenceID
        fallbackFieldsStack.arrangedSubviews.forEach {
            fallbackFieldsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (name, value) in fields {
            let field = NSTextField(wrappingLabelWithString: "\(name): \(value)")
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .labelColor
            fallbackFieldsStack.addArrangedSubview(field)
        }

        fallbackObservedSample.stringValue = Self.observedSampleText(observedSample)
        fallbackObservedSample.isHidden = fallbackObservedSample.stringValue.isEmpty
        modeSelector.isHidden = true
        currentMode = .overview
        updateModeButtonStates()
        installContent(fallbackView)
    }

    private func buildHierarchy() {
        setAccessibilityRole(.group)
        setAccessibilityLabel("Known allele detail")

        alleleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        alleleLabel.lineBreakMode = .byTruncatingMiddle
        alleleLabel.setAccessibilityIdentifier("knownAlleleAlleleLabel")

        rawReferenceIDLabel.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        rawReferenceIDLabel.textColor = .secondaryLabelColor
        rawReferenceIDLabel.lineBreakMode = .byTruncatingMiddle
        rawReferenceIDLabel.setAccessibilityIdentifier("knownAlleleRawReferenceID")

        let titleStack = NSStackView(views: [alleleLabel, rawReferenceIDLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        configureModeButton(
            modeOverviewButton,
            mode: .overview,
            identifier: "knownAlleleModeOverview"
        )
        configureModeButton(
            modeGenBankButton,
            mode: .genBank,
            identifier: "knownAlleleModeGenBank"
        )
        configureModeButton(
            modeFASTAButton,
            mode: .fasta,
            identifier: "knownAlleleModeFASTA"
        )
        modeSelector.addArrangedSubview(modeOverviewButton)
        modeSelector.addArrangedSubview(modeGenBankButton)
        modeSelector.addArrangedSubview(modeFASTAButton)
        modeSelector.orientation = .horizontal
        modeSelector.alignment = .centerY
        modeSelector.spacing = 0
        modeSelector.setAccessibilityIdentifier("knownAlleleModeControl")
        modeSelector.setAccessibilityRole(.group)
        modeSelector.setAccessibilityLabel("Known allele detail mode")

        let header = NSStackView(views: [titleStack, modeSelector])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 16
        header.translatesAutoresizingMaskIntoConstraints = false
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modeSelector.setContentHuggingPriority(.required, for: .horizontal)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(contentHost)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        buildOverviewContent()
        buildFallbackContent()
    }

    private func buildOverviewContent() {
        overviewContent.setAccessibilityRole(.group)
        overviewView.translatesAutoresizingMaskIntoConstraints = false
        factsRail.translatesAutoresizingMaskIntoConstraints = false
        overviewContent.addSubview(overviewView)
        overviewContent.addSubview(factsRail)

        NSLayoutConstraint.activate([
            overviewView.leadingAnchor.constraint(equalTo: overviewContent.leadingAnchor),
            overviewView.topAnchor.constraint(equalTo: overviewContent.topAnchor),
            overviewView.bottomAnchor.constraint(equalTo: overviewContent.bottomAnchor),
            overviewView.trailingAnchor.constraint(equalTo: factsRail.leadingAnchor),
            factsRail.trailingAnchor.constraint(equalTo: overviewContent.trailingAnchor),
            factsRail.topAnchor.constraint(equalTo: overviewContent.topAnchor),
            factsRail.bottomAnchor.constraint(equalTo: overviewContent.bottomAnchor),
            factsRail.widthAnchor.constraint(equalToConstant: 238),
        ])

        factsRail.setAccessibilityIdentifier("knownAlleleFactsRail")
        factsRail.setAccessibilityRole(.group)
        factsRail.setAccessibilityLabel("Known allele facts")
        factsRail.wantsLayer = true
        factsRail.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        locusValue.setAccessibilityIdentifier("knownAlleleLocus")
        lengthValue.setAccessibilityIdentifier("knownAlleleSequenceLength")
        rolesValue.setAccessibilityIdentifier("knownAlleleRoles")
        observedSampleValue.setAccessibilityIdentifier("knownAlleleObservedSample")

        let factsStack = NSStackView()
        factsStack.orientation = .vertical
        factsStack.alignment = .leading
        factsStack.spacing = 7
        factsStack.translatesAutoresizingMaskIntoConstraints = false
        factsRail.addSubview(factsStack)

        factsStack.addArrangedSubview(makeFact(title: "Allele", value: alleleLabelCopy()))
        factsStack.addArrangedSubview(makeFact(title: "Reference ID", value: rawReferenceIDLabelCopy()))
        factsStack.addArrangedSubview(makeFact(title: "Locus", value: locusValue))
        factsStack.addArrangedSubview(makeFact(title: "Length", value: lengthValue))
        factsStack.addArrangedSubview(makeFact(title: "Roles", value: rolesValue))

        observedSampleValue.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        observedSampleValue.textColor = .secondaryLabelColor
        observedSampleValue.maximumNumberOfLines = 2
        factsStack.addArrangedSubview(observedSampleValue)

        showGenBankButton.target = self
        showGenBankButton.action = #selector(showGenBank(_:))
        showGenBankButton.bezelStyle = .rounded
        showGenBankButton.controlSize = .small
        showGenBankButton.setAccessibilityIdentifier("knownAlleleShowGenBankButton")

        showFASTAButton.target = self
        showFASTAButton.action = #selector(showFASTA(_:))
        showFASTAButton.bezelStyle = .rounded
        showFASTAButton.controlSize = .small
        showFASTAButton.setAccessibilityIdentifier("knownAlleleShowFASTAButton")

        let actions = NSStackView(views: [showGenBankButton, showFASTAButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        factsStack.addArrangedSubview(actions)

        NSLayoutConstraint.activate([
            factsStack.leadingAnchor.constraint(equalTo: factsRail.leadingAnchor, constant: 16),
            factsStack.trailingAnchor.constraint(equalTo: factsRail.trailingAnchor, constant: -16),
            factsStack.topAnchor.constraint(equalTo: factsRail.topAnchor, constant: 16),
            factsStack.bottomAnchor.constraint(lessThanOrEqualTo: factsRail.bottomAnchor, constant: -16),
        ])
    }

    private func buildFallbackContent() {
        fallbackView.setAccessibilityRole(.group)
        fallbackView.setAccessibilityLabel("Legacy known allele metadata")

        fallbackFieldsStack.orientation = .vertical
        fallbackFieldsStack.alignment = .leading
        fallbackFieldsStack.spacing = 6

        fallbackObservedSample.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .medium
        )
        fallbackObservedSample.textColor = .secondaryLabelColor
        fallbackObservedSample.setAccessibilityIdentifier("knownAlleleObservedSample")

        fallbackNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fallbackNote.textColor = .secondaryLabelColor
        fallbackNote.setAccessibilityIdentifier("knownAlleleFallbackNote")

        let stack = NSStackView(views: [fallbackFieldsStack, fallbackObservedSample, fallbackNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        fallbackView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fallbackView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: fallbackView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: fallbackView.topAnchor, constant: 16),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
    }

    private func makeFact(title: String, value: NSTextField) -> NSView {
        let titleField = NSTextField(labelWithString: title.uppercased())
        titleField.font = .systemFont(ofSize: 9, weight: .semibold)
        titleField.textColor = .tertiaryLabelColor
        value.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        value.textColor = .labelColor
        value.maximumNumberOfLines = 2
        value.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleField, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    private func alleleLabelCopy() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.bind(.value, to: alleleLabel, withKeyPath: "stringValue")
        return label
    }

    private func rawReferenceIDLabelCopy() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.bind(.value, to: rawReferenceIDLabel, withKeyPath: "stringValue")
        return label
    }

    private func configureModeButton(
        _ button: NSButton,
        mode: Mode,
        identifier: String
    ) {
        button.setButtonType(.toggle)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(modeButtonPressed(_:))
        button.tag = mode.rawValue
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(button.title)
    }

    @objc private func modeButtonPressed(_ sender: NSButton) {
        guard let mode = Mode(rawValue: sender.tag) else { return }
        show(mode: mode)
    }

    @objc private func showGenBank(_ sender: Any?) {
        show(mode: .genBank)
    }

    @objc private func showFASTA(_ sender: Any?) {
        show(mode: .fasta)
    }

    private func show(mode: Mode) {
        currentMode = mode
        updateModeButtonStates()
        switch mode {
        case .overview:
            installContent(overviewContent)
        case .genBank:
            installContent(genBankScrollView)
        case .fasta:
            installContent(fastaScrollView)
        }
    }

    private func updateModeButtonStates() {
        for button in [modeOverviewButton, modeGenBankButton, modeFASTAButton] {
            button.state = button.tag == currentMode.rawValue ? .on : .off
        }
    }

    private func installContent(_ view: NSView) {
        NSLayoutConstraint.deactivate(activeContentConstraints)
        activeContent?.removeFromSuperview()

        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        activeContent = view
        activeContentConstraints = [
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ]
        NSLayoutConstraint.activate(activeContentConstraints)
        layoutSubtreeIfNeeded()
    }

    private static func makeTextHost(
        identifier: String,
        label: String
    ) -> (NSScrollView, NSTextView) {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier(identifier)
        textView.setAccessibilityLabel(label)

        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private static func roleText(
        _ assignments: [ONTMHCReferenceVisualizationRoleAssignment]
    ) -> String {
        var seen: Set<ONTMHCReferenceVisualizationRole> = []
        return assignments.compactMap { assignment in
            guard seen.insert(assignment.role).inserted else { return nil }
            switch assignment.role {
            case .exactKnownCall:
                return "Exact known call"
            case .closestNovelReference:
                return "Closest novel reference"
            case .closestExtensionReference:
                return "Closest extension reference"
            }
        }.joined(separator: ", ")
    }

    private static func observedSampleText(_ sample: String?) -> String {
        guard let sample, !sample.isEmpty else { return "" }
        return "Observed in sample \(sample)"
    }
}
