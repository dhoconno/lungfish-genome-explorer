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
    private let headerStack = NSStackView()
    private let contentHost = NSView()

    private let overviewView = GenotypeKnownAlleleOverviewView()
    private let overviewContent = NSView()
    private let overviewLayoutStack = NSStackView()
    private let factsRail = SemanticBackgroundView()
    private let locusValue = NSTextField(labelWithString: "")
    private let lengthValue = NSTextField(labelWithString: "")
    private let rolesValue = NSTextField(labelWithString: "")
    private let moleculeTypeValue = NSTextField(labelWithString: "")
    private let definitionValue = NSTextField(labelWithString: "")
    private let organismValue = NSTextField(labelWithString: "")
    private let productValue = NSTextField(labelWithString: "")
    private let exonCountValue = NSTextField(labelWithString: "")
    private let cdsLengthValue = NSTextField(labelWithString: "")
    private let proteinLengthValue = NSTextField(labelWithString: "")
    private let previousDesignationsValue = NSTextField(labelWithString: "")
    private let notesValue = NSTextField(labelWithString: "")
    private let observedSampleValue = NSTextField(labelWithString: "")
    private let factsScrollView = NSScrollView()
    private let factsDocumentView = NSView()
    private let factsStack = NSStackView()
    private let featureInformation = NSView()
    private let featureInformationText = NSTextField(
        wrappingLabelWithString: "Hover over or select a feature to inspect its annotation."
    )
    private let overviewCommentsView = KnownAlleleCommentsView()
    private let showGenBankButton = NSButton(title: "View GenBank", target: nil, action: nil)
    private let showFASTAButton = NSButton(title: "View FASTA", target: nil, action: nil)

    private let genBankScrollView: NSScrollView
    private let genBankTextView: NSTextView
    private let fastaScrollView: NSScrollView
    private let fastaTextView: NSTextView

    private let fallbackView = NSView()
    private let fallbackFieldsStack = NSStackView()
    private let fallbackObservedSample = NSTextField(labelWithString: "")
    private let fallbackCommentsView = KnownAlleleCommentsView()
    private let fallbackNote = NSTextField(
        wrappingLabelWithString: "A fresh analysis is required to generate graphical reference records."
    )

    private var activeContent: NSView?
    private var activeContentConstraints: [NSLayoutConstraint] = []
    private var isShowingFallback = false
    private var usesNarrowOverviewLayout: Bool?
    private var factsRailWidthConstraint: NSLayoutConstraint?
    private var narrowOverviewHeightConstraint: NSLayoutConstraint?
    private var narrowFactsHeightConstraint: NSLayoutConstraint?
    private var narrowOverviewWidthConstraint: NSLayoutConstraint?
    private var narrowFactsWidthConstraint: NSLayoutConstraint?
    private var comments: [(String, String)] = []
    private var overviewConfigurationCount = 0
    private var configuredOverviewRecord: ONTMHCReferenceVisualizationRecord?
    private(set) var testingCommentContentReplacementCount = 0

    var testingActiveContentConstraintIdentifiers: [ObjectIdentifier] {
        activeContentConstraints.map(ObjectIdentifier.init)
    }

    var testingOverviewConfigurationCount: Int {
        overviewConfigurationCount
    }

    override var intrinsicContentSize: NSSize {
        let height: CGFloat
        if isShowingFallback {
            height = 240 + commentContentHeight(isNarrow: bounds.width <= 0 || bounds.width < 560)
        } else {
            switch currentMode {
            case .overview:
                let isNarrow = bounds.width <= 0 || bounds.width < 560
                height = (isNarrow ? 610 : 340) + commentContentHeight(isNarrow: isNarrow)
            case .genBank, .fasta:
                height = 420
            }
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

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

    override func layout() {
        updateOverviewLayout(for: bounds.width)
        super.layout()
    }

    func configure(
        record: ONTMHCReferenceVisualizationRecord,
        observedSample: String?,
        comments: [(String, String)] = []
    ) {
        isShowingFallback = false
        alleleLabel.stringValue = record.alleleName
        rawReferenceIDLabel.stringValue = record.rawReferenceID
        locusValue.stringValue = record.locus ?? "—"
        lengthValue.stringValue = "\(record.sequence.count) bp"
        rolesValue.stringValue = Self.roleText(record.roles)
        moleculeTypeValue.stringValue = Self.moleculeType(in: record) ?? ""
        definitionValue.stringValue = Self.recordField("DEFINITION", in: record) ?? ""
        organismValue.stringValue = Self.organism(in: record) ?? ""
        productValue.stringValue = Self.products(in: record).joined(separator: "; ")
        exonCountValue.stringValue = Self.exonCount(in: record).map(String.init) ?? ""
        cdsLengthValue.stringValue = Self.cdsLength(in: record).map { "\($0) bp" } ?? ""
        proteinLengthValue.stringValue = Self.proteinLength(in: record).map { "\($0) aa" } ?? ""
        previousDesignationsValue.stringValue = Self.previousDesignations(in: record) ?? ""
        notesValue.stringValue = Self.notes(in: record).joined(separator: "; ")
        updateOptionalFactVisibility()
        observedSampleValue.stringValue = Self.observedSampleText(observedSample)
        observedSampleValue.isHidden = observedSampleValue.stringValue.isEmpty
        configureComments(comments)

        let shouldReconfigureOverview = configuredOverviewRecord != record
        if shouldReconfigureOverview {
            configuredOverviewRecord = record
            overviewConfigurationCount += 1
            overviewView.configure(record: record)
        }
        updateFeatureInformation(nil)
        genBankTextView.string = record.genBankText
        fastaTextView.string = record.fastaText

        modeSelector.isHidden = false
        show(mode: .overview)
        if shouldReconfigureOverview {
            layoutSubtreeIfNeeded()
        }
    }

    func configureFallback(
        alleleName: String,
        rawReferenceID: String,
        fields: [(String, String)],
        observedSample: String?,
        comments: [(String, String)] = []
    ) {
        isShowingFallback = true
        configuredOverviewRecord = nil
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
        configureComments(comments)
        modeSelector.isHidden = true
        currentMode = .overview
        updateModeButtonStates()
        installContent(fallbackView)
        invalidateIntrinsicContentSize()
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

        headerStack.addArrangedSubview(titleStack)
        headerStack.addArrangedSubview(modeSelector)
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.distribution = .fill
        headerStack.spacing = 16
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modeSelector.setContentHuggingPriority(.required, for: .horizontal)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStack)
        addSubview(contentHost)

        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 10),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        buildOverviewContent()
        buildFallbackContent()
    }

    private func buildOverviewContent() {
        overviewContent.setAccessibilityRole(.group)
        overviewView.translatesAutoresizingMaskIntoConstraints = false
        factsRail.translatesAutoresizingMaskIntoConstraints = false
        overviewLayoutStack.translatesAutoresizingMaskIntoConstraints = false
        overviewLayoutStack.distribution = .fill
        overviewLayoutStack.addArrangedSubview(overviewView)
        overviewLayoutStack.addArrangedSubview(factsRail)
        overviewContent.addSubview(overviewLayoutStack)

        NSLayoutConstraint.activate([
            overviewLayoutStack.leadingAnchor.constraint(equalTo: overviewContent.leadingAnchor),
            overviewLayoutStack.trailingAnchor.constraint(equalTo: overviewContent.trailingAnchor),
            overviewLayoutStack.topAnchor.constraint(equalTo: overviewContent.topAnchor),
            overviewLayoutStack.bottomAnchor.constraint(equalTo: overviewContent.bottomAnchor),
        ])
        factsRailWidthConstraint = factsRail.widthAnchor.constraint(equalToConstant: 238)
        narrowOverviewHeightConstraint = overviewView.heightAnchor.constraint(greaterThanOrEqualToConstant: 230)
        narrowFactsHeightConstraint = factsRail.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        narrowOverviewWidthConstraint = overviewView.widthAnchor.constraint(equalTo: overviewLayoutStack.widthAnchor)
        narrowFactsWidthConstraint = factsRail.widthAnchor.constraint(equalTo: overviewLayoutStack.widthAnchor)
        updateOverviewLayout(for: bounds.width)

        factsRail.setAccessibilityIdentifier("knownAlleleFactsRail")
        factsRail.setAccessibilityRole(.group)
        factsRail.setAccessibilityLabel("Known allele facts")

        locusValue.setAccessibilityIdentifier("knownAlleleLocus")
        lengthValue.setAccessibilityIdentifier("knownAlleleSequenceLength")
        rolesValue.setAccessibilityIdentifier("knownAlleleRoles")
        moleculeTypeValue.setAccessibilityIdentifier("knownAlleleMoleculeType")
        definitionValue.setAccessibilityIdentifier("knownAlleleDefinition")
        organismValue.setAccessibilityIdentifier("knownAlleleOrganism")
        productValue.setAccessibilityIdentifier("knownAlleleProduct")
        exonCountValue.setAccessibilityIdentifier("knownAlleleExonCount")
        cdsLengthValue.setAccessibilityIdentifier("knownAlleleCDSLength")
        proteinLengthValue.setAccessibilityIdentifier("knownAlleleProteinLength")
        previousDesignationsValue.setAccessibilityIdentifier("knownAllelePreviousDesignations")
        notesValue.setAccessibilityIdentifier("knownAlleleNotes")
        observedSampleValue.setAccessibilityIdentifier("knownAlleleObservedSample")

        factsStack.orientation = .vertical
        factsStack.alignment = .width
        factsStack.spacing = 7
        factsStack.translatesAutoresizingMaskIntoConstraints = false

        factsScrollView.borderType = .noBorder
        factsScrollView.drawsBackground = false
        factsScrollView.hasVerticalScroller = true
        factsScrollView.hasHorizontalScroller = false
        factsScrollView.autohidesScrollers = true
        factsScrollView.translatesAutoresizingMaskIntoConstraints = false
        factsDocumentView.translatesAutoresizingMaskIntoConstraints = false
        factsDocumentView.addSubview(factsStack)
        factsScrollView.documentView = factsDocumentView
        factsRail.addSubview(factsScrollView)

        factsStack.addArrangedSubview(makeFact(title: "Allele", value: alleleLabelCopy()))
        factsStack.addArrangedSubview(makeFact(title: "Reference ID", value: rawReferenceIDLabelCopy()))
        factsStack.addArrangedSubview(makeFact(title: "Locus", value: locusValue))
        factsStack.addArrangedSubview(makeFact(title: "Molecule type", value: moleculeTypeValue))
        factsStack.addArrangedSubview(makeFact(title: "Definition", value: definitionValue))
        factsStack.addArrangedSubview(makeFact(title: "Organism", value: organismValue))
        factsStack.addArrangedSubview(makeFact(title: "Product", value: productValue))
        factsStack.addArrangedSubview(makeFact(title: "Length", value: lengthValue))
        factsStack.addArrangedSubview(makeFact(title: "Exons", value: exonCountValue))
        factsStack.addArrangedSubview(makeFact(title: "CDS length", value: cdsLengthValue))
        factsStack.addArrangedSubview(makeFact(title: "Protein length", value: proteinLengthValue))
        factsStack.addArrangedSubview(makeFact(
            title: "Previous designations",
            value: previousDesignationsValue
        ))
        factsStack.addArrangedSubview(makeFact(title: "Notes", value: notesValue))
        factsStack.addArrangedSubview(makeFact(title: "Roles", value: rolesValue))

        buildFeatureInformation()
        factsStack.addArrangedSubview(featureInformation)
        featureInformation.widthAnchor.constraint(equalTo: factsStack.widthAnchor).isActive = true

        observedSampleValue.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        observedSampleValue.textColor = .secondaryLabelColor
        observedSampleValue.maximumNumberOfLines = 2
        observedSampleValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        factsStack.addArrangedSubview(observedSampleValue)
        factsStack.addArrangedSubview(overviewCommentsView)
        overviewCommentsView.widthAnchor.constraint(equalTo: factsStack.widthAnchor).isActive = true

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
            factsScrollView.leadingAnchor.constraint(equalTo: factsRail.leadingAnchor),
            factsScrollView.trailingAnchor.constraint(equalTo: factsRail.trailingAnchor),
            factsScrollView.topAnchor.constraint(equalTo: factsRail.topAnchor),
            factsScrollView.bottomAnchor.constraint(equalTo: factsRail.bottomAnchor),
            factsDocumentView.leadingAnchor.constraint(equalTo: factsScrollView.contentView.leadingAnchor),
            factsDocumentView.trailingAnchor.constraint(equalTo: factsScrollView.contentView.trailingAnchor),
            factsDocumentView.topAnchor.constraint(equalTo: factsScrollView.contentView.topAnchor),
            factsDocumentView.widthAnchor.constraint(equalTo: factsScrollView.contentView.widthAnchor),
            factsStack.leadingAnchor.constraint(equalTo: factsDocumentView.leadingAnchor, constant: 16),
            factsStack.trailingAnchor.constraint(equalTo: factsDocumentView.trailingAnchor, constant: -16),
            factsStack.topAnchor.constraint(equalTo: factsDocumentView.topAnchor, constant: 16),
            factsStack.bottomAnchor.constraint(equalTo: factsDocumentView.bottomAnchor, constant: -16),
        ])

        overviewView.onFeatureInspection = { [weak self] feature in
            self?.updateFeatureInformation(feature)
        }
    }

    private func buildFeatureInformation() {
        featureInformation.setAccessibilityIdentifier("knownAlleleFeatureInformation")
        featureInformation.setAccessibilityRole(.group)
        featureInformation.setAccessibilityLabel("Feature information")
        featureInformation.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "FEATURE")
        title.font = .systemFont(ofSize: 9, weight: .semibold)
        title.textColor = .tertiaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        featureInformationText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        featureInformationText.textColor = .labelColor
        featureInformationText.maximumNumberOfLines = 7
        featureInformationText.lineBreakMode = .byTruncatingTail
        featureInformationText.setAccessibilityIdentifier("knownAlleleFeatureInformationText")
        featureInformationText.translatesAutoresizingMaskIntoConstraints = false

        featureInformation.addSubview(title)
        featureInformation.addSubview(featureInformationText)
        NSLayoutConstraint.activate([
            featureInformation.heightAnchor.constraint(equalToConstant: 126),
            title.leadingAnchor.constraint(equalTo: featureInformation.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: featureInformation.trailingAnchor),
            title.topAnchor.constraint(equalTo: featureInformation.topAnchor),
            featureInformationText.leadingAnchor.constraint(equalTo: featureInformation.leadingAnchor),
            featureInformationText.trailingAnchor.constraint(equalTo: featureInformation.trailingAnchor),
            featureInformationText.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            featureInformationText.bottomAnchor.constraint(lessThanOrEqualTo: featureInformation.bottomAnchor),
        ])
    }

    private func updateOverviewLayout(for width: CGFloat) {
        guard let factsRailWidthConstraint,
              let narrowOverviewHeightConstraint,
              let narrowFactsHeightConstraint,
              let narrowOverviewWidthConstraint,
              let narrowFactsWidthConstraint else { return }
        let shouldUseNarrowLayout = width <= 0 || width < 560
        guard usesNarrowOverviewLayout != shouldUseNarrowLayout else { return }
        usesNarrowOverviewLayout = shouldUseNarrowLayout

        if shouldUseNarrowLayout {
            headerStack.orientation = .vertical
            headerStack.alignment = .leading
            headerStack.spacing = 6
            factsRailWidthConstraint.isActive = false
            overviewLayoutStack.orientation = .vertical
            overviewLayoutStack.alignment = .width
            overviewLayoutStack.spacing = 8
            NSLayoutConstraint.activate([
                narrowOverviewHeightConstraint,
                narrowFactsHeightConstraint,
                narrowOverviewWidthConstraint,
                narrowFactsWidthConstraint,
            ])
        } else {
            headerStack.orientation = .horizontal
            headerStack.alignment = .centerY
            headerStack.spacing = 16
            NSLayoutConstraint.deactivate([
                narrowOverviewHeightConstraint,
                narrowFactsHeightConstraint,
                narrowOverviewWidthConstraint,
                narrowFactsWidthConstraint,
            ])
            overviewLayoutStack.orientation = .horizontal
            overviewLayoutStack.alignment = .height
            overviewLayoutStack.spacing = 0
            factsRailWidthConstraint.isActive = true
        }
        invalidateIntrinsicContentSize()
        overviewContent.needsLayout = true
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

        let stack = NSStackView(views: [
            fallbackFieldsStack,
            fallbackObservedSample,
            fallbackCommentsView,
            fallbackNote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        fallbackView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fallbackView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: fallbackView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: fallbackView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: fallbackView.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            fallbackCommentsView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func configureComments(_ comments: [(String, String)]) {
        let commentsChanged = self.comments.count != comments.count
            || zip(self.comments, comments).contains { pair in
                pair.0.0 != pair.1.0 || pair.0.1 != pair.1.1
            }
        guard commentsChanged else { return }
        testingCommentContentReplacementCount += 1
        self.comments = comments
        overviewCommentsView.configure(comments)
        fallbackCommentsView.configure(comments)
        invalidateIntrinsicContentSize()
    }

    private func commentContentHeight(isNarrow: Bool) -> CGFloat {
        guard !comments.isEmpty else { return 0 }
        let charactersPerLine = isNarrow ? 54 : 28
        let rowsHeight = comments.reduce(CGFloat.zero) { height, comment in
            let bodyLineCount = max(
                1,
                Int(ceil(Double(max(1, comment.1.count)) / Double(charactersPerLine)))
            )
            return height + 17 + (CGFloat(bodyLineCount) * 14) + 7
        }
        return 22 + rowsHeight
    }

    private func updateOptionalFactVisibility() {
        for value in [
            moleculeTypeValue,
            definitionValue,
            organismValue,
            productValue,
            exonCountValue,
            cdsLengthValue,
            proteinLengthValue,
            previousDesignationsValue,
            notesValue,
        ] {
            value.superview?.isHidden = value.stringValue.isEmpty
        }
    }

    private func updateFeatureInformation(
        _ feature: ONTMHCReferenceVisualizationFeature?
    ) {
        guard let feature else {
            featureInformationText.stringValue =
                "Hover over or select a feature to inspect its annotation."
            return
        }

        var lines = [feature.type.localizedCapitalized]
        if let number = Self.qualifierValue(in: feature, keys: ["exon_number", "number"]) {
            lines.append("Number: \(number)")
        }
        lines.append("Coordinates: \(feature.start + 1)–\(feature.end) (\(feature.end - feature.start) bp)")
        if !feature.strand.isEmpty {
            lines.append("Strand: \(feature.strand)")
        }
        if let sourceLocation = feature.rawGenBankLocation, !sourceLocation.isEmpty {
            lines.append("Source location: \(sourceLocation)")
        }

        for key in feature.qualifiers.keys.sorted(by: {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }) {
            guard !["exon_number", "number"].contains(where: {
                $0.caseInsensitiveCompare(key) == .orderedSame
            }) else { continue }
            let values = feature.qualifiers[key, default: []].filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            let title = key.replacingOccurrences(of: "_", with: " ").capitalized
            if key.caseInsensitiveCompare("translation") == .orderedSame {
                let length = values[0].filter { !$0.isWhitespace }.count
                lines.append("\(title): \(length) aa")
            } else {
                lines.append("\(title): \(values.joined(separator: "; "))")
            }
        }
        featureInformationText.stringValue = lines.joined(separator: "\n")
    }

    private func makeFact(title: String, value: NSTextField) -> NSView {
        let titleField = NSTextField(labelWithString: title.uppercased())
        titleField.font = .systemFont(ofSize: 9, weight: .semibold)
        titleField.textColor = .tertiaryLabelColor
        value.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        value.textColor = .labelColor
        value.maximumNumberOfLines = 2
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleField, value])
        stack.orientation = .vertical
        stack.alignment = .width
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
        invalidateIntrinsicContentSize()
    }

    private func updateModeButtonStates() {
        for button in [modeOverviewButton, modeGenBankButton, modeFASTAButton] {
            button.state = button.tag == currentMode.rawValue ? .on : .off
        }
    }

    private func installContent(_ view: NSView) {
        guard activeContent !== view else { return }
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
            case .closestUnnameableReference:
                return "Closest un-nameable reference"
            }
        }.joined(separator: ", ")
    }

    private static func observedSampleText(_ sample: String?) -> String {
        guard let sample, !sample.isEmpty else { return "" }
        return "Observed in sample \(sample)"
    }

    private static func recordField(
        _ key: String,
        in record: ONTMHCReferenceVisualizationRecord
    ) -> String? {
        record.recordFields.keys.sorted().first(where: {
            $0.caseInsensitiveCompare(key) == .orderedSame
        }).flatMap { actualKey in
            joinedUnique(record.recordFields[actualKey, default: []])
        }
    }

    private static func moleculeType(
        in record: ONTMHCReferenceVisualizationRecord
    ) -> String? {
        recordField("LOCUS.MOLECULE_TYPE", in: record)
            ?? qualifierValues(in: record.features, key: "mol_type").first
    }

    private static func organism(
        in record: ONTMHCReferenceVisualizationRecord
    ) -> String? {
        recordField("ORGANISM", in: record)
            ?? qualifierValues(in: record.features, key: "organism").first
            ?? recordField("SOURCE", in: record)
    }

    private static func products(
        in record: ONTMHCReferenceVisualizationRecord
    ) -> [String] {
        unique(qualifierValues(
            in: record.features.filter {
                $0.type.caseInsensitiveCompare("CDS") == .orderedSame
            },
            key: "product"
        ))
    }

    private static func exonCount(
        in record: ONTMHCReferenceVisualizationRecord
    ) -> Int? {
        let ordinals = Set(record.features.filter {
            $0.type.caseInsensitiveCompare("exon") == .orderedSame
        }.map(\.sourceOrdinal))
        return ordinals.isEmpty ? nil : ordinals.count
    }

    private static func cdsLength(
        in record: ONTMHCReferenceVisualizationRecord
    ) -> Int? {
        let codingFeatures = record.features.filter {
            $0.type.caseInsensitiveCompare("CDS") == .orderedSame
        }
        guard !codingFeatures.isEmpty else { return nil }
        let sourceOrdinal = record.annotatedTranslation.flatMap { translation in
            codingFeatures.first(where: {
                qualifierValues(in: [$0], key: "translation").contains(translation)
            })?.sourceOrdinal
        } ?? codingFeatures[0].sourceOrdinal
        return codingFeatures.lazy
            .filter { $0.sourceOrdinal == sourceOrdinal }
            .reduce(0) { $0 + ($1.end - $1.start) }
    }

    private static func proteinLength(
        in record: ONTMHCReferenceVisualizationRecord
    ) -> Int? {
        guard let translation = record.annotatedTranslation, !translation.isEmpty else {
            return nil
        }
        return translation.filter { !$0.isWhitespace }.count
    }

    private static func previousDesignations(
        in record: ONTMHCReferenceVisualizationRecord
    ) -> String? {
        let notes = qualifierValues(in: record.features, key: "note")
        if let note = notes.first(where: {
            $0.range(of: "previous designations:", options: .caseInsensitive) != nil
        }), let separator = note.firstIndex(of: ":") {
            let value = note[note.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        let key = record.recordFields.keys.sorted().first(where: {
            $0.range(of: "previous designations", options: .caseInsensitive) != nil
        })
        return key.flatMap { joinedUnique(record.recordFields[$0, default: []]) }
    }

    private static func notes(
        in record: ONTMHCReferenceVisualizationRecord
    ) -> [String] {
        unique(qualifierValues(in: record.features, key: "note").filter {
            $0.range(of: "previous designations:", options: .caseInsensitive) == nil
        })
    }

    private static func qualifierValue(
        in feature: ONTMHCReferenceVisualizationFeature,
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = qualifierValues(in: [feature], key: key).first {
                return value
            }
        }
        return nil
    }

    private static func qualifierValues(
        in features: [ONTMHCReferenceVisualizationFeature],
        key: String
    ) -> [String] {
        features.flatMap { feature in
            feature.qualifiers.keys.sorted().first(where: {
                $0.caseInsensitiveCompare(key) == .orderedSame
            }).map { feature.qualifiers[$0, default: []] } ?? []
        }.filter { !$0.isEmpty }
    }

    private static func joinedUnique(_ values: [String]) -> String? {
        let values = unique(values)
        return values.isEmpty ? nil : values.joined(separator: "; ")
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            !value.isEmpty && seen.insert(value).inserted
        }
    }
}

