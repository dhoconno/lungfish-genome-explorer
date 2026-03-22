// TaxonomyBreadcrumbBar.swift - Zoom path breadcrumb navigation for taxonomy views
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - TaxonomyBreadcrumbBar

/// A horizontal bar showing the current zoom path in the taxonomy hierarchy.
///
/// Displays clickable segments separated by chevron.right SF Symbols:
/// `Root > Bacteria > Proteobacteria > Gammaproteobacteria`
///
/// Each segment is a clickable button that navigates back to that level.
/// The final (current) segment is displayed in bold and is not clickable.
///
/// ## Layout
///
/// The bar is 28pt tall and scrolls horizontally if the path overflows.
/// Uses `NSButton` with `.accessoryBarAction` bezel style for visual
/// consistency with the FASTA collection back button.
@MainActor
final class TaxonomyBreadcrumbBar: NSView {

    // MARK: - Callback

    /// Called when the user clicks a breadcrumb segment to navigate to that node.
    ///
    /// The node is `nil` when clicking the "Root" segment (meaning zoom to root).
    var onNavigateToNode: ((TaxonNode?) -> Void)?

    // MARK: - State

    /// The current zoom path from root to the current zoom node.
    private var pathNodes: [TaxonNode] = []

    /// Whether the bar is showing the root level (no zoom).
    private(set) var isAtRoot: Bool = true

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    private let contentView = NSView()

    // MARK: - Initialization

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])

        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Taxonomy Breadcrumb Navigation")

        // Show root by default
        updateBreadcrumbs(path: [])
    }

    // MARK: - Public API

    /// Updates the breadcrumb bar to show the path from root to the given node.
    ///
    /// - Parameter node: The current zoom target. Pass `nil` to show root only.
    func update(zoomNode: TaxonNode?) {
        if let node = zoomNode {
            pathNodes = node.pathFromRoot()
            isAtRoot = false
        } else {
            pathNodes = []
            isAtRoot = true
        }
        updateBreadcrumbs(path: pathNodes)
    }

    /// Returns the display path as a string (for testing/accessibility).
    var displayPath: String {
        var segments = ["Root"]
        for node in pathNodes {
            if node.rank != .root {
                segments.append(node.name)
            }
        }
        return segments.joined(separator: " > ")
    }

    /// Returns the number of breadcrumb segments shown (including Root).
    var segmentCount: Int {
        let nonRootNodes = pathNodes.filter { $0.rank != .root }
        return 1 + nonRootNodes.count  // +1 for Root
    }

    // MARK: - Breadcrumb Construction

    private func updateBreadcrumbs(path: [TaxonNode]) {
        // Remove existing subviews from content view
        for sub in contentView.subviews {
            sub.removeFromSuperview()
        }

        var views: [NSView] = []
        let isLast: (Int, Int) -> Bool = { index, count in index == count - 1 }

        // Build the segments: "Root" + each non-root node in the path
        var segments: [(name: String, node: TaxonNode?)] = [("Root", nil)]
        for node in path where node.rank != .root {
            segments.append((node.name, node))
        }

        for (index, segment) in segments.enumerated() {
            let isFinal = isLast(index, segments.count)

            // Add chevron separator before non-first segments
            if index > 0 {
                let chevron = makeChevron()
                views.append(chevron)
            }

            let button = makeSegmentButton(
                title: segment.name,
                node: segment.node,
                isCurrent: isFinal
            )
            views.append(button)
        }

        // Layout horizontally
        var leading = contentView.leadingAnchor
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)

            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leading, constant: leading === contentView.leadingAnchor ? 8 : 2),
                v.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
            leading = v.trailingAnchor
        }

        // Pin trailing for scroll content size
        if let last = views.last {
            last.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -8).isActive = true
        }

        // Ensure content view is wide enough
        if let last = views.last {
            let widthConstraint = contentView.trailingAnchor.constraint(
                greaterThanOrEqualTo: last.trailingAnchor, constant: 8
            )
            widthConstraint.isActive = true
        }
    }

    private func makeSegmentButton(title: String, node: TaxonNode?, isCurrent: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(breadcrumbClicked(_:)))
        button.bezelStyle = .accessoryBarAction
        button.font = isCurrent
            ? .systemFont(ofSize: 11, weight: .semibold)
            : .systemFont(ofSize: 11, weight: .regular)
        button.isBordered = !isCurrent
        button.isEnabled = !isCurrent
        button.tag = node?.taxId ?? 0
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        if isCurrent {
            button.contentTintColor = .labelColor
        }

        button.setAccessibilityLabel(
            isCurrent ? "Current: \(title)" : "Navigate to \(title)"
        )

        return button
    }

    private func makeChevron() -> NSImageView {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let imageView = NSImageView(image: image ?? NSImage())
        imageView.contentTintColor = .tertiaryLabelColor
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        return imageView
    }

    // MARK: - Actions

    @objc private func breadcrumbClicked(_ sender: NSButton) {
        let taxId = sender.tag
        if taxId == 0 {
            // Root
            onNavigateToNode?(nil)
        } else {
            // Find the node in the path
            let targetNode = pathNodes.first { $0.taxId == taxId }
            onNavigateToNode?(targetNode)
        }
    }
}
