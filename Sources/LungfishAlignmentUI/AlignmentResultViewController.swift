// AlignmentResultViewController.swift - Summary viewport for BAM alignment results
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Displays BAM alignment output summaries from read-mapping tools (minimap2,
// BWA-MEM2, Bowtie2). Detailed pileup and coverage inspection is handled by
// the project's BAM track viewers; this result viewport remains a lightweight
// summary surface.
//
// ## Viewport class conventions
// Mapping workflows that produce sorted, indexed BAM tracks share this
// viewport. The concrete result type remains `Minimap2Result` for compatibility
// with the original mapping workflow while newer toolchains route through the
// same summary surface.

import AppKit
import LungfishWorkflow
import LungfishKit

@MainActor
private final class AlignmentTypographyObservation {
    private var token: NSObjectProtocol?

    init(handler: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
    }

    func cancel() {
        guard let token else { return }
        self.token = nil
        NotificationCenter.default.removeObserver(token)
    }

    isolated deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

// MARK: - AlignmentResultViewController

/// Viewport controller for BAM alignment results.
///
/// Implements ``ResultViewportController`` for the Alignment Viewer viewport
/// class (Track A3). Displays output from read-mapping tools that produce
/// sorted, indexed BAM files.
///
/// ## Current state
/// This implementation stores the result and shows a summary bar plus the BAM
/// payload identity. Detailed pileup/coverage inspection happens in the app's
/// BAM track display surfaces rather than in this summary viewport.
///
/// ## Usage
/// ```swift
/// let vc = AlignmentResultViewController()
/// vc.configure(result: minimap2Result)
/// addChild(vc)
/// ```
@MainActor
public final class AlignmentResultViewController: NSViewController {

    // MARK: - ResultViewportController storage

    /// The most recently configured alignment result.
    private(set) var currentResult: Minimap2Result?

    // MARK: - Summary bar

    /// Backing summary bar view displayed at the top of the viewport.
    private let summaryBar: NSView = {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "Alignment Results")
    private var summaryBarHeightConstraint: NSLayoutConstraint?

    // MARK: - Placeholder content

    /// Placeholder text field shown until a result is configured.
    private let placeholderLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "No alignment loaded")
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private var contentTypographyObservation: AlignmentTypographyObservation?
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
#if DEBUG
    private var typographyApplicationCount = 0
#endif

    // MARK: - Lifecycle

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        self.view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryBar.addSubview(summaryLabel)

        view.addSubview(summaryBar)
        view.addSubview(placeholderLabel)

        let summaryBarHeightConstraint = summaryBar.heightAnchor.constraint(equalToConstant: 32)
        self.summaryBarHeightConstraint = summaryBarHeightConstraint
        NSLayoutConstraint.activate([
            // Summary bar pinned to the top
            summaryBar.topAnchor.constraint(equalTo: view.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryBarHeightConstraint,
            summaryLabel.leadingAnchor.constraint(equalTo: summaryBar.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: summaryBar.trailingAnchor, constant: -12),
            summaryLabel.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),

            // Placeholder centered in the remaining space
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            placeholderLabel.topAnchor.constraint(greaterThanOrEqualTo: summaryBar.bottomAnchor, constant: 12),
            placeholderLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
        ])

        applyContentTypography()
        contentTypographyObservation = AlignmentTypographyObservation { [weak self] in
            self?.applyContentTypography()
        }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateSummaryBarHeight()
    }

    isolated deinit {
        contentTypographyObservation?.cancel()
    }

    // MARK: - Private helpers

    private func applyContentTypography() {
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        let summaryFont = typography.font(for: .caption)
        summaryLabel.font = summaryFont
        placeholderLabel.font = typography.font(for: .detail)
        updateSummaryBarHeight()
        view.needsLayout = true
#if DEBUG
        typographyApplicationCount += 1
#endif
    }

    private func updateSummaryBarHeight() {
        guard let summaryFont = summaryLabel.font else { return }
        let availableWidth = max(
            1,
            (summaryBar.bounds.width > 0 ? summaryBar.bounds.width : view.bounds.width) - 24
        )
        let measuredHeight = measuredTextHeight(
            summaryLabel.stringValue,
            font: summaryFont,
            width: availableWidth,
            maximumLines: summaryLabel.maximumNumberOfLines
        )
        let requiredHeight = max(
            32,
            ceil(measuredHeight + 12)
        )
        if abs((summaryBarHeightConstraint?.constant ?? 0) - requiredHeight) > 0.5 {
            summaryBarHeightConstraint?.constant = requiredHeight
        }
    }

    private func measuredTextHeight(
        _ text: String,
        font: NSFont,
        width: CGFloat,
        maximumLines: Int
    ) -> CGFloat {
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        guard maximumLines > 0 else { return ceil(measured) }
        return ceil(min(measured, font.boundingRectForFont.height * CGFloat(maximumLines)))
    }

    private func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        guard isViewLoaded else { return }
        applyContentTypography()
    }

    /// Updates the summary bar label to reflect the current result.
    private func updateSummaryBar() {
        guard let result = currentResult else { return }

        let mapped = result.mappedReads
        let total = result.totalReads
        let pct = total > 0 ? String(format: "%.1f%%", Double(mapped) / Double(total) * 100) : "—"

        summaryLabel.stringValue = "Alignment Results — \(mapped.formatted()) / \(total.formatted()) reads mapped (\(pct))"
        updateSummaryBarHeight()
    }

    /// Updates the placeholder to show the BAM file name once a result is set.
    private func updatePlaceholder() {
        guard let result = currentResult else {
            placeholderLabel.stringValue = "No alignment loaded"
            return
        }
        let name = result.bamURL.deletingPathExtension().lastPathComponent
        placeholderLabel.stringValue = """
        BAM: \(name)
        Alignment summary only. Open the BAM track for pileup and coverage inspection.
        """
        view.needsLayout = true
    }
}

