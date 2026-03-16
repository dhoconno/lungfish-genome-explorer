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
    private let overflowPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dismissButton: NSButton
    private var barHeightConstraint: NSLayoutConstraint!
    private var geneRegions: [GeneRegion] = []
    private var visibleRegions: [GeneRegion] = []
    private var selectedGlobalIndex: Int?

    private static let barHeight: CGFloat = 28
    private static let maxVisibleTabs = 8

    public override init(frame frameRect: NSRect) {
        dismissButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close gene tabs")!,
                                 target: nil, action: nil)
        super.init(frame: frameRect)


        // Segmented control styling
        segmentedControl.segmentStyle = .automatic
        segmentedControl.trackingMode = .selectOne
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentClicked(_:))
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.controlSize = .small
        segmentedControl.font = .systemFont(ofSize: 11, weight: .medium)
        addSubview(segmentedControl)

        // Overflow popup for long gene lists.
        overflowPopup.target = self
        overflowPopup.action = #selector(overflowSelected(_:))
        overflowPopup.controlSize = .small
        overflowPopup.font = .systemFont(ofSize: 11, weight: .regular)
        overflowPopup.translatesAutoresizingMaskIntoConstraints = false
        overflowPopup.isHidden = true
        addSubview(overflowPopup)

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
            segmentedControl.trailingAnchor.constraint(lessThanOrEqualTo: overflowPopup.leadingAnchor, constant: -8),

            overflowPopup.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflowPopup.trailingAnchor.constraint(lessThanOrEqualTo: dismissButton.leadingAnchor, constant: -8),
            overflowPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),

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
    func setGeneRegions(
        _ regions: [GeneRegion],
        preferredRegion: GeneRegion? = nil,
        preferredGeneName: String? = nil
    ) {
        let priorSelectedName = selectedGeneRegion?.name
        geneRegions = regions

        if regions.isEmpty {
            selectedGlobalIndex = nil
            visibleRegions = []
            overflowPopup.removeAllItems()
            barHeightConstraint.constant = 0
            isHidden = true
            logger.debug("Gene tab bar hidden")
            return
        }

        // Populate primary tabs with an overflow menu for remaining genes.
        visibleRegions = Array(regions.prefix(Self.maxVisibleTabs))
        segmentedControl.segmentCount = visibleRegions.count
        for (i, region) in visibleRegions.enumerated() {
            let label = "\(region.name) (\(region.chromosome))"
            segmentedControl.setLabel(label, forSegment: i)
            segmentedControl.setWidth(0, forSegment: i) // auto-size
        }

        rebuildOverflowMenu()

        // Preserve previous selection when possible.
        if let preferredRegion,
           let idx = regions.firstIndex(where: {
               $0.name.caseInsensitiveCompare(preferredRegion.name) == .orderedSame &&
               $0.chromosome.caseInsensitiveCompare(preferredRegion.chromosome) == .orderedSame &&
               $0.start == preferredRegion.start &&
               $0.end == preferredRegion.end
           }) {
            selectedGlobalIndex = idx
        } else if let candidateName = preferredGeneName ?? priorSelectedName ?? regions.first?.name,
           let idx = regions.firstIndex(where: { $0.name.caseInsensitiveCompare(candidateName) == .orderedSame }) {
            selectedGlobalIndex = idx
        } else {
            selectedGlobalIndex = regions.isEmpty ? nil : 0
        }
        refreshSelectionUI()

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
        guard let selectedGlobalIndex,
              selectedGlobalIndex >= 0,
              selectedGlobalIndex < geneRegions.count else { return nil }
        return geneRegions[selectedGlobalIndex]
    }

    /// Selects a gene tab by index without firing the delegate.
    func selectGeneTab(at index: Int) {
        guard index >= 0, index < geneRegions.count else { return }
        selectedGlobalIndex = index
        refreshSelectionUI()
    }

    // MARK: - Actions

    @objc private func segmentClicked(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard idx >= 0, idx < visibleRegions.count else { return }
        guard let globalIndex = indexOfVisibleRegion(visibleRegions[idx]) else { return }
        selectedGlobalIndex = globalIndex
        refreshSelectionUI()
        let region = visibleRegions[idx]
        logger.debug("Gene tab selected: \(region.name, privacy: .public) at \(region.chromosome, privacy: .public):\(region.start)-\(region.end)")
        delegate?.geneTabBar(self, didSelectGene: region)
    }

    @objc private func overflowSelected(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx > 0 else { return } // index 0 is header item
        let remainingStart = visibleRegions.count
        let globalIndex = remainingStart + (idx - 1)
        guard globalIndex >= 0, globalIndex < geneRegions.count else { return }
        selectedGlobalIndex = globalIndex
        refreshSelectionUI()
        delegate?.geneTabBar(self, didSelectGene: geneRegions[globalIndex])
    }

    @objc private func dismissClicked(_ sender: NSButton) {
        setGeneRegions([])
        delegate?.geneTabBarDidRequestDismiss(self)
    }

    // MARK: - Helpers

    private func rebuildOverflowMenu() {
        overflowPopup.removeAllItems()
        let overflowCount = max(0, geneRegions.count - visibleRegions.count)
        guard overflowCount > 0 else {
            overflowPopup.isHidden = true
            return
        }

        overflowPopup.isHidden = false
        overflowPopup.addItem(withTitle: "More (\(overflowCount))")
        overflowPopup.item(at: 0)?.isEnabled = false

        for region in geneRegions.dropFirst(visibleRegions.count) {
            overflowPopup.addItem(withTitle: "\(region.name) (\(region.chromosome))")
        }
    }

    private func indexOfVisibleRegion(_ region: GeneRegion) -> Int? {
        geneRegions.firstIndex {
            $0.name == region.name &&
            $0.chromosome == region.chromosome &&
            $0.start == region.start &&
            $0.end == region.end
        }
    }

    private func refreshSelectionUI() {
        guard let selectedGlobalIndex else {
            segmentedControl.selectedSegment = -1
            if overflowPopup.numberOfItems > 0 {
                overflowPopup.selectItem(at: 0)
            }
            return
        }

        if selectedGlobalIndex < visibleRegions.count {
            segmentedControl.selectedSegment = selectedGlobalIndex
            if overflowPopup.numberOfItems > 0 {
                overflowPopup.selectItem(at: 0)
            }
        } else {
            segmentedControl.selectedSegment = -1
            if overflowPopup.numberOfItems > 0 {
                let overflowIndex = selectedGlobalIndex - visibleRegions.count
                overflowPopup.selectItem(at: overflowIndex + 1)
            }
        }
    }

    // MARK: - Drawing

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        // Subtle separator line at the bottom
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
