// BlastResultsDrawerTab.swift - BLAST verification results drawer tab
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log
import UniformTypeIdentifiers

private let blastLogger = Logger(subsystem: LogSubsystem.app, category: "BlastResultsDrawer")

// MARK: - UI Helpers for BlastVerdict

extension BlastVerdict {

    /// SF Symbol name for this verdict's icon in the results table.
    var sfSymbolName: String {
        switch self {
        case .verified:   return "checkmark.circle.fill"
        case .ambiguous:  return "exclamationmark.triangle.fill"
        case .unverified: return "xmark.circle.fill"
        case .error:      return "exclamationmark.octagon.fill"
        }
    }

    /// Display color for this verdict's icon.
    var displayColor: NSColor {
        switch self {
        case .verified:   return .systemGreen
        case .ambiguous:  return .systemYellow
        case .unverified: return .systemRed
        case .error:      return .systemGray
        }
    }

    /// Accessibility description for VoiceOver.
    var accessibilityDescription: String {
        switch self {
        case .verified:   return "Verified"
        case .ambiguous:  return "Ambiguous"
        case .unverified: return "Unverified"
        case .error:      return "Error"
        }
    }
}

// MARK: - UI Helpers for BlastVerificationResult.Confidence

extension BlastVerificationResult.Confidence {

    /// Background tint color for the summary bar (alpha 0.15).
    var tintColor: NSColor {
        switch self {
        case .supported:    return NSColor.systemGreen.withAlphaComponent(0.15)
        case .mixed:        return NSColor.systemYellow.withAlphaComponent(0.15)
        case .unsupported:  return NSColor.systemRed.withAlphaComponent(0.15)
        case .inconclusive: return NSColor.systemGray.withAlphaComponent(0.15)
        }
    }

    /// Foreground accent color for confidence indicators.
    var accentColor: NSColor {
        switch self {
        case .supported:    return .systemGreen
        case .mixed:        return .systemYellow
        case .unsupported:  return .systemRed
        case .inconclusive: return .systemGray
        }
    }

    /// Human-readable display label.
    var displayLabel: String {
        switch self {
        case .supported:    return "Supported"
        case .mixed:        return "Mixed"
        case .unsupported:  return "Unsupported"
        case .inconclusive: return "Inconclusive"
        }
    }
}

// MARK: - NCBI URL Helper

extension BlastVerificationResult {

    /// URL to open the BLAST results in the NCBI web interface.
    var ncbiResultsURL: URL? {
        URL(string: "https://blast.ncbi.nlm.nih.gov/Blast.cgi?CMD=Get&RID=\(rid)&FORMAT_TYPE=HTML")
    }

    /// Verification rate as a percentage (0 to 100).
    var verificationPercentage: Int {
        Int(round(verificationRate * 100))
    }
}

// MARK: - BLAST Job Phase

/// The current phase of a BLAST verification job.
///
/// Displayed in the loading state to give the user context on what the
/// app is doing while waiting for NCBI BLAST.
public enum BlastJobPhase: Int, Sendable {
    /// Submitting reads to the NCBI BLAST API.
    case submitting = 1
    /// Waiting for NCBI BLAST to process the job.
    case waiting = 2
    /// Parsing the returned BLAST results.
    case parsing = 3

    /// Human-readable label for this phase.
    public var label: String {
        switch self {
        case .submitting: return "Submitting reads to NCBI BLAST..."
        case .waiting:    return "Waiting for NCBI BLAST results..."
        case .parsing:    return "Parsing BLAST results..."
        }
    }

    /// Total number of phases.
    public static let totalPhases = 3
}

// MARK: - Outline View Wrapper Classes

/// Wrapper for `BlastReadResult` providing stable object identity for
/// `NSOutlineView`, which uses `===` for item comparison.
///
/// Each `ReadResultItem` is a parent row in the outline view. Its children
/// are `HitSummaryItem` instances representing hits 2-5 (hit 1 is shown
/// inline on the parent row).
@MainActor
final class ReadResultItem {

    /// The underlying BLAST read result.
    let result: BlastReadResult

    /// Child hit items (hits 2+, since hit 1 is shown on the parent row).
    let hitItems: [HitSummaryItem]

    /// Creates a wrapper for the given read result.
    ///
    /// Populates `hitItems` from `result.topHits` where rank > 1.
    init(_ result: BlastReadResult) {
        self.result = result
        let items = result.topHits.dropFirst().map { HitSummaryItem($0) }
        self.hitItems = items
        // Set parent reference after creation
        for item in items {
            item.parent = self
        }
    }
}

/// Wrapper for `BlastHitSummary` providing stable object identity for
/// `NSOutlineView`.
///
/// Each `HitSummaryItem` is a child row under a `ReadResultItem`, showing
/// a secondary BLAST hit's accession, organism, identity, and E-value.
@MainActor
final class HitSummaryItem {

    /// The underlying BLAST hit summary.
    let hit: BlastHitSummary

    /// Back-reference to the parent read result item.
    weak var parent: ReadResultItem?

    /// Creates a wrapper for the given hit summary.
    init(_ hit: BlastHitSummary) {
        self.hit = hit
    }
}

// MARK: - BlastResultsDrawerTab Column Identifiers

private extension NSUserInterfaceItemIdentifier {
    static let blastStatus = NSUserInterfaceItemIdentifier("blastStatus")
    static let blastReadId = NSUserInterfaceItemIdentifier("blastReadId")
    static let blastOrganism = NSUserInterfaceItemIdentifier("blastOrganism")
    static let blastIdentity = NSUserInterfaceItemIdentifier("blastIdentity")
    static let blastEValue = NSUserInterfaceItemIdentifier("blastEValue")
    static let blastBitScore = NSUserInterfaceItemIdentifier("blastBitScore")
}

// MARK: - BlastResultsDrawerTab

