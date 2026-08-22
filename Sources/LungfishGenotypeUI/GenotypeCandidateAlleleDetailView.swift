import AppKit
import Foundation
import LungfishIO
import LungfishKit

/// Persistent candidate-allele detail backed only by validated, preloaded result artifacts.
@MainActor
final class GenotypeCandidateAlleleDetailView: NSView {
    enum Mode: Int {
        case overview
        case genBank
        case fasta
    }

    private struct ReferencePresentationSignature: Equatable {
        let rawReferenceID: String
        let sourceOrdinal: Int
        let alleleName: String
        let locus: String?
        let sequence: String
        let sequenceSHA256: String
        let recordFields: [String: [String]]
        let features: [ONTMHCReferenceVisualizationFeature]
        let annotatedTranslation: String?
        let genBankText: String
        let fastaText: String
        let roles: [ONTMHCReferenceVisualizationRoleAssignment]
    }

    private struct CandidatePresentationSignature: Equatable {
        let stableClusterID: String
        let provisionalName: String
        let classification: String
        let supportClass: String
        let independentSampleCount: Int
        let totalClusterReads: Int
        let sequenceSHA256: String
        let candidateSequence: String?
        let referenceStart: Int
        let cigar: String
        let reference: ReferencePresentationSignature?
    }

    private struct CandidatePresentationCacheEntry {
        let signature: CandidatePresentationSignature
        let differenceTrack: GenotypeCandidateDifferenceTrackView.Presentation
        let fastaText: String
    }

    private(set) var currentMode: Mode = .overview
    private(set) var fastaFormattingCount = 0
    private(set) var immutablePresentationApplicationCount = 0
    private(set) var fastaTextAssignmentCount = 0
    private(set) var genBankTextAssignmentCount = 0
    private(set) var referenceOverviewConfigurationCount = 0

    var differenceTrackConfigurationCount: Int {
        differenceTrack.configurationCount
    }

    var differenceTrackPresentationApplicationCount: Int {
        differenceTrack.presentationApplicationCount
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
    private let overviewLayoutStack = NSStackView()
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
    private let locusValue = NSTextField(labelWithString: "")
    private let classificationValue = NSTextField(labelWithString: "")
    private let supportClassValue = NSTextField(labelWithString: "")
    private let sampleCountValue = NSTextField(labelWithString: "")
    private let sampleIDsValue = NSTextField(labelWithString: "")
    private let occurrenceCountValue = NSTextField(labelWithString: "")
    private let totalReadsValue = NSTextField(labelWithString: "")
    private let selectedSampleValue = NSTextField(labelWithString: "")
    private let selectedSampleReadCountValue = NSTextField(labelWithString: "")
    private let closestAlleleValue = NSTextField(labelWithString: "")
    private let closestRawReferenceIDValue = NSTextField(labelWithString: "")
    private let closestReferenceClassValue = NSTextField(labelWithString: "")
    private let extensionOfValue = NSTextField(wrappingLabelWithString: "")
    private let snpCountValue = NSTextField(labelWithString: "")
    private let insertedBasesValue = NSTextField(labelWithString: "")
    private let deletedBasesValue = NSTextField(labelWithString: "")
    private let longGapBasesValue = NSTextField(labelWithString: "")
    private let comparableBasesValue = NSTextField(labelWithString: "")
    private let coverageValue = NSTextField(labelWithString: "")
    private let identityValue = NSTextField(labelWithString: "")
    private let mappingQualityValue = NSTextField(labelWithString: "")
    private let alignmentScoreValue = NSTextField(labelWithString: "")
    private let candidateLengthValue = NSTextField(labelWithString: "")
    private let fastaRecordIDValue = NSTextField(labelWithString: "")
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

    private var activeContent: NSView?
    private var activeContentConstraints: [NSLayoutConstraint] = []
    private var contentConstraintsByView: [ObjectIdentifier: [NSLayoutConstraint]] = [:]
    private var isShowingFallback = false
    private var presentationCache: [CandidatePresentationCacheEntry] = []
    private var activePresentationSignature: CandidatePresentationSignature?
    private var activeReferencePresentationSignature: ReferencePresentationSignature?
    private var hasAppliedReferencePresentation = false
    private var usesNarrowOverviewLayout: Bool?
    private var factsRailWidthConstraint: NSLayoutConstraint?
    private var narrowReferenceHeightConstraint: NSLayoutConstraint?
    private var narrowFactsHeightConstraint: NSLayoutConstraint?
    private var narrowHeaderWidthConstraint: NSLayoutConstraint?
    private var narrowOverviewStackWidthConstraint: NSLayoutConstraint?
    private var narrowReferenceWidthConstraint: NSLayoutConstraint?
    private var narrowFactsWidthConstraint: NSLayoutConstraint?
    private var contentTypographyObservation: ContentTypographyViewObservation?
    private let sequenceTextFontBaseline = NSFont.monospacedSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    )
    private static let maximumCachedPresentations = 8

