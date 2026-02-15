// GeneTabBarView.swift - Browser-style gene tab bar for multi-gene navigation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import os.log

private let logger = Logger(subsystem: "com.lungfish.browser", category: "GeneTabBar")

/// A resolved gene region for tab bar display.
public struct GeneRegion {
    public let name: String
    public let chromosome: String
    public let start: Int
    public let end: Int

    public init(name: String, chromosome: String, start: Int, end: Int) {
        self.name = name
        self.chromosome = chromosome
        self.start = start
        self.end = end
    }
}

/// Delegate for gene tab bar interactions.
@MainActor
protocol GeneTabBarDelegate: AnyObject {
    func geneTabBar(_ tabBar: GeneTabBarView, didSelectGene region: GeneRegion)
    func geneTabBarDidRequestDismiss(_ tabBar: GeneTabBarView)
}

/// A lightweight tab bar that appears above the genome viewer when
/// a gene list query resolves multiple discontiguous gene regions.
///
/// Each tab represents one gene. Clicking a tab navigates the viewer
/// to that gene's genomic region without duplicating the viewer.
@MainActor
public final class GeneTabBarView: NSView {

    weak var delegate: GeneTabBarDelegate?

    private let segmentedControl = NSSegmentedControl()
    private let dismissButton: NSButton
    private var barHeightConstraint: NSLayoutConstraint!
    private var geneRegions: [GeneRegion] = []

    private static let barHeight: CGFloat = 28

    public override init(frame frameRect: NSRect) {
        dismissButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close gene tabs")!,
                                 target: nil, action: nil)
        super.init(frame: frameRect)

        wantsLayer = true

        // Segmented control styling
        segmentedControl.segmentStyle = .automatic
        segmentedControl.trackingMode = .selectOne
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentClicked(_:))
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.controlSize = .small
        segmentedControl.font = .systemFont(ofSize: 11, weight: .medium)
        addSubview(segmentedControl)

        // Dismiss button
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked(_:))
        dismissButton.bezelStyle = .accessoryBarAction
        dismissButton.isBordered = false
        dismissButton.controlSize = .small
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.setAccessibilityLabel("Dismiss gene tabs")
        addSubview(dismissButton)

        // Height constraint — 0 when hidden
        barHeightConstraint = heightAnchor.constraint(equalToConstant: 0)

        // Layout
        NSLayoutConstraint.activate([
            barHeightConstraint,

            segmentedControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            segmentedControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            segmentedControl.trailingAnchor.constraint(lessThanOrEqualTo: dismissButton.leadingAnchor, constant: -8),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 20),
            dismissButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// Populates the tab bar with gene regions.
    /// Pass an empty array to hide the tab bar.
    func setGeneRegions(_ regions: [GeneRegion]) {
        geneRegions = regions

        if regions.isEmpty {
            barHeightConstraint.constant = 0
            isHidden = true
            logger.debug("Gene tab bar hidden")
            return
        }

        // Populate segments (cap at 20)
        let displayRegions = Array(regions.prefix(20))
        segmentedControl.segmentCount = displayRegions.count
        for (i, region) in displayRegions.enumerated() {
            let label = "\(region.name) (\(region.chromosome))"
            segmentedControl.setLabel(label, forSegment: i)
            segmentedControl.setWidth(0, forSegment: i) // auto-size
        }

        segmentedControl.selectedSegment = 0

        barHeightConstraint.constant = Self.barHeight
        isHidden = false

        // Animate appearance
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            superview?.layoutSubtreeIfNeeded()
        }

        logger.info("Gene tab bar showing \(regions.count) gene(s)")
    }

    /// Returns the currently selected gene region, or nil if none.
    var selectedGeneRegion: GeneRegion? {
        let idx = segmentedControl.selectedSegment
        guard idx >= 0, idx < geneRegions.count else { return nil }
        return geneRegions[idx]
    }

    /// Selects a gene tab by index without firing the delegate.
    func selectGeneTab(at index: Int) {
        guard index >= 0, index < segmentedControl.segmentCount else { return }
        segmentedControl.selectedSegment = index
    }

    // MARK: - Actions

    @objc private func segmentClicked(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard idx >= 0, idx < geneRegions.count else { return }
        let region = geneRegions[idx]
        logger.debug("Gene tab selected: \(region.name, privacy: .public) at \(region.chromosome, privacy: .public):\(region.start)-\(region.end)")
        delegate?.geneTabBar(self, didSelectGene: region)
    }

    @objc private func dismissClicked(_ sender: NSButton) {
        setGeneRegions([])
        delegate?.geneTabBarDidRequestDismiss(self)
    }

    // MARK: - Drawing

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        // Subtle separator line at the bottom
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
