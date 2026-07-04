// AlignmentResultViewController.swift - Summary viewport for BAM alignment results
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Track A3: Alignment Viewer viewport class.
//
// Displays BAM alignment output summaries from read-mapping tools (minimap2,
// BWA-MEM2, Bowtie2). Detailed pileup and coverage inspection is handled by
// the project's BAM track viewers; this result viewport remains a lightweight
// summary surface.
//
// ## Viewport class conventions
// All alignment tools share this single viewport. The ResultType is
// Minimap2Result because minimap2 is the first tool in this class; future
// tools (BWA-MEM2, Bowtie2) will contribute the same result type or a common
// AlignmentResult wrapper once those pipelines are added.

import AppKit
import LungfishWorkflow
import LungfishKit

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

        let label = NSTextField(labelWithString: "Alignment Results")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 32),
        ])

        return bar
    }()

    // MARK: - Placeholder content

    /// Placeholder text field shown until a result is configured.
    private let placeholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "No alignment loaded")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Lifecycle

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        self.view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(summaryBar)
        view.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            // Summary bar pinned to the top
            summaryBar.topAnchor.constraint(equalTo: view.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Placeholder centered in the remaining space
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Private helpers

    /// Updates the summary bar label to reflect the current result.
    private func updateSummaryBar() {
        guard let result = currentResult else { return }

        let mapped = result.mappedReads
        let total = result.totalReads
        let pct = total > 0 ? String(format: "%.1f%%", Double(mapped) / Double(total) * 100) : "—"

        // Find the label inside the summary bar and update it
        if let label = summaryBar.subviews.compactMap({ $0 as? NSTextField }).first {
            label.stringValue = "Alignment Results — \(mapped.formatted()) / \(total.formatted()) reads mapped (\(pct))"
        }
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
