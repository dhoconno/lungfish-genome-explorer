// BlastResultsDrawerContainerView.swift - Shared resizable container for BLAST drawers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

// MARK: - BlastResultsDrawerDividerView

/// Drag-to-resize handle for the shared BLAST drawer container.
///
/// Mirrors the divider styling used by the other metagenomics drawers so the
/// bottom BLAST drawer feels consistent across result views.
@MainActor
final class BlastResultsDrawerDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    private var dragStartY: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityElement(true)
        setAccessibilityLabel("Resize BLAST drawer")
        setAccessibilityIdentifier("blast-results-drawer-divider")
        setAccessibilityHelp("Drag vertically to resize the BLAST results drawer.")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1))

        let cx = bounds.midX
        let cy = bounds.midY
        NSColor.tertiaryLabelColor.setFill()
        for offset: CGFloat in [-2, 0, 2] {
            NSBezierPath.fill(NSRect(x: cx - 8, y: cy + offset, width: 16, height: 0.5))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        let currentY = NSEvent.mouseLocation.y
        let delta = currentY - dragStartY
        dragStartY = currentY
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}

// MARK: - BlastResultsDrawerContainerView

/// Shared wrapper that places a draggable divider above a `BlastResultsDrawerTab`.
///
/// The container itself is sized by its host controller. The divider lets the
/// host adjust the height constraint while keeping the tab content reusable.
@MainActor
public final class BlastResultsDrawerContainerView: NSView {
    let dividerView = BlastResultsDrawerDividerView()
    private let contentContainer = NSView()
    let blastResultsTab = BlastResultsDrawerTab()

    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    var onRerunBlast: (() -> Void)? {
        didSet {
            blastResultsTab.onRerunBlast = onRerunBlast
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        blastResultsTab.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dividerView)
        addSubview(contentContainer)
        contentContainer.addSubview(blastResultsTab)

        dividerView.onDrag = { [weak self] delta in
            self?.onDrag?(delta)
        }
        dividerView.onDragEnd = { [weak self] in
            self?.onDragEnd?()
        }

        NSLayoutConstraint.activate([
            dividerView.topAnchor.constraint(equalTo: topAnchor),
            dividerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 8),

            contentContainer.topAnchor.constraint(equalTo: dividerView.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            blastResultsTab.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            blastResultsTab.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            blastResultsTab.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            blastResultsTab.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    func showEmpty() {
        blastResultsTab.showEmpty()
    }

    func showLoading(phase: BlastJobPhase, requestId: String?) {
        blastResultsTab.showLoading(phase: phase, requestId: requestId)
    }

    func showResults(_ result: BlastVerificationResult) {
        blastResultsTab.showResults(result)
    }

    func showFailure(message: String) {
        blastResultsTab.showFailure(message: message)
    }

    // MARK: - Testing Accessors

    var testDividerView: NSView { dividerView }
    var testDrawerTab: BlastResultsDrawerTab { blastResultsTab }
    var testContentContainer: NSView { contentContainer }
}