/// An NSView-based tab for the bottom drawer showing BLAST verification results.
///
/// ## Layout
///
/// ```
/// +----------------------------------------------------------------------+
/// | BLAST Verification Results                                            |
/// +----------------------------------------------------------------------+
/// | Summary: 18/20 verified (90%)  [dots] High  . 2 conflicting  [Export] |
/// +----------------------------------------------------------------------+
/// | St | Read ID / Accession | Organism       | Identity | E-value | Bit |
/// | CK | read_12345          | Oxbow virus    | 98.5%    | 1e-45   | 180 |
/// |  > |   NZ_CP012345.1     | Oxbow virus    | 96.2%    | 3e-38   | 165 |
/// |  > |   NC_002695.2       | Bunyaviridae   | 82.1%    | 2e-12   |  90 |
/// | WN | read_67890          | (no hit)       | --       | --      | --  |
/// +----------------------------------------------------------------------+
/// | [Open in NCBI BLAST]                              [Re-run BLAST]      |
/// +----------------------------------------------------------------------+
/// ```
///
/// ## States
///
/// The view has three states:
/// - **Empty**: No BLAST results yet. Shows a centered icon and instructional text.
/// - **Loading**: A BLAST job is in progress. Shows a spinner, phase label, and progress.
/// - **Results**: BLAST verification results are available. Shows summary bar and
///   hierarchical outline view with expandable per-read hit details.
///
/// ## Thread Safety
///
/// This class is `@MainActor` isolated. All data source and delegate methods
/// run on the main thread.
@MainActor
public final class BlastResultsDrawerTab: NSView, NSMenuItemValidation {

    // MARK: - State

    /// The current display state of the BLAST results tab.
    enum DisplayState {
        case empty
        case loading(phase: BlastJobPhase, requestId: String?)
        case results(BlastVerificationResult)
    }

    /// The current display state.
    private(set) var displayState: DisplayState = .empty

    /// Outline view wrapper items for the current result (parent rows).
    private var outlineItems: [ReadResultItem] = []

    /// The current sort descriptor key path and direction.
    private var sortKey: NSUserInterfaceItemIdentifier = .blastStatus
    private var sortAscending: Bool = true

    // MARK: - Callbacks

    /// Called when the user clicks "Open in NCBI BLAST".
    var onOpenInBrowser: ((URL) -> Void)?

    /// Called when the user clicks "Re-run BLAST".
    var onRerunBlast: (() -> Void)?

    /// Called when the user clicks "Cancel" during loading.
    var onCancelBlast: (() -> Void)?

    // MARK: - Subviews: Empty State

    private let emptyStateContainer = NSView()
    private let emptyStateIcon = NSImageView()
    private let emptyStateTitleLabel = NSTextField(labelWithString: "No BLAST Verifications")
    private let emptyStateDetailLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: - Subviews: Loading State

    private let loadingStateContainer = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingPhaseLabel = NSTextField(labelWithString: "")
    private let loadingPhaseNumberLabel = NSTextField(labelWithString: "")
    private let loadingProgressBar = NSProgressIndicator()
    private let loadingDetailLabel = NSTextField(labelWithString: "")
    private let loadingCancelButton = NSButton()

    // MARK: - Subviews: Results State

    private let resultsContainer = NSView()
    let summaryBar = NSView()
    private let summaryIcon = NSImageView()
    let summaryLabel = NSTextField(labelWithString: "")
    let lcaWarningLabel = NSTextField(labelWithString: "")
    let confidenceLabel = NSTextField(labelWithString: "")
    let confidenceDots = NSTextField(labelWithString: "")
    let exportButton = NSButton()
    private let resultsScrollView = NSScrollView()
    let resultsOutlineView = NSOutlineView()
    private let actionBar = NSView()
    let openInBlastButton = NSButton()
    let rerunBlastButton = NSButton()

    // MARK: - Initialization

    public override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        setupEmptyState()
        setupLoadingState()
        setupResultsState()
        showState(.empty)