// MARK: - ResultViewportController

extension AlignmentResultViewController: ResultViewportController {

    public typealias ResultType = Minimap2Result

    /// Display name used in menus, window titles, and export dialogs.
    public static var resultTypeName: String { "Alignment Results" }

    /// Configure the viewport with a minimap2 (or compatible) alignment result.
    ///
    /// Stores the result and refreshes the summary bar and placeholder.
    /// - Parameter result: The `Minimap2Result` to display.
    public func configure(result: Minimap2Result) {
        currentResult = result
        updateSummaryBar()
        updatePlaceholder()
    }

    /// The summary bar view shown at the top of the viewport.
    public var summaryBarView: NSView { summaryBar }

    /// Export alignment results.
    ///
    /// - Note: The alignment result viewport is a summary surface; export the
    ///   BAM/index payloads or derived coverage data from the project track.
    public func exportResults(to url: URL, format: ResultExportFormat) throws {
        throw NSError(
            domain: "Lungfish",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Alignment summary export is not available from this viewport"]
        )
    }
}

#if DEBUG
extension AlignmentResultViewController {
    var testSummaryFontPointSize: CGFloat { summaryLabel.font?.pointSize ?? 0 }
    var testSummaryFontLineHeight: CGFloat {
        summaryLabel.font?.boundingRectForFont.height ?? 0
    }
    var testPlaceholderFontPointSize: CGFloat { placeholderLabel.font?.pointSize ?? 0 }
    var testSummaryBarHeight: CGFloat { summaryBarHeightConstraint?.constant ?? 0 }
    var testPlaceholderMaximumNumberOfLines: Int { placeholderLabel.maximumNumberOfLines }
    var testPlaceholderLineBreakMode: NSLineBreakMode { placeholderLabel.lineBreakMode }
    var testTypographyApplicationCount: Int { typographyApplicationCount }
    var testSummaryBarBounds: NSRect { summaryBar.bounds }
    var testSummaryLabelFrame: NSRect { summaryLabel.frame }
    var testPlaceholderFrame: NSRect { placeholderLabel.frame }
    var testSummaryMeasuredTextHeight: CGFloat {
        guard let font = summaryLabel.font else { return 0 }
        return measuredTextHeight(
            summaryLabel.stringValue,
            font: font,
            width: max(1, summaryLabel.bounds.width),
            maximumLines: summaryLabel.maximumNumberOfLines
        )
    }
    var testHasAmbiguousPrimaryLayout: Bool {
        view.hasAmbiguousLayout
            || summaryBar.hasAmbiguousLayout
            || summaryLabel.hasAmbiguousLayout
            || placeholderLabel.hasAmbiguousLayout
    }

    func testSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        setContentPreferredFontProvider(provider)
    }
}
#endif