    override var intrinsicContentSize: NSSize {
        let isNarrow = bounds.width <= 0 || bounds.width < 560
        let height: CGFloat
        if isShowingFallback {
            if isNarrow {
                height = 740
            } else {
                height = closestReferenceOverviewCanvas.isHidden ? 250 : 560
            }
        } else {
            height = currentMode == .overview ? (isNarrow ? 740 : 560) : 460
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

    override func layout() {
        updateOverviewLayout(for: bounds.width)
        super.layout()
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
        locusValue.stringValue = candidate.locus
        classificationValue.stringValue = Self.classificationText(candidate.classification)
        supportClassValue.stringValue = Self.supportClassText(candidate.supportClass)
        sampleCountValue.stringValue = String(candidate.independentSampleCount)
        sampleIDsValue.stringValue = candidate.supportingSampleIDs.sorted().joined(separator: ", ")
        occurrenceCountValue.stringValue = String(candidate.occurrenceCount)
        totalReadsValue.stringValue = String(candidate.totalClusterReads)
        selectedSampleValue.stringValue = Self.availableText(selectedSampleID)
        selectedSampleReadCountValue.stringValue = selectedSampleReadCount.map(String.init) ?? "—"
        closestAlleleValue.stringValue = closestReference?.alleleName ?? candidate.closestReferenceName
        closestRawReferenceIDValue.stringValue = closestReference?.rawReferenceID ?? "Unavailable"
        closestReferenceClassValue.stringValue = Self.referenceClassText(candidate.closestReferenceClass)
        extensionOfValue.stringValue = candidate.extensionOf.isEmpty
            ? "—"
            : candidate.extensionOf.joined(separator: ", ")
        snpCountValue.stringValue = String(candidate.snpCount)
        insertedBasesValue.stringValue = String(candidate.insertedBases)
        deletedBasesValue.stringValue = String(candidate.deletedBases)
        longGapBasesValue.stringValue = String(candidate.longGapBases)
        comparableBasesValue.stringValue = String(candidate.comparableBases)
        coverageValue.stringValue = Self.percentText(candidate.shorterCoverage)
        identityValue.stringValue = Self.percentText(candidate.identity)
        mappingQualityValue.stringValue = String(candidate.mappingQuality)
        alignmentScoreValue.stringValue = String(candidate.alignmentScore)
        candidateLengthValue.stringValue = candidateSequence.map { "\($0.count) bp" } ?? "Unavailable"
        fastaRecordIDValue.stringValue = candidate.fastaRecordID
        sequenceSHA256Value.stringValue = candidate.sequenceSHA256
        commentsView.configure(comments)

        let referenceSignature = Self.referencePresentationSignature(for: closestReference)
        configureReferencePresentationIfNeeded(
            closestReference: closestReference,
            signature: referenceSignature
        )

        configureCachedPresentation(
            candidate: candidate,
            closestReference: closestReference,
            candidateSequence: candidateSequence,
            referenceSignature: referenceSignature
        )

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

        let missingSequence = candidateSequence == nil
        let missingReference = closestReference == nil
        isShowingFallback = missingSequence || missingReference
        updateOverviewFallbackVisibility(
            isFallback: isShowingFallback,
            hidesReferenceGeometry: missingReference
        )
        if isShowingFallback {
            fallbackNote.stringValue = Self.fallbackText(
                missingSequence: missingSequence,
                missingReference: missingReference
            )
            modeControl.isHidden = true
            show(mode: .overview)
        } else {
            modeControl.isHidden = false
            show(mode: .overview)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        contentTypographyObservation?.refresh()
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

        for content in [overviewContent, genBankContent, fastaContent] {
            content.translatesAutoresizingMaskIntoConstraints = false
            content.isHidden = true
            contentHost.addSubview(content)
            contentConstraintsByView[ObjectIdentifier(content)] = [
                content.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                content.topAnchor.constraint(equalTo: contentHost.topAnchor),
                content.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ]
        }
        show(mode: .genBank)
        show(mode: .fasta)
        show(mode: .overview)
        updateOverviewLayout(for: bounds.width)
        contentTypographyObservation = ContentTypographyViewObservation(
            applicator: ContentTypographyViewApplicator(excludedSubtree: { view in
                view is NSButton
                    || view is NSSegmentedControl
                    || view is NSPopUpButton
                    || view is NSSlider
                    || view is GenotypeKnownAlleleOverviewView
                    || view is GenotypeCandidateDifferenceTrackView
            }),
            rootProvider: { [weak self] in self },
            afterApply: { [weak self] in
                self?.applySequenceTextTypography()
                self?.invalidateIntrinsicContentSize()
                self?.needsLayout = true
            }
        )
    }

    private func buildHeader() {
        alleleNameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        alleleNameLabel.lineBreakMode = .byTruncatingMiddle
        alleleNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        alleleNameLabel.setAccessibilityIdentifier("candidateAlleleName")

        stableClusterIDLabel.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        stableClusterIDLabel.textColor = .secondaryLabelColor
        stableClusterIDLabel.lineBreakMode = .byTruncatingMiddle
        stableClusterIDLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stableClusterIDLabel.setAccessibilityIdentifier("candidateStableClusterID")

        let titleStack = NSStackView(views: [alleleNameLabel, stableClusterIDLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        configureModeButton(overviewModeButton, mode: .overview, identifier: "candidateModeOverview")
        configureModeButton(genBankModeButton, mode: .genBank, identifier: "candidateModeGenBank")
        configureModeButton(fastaModeButton, mode: .fasta, identifier: "candidateModeFASTA")
        for button in [overviewModeButton, genBankModeButton, fastaModeButton] {
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
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
        modeControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modeControl.setClippingResistancePriority(.defaultLow, for: .horizontal)

        headerStack.addArrangedSubview(titleStack)
        headerStack.addArrangedSubview(modeControl)
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.distribution = .fill
        headerStack.spacing = 16
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        headerStack.setAccessibilityIdentifier("candidateHeader")
        headerStack.setAccessibilityRole(.group)
        headerStack.setAccessibilityLabel("Candidate header")
    }

    private func buildOverview() {
        overviewContent.setAccessibilityIdentifier("candidateOverview")
        overviewContent.setAccessibilityRole(.group)

        closestReferenceGeometryLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .semibold
        )
        closestReferenceGeometryLabel.textColor = .secondaryLabelColor
        closestReferenceGeometryLabel.lineBreakMode = .byTruncatingTail
        closestReferenceGeometryLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        closestReferenceGeometryLabel.setAccessibilityIdentifier(
            "candidateClosestReferenceGeometryLabel"
        )

        closestReferenceOverviewCanvas.setAccessibilityIdentifier(
            "candidateClosestReferenceOverview"
        )
        closestReferenceOverviewCanvas.setAccessibilityRole(.group)
        closestReferenceOverviewCanvas.setAccessibilityLabel("Closest-reference geometry")
        closestReferenceOverview.setAccessibilityIdentifier("candidateClosestReferenceRenderer")
        closestReferenceOverview.setAccessibilityLabel("Closest-reference feature renderer")
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
        differenceLabel.lineBreakMode = .byTruncatingTail
        differenceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        closestReferenceColumn.setClippingResistancePriority(.defaultLow, for: .horizontal)

        buildFactsRail()
        overviewLayoutStack.addArrangedSubview(closestReferenceColumn)
        overviewLayoutStack.addArrangedSubview(factsRail)
        overviewLayoutStack.distribution = .fill
        overviewLayoutStack.translatesAutoresizingMaskIntoConstraints = false
        overviewLayoutStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        overviewContent.addSubview(overviewLayoutStack)
        NSLayoutConstraint.activate([
            overviewLayoutStack.leadingAnchor.constraint(equalTo: overviewContent.leadingAnchor),
            overviewLayoutStack.trailingAnchor.constraint(equalTo: overviewContent.trailingAnchor),
            overviewLayoutStack.topAnchor.constraint(equalTo: overviewContent.topAnchor),
            overviewLayoutStack.bottomAnchor.constraint(equalTo: overviewContent.bottomAnchor),
        ])
        factsRailWidthConstraint = factsRail.widthAnchor.constraint(equalToConstant: 280)
        narrowReferenceHeightConstraint = closestReferenceColumn.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 400
        )
        narrowFactsHeightConstraint = factsRail.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 240
        )
        narrowHeaderWidthConstraint = headerStack.widthAnchor.constraint(
            equalTo: widthAnchor,
            constant: -32
        )
        narrowOverviewStackWidthConstraint = overviewLayoutStack.widthAnchor.constraint(
            equalTo: widthAnchor
        )
        narrowReferenceWidthConstraint = closestReferenceColumn.widthAnchor.constraint(
            equalTo: overviewLayoutStack.widthAnchor
        )
        narrowFactsWidthConstraint = factsRail.widthAnchor.constraint(
            equalTo: overviewLayoutStack.widthAnchor
        )
    }

    private func updateOverviewLayout(for width: CGFloat) {
        guard let factsRailWidthConstraint,
              let narrowReferenceHeightConstraint,
              let narrowFactsHeightConstraint,
              let narrowHeaderWidthConstraint,
              let narrowOverviewStackWidthConstraint,
              let narrowReferenceWidthConstraint,
              let narrowFactsWidthConstraint else { return }
        let shouldUseNarrowLayout = width <= 0 || width < 560
        guard usesNarrowOverviewLayout != shouldUseNarrowLayout else { return }
        usesNarrowOverviewLayout = shouldUseNarrowLayout

        if shouldUseNarrowLayout {
            headerStack.orientation = .vertical
            headerStack.alignment = .leading
            headerStack.spacing = 6
            modeControl.distribution = .fillEqually
            factsRailWidthConstraint.isActive = false
            overviewLayoutStack.orientation = .vertical
            overviewLayoutStack.alignment = .leading
            overviewLayoutStack.spacing = 8
            closestReferenceColumn.edgeInsets = NSEdgeInsets(
                top: 14,
                left: 8,
                bottom: 14,
                right: 8
            )
            NSLayoutConstraint.activate([
                narrowReferenceHeightConstraint,
                narrowFactsHeightConstraint,
                narrowHeaderWidthConstraint,
                narrowOverviewStackWidthConstraint,
                narrowReferenceWidthConstraint,
                narrowFactsWidthConstraint,
            ])
        } else {
            headerStack.orientation = .horizontal
            headerStack.alignment = .centerY
            headerStack.spacing = 16
            modeControl.distribution = .fill
            NSLayoutConstraint.deactivate([
                narrowReferenceHeightConstraint,
                narrowFactsHeightConstraint,
                narrowHeaderWidthConstraint,
                narrowOverviewStackWidthConstraint,
                narrowReferenceWidthConstraint,
                narrowFactsWidthConstraint,
            ])
            overviewLayoutStack.orientation = .horizontal
            overviewLayoutStack.alignment = .height
            overviewLayoutStack.spacing = 0
            closestReferenceColumn.edgeInsets = NSEdgeInsets(
                top: 14,
                left: 16,
                bottom: 14,
                right: 16
            )
            factsRailWidthConstraint.isActive = true
        }
        invalidateIntrinsicContentSize()
        overviewContent.needsLayout = true
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
        factsStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

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
        addFact("Locus", value: locusValue, identifier: "candidateLocus")
        addFact("Classification", value: classificationValue, identifier: "candidateClassification")
        addFact("Support", value: supportClassValue, identifier: "candidateSupportClass")
        addFact("Sample count", value: sampleCountValue, identifier: "candidateSampleCount")
        addFact("Sample IDs", value: sampleIDsValue, identifier: "candidateSampleIDs")
        addFact("Occurrences", value: occurrenceCountValue, identifier: "candidateOccurrenceCount")
        addFact("Total reads", value: totalReadsValue, identifier: "candidateTotalReads")
        addFact("Selected sample", value: selectedSampleValue, identifier: "candidateSelectedSample")
        addFact("Selected sample reads", value: selectedSampleReadCountValue, identifier: "candidateSelectedSampleReadCount")
        addFact("Closest allele", value: closestAlleleValue, identifier: "candidateClosestAllele")
        addFact("Closest raw ID", value: closestRawReferenceIDValue, identifier: "candidateClosestRawReferenceID", monospaced: true)
        addFact("Closest class", value: closestReferenceClassValue, identifier: "candidateClosestReferenceClass")
        addFact("Extension of", value: extensionOfValue, identifier: "candidateExtensionOf")
        addFact("SNP bases", value: snpCountValue, identifier: "candidateSNPCount")
        addFact("Inserted bases", value: insertedBasesValue, identifier: "candidateInsertedBases")
        addFact("Deleted bases", value: deletedBasesValue, identifier: "candidateDeletedBases")
        addFact("Long-gap bases", value: longGapBasesValue, identifier: "candidateLongGapBases")
        addFact("Comparable bases", value: comparableBasesValue, identifier: "candidateComparableBases")
        addFact("Coverage", value: coverageValue, identifier: "candidateCoverage")
        addFact("Identity", value: identityValue, identifier: "candidateIdentity")
        addFact("MAPQ", value: mappingQualityValue, identifier: "candidateMappingQuality")
        addFact("AS", value: alignmentScoreValue, identifier: "candidateAlignmentScore")
        addFact("Candidate length", value: candidateLengthValue, identifier: "candidateSequenceLength")
        addFact("FASTA record ID", value: fastaRecordIDValue, identifier: "candidateFASTARecordID", monospaced: true)
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

        let stack = NSStackView(views: [fallbackNote])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        fallbackContent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fallbackContent.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: fallbackContent.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: fallbackContent.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: fallbackContent.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
        ])
        closestReferenceColumn.insertArrangedSubview(fallbackContent, at: 0)
        fallbackContent.isHidden = true
    }

    private func configureModeButton(_ button: NSButton, mode: Mode, identifier: String) {
        button.setButtonType(.toggle)
        button.bezelStyle = .rounded
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
            installContent(overviewContent)
        case .genBank:
            installContent(genBankContent)
        case .fasta:
            installContent(fastaContent)
        }
        invalidateIntrinsicContentSize()
    }