        setAccessibilityRole(.group)
        setAccessibilityLabel("BLAST Verification Results")
    }

    // MARK: - Public API

    /// Shows the empty state with instructional text.
    func showEmpty() {
        displayState = .empty
        showState(.empty)
    }

    /// Shows the loading state with the given phase and optional request ID.
    ///
    /// - Parameters:
    ///   - phase: The current BLAST job phase.
    ///   - requestId: The NCBI BLAST request ID, if available.
    func showLoading(phase: BlastJobPhase, requestId: String?) {
        displayState = .loading(phase: phase, requestId: requestId)

        loadingPhaseLabel.stringValue = phase.label
        loadingPhaseNumberLabel.stringValue = "Phase \(phase.rawValue) of \(BlastJobPhase.totalPhases)"

        if let rid = requestId {
            loadingDetailLabel.stringValue = "Request ID: \(rid)"
        } else {
            loadingDetailLabel.stringValue = ""
        }

        // Phase 2 (waiting) uses indeterminate progress
        loadingProgressBar.isIndeterminate = (phase == .waiting)
        if phase == .waiting {
            loadingProgressBar.startAnimation(nil)
        } else {
            loadingProgressBar.stopAnimation(nil)
            loadingProgressBar.doubleValue = phase == .submitting ? 30.0 : 90.0
        }

        showState(.loading(phase: phase, requestId: requestId))
    }

    /// Shows BLAST verification results.
    ///
    /// Populates the summary bar and results outline view with data from the
    /// verification result. Reads are displayed as parent rows with expandable
    /// child rows for secondary BLAST hits.
    ///
    /// - Parameter result: The BLAST verification result to display.
    func showResults(_ result: BlastVerificationResult) {
        displayState = .results(result)

        // Update summary bar with taxon-aware counts
        let supporting = result.supportingCount
        let contradicting = result.contradictingCount
        let total = result.totalReads
        summaryLabel.stringValue = "BLAST for \(result.taxonName): \(supporting) supporting, \(contradicting) contradicting (\(total) reads)"

        let confidence = result.confidence
        confidenceLabel.stringValue = confidence.displayLabel
        confidenceLabel.textColor = confidence.accentColor
        confidenceDots.stringValue = buildConfidenceDots(
            supporting: supporting,
            contradicting: contradicting,
            total: total
        )
        confidenceDots.textColor = confidence.accentColor
        summaryBar.layer?.backgroundColor = confidence.tintColor.cgColor

        // LCA disagreement indicator
        let lcaCount = result.lcaDisagreementCount
        if lcaCount > 0 {
            lcaWarningLabel.stringValue = "\(lcaCount) with conflicting organisms"
            lcaWarningLabel.textColor = .systemOrange
            lcaWarningLabel.isHidden = false
        } else {
            lcaWarningLabel.stringValue = ""
            lcaWarningLabel.isHidden = true
        }

        let summaryIconName: String
        switch confidence {
        case .supported:    summaryIconName = "checkmark.circle.fill"
        case .mixed:        summaryIconName = "exclamationmark.triangle.fill"
        case .unsupported:  summaryIconName = "xmark.circle.fill"
        case .inconclusive: summaryIconName = "questionmark.circle.fill"
        }
        let summaryIconImage = NSImage(
            systemSymbolName: summaryIconName,
            accessibilityDescription: confidence.displayLabel
        )
        summaryIcon.image = summaryIconImage
        summaryIcon.contentTintColor = confidence.accentColor

        // Enable/disable "Open in BLAST" based on request ID
        openInBlastButton.isEnabled = !result.rid.isEmpty

        // Build outline items, sort, and reload
        outlineItems = result.readResults.map { ReadResultItem($0) }
        applySortDescriptors()
        resultsOutlineView.reloadData()

        showState(.results(result))

        blastLogger.info(
            "Showing BLAST results: \(supporting) supporting, \(contradicting) contradicting of \(total) for \(result.taxonName, privacy: .public)"
        )
    }

    /// Returns the current result, if in the results state.
    var currentResult: BlastVerificationResult? {
        if case .results(let result) = displayState { return result }
        return nil
    }

    // MARK: - State Switching

    /// Shows or hides the appropriate container for the given state.
    private func showState(_ state: DisplayState) {
        emptyStateContainer.isHidden = true
        loadingStateContainer.isHidden = true
        resultsContainer.isHidden = true

        switch state {
        case .empty:
            emptyStateContainer.isHidden = false
        case .loading:
            loadingStateContainer.isHidden = false
            loadingSpinner.startAnimation(nil)
        case .results:
            resultsContainer.isHidden = false
            loadingSpinner.stopAnimation(nil)
        }
    }

    // MARK: - Setup: Empty State

    private func setupEmptyState() {
        emptyStateContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyStateContainer)

        let icon = NSImage(
            systemSymbolName: "bolt.badge.checkmark",
            accessibilityDescription: "BLAST verification"
        )
        emptyStateIcon.image = icon
        emptyStateIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyStateIcon.contentTintColor = .tertiaryLabelColor
        emptyStateIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
        emptyStateContainer.addSubview(emptyStateIcon)

        emptyStateTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateTitleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyStateTitleLabel.textColor = .secondaryLabelColor
        emptyStateTitleLabel.alignment = .center
        emptyStateContainer.addSubview(emptyStateTitleLabel)

        emptyStateDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateDetailLabel.stringValue =
            "Right-click a taxon and choose \"BLAST Matching Reads...\" to verify its classification against the NCBI database."
        emptyStateDetailLabel.font = .systemFont(ofSize: 12)
        emptyStateDetailLabel.textColor = .tertiaryLabelColor
        emptyStateDetailLabel.alignment = .center
        emptyStateDetailLabel.maximumNumberOfLines = 3
        emptyStateDetailLabel.preferredMaxLayoutWidth = 400
        emptyStateContainer.addSubview(emptyStateDetailLabel)

        NSLayoutConstraint.activate([
            emptyStateContainer.topAnchor.constraint(equalTo: topAnchor),
            emptyStateContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyStateContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyStateContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyStateIcon.centerXAnchor.constraint(equalTo: emptyStateContainer.centerXAnchor),
            emptyStateIcon.centerYAnchor.constraint(equalTo: emptyStateContainer.centerYAnchor, constant: -30),
            emptyStateIcon.widthAnchor.constraint(equalToConstant: 40),
            emptyStateIcon.heightAnchor.constraint(equalToConstant: 40),

            emptyStateTitleLabel.topAnchor.constraint(equalTo: emptyStateIcon.bottomAnchor, constant: 8),
            emptyStateTitleLabel.centerXAnchor.constraint(equalTo: emptyStateContainer.centerXAnchor),

            emptyStateDetailLabel.topAnchor.constraint(equalTo: emptyStateTitleLabel.bottomAnchor, constant: 4),
            emptyStateDetailLabel.centerXAnchor.constraint(equalTo: emptyStateContainer.centerXAnchor),
            emptyStateDetailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
    }

    // MARK: - Setup: Loading State

    private func setupLoadingState() {
        loadingStateContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loadingStateContainer)

        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingStateContainer.addSubview(loadingSpinner)

        loadingPhaseLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingPhaseLabel.font = .systemFont(ofSize: 13, weight: .medium)
        loadingPhaseLabel.textColor = .labelColor
        loadingPhaseLabel.alignment = .center
        loadingStateContainer.addSubview(loadingPhaseLabel)

        loadingPhaseNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingPhaseNumberLabel.font = .systemFont(ofSize: 11)
        loadingPhaseNumberLabel.textColor = .secondaryLabelColor
        loadingPhaseNumberLabel.alignment = .center
        loadingStateContainer.addSubview(loadingPhaseNumberLabel)

        loadingProgressBar.translatesAutoresizingMaskIntoConstraints = false
        loadingProgressBar.style = .bar
        loadingProgressBar.minValue = 0
        loadingProgressBar.maxValue = 100
        loadingProgressBar.isIndeterminate = false
        loadingStateContainer.addSubview(loadingProgressBar)

        loadingDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingDetailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        loadingDetailLabel.textColor = .tertiaryLabelColor
        loadingDetailLabel.alignment = .center
        loadingStateContainer.addSubview(loadingDetailLabel)

        loadingCancelButton.translatesAutoresizingMaskIntoConstraints = false
        loadingCancelButton.title = "Cancel"
        loadingCancelButton.bezelStyle = .rounded
        loadingCancelButton.controlSize = .regular
        loadingCancelButton.target = self
        loadingCancelButton.action = #selector(cancelButtonClicked(_:))
        loadingStateContainer.addSubview(loadingCancelButton)

        NSLayoutConstraint.activate([
            loadingStateContainer.topAnchor.constraint(equalTo: topAnchor),
            loadingStateContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            loadingStateContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            loadingStateContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: loadingStateContainer.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: loadingStateContainer.centerYAnchor, constant: -40),

            loadingPhaseLabel.topAnchor.constraint(equalTo: loadingSpinner.bottomAnchor, constant: 12),
            loadingPhaseLabel.centerXAnchor.constraint(equalTo: loadingStateContainer.centerXAnchor),

            loadingPhaseNumberLabel.topAnchor.constraint(equalTo: loadingPhaseLabel.bottomAnchor, constant: 4),
            loadingPhaseNumberLabel.centerXAnchor.constraint(equalTo: loadingStateContainer.centerXAnchor),

            loadingProgressBar.topAnchor.constraint(equalTo: loadingPhaseNumberLabel.bottomAnchor, constant: 8),
            loadingProgressBar.centerXAnchor.constraint(equalTo: loadingStateContainer.centerXAnchor),
            loadingProgressBar.widthAnchor.constraint(equalToConstant: 240),

            loadingDetailLabel.topAnchor.constraint(equalTo: loadingProgressBar.bottomAnchor, constant: 8),
            loadingDetailLabel.centerXAnchor.constraint(equalTo: loadingStateContainer.centerXAnchor),

            loadingCancelButton.topAnchor.constraint(equalTo: loadingDetailLabel.bottomAnchor, constant: 12),
            loadingCancelButton.centerXAnchor.constraint(equalTo: loadingStateContainer.centerXAnchor),
        ])
    }

    // MARK: - Setup: Results State

    private func setupResultsState() {
        resultsContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resultsContainer)

        setupSummaryBar()
        setupResultsOutlineView()
        setupActionBar()

        NSLayoutConstraint.activate([
            resultsContainer.topAnchor.constraint(equalTo: topAnchor),
            resultsContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            resultsContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            resultsContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Summary bar at top (36pt)
            summaryBar.topAnchor.constraint(equalTo: resultsContainer.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 36),

            // Results outline view (fills middle)
            resultsScrollView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            resultsScrollView.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor),
            resultsScrollView.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor),
            resultsScrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            // Action bar at bottom (32pt)
            actionBar.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: resultsContainer.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    // MARK: - Setup: Summary Bar

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        resultsContainer.addSubview(summaryBar)

        summaryIcon.translatesAutoresizingMaskIntoConstraints = false
        summaryIcon.contentTintColor = .systemGreen
        summaryIcon.setContentHuggingPriority(.required, for: .horizontal)
        summaryBar.addSubview(summaryIcon)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = .labelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryBar.addSubview(summaryLabel)

        lcaWarningLabel.translatesAutoresizingMaskIntoConstraints = false
        lcaWarningLabel.font = .systemFont(ofSize: 11, weight: .medium)
        lcaWarningLabel.textColor = .systemOrange
        lcaWarningLabel.lineBreakMode = .byTruncatingTail
        lcaWarningLabel.isHidden = true
        lcaWarningLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        summaryBar.addSubview(lcaWarningLabel)

        confidenceDots.translatesAutoresizingMaskIntoConstraints = false
        confidenceDots.font = .systemFont(ofSize: 10)
        confidenceDots.alignment = .center
        confidenceDots.setContentHuggingPriority(.required, for: .horizontal)
        summaryBar.addSubview(confidenceDots)

        confidenceLabel.translatesAutoresizingMaskIntoConstraints = false
        confidenceLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        confidenceLabel.alignment = .right
        confidenceLabel.setContentHuggingPriority(.required, for: .horizontal)
        summaryBar.addSubview(confidenceLabel)

        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.bezelStyle = .accessoryBarAction
        exportButton.controlSize = .small
        exportButton.font = .systemFont(ofSize: 11)
        exportButton.title = "Export"
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up",
                                     accessibilityDescription: "Export")
        exportButton.imagePosition = .imageLeading
        exportButton.target = self
        exportButton.action = #selector(exportButtonClicked(_:))
        exportButton.setAccessibilityLabel("Export BLAST results")
        summaryBar.addSubview(exportButton)

        NSLayoutConstraint.activate([
            summaryIcon.leadingAnchor.constraint(equalTo: summaryBar.leadingAnchor, constant: 12),
            summaryIcon.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),
            summaryIcon.widthAnchor.constraint(equalToConstant: 16),
            summaryIcon.heightAnchor.constraint(equalToConstant: 16),

            summaryLabel.leadingAnchor.constraint(equalTo: summaryIcon.trailingAnchor, constant: 8),
            summaryLabel.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),

            lcaWarningLabel.leadingAnchor.constraint(equalTo: summaryLabel.trailingAnchor, constant: 8),
            lcaWarningLabel.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),

            confidenceDots.leadingAnchor.constraint(greaterThanOrEqualTo: lcaWarningLabel.trailingAnchor, constant: 8),
            confidenceDots.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),

            confidenceLabel.leadingAnchor.constraint(equalTo: confidenceDots.trailingAnchor, constant: 8),
            confidenceLabel.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),

            exportButton.leadingAnchor.constraint(equalTo: confidenceLabel.trailingAnchor, constant: 12),
            exportButton.trailingAnchor.constraint(equalTo: summaryBar.trailingAnchor, constant: -12),
            exportButton.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),
        ])

        summaryBar.setAccessibilityRole(.group)
        summaryBar.setAccessibilityLabel("BLAST verification summary")
    }

    // MARK: - Setup: Results Outline View

    private func setupResultsOutlineView() {
        resultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        resultsScrollView.hasVerticalScroller = true
        resultsScrollView.hasHorizontalScroller = false
        resultsScrollView.autohidesScrollers = true
        resultsScrollView.borderType = .noBorder
        resultsContainer.addSubview(resultsScrollView)

        resultsOutlineView.rowHeight = 24
        resultsOutlineView.intercellSpacing = NSSize(width: 4, height: 0)
        resultsOutlineView.usesAlternatingRowBackgroundColors = true
        resultsOutlineView.allowsMultipleSelection = true
        resultsOutlineView.allowsColumnReordering = false
        resultsOutlineView.indentationPerLevel = 16
        resultsOutlineView.headerView = NSTableHeaderView()

        // Status column (30pt, icon)
        let statusColumn = NSTableColumn(identifier: .blastStatus)
        statusColumn.title = ""
        statusColumn.width = 30
        statusColumn.minWidth = 30
        statusColumn.maxWidth = 30
        statusColumn.sortDescriptorPrototype = NSSortDescriptor(key: "status", ascending: true)
        resultsOutlineView.addTableColumn(statusColumn)

        // Read/Accession column (flexible)
        let readIdColumn = NSTableColumn(identifier: .blastReadId)
        readIdColumn.title = "Read / Accession"
        readIdColumn.minWidth = 120
        readIdColumn.resizingMask = .autoresizingMask
        readIdColumn.sortDescriptorPrototype = NSSortDescriptor(key: "readId", ascending: true)
        resultsOutlineView.addTableColumn(readIdColumn)

        // Organism column (flexible)
        let organismColumn = NSTableColumn(identifier: .blastOrganism)
        organismColumn.title = "Organism"
        organismColumn.minWidth = 100
        organismColumn.resizingMask = .autoresizingMask
        organismColumn.sortDescriptorPrototype = NSSortDescriptor(key: "organism", ascending: true)
        resultsOutlineView.addTableColumn(organismColumn)

        // Identity column (60pt, right-aligned monospaced)
        let identityColumn = NSTableColumn(identifier: .blastIdentity)
        identityColumn.title = "Identity"
        identityColumn.width = 60
        identityColumn.minWidth = 50
        identityColumn.maxWidth = 80
        identityColumn.sortDescriptorPrototype = NSSortDescriptor(key: "identity", ascending: false)
        resultsOutlineView.addTableColumn(identityColumn)

        // E-value column (70pt, right-aligned)
        let eValueColumn = NSTableColumn(identifier: .blastEValue)
        eValueColumn.title = "E-value"
        eValueColumn.width = 70
        eValueColumn.minWidth = 55
        eValueColumn.maxWidth = 90
        eValueColumn.sortDescriptorPrototype = NSSortDescriptor(key: "eValue", ascending: true)
        resultsOutlineView.addTableColumn(eValueColumn)

        // Bit Score column (65pt, right-aligned)
        let bitScoreColumn = NSTableColumn(identifier: .blastBitScore)
        bitScoreColumn.title = "Bit Score"
        bitScoreColumn.width = 65
        bitScoreColumn.minWidth = 50
        bitScoreColumn.maxWidth = 85
        bitScoreColumn.sortDescriptorPrototype = NSSortDescriptor(key: "bitScore", ascending: false)
        resultsOutlineView.addTableColumn(bitScoreColumn)

        // The outline column is Read/Accession (shows disclosure triangles)
        resultsOutlineView.outlineTableColumn = readIdColumn

        resultsOutlineView.dataSource = self
        resultsOutlineView.delegate = self
        resultsOutlineView.menu = buildContextMenu()

        resultsScrollView.documentView = resultsOutlineView

        resultsOutlineView.setAccessibilityLabel("BLAST Results Table")
    }

    // MARK: - Setup: Action Bar

    private func setupActionBar() {
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        resultsContainer.addSubview(actionBar)

        // Separator line at top of action bar
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(separator)

        openInBlastButton.translatesAutoresizingMaskIntoConstraints = false
        openInBlastButton.title = "Open in NCBI BLAST"
        openInBlastButton.bezelStyle = .accessoryBarAction
        openInBlastButton.controlSize = .small
        openInBlastButton.font = .systemFont(ofSize: 11)
        openInBlastButton.target = self
        openInBlastButton.action = #selector(openInBlastClicked(_:))
        openInBlastButton.setAccessibilityLabel("Open results in NCBI BLAST website")
        actionBar.addSubview(openInBlastButton)

        rerunBlastButton.translatesAutoresizingMaskIntoConstraints = false
        rerunBlastButton.title = "Re-run BLAST"
        rerunBlastButton.bezelStyle = .accessoryBarAction
        rerunBlastButton.controlSize = .small
        rerunBlastButton.font = .systemFont(ofSize: 11)
        rerunBlastButton.target = self
        rerunBlastButton.action = #selector(rerunBlastClicked(_:))
        rerunBlastButton.setAccessibilityLabel("Re-run BLAST verification")
        actionBar.addSubview(rerunBlastButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: actionBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            openInBlastButton.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 12),
            openInBlastButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),

            rerunBlastButton.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor, constant: -12),
            rerunBlastButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
        ])
    }

    // MARK: - Context Menu

    /// Builds the context menu for the outline view.
    ///
    /// Menu items include:
    /// - Copy Sequence as FASTA (parent rows only)
    /// - Copy Read ID (parent rows only)
    /// - Copy Accession (both parent and child rows)
    /// - Expand All / Collapse All
    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "Copy Sequence as FASTA",
                     action: #selector(contextCopyFASTA(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Copy Read ID",
                     action: #selector(contextCopyReadId(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Copy Accession",
                     action: #selector(contextCopyAccession(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Expand All",
                     action: #selector(contextExpandAll(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Collapse All",
                     action: #selector(contextCollapseAll(_:)),
                     keyEquivalent: "")

        return menu
    }

    // MARK: - Selection Helpers

    /// Returns the selected `ReadResultItem` instances from the outline view.
    ///
    /// For selected child rows (`HitSummaryItem`), the parent `ReadResultItem`
    /// is included instead (deduplicated). Items are returned in outline view
    /// order.
    ///
    /// - Returns: An ordered array of unique `ReadResultItem` instances.
    private func selectedReadItems() -> [ReadResultItem] {
        let indexes = resultsOutlineView.selectedRowIndexes
        var seen = Set<ObjectIdentifier>()
        var items: [ReadResultItem] = []

        for row in indexes {
            let item = resultsOutlineView.item(atRow: row)
            let readItem: ReadResultItem?
            if let ri = item as? ReadResultItem {
                readItem = ri
            } else if let hi = item as? HitSummaryItem {
                readItem = hi.parent
            } else {
                readItem = nil
            }
            if let readItem, seen.insert(ObjectIdentifier(readItem)).inserted {
                items.append(readItem)
            }
        }
        return items
    }

    /// Returns all selected items (both `ReadResultItem` and `HitSummaryItem`)
    /// in outline view order.
    private func selectedItems() -> [AnyObject] {
        let indexes = resultsOutlineView.selectedRowIndexes
        var items: [AnyObject] = []
        for row in indexes {
            if let item = resultsOutlineView.item(atRow: row) as AnyObject? {
                items.append(item)
            }
        }
        return items
    }

    /// Validates context menu items based on the current selection.
    ///
    /// With multi-selection enabled, validation checks all selected rows:
    /// - "Copy Sequence as FASTA" is enabled when at least one selected parent
    ///   row has a `querySequence`.
    /// - "Copy Read ID" is enabled when at least one parent row is selected.
    /// - "Copy Accession" is enabled when at least one selected row (parent or
    ///   child) has an accession.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(contextExpandAll(_:)),
             #selector(contextCollapseAll(_:)):
            return true

        case #selector(contextCopyFASTA(_:)):
            let readItems = selectedReadItems()
            return readItems.contains { $0.result.querySequence != nil }

        case #selector(contextCopyReadId(_:)):
            return !selectedReadItems().isEmpty

        case #selector(contextCopyAccession(_:)):
            let items = selectedItems()
            return items.contains { item in
                if let readItem = item as? ReadResultItem {
                    return readItem.result.topHitAccession != nil
                }
                if item is HitSummaryItem {
                    return true
                }
                return false
            }

        default:
            return true
        }
    }

    /// Copies all selected reads as FASTA entries to the pasteboard.
    ///
    /// Each selected read with a `querySequence` becomes a separate FASTA
    /// entry, joined by newlines.
    @objc private func contextCopyFASTA(_ sender: Any?) {
        let readItems = selectedReadItems()
        var entries: [String] = []
        for readItem in readItems {
            if let sequence = readItem.result.querySequence {
                entries.append(">\(readItem.result.id)\n\(sequence)")
            }
        }
        guard !entries.isEmpty else { return }
        let fasta = entries.joined(separator: "\n") + "\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fasta, forType: .string)
    }

    /// Copies the read IDs of all selected parent rows to the pasteboard,
    /// one per line.
    @objc private func contextCopyReadId(_ sender: Any?) {
        let readItems = selectedReadItems()
        guard !readItems.isEmpty else { return }
        let ids = readItems.map { $0.result.id }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ids.joined(separator: "\n"), forType: .string)
    }

    /// Copies accessions from all selected rows to the pasteboard, one per line.
    ///
    /// For parent rows, the top hit accession is used. For child rows, the
    /// hit accession is used.
    @objc private func contextCopyAccession(_ sender: Any?) {
        let items = selectedItems()
        var accessions: [String] = []
        for item in items {
            if let readItem = item as? ReadResultItem,
               let accession = readItem.result.topHitAccession {
                accessions.append(accession)
            } else if let hitItem = item as? HitSummaryItem {
                accessions.append(hitItem.hit.accession)
            }
        }
        guard !accessions.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accessions.joined(separator: "\n"), forType: .string)
    }

    @objc private func contextExpandAll(_ sender: Any?) {
        resultsOutlineView.expandItem(nil, expandChildren: true)
    }

    @objc private func contextCollapseAll(_ sender: Any?) {
        resultsOutlineView.collapseItem(nil, collapseChildren: true)
    }

    // MARK: - Confidence Dots

    /// Builds a string of filled and empty circle characters representing the
    /// taxon support rate among reads with significant BLAST hits.
    ///
    /// Green-filled dots represent supporting reads, red-filled dots represent
    /// contradicting reads, and empty dots represent inconclusive reads.
    ///
    /// - Parameters:
    ///   - supporting: Number of reads whose top hit matches the queried taxon.
    ///   - contradicting: Number of reads whose top hit is a different organism.
    ///   - total: Total number of reads submitted.
    /// - Returns: A string like "●●●●●●●●●○○" with 10 characters total.
    func buildConfidenceDots(supporting: Int, contradicting: Int, total: Int) -> String {
        guard total > 0 else { return String(repeating: "\u{25CB}", count: 10) }
        let supportDots = Int(round(Double(supporting) / Double(total) * 10.0))
        let contradictDots = Int(round(Double(contradicting) / Double(total) * 10.0))
        let emptyDots = max(0, 10 - supportDots - contradictDots)
        let filled = String(repeating: "\u{25CF}", count: supportDots)
        let contra = String(repeating: "\u{25C6}", count: contradictDots)
        let empty = String(repeating: "\u{25CB}", count: emptyDots)
        return filled + contra + empty
    }

    // MARK: - Sorting

    /// Sorts the outline items based on the current sort key and direction.
    private func applySortDescriptors() {
        outlineItems.sort { lhs, rhs in
            let result: Bool
            switch sortKey {
            case .blastStatus:
                result = lhs.result.verdict.rawValue < rhs.result.verdict.rawValue
            case .blastReadId:
                result = lhs.result.id.localizedStandardCompare(rhs.result.id) == .orderedAscending
            case .blastOrganism:
                let lhsOrg = lhs.result.topHitOrganism ?? ""
                let rhsOrg = rhs.result.topHitOrganism ?? ""
                result = lhsOrg.localizedStandardCompare(rhsOrg) == .orderedAscending
            case .blastIdentity:
                result = (lhs.result.percentIdentity ?? -1) < (rhs.result.percentIdentity ?? -1)
            case .blastEValue:
                result = (lhs.result.eValue ?? Double.infinity) < (rhs.result.eValue ?? Double.infinity)
            case .blastBitScore:
                result = (lhs.result.bitScore ?? -1) < (rhs.result.bitScore ?? -1)
            default:
                result = false
            }
            return sortAscending ? result : !result
        }
    }

    // MARK: - E-Value Formatting

    /// Formats an E-value for display in the table.
    ///
    /// Very small values use scientific notation (e.g., "1e-45").
    /// Zero is displayed as "0.0".
    ///
    /// - Parameter eValue: The E-value to format, or `nil`.
    /// - Returns: A formatted string, or "--" if `nil`.
    static func formatEValue(_ eValue: Double?) -> String {
        guard let eValue else { return "--" }
        if eValue == 0.0 { return "0.0" }
        if eValue < 0.001 {
            let exponent = Int(floor(log10(eValue)))
            let mantissa = eValue / pow(10, Double(exponent))
            if abs(mantissa - 1.0) < 0.05 {
                return "1e\(exponent)"
            }
            return String(format: "%.0fe%d", mantissa, exponent)
        }
        return String(format: "%.1e", eValue)
    }

    /// Formats a bit score for display in the table.
    ///
    /// - Parameter bitScore: The bit score to format, or `nil`.
    /// - Returns: A formatted string, or "--" if `nil`.
    static func formatBitScore(_ bitScore: Double?) -> String {
        guard let bitScore else { return "--" }
        if bitScore >= 100 {
            return String(format: "%.0f", bitScore)
        }
        return String(format: "%.1f", bitScore)
    }

    // MARK: - Export

    /// Presents an NSSavePanel for exporting BLAST results as CSV or TSV.
    ///
    /// Uses `beginSheetModal` (never `runModal`) per macOS 26 guidelines.
    @objc private func exportButtonClicked(_ sender: NSButton) {
        guard case .results(_) = displayState else { return }

        let menu = NSMenu()
        let csvItem = NSMenuItem(title: "Export as CSV...", action: #selector(exportCSV(_:)), keyEquivalent: "")
        csvItem.target = self
        let tsvItem = NSMenuItem(title: "Export as TSV...", action: #selector(exportTSV(_:)), keyEquivalent: "")
        tsvItem.target = self
        menu.addItem(csvItem)
        menu.addItem(tsvItem)

        // Show the menu below the button
        let point = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func exportCSV(_ sender: Any?) {
        exportResults(separator: ",", fileExtension: "csv")
    }

    @objc private func exportTSV(_ sender: Any?) {
        exportResults(separator: "\t", fileExtension: "tsv")
    }

    /// Exports results to a delimited file using NSSavePanel.
    private func exportResults(separator: String, fileExtension: String) {
        guard case .results(let result) = displayState else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "blast_results.\(fileExtension)"
        panel.allowedContentTypes = fileExtension == "csv"
            ? [UTType.commaSeparatedText]
            : [UTType.tabSeparatedText]
        panel.canCreateDirectories = true

        guard let parentWindow = window else {
            blastLogger.warning("No parent window for export save panel")
            return
        }

        panel.beginSheetModal(for: parentWindow) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writeExportFile(result: result, to: url, separator: separator)
        }
    }

    /// Writes the export file to disk.
    ///
    /// CSV/TSV columns: Read ID, Verdict, LCA Flag, Hit Rank, Accession,
    /// Organism, TaxId, Identity%, Coverage%, E-value, Bit Score, Alignment Length.
    ///
    /// One row per hit (a read with 5 hits produces 5 output rows).
    private func writeExportFile(
        result: BlastVerificationResult,
        to url: URL,
        separator: String
    ) {
        var lines: [String] = []

        // Header
        let header = [
            "Read ID", "Verdict", "LCA Flag", "Hit Rank", "Accession",
            "Organism", "TaxId", "Identity%", "Coverage%", "E-value",
            "Bit Score", "Alignment Length"
        ]
        lines.append(header.joined(separator: separator))

        // Data rows
        for readResult in result.readResults {
            if readResult.topHits.isEmpty {
                // Read with no hits: single row with top-level fields
                let row = [
                    escapeField(readResult.id, separator: separator),
                    readResult.verdict.rawValue,
                    readResult.hasLCADisagreement ? "true" : "false",
                    "1",
                    escapeField(readResult.topHitAccession ?? "", separator: separator),
                    escapeField(readResult.topHitOrganism ?? "", separator: separator),
                    "",
                    readResult.percentIdentity.map { String(format: "%.2f", $0) } ?? "",
                    readResult.queryCoverage.map { String(format: "%.2f", $0) } ?? "",
                    readResult.eValue.map { String($0) } ?? "",
                    readResult.bitScore.map { String(format: "%.1f", $0) } ?? "",
                    readResult.alignmentLength.map { String($0) } ?? "",
                ]
                lines.append(row.joined(separator: separator))
            } else {
                // One row per hit
                for hit in readResult.topHits {
                    let row = [
                        escapeField(readResult.id, separator: separator),
                        readResult.verdict.rawValue,
                        readResult.hasLCADisagreement ? "true" : "false",
                        String(hit.rank),
                        escapeField(hit.accession, separator: separator),
                        escapeField(hit.organism ?? "", separator: separator),
                        hit.taxId.map { String($0) } ?? "",
                        String(format: "%.2f", hit.percentIdentity),
                        String(format: "%.2f", hit.queryCoverage),
                        String(hit.eValue),
                        String(format: "%.1f", hit.bitScore),
                        String(hit.alignmentLength),
                    ]
                    lines.append(row.joined(separator: separator))
                }
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            blastLogger.info("Exported BLAST results to \(url.path, privacy: .public)")
        } catch {
            blastLogger.error("Failed to export BLAST results: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Escapes a field for CSV output by quoting if it contains the separator,
    /// quotes, or newlines.
    private func escapeField(_ value: String, separator: String) -> String {
        if value.contains(separator) || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    // MARK: - Actions

    @objc private func openInBlastClicked(_ sender: NSButton) {
        if case .results(let result) = displayState, let url = result.ncbiResultsURL {
            blastLogger.info("Opening BLAST results in browser: \(url.absoluteString, privacy: .public)")
            if let callback = onOpenInBrowser { callback(url) } else { NSWorkspace.shared.open(url) }
        }
    }

    @objc private func rerunBlastClicked(_ sender: NSButton) {
        blastLogger.info("Re-run BLAST requested")
        onRerunBlast?()
    }

    @objc private func cancelButtonClicked(_ sender: NSButton) {
        blastLogger.info("BLAST job cancel requested")
        onCancelBlast?()
    }
}

// MARK: - NSOutlineViewDataSource

extension BlastResultsDrawerTab: NSOutlineViewDataSource {

    /// Returns the number of children for the given item.
    ///
    /// - `nil` item: returns the count of top-level read result items.
    /// - `ReadResultItem`: returns the count of child hit items.
    /// - `HitSummaryItem`: returns 0 (leaf node).
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return outlineItems.count
        }
        if let readItem = item as? ReadResultItem {
            return readItem.hitItems.count
        }
        return 0
    }

    /// Returns the child at the given index.
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return outlineItems[index]
        }
        if let readItem = item as? ReadResultItem {
            return readItem.hitItems[index]
        }
        fatalError("Unexpected outline item type: \(type(of: item))")
    }

    /// Returns whether the item can be expanded (has children).
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let readItem = item as? ReadResultItem {
            return !readItem.hitItems.isEmpty
        }
        return false
    }

    /// Handles sort descriptor changes from column header clicks.
    public func outlineView(
        _ outlineView: NSOutlineView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key else { return }

        // Map sort descriptor keys to column identifiers
        let columnId: NSUserInterfaceItemIdentifier
        switch key {
        case "status":   columnId = .blastStatus
        case "readId":   columnId = .blastReadId
        case "organism": columnId = .blastOrganism
        case "identity": columnId = .blastIdentity
        case "eValue":   columnId = .blastEValue
        case "bitScore": columnId = .blastBitScore
        default: return
        }

        sortKey = columnId
        sortAscending = descriptor.ascending
        applySortDescriptors()
        outlineView.reloadData()
    }
}

// MARK: - NSOutlineViewDelegate

extension BlastResultsDrawerTab: NSOutlineViewDelegate {

    /// Provides the cell view for a given item and column.
    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let columnId = tableColumn?.identifier else { return nil }

        if let readItem = item as? ReadResultItem {
            return makeParentCell(columnId: columnId, readItem: readItem)
        }

        if let hitItem = item as? HitSummaryItem {
            return makeChildCell(columnId: columnId, hitItem: hitItem)
        }

        return nil
    }

    // MARK: - Parent Row Cells (ReadResultItem)

    /// Creates a cell for a parent (read result) row.
    private func makeParentCell(columnId: NSUserInterfaceItemIdentifier, readItem: ReadResultItem) -> NSView? {
        let readResult = readItem.result

        switch columnId {
        case .blastStatus:
            return makeParentStatusCell(for: readResult)
        case .blastReadId:
            return makeTextCell(
                readResult.id,
                font: .monospacedSystemFont(ofSize: 11, weight: .regular)
            )
        case .blastOrganism:
            return makeOrganismCell(
                organism: readResult.topHitOrganism ?? "No significant hit",
                hasLCADisagreement: readResult.hasLCADisagreement
            )
        case .blastIdentity:
            let text: String
            if let pct = readResult.percentIdentity {
                text = String(format: "%.1f%%", pct)
            } else {
                text = "--"
            }
            return makeTextCell(
                text,
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                alignment: .right
            )
        case .blastEValue:
            return makeTextCell(
                Self.formatEValue(readResult.eValue),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                alignment: .right
            )
        case .blastBitScore:
            return makeTextCell(
                Self.formatBitScore(readResult.bitScore),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                alignment: .right
            )
        default:
            return nil
        }
    }

    // MARK: - Child Row Cells (HitSummaryItem)

    /// Creates a cell for a child (hit summary) row.
    private func makeChildCell(columnId: NSUserInterfaceItemIdentifier, hitItem: HitSummaryItem) -> NSView? {
        let hit = hitItem.hit

        switch columnId {
        case .blastStatus:
            return makeChildStatusCell(rank: hit.rank)
        case .blastReadId:
            return makeTextCell(
                hit.accession,
                font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                textColor: .secondaryLabelColor
            )
        case .blastOrganism:
            return makeTextCell(
                hit.organism ?? "",
                font: .systemFont(ofSize: 11),
                textColor: .secondaryLabelColor
            )
        case .blastIdentity:
            return makeTextCell(
                String(format: "%.1f%%", hit.percentIdentity),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                alignment: .right,
                textColor: .secondaryLabelColor
            )
        case .blastEValue:
            return makeTextCell(
                Self.formatEValue(hit.eValue),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                alignment: .right,
                textColor: .secondaryLabelColor
            )
        case .blastBitScore:
            return makeTextCell(
                Self.formatBitScore(hit.bitScore),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                alignment: .right,
                textColor: .secondaryLabelColor
            )
        default:
            return nil
        }
    }

    // MARK: - Cell Factories

    /// Creates a status icon cell for a parent row (read result).
    ///
    /// Shows the verdict icon. When `hasLCADisagreement` is true, an additional
    /// orange warning triangle is overlaid.
    private func makeParentStatusCell(for result: BlastReadResult) -> NSView {
        let cell = NSTableCellView()

        if result.hasLCADisagreement {
            // Show orange LCA warning triangle instead of verdict icon
            let warningImage = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "LCA disagreement"
            )
            let imageView = NSImageView(image: warningImage ?? NSImage())
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentTintColor = .systemOrange
            cell.addSubview(imageView)

            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 14),
                imageView.heightAnchor.constraint(equalToConstant: 14),
            ])
        } else {
            let image = NSImage(
                systemSymbolName: result.verdict.sfSymbolName,
                accessibilityDescription: result.verdict.accessibilityDescription
            )
            let imageView = NSImageView(image: image ?? NSImage())
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentTintColor = result.verdict.displayColor
            cell.addSubview(imageView)

            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 14),
                imageView.heightAnchor.constraint(equalToConstant: 14),
            ])
        }

        return cell
    }

    /// Creates a status cell for a child row showing the hit rank number.
    private func makeChildStatusCell(rank: Int) -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "#\(rank)")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    /// Creates an organism name cell, with orange tint when LCA disagreement is present.
    private func makeOrganismCell(organism: String, hasLCADisagreement: Bool) -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: organism)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = hasLCADisagreement ? .systemOrange : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = organism
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    /// Creates a text cell with the given string, font, alignment, and color.
    private func makeTextCell(
        _ text: String,
        font: NSFont,
        alignment: NSTextAlignment = .left,
        textColor: NSColor = .labelColor
    ) -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = textColor
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}
