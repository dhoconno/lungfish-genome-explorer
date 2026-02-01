// ViewerViewController.swift - Main sequence/track viewer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

/// Controller for the main viewer panel containing sequence and track display.
///
/// This is a placeholder that will be expanded with Metal rendering
/// and the full track system in later phases.
@MainActor
public class ViewerViewController: NSViewController {

    // MARK: - UI Components

    /// The custom view for rendering sequences and tracks
    private var viewerView: SequenceViewerView!

    /// Header view for track labels
    private var headerView: TrackHeaderView!

    /// Coordinate ruler at the top
    private var rulerView: CoordinateRulerView!

    /// Status bar at the bottom
    private var statusBar: ViewerStatusBar!

    // MARK: - State

    /// Current reference frame for coordinate mapping
    public var referenceFrame: ReferenceFrame?

    // MARK: - Lifecycle

    public override func loadView() {
        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true

        // Create ruler view
        rulerView = CoordinateRulerView()
        rulerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(rulerView)

        // Create track header view
        headerView = TrackHeaderView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(headerView)

        // Create main viewer view
        viewerView = SequenceViewerView()
        viewerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(viewerView)

        // Create status bar
        statusBar = ViewerStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusBar)

        // Layout
        let headerWidth: CGFloat = 120
        let rulerHeight: CGFloat = 24
        let statusHeight: CGFloat = 22

        NSLayoutConstraint.activate([
            // Ruler spans full width above content
            rulerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            rulerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: headerWidth),
            rulerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            rulerView.heightAnchor.constraint(equalToConstant: rulerHeight),

            // Header on the left
            headerView.topAnchor.constraint(equalTo: rulerView.bottomAnchor),
            headerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            headerView.widthAnchor.constraint(equalToConstant: headerWidth),
            headerView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Viewer fills the main area
            viewerView.topAnchor.constraint(equalTo: rulerView.bottomAnchor),
            viewerView.leadingAnchor.constraint(equalTo: headerView.trailingAnchor),
            viewerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            viewerView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Status bar at the bottom
            statusBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: statusHeight),
        ])

        self.view = containerView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Set background color
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Create initial reference frame
        referenceFrame = ReferenceFrame(
            chromosome: "chr1",
            start: 0,
            end: 10000,
            pixelWidth: Int(view.bounds.width)
        )
    }

    // MARK: - Public API

    /// Zooms in on the current view
    public func zoomIn() {
        referenceFrame?.zoomIn(factor: 2.0)
        viewerView.setNeedsDisplay(viewerView.bounds)
        rulerView.setNeedsDisplay(rulerView.bounds)
        updateStatusBar()
    }

    /// Zooms out from the current view
    public func zoomOut() {
        referenceFrame?.zoomOut(factor: 2.0)
        viewerView.setNeedsDisplay(viewerView.bounds)
        rulerView.setNeedsDisplay(rulerView.bounds)
        updateStatusBar()
    }

    /// Zooms to fit the entire sequence
    public func zoomToFit() {
        // TODO: Implement zoom to fit
    }

    /// Navigates to a specific genomic region
    public func navigate(to region: GenomicRegion) {
        referenceFrame = ReferenceFrame(
            chromosome: region.chromosome,
            start: Double(region.start),
            end: Double(region.end),
            pixelWidth: Int(view.bounds.width)
        )
        viewerView.setNeedsDisplay(viewerView.bounds)
        rulerView.setNeedsDisplay(rulerView.bounds)
        updateStatusBar()
    }

    private func updateStatusBar() {
        guard let frame = referenceFrame else { return }
        statusBar.update(
            position: "\(frame.chromosome):\(Int(frame.start))-\(Int(frame.end))",
            selection: nil,
            scale: frame.scale
        )
    }
}

// MARK: - SequenceViewerView