    private func installContent(_ view: NSView) {
        guard activeContent !== view else { return }
        NSLayoutConstraint.deactivate(activeContentConstraints)
        activeContent?.isHidden = true

        view.isHidden = false
        activeContent = view
        activeContentConstraints = contentConstraintsByView[ObjectIdentifier(view)] ?? []
        NSLayoutConstraint.activate(activeContentConstraints)
        layoutSubtreeIfNeeded()
    }

    private func updateOverviewFallbackVisibility(
        isFallback: Bool,
        hidesReferenceGeometry: Bool
    ) {
        fallbackContent.isHidden = !isFallback
        closestReferenceGeometryLabel.isHidden = hidesReferenceGeometry
        closestReferenceOverviewCanvas.isHidden = hidesReferenceGeometry
        differenceLabel.isHidden = hidesReferenceGeometry
        differenceTrack.isHidden = hidesReferenceGeometry
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

    private func applySequenceTextTypography() {
        let bodyFont = ContentTypography.current().font(for: .body)
        let scale = bodyFont.pointSize / max(NSFont.systemFontSize, 1)
        let pointSize = max(
            ContentTypography.minimumPointSize,
            sequenceTextFontBaseline.pointSize * scale
        )
        let resolvedFont = NSFont(
            descriptor: sequenceTextFontBaseline.fontDescriptor,
            size: pointSize
        ) ?? sequenceTextFontBaseline
        for (scrollView, textView) in [
            (genBankScrollView, genBankTextView),
            (fastaScrollView, fastaTextView),
        ] {
            if let currentFont = textView.font,
               currentFont.fontName == resolvedFont.fontName,
               abs(currentFont.pointSize - resolvedFont.pointSize) < 0.001,
               currentFont.fontDescriptor.symbolicTraits
                    == resolvedFont.fontDescriptor.symbolicTraits {
                continue
            }
            let selectedRange = textView.selectedRange()
            let scrollOrigin = scrollView.contentView.bounds.origin
            textView.font = resolvedFont
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            textView.setSelectedRange(selectedRange)
            scrollView.contentView.setBoundsOrigin(scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private static func classificationText(_ classification: ONTMHCCandidateClassification) -> String {
        switch classification {
        case .novel: return "Novel"
        case .extension: return "Extension"
        case .partialExtension: return "Partial extension"
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

    private func configureCachedPresentation(
        candidate: ONTMHCCandidateRecord,
        closestReference: ONTMHCReferenceVisualizationRecord?,
        candidateSequence: String?,
        referenceSignature: ReferencePresentationSignature?
    ) {
        let signature = CandidatePresentationSignature(
            stableClusterID: candidate.stableClusterID,
            provisionalName: candidate.provisionalName,
            classification: candidate.classification.rawValue,
            supportClass: candidate.supportClass.rawValue,
            independentSampleCount: candidate.independentSampleCount,
            totalClusterReads: candidate.totalClusterReads,
            sequenceSHA256: candidate.sequenceSHA256,
            candidateSequence: candidateSequence,
            referenceStart: candidate.selectedEvidence.referenceStart,
            cigar: candidate.selectedEvidence.cigar,
            reference: referenceSignature
        )

        guard activePresentationSignature != signature else { return }

        if let cachedIndex = presentationCache.firstIndex(where: {
            $0.signature == signature
        }) {
            let cached = presentationCache.remove(at: cachedIndex)
            presentationCache.append(cached)
            differenceTrack.apply(presentation: cached.differenceTrack)
            assignFASTAText(cached.fastaText)
            immutablePresentationApplicationCount += 1
            activePresentationSignature = signature
            return
        }

        differenceTrack.configure(
            referenceLength: closestReference?.sequence.count ?? 0,
            referenceStart: candidate.selectedEvidence.referenceStart,
            cigar: candidate.selectedEvidence.cigar,
            features: closestReference?.features ?? []
        )
        let fastaText: String
        if let candidateSequence {
            fastaFormattingCount += 1
            fastaText = Self.candidateFASTA(candidate: candidate, sequence: candidateSequence)
        } else {
            fastaText = ""
        }
        assignFASTAText(fastaText)
        immutablePresentationApplicationCount += 1
        activePresentationSignature = signature

        if presentationCache.count == Self.maximumCachedPresentations {
            presentationCache.removeFirst()
        }
        presentationCache.append(CandidatePresentationCacheEntry(
            signature: signature,
            differenceTrack: differenceTrack.currentPresentation,
            fastaText: fastaText
        ))
    }

    private static func referencePresentationSignature(
        for reference: ONTMHCReferenceVisualizationRecord?
    ) -> ReferencePresentationSignature? {
        reference.map { reference in
            ReferencePresentationSignature(
                rawReferenceID: reference.rawReferenceID,
                sourceOrdinal: reference.sourceOrdinal,
                alleleName: reference.alleleName,
                locus: reference.locus,
                sequence: reference.sequence,
                sequenceSHA256: reference.sequenceSHA256,
                recordFields: reference.recordFields,
                features: reference.features,
                annotatedTranslation: reference.annotatedTranslation,
                genBankText: reference.genBankText,
                fastaText: reference.fastaText,
                roles: reference.roles
            )
        }
    }

    private func configureReferencePresentationIfNeeded(
        closestReference: ONTMHCReferenceVisualizationRecord?,
        signature: ReferencePresentationSignature?
    ) {
        guard !hasAppliedReferencePresentation
                || activeReferencePresentationSignature != signature else { return }

        hasAppliedReferencePresentation = true
        activeReferencePresentationSignature = signature
        if let closestReference {
            closestReferenceGeometryLabel.stringValue =
                "Closest-reference geometry: \(closestReference.alleleName) (\(closestReference.rawReferenceID))"
            closestReferenceOverview.configure(record: closestReference)
            referenceOverviewConfigurationCount += 1
            genBankContext.stringValue =
                "Canonical closest-reference GenBank: \(closestReference.alleleName) (\(closestReference.rawReferenceID))"
            assignGenBankText(closestReference.genBankText)
        } else {
            closestReferenceGeometryLabel.stringValue = "Closest-reference geometry unavailable"
            genBankContext.stringValue = "Canonical closest-reference GenBank unavailable"
            assignGenBankText("")
        }
    }

    private func assignFASTAText(_ text: String) {
        fastaTextAssignmentCount += 1
        fastaTextView.string = text
    }

    private func assignGenBankText(_ text: String) {
        genBankTextAssignmentCount += 1
        genBankTextView.string = text
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

#if DEBUG
    var testingPrimaryContentFontPointSize: CGFloat {
        alleleNameLabel.font?.pointSize ?? 0
    }

    var testingDifferenceTrackGeometry: [CGFloat] {
        [differenceTrack.intrinsicContentSize.width, differenceTrack.intrinsicContentSize.height]
            + differenceTrack.constraints
                .filter { $0.relation == .equal }
                .map(\.constant)
    }
#endif
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