@MainActor
private final class KnownAlleleCommentsView: NSStackView {
    private let rowsStack = NSStackView()

    init() {
        super.init(frame: .zero)
        buildHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildHierarchy()
    }

    func configure(_ comments: [(String, String)]) {
        rowsStack.arrangedSubviews.forEach { view in
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, comment) in comments.enumerated() {
            let label = NSTextField(labelWithString: comment.0)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityIdentifier("knownAlleleCommentLabel.\(index)")

            let body = NSTextField(wrappingLabelWithString: comment.1)
            body.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            body.textColor = .labelColor
            body.maximumNumberOfLines = 0
            body.lineBreakMode = .byWordWrapping
            body.setAccessibilityIdentifier("knownAlleleCommentBody.\(index)")

            let row = NSStackView(views: [label, body])
            row.orientation = .vertical
            row.alignment = .width
            row.spacing = 2
            row.setAccessibilityRole(.group)
            row.setAccessibilityIdentifier("knownAlleleCommentRow.\(index)")
            rowsStack.addArrangedSubview(row)
        }

        let shouldHide = comments.isEmpty
        if isHidden != shouldHide {
            isHidden = shouldHide
        }
    }

    private func buildHierarchy() {
        orientation = .vertical
        alignment = .width
        spacing = 6
        setAccessibilityRole(.group)
        setAccessibilityLabel("Comments")
        setAccessibilityIdentifier("knownAlleleCommentsSection")

        let title = NSTextField(labelWithString: "Comments")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.setAccessibilityIdentifier("knownAlleleCommentsTitle")

        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 7
        addArrangedSubview(title)
        addArrangedSubview(rowsStack)
        isHidden = true
    }
}

@MainActor
private final class SemanticBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.controlBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
