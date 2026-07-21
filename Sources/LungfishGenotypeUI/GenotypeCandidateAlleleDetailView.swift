import AppKit
import Foundation
import LungfishIO

/// Persistent candidate-allele detail backed only by validated, preloaded result artifacts.
@MainActor
final class GenotypeCandidateAlleleDetailView: NSView {
    enum Mode: Int {
        case overview
        case genBank
        case fasta
    }

    private(set) var currentMode: Mode = .overview

    var differenceTrackConfigurationCount: Int {
        differenceTrack.configurationCount
    }

    private let alleleNameLabel = NSTextField(labelWithString: "")
    private let stableClusterIDLabel = NSTextField(labelWithString: "")
    private let modeControl = NSStackView()
    private let overviewModeButton = NSButton(title: "Overview", target: nil, action: nil)
    private let genBankModeButton = NSButton(title: "GenBank", target: nil, action: nil)
    private let fastaModeButton = NSButton(title: "FASTA", target: nil, action: nil)
    private let headerStack = NSStackView()
    private let contentHost = NSView()

    private let overviewContent = NSView()
    private let closestReferenceColumn = NSStackView()
    private let closestReferenceGeometryLabel = NSTextField(labelWithString: "")
    private let closestReferenceOverviewCanvas = NSView()
    private let closestReferenceOverview = GenotypeKnownAlleleOverviewView()
    private let differenceLabel = NSTextField(
        labelWithString: "Candidate differences relative to closest reference"
    )
    private let differenceTrack = GenotypeCandidateDifferenceTrackView()
    private let factsRail = CandidateFactsBackgroundView()
    private let factsScrollView = NSScrollView()
    private let factsDocumentView = NSView()
    private let factsStack = NSStackView()

    private let factAlleleName = NSTextField(labelWithString: "")
    private let factStableClusterID = NSTextField(labelWithString: "")
    private let classificationValue = NSTextField(labelWithString: "")
    private let supportClassValue = NSTextField(labelWithString: "")
    private let sampleCountValue = NSTextField(labelWithString: "")
    private let sampleIDsValue = NSTextField(labelWithString: "")
    private let totalReadsValue = NSTextField(labelWithString: "")
    private let selectedSampleValue = NSTextField(labelWithString: "")
    private let selectedSampleReadCountValue = NSTextField(labelWithString: "")
    private let closestAlleleValue = NSTextField(labelWithString: "")
    private let closestRawReferenceIDValue = NSTextField(labelWithString: "")
    private let closestReferenceClassValue = NSTextField(labelWithString: "")
    private let snpCountValue = NSTextField(labelWithString: "")
    private let insertedBasesValue = NSTextField(labelWithString: "")
    private let deletedBasesValue = NSTextField(labelWithString: "")
    private let longGapBasesValue = NSTextField(labelWithString: "")
    private let coverageValue = NSTextField(labelWithString: "")
    private let identityValue = NSTextField(labelWithString: "")
    private let mappingQualityValue = NSTextField(labelWithString: "")
    private let alignmentScoreValue = NSTextField(labelWithString: "")
    private let candidateLengthValue = NSTextField(labelWithString: "")
    private let sequenceSHA256Value = NSTextField(labelWithString: "")
    private let commentsView = CandidateCommentsView()
    private let limitationValue = NSTextField(
        wrappingLabelWithString: "Reference-relative only. Marker regions use stored closest-reference exon intervals; biological consequence and candidate gene structure are not inferred."
    )
    private let warningValue = NSTextField(wrappingLabelWithString: "")
    private let showGenBankButton = NSButton(title: "View GenBank", target: nil, action: nil)
    private let showFASTAButton = NSButton(title: "View FASTA", target: nil, action: nil)

    private let genBankContent = NSView()
    private let genBankContext = NSTextField(labelWithString: "")
    private let genBankScrollView: NSScrollView
    private let genBankTextView: NSTextView
    private let fastaContent = NSView()
    private let fastaContext = NSTextField(labelWithString: "Exact validated candidate FASTA")
    private let fastaScrollView: NSScrollView
    private let fastaTextView: NSTextView

    private let fallbackContent = NSView()
    private let fallbackNote = NSTextField(wrappingLabelWithString: "")
    private let fallbackWarning = NSTextField(wrappingLabelWithString: "")