/// The main view for rendering sequence and track data.
///
/// This is a placeholder that will be replaced with Metal rendering.
public class SequenceViewerView: NSView {

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.textBackgroundColor.cgColor)
        context.fill(bounds)

        // Placeholder message
        let message = "Sequence Viewer\n\nDrop files here or use File > Open"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]

        let size = (message as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )

        (message as NSString).draw(in: rect, withAttributes: attributes)
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        // Handle keyboard navigation
        switch event.keyCode {
        case 123: // Left arrow
            // Pan left
            break
        case 124: // Right arrow
            // Pan right
            break
        case 126: // Up arrow
            // Zoom in
            break
        case 125: // Down arrow
            // Zoom out
            break
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - TrackHeaderView

/// View for displaying track labels and controls.
public class TrackHeaderView: NSView {

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)

        // Right border
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: bounds.maxX - 0.5, y: 0))
        context.addLine(to: CGPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        context.strokePath()

        // Sample track labels
        let labels = ["Reference", "Genes", "Coverage"]
        let rowHeight: CGFloat = 60

        for (index, label) in labels.enumerated() {
            let y = CGFloat(index) * rowHeight + 20
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ]
            (label as NSString).draw(at: CGPoint(x: 8, y: y), withAttributes: attributes)
        }
    }
}

// MARK: - CoordinateRulerView

/// View for displaying genomic coordinate ruler.
public class CoordinateRulerView: NSView {

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)

        // Bottom border
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: bounds.maxY - 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        context.strokePath()

        // Draw ruler ticks (placeholder)
        let tickInterval: CGFloat = 100
        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)

        for x in stride(from: CGFloat(0), to: bounds.width, by: tickInterval) {
            context.move(to: CGPoint(x: x, y: bounds.maxY - 5))
            context.addLine(to: CGPoint(x: x, y: bounds.maxY))
            context.strokePath()
        }
    }
}

// MARK: - ViewerStatusBar

/// Status bar showing current position and selection info.
public class ViewerStatusBar: NSView {

    private var positionLabel: NSTextField!
    private var selectionLabel: NSTextField!
    private var scaleLabel: NSTextField!

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true

        positionLabel = createLabel()
        positionLabel.stringValue = "Position: —"
        addSubview(positionLabel)

        selectionLabel = createLabel()
        selectionLabel.stringValue = "Selection: None"
        addSubview(selectionLabel)

        scaleLabel = createLabel()
        scaleLabel.stringValue = "Scale: —"
        scaleLabel.alignment = .right
        addSubview(scaleLabel)

        NSLayoutConstraint.activate([
            positionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            positionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            positionLabel.widthAnchor.constraint(equalToConstant: 200),

            selectionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            selectionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            scaleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scaleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            scaleLabel.widthAnchor.constraint(equalToConstant: 150),
        ])
    }

    private func createLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)

        // Top border
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: 0.5))
        context.strokePath()
    }

    public func update(position: String?, selection: String?, scale: Double) {
        positionLabel.stringValue = position ?? "Position: —"
        selectionLabel.stringValue = selection ?? "Selection: None"
        scaleLabel.stringValue = String(format: "%.2f bp/px", scale)
    }
}

// MARK: - ReferenceFrame

/// Coordinate system for genomic visualization (following IGV pattern).
public class ReferenceFrame {
    /// Chromosome/sequence name
    public var chromosome: String

    /// Start position in base pairs
    public var start: Double

    /// End position in base pairs
    public var end: Double

    /// Width of the view in pixels
    public var pixelWidth: Int

    /// Base pairs per pixel
    public var scale: Double {
        (end - start) / Double(pixelWidth)
    }

    public init(chromosome: String, start: Double, end: Double, pixelWidth: Int) {
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.pixelWidth = pixelWidth
    }

    /// Converts a screen X coordinate to genomic position
    public func genomicPosition(for screenX: CGFloat) -> Double {
        start + Double(screenX) * scale
    }

    /// Converts a genomic position to screen X coordinate
    public func screenPosition(for genomicPos: Double) -> CGFloat {
        CGFloat((genomicPos - start) / scale)
    }

    /// Zooms in by the specified factor
    public func zoomIn(factor: Double) {
        let center = (start + end) / 2
        let halfWidth = (end - start) / (2 * factor)
        start = max(0, center - halfWidth)
        end = center + halfWidth
    }

    /// Zooms out by the specified factor
    public func zoomOut(factor: Double) {
        let center = (start + end) / 2
        let halfWidth = (end - start) * factor / 2
        start = max(0, center - halfWidth)
        end = center + halfWidth
    }
}