    private var isShowingFallback = false
    private var configuredOverviewRecord: ONTMHCReferenceVisualizationRecord?

    override var intrinsicContentSize: NSSize {
        let height: CGFloat
        if isShowingFallback {
            height = 250
        } else {
            height = currentMode == .overview ? 560 : 460
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override init(frame frameRect: NSRect) {
        (genBankScrollView, genBankTextView) = Self.makeTextHost(
            identifier: "candidateGenBankTextView",
            label: "Canonical closest-reference GenBank record"
        )
        (fastaScrollView, fastaTextView) = Self.makeTextHost(
            identifier: "candidateFASTATextView",
            label: "Exact candidate FASTA record"
        )
        super.init(frame: frameRect)
        buildHierarchy()
    }

    required init?(coder: NSCoder) {
        (genBankScrollView, genBankTextView) = Self.makeTextHost(
            identifier: "candidateGenBankTextView",
            label: "Canonical closest-reference GenBank record"
        )
        (fastaScrollView, fastaTextView) = Self.makeTextHost(
            identifier: "candidateFASTATextView",
            label: "Exact candidate FASTA record"
        )
        super.init(coder: coder)
        buildHierarchy()
    }

    func configure(
        candidate: ONTMHCCandidateRecord,
        closestReference: ONTMHCReferenceVisualizationRecord?,
        candidateSequence: String?,
        selectedSampleID: String?,
        selectedSampleReadCount: Int?,
        comments: [(String, String)] = [],
        warning: String? = nil
    ) {
        alleleNameLabel.stringValue = candidate.provisionalName
        stableClusterIDLabel.stringValue = candidate.stableClusterID
        factAlleleName.stringValue = candidate.provisionalName
        factStableClusterID.stringValue = candidate.stableClusterID
        classificationValue.stringValue = Self.classificationText(candidate.classification)
        supportClassValue.stringValue = Self.supportClassText(candidate.supportClass)
        sampleCountValue.stringValue = String(candidate.independentSampleCount)
        sampleIDsValue.stringValue = candidate.supportingSampleIDs.sorted().joined(separator: ", ")
        totalReadsValue.stringValue = String(candidate.totalClusterReads)
        selectedSampleValue.stringValue = Self.availableText(selectedSampleID)
        selectedSampleReadCountValue.stringValue = selectedSampleReadCount.map(String.init) ?? "—"
        closestAlleleValue.stringValue = closestReference?.alleleName ?? candidate.closestReferenceName
        closestRawReferenceIDValue.stringValue = closestReference?.rawReferenceID ?? "Unavailable"
        closestReferenceClassValue.stringValue = Self.referenceClassText(candidate.closestReferenceClass)
        snpCountValue.stringValue = String(candidate.snpCount)
        insertedBasesValue.stringValue = String(candidate.insertedBases)
        deletedBasesValue.stringValue = String(candidate.deletedBases)
        longGapBasesValue.stringValue = String(candidate.longGapBases)
        coverageValue.stringValue = Self.percentText(candidate.shorterCoverage)
        identityValue.stringValue = Self.percentText(candidate.identity)
        mappingQualityValue.stringValue = String(candidate.mappingQuality)
        alignmentScoreValue.stringValue = String(candidate.alignmentScore)
        candidateLengthValue.stringValue = candidateSequence.map { "\($0.count) bp" } ?? "Unavailable"
        sequenceSHA256Value.stringValue = candidate.sequenceSHA256
        commentsView.configure(comments)

        if let closestReference {
            closestReferenceGeometryLabel.stringValue =
                "Closest-reference geometry: \(closestReference.alleleName) (\(closestReference.rawReferenceID))"
            if configuredOverviewRecord != closestReference {
                configuredOverviewRecord = closestReference
                closestReferenceOverview.configure(record: closestReference)
            }
            differenceTrack.configure(
                referenceLength: closestReference.sequence.count,
                referenceStart: candidate.selectedEvidence.referenceStart,
                cigar: candidate.selectedEvidence.cigar,
                features: closestReference.features
            )
            genBankContext.stringValue =
                "Canonical closest-reference GenBank: \(closestReference.alleleName) (\(closestReference.rawReferenceID))"
            genBankTextView.string = closestReference.genBankText
        } else {
            configuredOverviewRecord = nil
            closestReferenceGeometryLabel.stringValue = "Closest-reference geometry unavailable"
            differenceTrack.configure(
                referenceLength: 0,
                referenceStart: candidate.selectedEvidence.referenceStart,
                cigar: candidate.selectedEvidence.cigar,
                features: []
            )
            genBankContext.stringValue = "Canonical closest-reference GenBank unavailable"
            genBankTextView.string = ""
        }

        if let candidateSequence {
            fastaTextView.string = Self.candidateFASTA(candidate: candidate, sequence: candidateSequence)
        } else {
            fastaTextView.string = ""
        }

        let warningCandidates: [String?] = [
            warning,
            closestReference == nil ? nil : differenceTrack.parsingIssue,
        ]
        let displayWarnings: [String] = warningCandidates.compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        warningValue.stringValue = displayWarnings.joined(separator: "\n")
        warningValue.superview?.isHidden = warningValue.stringValue.isEmpty
        fallbackWarning.stringValue = warning ?? ""
        fallbackWarning.isHidden = fallbackWarning.stringValue.isEmpty

        let missingSequence = candidateSequence == nil
        let missingReference = closestReference == nil
        isShowingFallback = missingSequence || missingReference
        if isShowingFallback {
            fallbackNote.stringValue = Self.fallbackText(
                missingSequence: missingSequence,
                missingReference: missingReference
            )
            modeControl.isHidden = true
            currentMode = .overview
            showOnly(fallbackContent)
        } else {
            modeControl.isHidden = false
            show(mode: .overview)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func buildHierarchy() {
        setAccessibilityIdentifier("candidateAlleleDetail")
        setAccessibilityRole(.group)
        setAccessibilityLabel("MHC candidate allele detail")

        buildHeader()
        buildOverview()
        buildTextContent()
        buildFallback()

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

        for content in [overviewContent, genBankContent, fastaContent, fallbackContent] {
            content.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                content.topAnchor.constraint(equalTo: contentHost.topAnchor),
                content.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
        }
        show(mode: .overview)
    }

    private func buildHeader() {
        alleleNameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        alleleNameLabel.lineBreakMode = .byTruncatingMiddle
        alleleNameLabel.setAccessibilityIdentifier("candidateAlleleName")

        stableClusterIDLabel.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        stableClusterIDLabel.textColor = .secondaryLabelColor
        stableClusterIDLabel.lineBreakMode = .byTruncatingMiddle
        stableClusterIDLabel.setAccessibilityIdentifier("candidateStableClusterID")

        let titleStack = NSStackView(views: [alleleNameLabel, stableClusterIDLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureModeButton(overviewModeButton, mode: .overview, identifier: "candidateModeOverview")
        configureModeButton(genBankModeButton, mode: .genBank, identifier: "candidateModeGenBank")
        configureModeButton(fastaModeButton, mode: .fasta, identifier: "candidateModeFASTA")
        modeControl.addArrangedSubview(overviewModeButton)
        modeControl.addArrangedSubview(genBankModeButton)
        modeControl.addArrangedSubview(fastaModeButton)
        modeControl.orientation = .horizontal
        modeControl.alignment = .centerY
        modeControl.spacing = 0
        modeControl.setAccessibilityIdentifier("candidateModeControl")
        modeControl.setAccessibilityRole(.group)
        modeControl.setAccessibilityLabel("Candidate detail mode")
        modeControl.setContentHuggingPriority(.required, for: .horizontal)

        headerStack.addArrangedSubview(titleStack)
        headerStack.addArrangedSubview(modeControl)
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.distribution = .fill
        headerStack.spacing = 16
        headerStack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildOverview() {
        overviewContent.setAccessibilityIdentifier("candidateOverview")
        overviewContent.setAccessibilityRole(.group)

        closestReferenceGeometryLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .semibold
        )
        closestReferenceGeometryLabel.textColor = .secondaryLabelColor
        closestReferenceGeometryLabel.setAccessibilityIdentifier(
            "candidateClosestReferenceGeometryLabel"
        )

        closestReferenceOverviewCanvas.setAccessibilityIdentifier(
            "candidateClosestReferenceOverview"
        )
        closestReferenceOverviewCanvas.setAccessibilityRole(.group)
        closestReferenceOverviewCanvas.setAccessibilityLabel("Closest-reference geometry")
        closestReferenceOverview.translatesAutoresizingMaskIntoConstraints = false
        closestReferenceOverviewCanvas.addSubview(closestReferenceOverview)
        NSLayoutConstraint.activate([
            closestReferenceOverview.leadingAnchor.constraint(
                equalTo: closestReferenceOverviewCanvas.leadingAnchor
            ),
            closestReferenceOverview.trailingAnchor.constraint(
                equalTo: closestReferenceOverviewCanvas.trailingAnchor
            ),
            closestReferenceOverview.topAnchor.constraint(
                equalTo: closestReferenceOverviewCanvas.topAnchor
            ),
            closestReferenceOverview.bottomAnchor.constraint(
                equalTo: closestReferenceOverviewCanvas.bottomAnchor
            ),
            closestReferenceOverviewCanvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
        ])

        differenceLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        differenceLabel.textColor = .secondaryLabelColor
        differenceLabel.setAccessibilityIdentifier("candidateDifferenceTrackLabel")
        differenceTrack.translatesAutoresizingMaskIntoConstraints = false
        differenceTrack.heightAnchor.constraint(equalToConstant: 58).isActive = true

        closestReferenceColumn.addArrangedSubview(closestReferenceGeometryLabel)
        closestReferenceColumn.addArrangedSubview(closestReferenceOverviewCanvas)
        closestReferenceColumn.addArrangedSubview(differenceLabel)
        closestReferenceColumn.addArrangedSubview(differenceTrack)
        closestReferenceColumn.orientation = .vertical
        closestReferenceColumn.alignment = .width
        closestReferenceColumn.spacing = 7
        closestReferenceColumn.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        buildFactsRail()
        let overviewStack = NSStackView(views: [closestReferenceColumn, factsRail])
        overviewStack.orientation = .horizontal
        overviewStack.alignment = .height
        overviewStack.distribution = .fill
        overviewStack.spacing = 0
        overviewStack.translatesAutoresizingMaskIntoConstraints = false
        overviewContent.addSubview(overviewStack)
        NSLayoutConstraint.activate([
            overviewStack.leadingAnchor.constraint(equalTo: overviewContent.leadingAnchor),
            overviewStack.trailingAnchor.constraint(equalTo: overviewContent.trailingAnchor),
            overviewStack.topAnchor.constraint(equalTo: overviewContent.topAnchor),
            overviewStack.bottomAnchor.constraint(equalTo: overviewContent.bottomAnchor),
            factsRail.widthAnchor.constraint(equalToConstant: 280),
        ])
    }

    private func buildFactsRail() {
        factsRail.setAccessibilityIdentifier("candidateFactsRail")
        factsRail.setAccessibilityRole(.group)
        factsRail.setAccessibilityLabel("Candidate facts")
        factsRail.translatesAutoresizingMaskIntoConstraints = false

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

        addFact("Name", value: factAlleleName, identifier: "candidateFactAlleleName")
        addFact("Stable ID", value: factStableClusterID, identifier: "candidateFactStableClusterID", monospaced: true)
        addFact("Classification", value: classificationValue, identifier: "candidateClassification")
        addFact("Support", value: supportClassValue, identifier: "candidateSupportClass")
        addFact("Sample count", value: sampleCountValue, identifier: "candidateSampleCount")
        addFact("Sample IDs", value: sampleIDsValue, identifier: "candidateSampleIDs")
        addFact("Total reads", value: totalReadsValue, identifier: "candidateTotalReads")
        addFact("Selected sample", value: selectedSampleValue, identifier: "candidateSelectedSample")
        addFact("Selected sample reads", value: selectedSampleReadCountValue, identifier: "candidateSelectedSampleReadCount")
        addFact("Closest allele", value: closestAlleleValue, identifier: "candidateClosestAllele")
        addFact("Closest raw ID", value: closestRawReferenceIDValue, identifier: "candidateClosestRawReferenceID", monospaced: true)
        addFact("Closest class", value: closestReferenceClassValue, identifier: "candidateClosestReferenceClass")
        addFact("SNP bases", value: snpCountValue, identifier: "candidateSNPCount")
        addFact("Inserted bases", value: insertedBasesValue, identifier: "candidateInsertedBases")
        addFact("Deleted bases", value: deletedBasesValue, identifier: "candidateDeletedBases")
        addFact("Long-gap bases", value: longGapBasesValue, identifier: "candidateLongGapBases")
        addFact("Coverage", value: coverageValue, identifier: "candidateCoverage")
        addFact("Identity", value: identityValue, identifier: "candidateIdentity")
        addFact("MAPQ", value: mappingQualityValue, identifier: "candidateMappingQuality")
        addFact("AS", value: alignmentScoreValue, identifier: "candidateAlignmentScore")
        addFact("Candidate length", value: candidateLengthValue, identifier: "candidateSequenceLength")
        addFact("Candidate SHA-256", value: sequenceSHA256Value, identifier: "candidateSequenceSHA256", monospaced: true)

        factsStack.addArrangedSubview(commentsView)
        commentsView.widthAnchor.constraint(equalTo: factsStack.widthAnchor).isActive = true
        addFact("Limitation", value: limitationValue, identifier: "candidateLimitation")
        addFact("Warning", value: warningValue, identifier: "candidateWarning")

        showGenBankButton.target = self
        showGenBankButton.action = #selector(showGenBank(_:))
        showGenBankButton.bezelStyle = .rounded
        showGenBankButton.controlSize = .small
        showGenBankButton.setAccessibilityIdentifier("candidateShowGenBankButton")

        showFASTAButton.target = self
        showFASTAButton.action = #selector(showFASTA(_:))
        showFASTAButton.bezelStyle = .rounded
        showFASTAButton.controlSize = .small
        showFASTAButton.setAccessibilityIdentifier("candidateShowFASTAButton")

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
    }

    private func addFact(
        _ title: String,
        value: NSTextField,
        identifier: String,
        monospaced: Bool = false
    ) {
        value.setAccessibilityIdentifier(identifier)
        value.font = monospaced
            ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        value.textColor = .labelColor
        value.maximumNumberOfLines = 3
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleField = NSTextField(labelWithString: title.uppercased())
        titleField.font = .systemFont(ofSize: 9, weight: .semibold)
        titleField.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [titleField, value])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 1
        factsStack.addArrangedSubview(stack)
    }

    private func buildTextContent() {
        configureTextContent(
            genBankContent,
            context: genBankContext,
            contextIdentifier: "candidateGenBankContext",
            scrollView: genBankScrollView
        )
        configureTextContent(
            fastaContent,
            context: fastaContext,
            contextIdentifier: "candidateFASTAContext",
            scrollView: fastaScrollView
        )
    }

    private func configureTextContent(
        _ content: NSView,
        context: NSTextField,
        contextIdentifier: String,
        scrollView: NSScrollView
    ) {
        context.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        context.textColor = .secondaryLabelColor
        context.setAccessibilityIdentifier(contextIdentifier)
        context.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(context)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            context.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            context.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            context.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: context.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func buildFallback() {
        fallbackContent.setAccessibilityIdentifier("candidateFallback")
        fallbackContent.setAccessibilityRole(.group)
        fallbackContent.setAccessibilityLabel("Candidate visualization unavailable")

        fallbackNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fallbackNote.textColor = .secondaryLabelColor
        fallbackNote.maximumNumberOfLines = 0
        fallbackNote.setAccessibilityIdentifier("candidateFallbackNote")

        fallbackWarning.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        fallbackWarning.textColor = .systemOrange
        fallbackWarning.maximumNumberOfLines = 0
        fallbackWarning.setAccessibilityIdentifier("candidateFallbackWarning")

        let stack = NSStackView(views: [fallbackNote, fallbackWarning])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        fallbackContent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fallbackContent.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: fallbackContent.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: fallbackContent.topAnchor, constant: 16),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
        ])
    }

    private func configureModeButton(_ button: NSButton, mode: Mode, identifier: String) {
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
        guard let mode = Mode(rawValue: sender.tag), !isShowingFallback else { return }
        show(mode: mode)
    }

    @objc private func showGenBank(_ sender: Any?) {
        guard !isShowingFallback else { return }
        show(mode: .genBank)
    }

    @objc private func showFASTA(_ sender: Any?) {
        guard !isShowingFallback else { return }
        show(mode: .fasta)
    }

    private func show(mode: Mode) {
        currentMode = mode
        updateModeButtons()
        switch mode {
        case .overview:
            showOnly(overviewContent)
        case .genBank:
            showOnly(genBankContent)
        case .fasta:
            showOnly(fastaContent)
        }
        invalidateIntrinsicContentSize()
    }

    private func showOnly(_ visibleContent: NSView) {
        for content in [overviewContent, genBankContent, fastaContent, fallbackContent] {
            content.isHidden = content !== visibleContent
        }
    }

    private func updateModeButtons() {
        for button in [overviewModeButton, genBankModeButton, fastaModeButton] {
            button.state = button.tag == currentMode.rawValue ? .on : .off
        }
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
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
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

    private static func classificationText(_ classification: ONTMHCCandidateClassification) -> String {
        switch classification {
        case .novel: return "Novel"
        case .extension: return "Extension"
        }
    }

    private static func supportClassText(_ supportClass: ONTMHCCandidateSupportClass) -> String {
        switch supportClass {
        case .singleton: return "Singleton"
        case .shared: return "Shared"
        }
    }

    private static func referenceClassText(_ referenceClass: MHCReferenceMoleculeClass) -> String {
        switch referenceClass {
        case .genomicDNA: return "Genomic DNA"
        case .cDNA: return "cDNA"
        }
    }

    private static func availableText(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    private static func percentText(_ fraction: Double) -> String {
        String(format: "%.2f%%", locale: Locale(identifier: "en_US_POSIX"), fraction * 100)
    }

    private static func candidateFASTA(
        candidate: ONTMHCCandidateRecord,
        sequence: String
    ) -> String {
        let header = ">\(candidate.stableClusterID) \(candidate.provisionalName) "
            + "classification=\(candidate.classification.rawValue) "
            + "support=\(candidate.supportClass.rawValue) "
            + "samples=\(candidate.independentSampleCount) reads=\(candidate.totalClusterReads)"
        let bytes = Array(sequence.utf8)
        let lines = stride(from: 0, to: bytes.count, by: 80).map { start in
            String(decoding: bytes[start..<min(start + 80, bytes.count)], as: UTF8.self)
        }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }

    private static func fallbackText(missingSequence: Bool, missingReference: Bool) -> String {
        var missing: [String] = []
        if missingSequence { missing.append("the validated candidate sequence") }
        if missingReference { missing.append("the closest-reference visualization") }
        return "This saved result does not contain \(missing.joined(separator: " or ")). "
            + "Run a fresh analysis to generate the graphical candidate detail artifacts."
    }
}

@MainActor
private final class CandidateCommentsView: NSStackView {
    private let titleLabel = NSTextField(labelWithString: "COMMENTS")
    private let rowsStack = NSStackView()
    private var comments: [(String, String)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildHierarchy()
    }

    func configure(_ comments: [(String, String)]) {
        let changed = self.comments.count != comments.count
            || zip(self.comments, comments).contains { lhs, rhs in
                lhs.0 != rhs.0 || lhs.1 != rhs.1
            }
        guard changed else { return }
        self.comments = comments

        rowsStack.arrangedSubviews.forEach { view in
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, comment) in comments.enumerated() {
            let label = NSTextField(labelWithString: comment.0)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityIdentifier("candidateCommentLabel.\(index)")

            let body = NSTextField(wrappingLabelWithString: comment.1)
            body.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            body.textColor = .labelColor
            body.maximumNumberOfLines = 0
            body.lineBreakMode = .byWordWrapping
            body.setAccessibilityIdentifier("candidateCommentBody.\(index)")

            let row = NSStackView(views: [label, body])
            row.orientation = .vertical
            row.alignment = .width
            row.spacing = 2
            rowsStack.addArrangedSubview(row)
        }
        isHidden = comments.isEmpty
    }

    private func buildHierarchy() {
        orientation = .vertical
        alignment = .width
        spacing = 3
        titleLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 7
        addArrangedSubview(titleLabel)
        addArrangedSubview(rowsStack)
        isHidden = true
    }
}

@MainActor
private final class CandidateFactsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
