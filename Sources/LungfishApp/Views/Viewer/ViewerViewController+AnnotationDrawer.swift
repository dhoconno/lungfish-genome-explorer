// ViewerViewController+AnnotationDrawer.swift - Annotation drawer integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

/// Logger for annotation drawer operations
private let annotDrawerLogger = Logger(subsystem: "com.lungfish.browser", category: "ViewerAnnotationDrawer")

/// Height of the annotation drawer when open.
private let annotationDrawerHeight: CGFloat = 250

// MARK: - ViewerViewController Annotation Drawer Extension

extension ViewerViewController: AnnotationTableDrawerDelegate {

    // MARK: - Public API

    /// Toggles the annotation drawer open/closed with animation.
    public func toggleAnnotationDrawer() {
        if annotationDrawerView == nil {
            configureAnnotationDrawer()
        }

        guard let bottomConstraint = annotationDrawerBottomConstraint else { return }

        let isOpen = isAnnotationDrawerOpen
        let target: CGFloat = isOpen ? annotationDrawerHeight : 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            bottomConstraint.animator().constant = target
            self.view.layoutSubtreeIfNeeded()
        }

        isAnnotationDrawerOpen = !isOpen
        annotDrawerLogger.info("toggleAnnotationDrawer: Drawer now \(self.isAnnotationDrawerOpen ? "open" : "closed")")

        // Connect to search index if opening and index is available
        if isAnnotationDrawerOpen, let index = annotationSearchIndex {
            if !index.isBuilding {
                annotationDrawerView?.setSearchIndex(index)
            }
        }
    }

    // MARK: - Configuration

    /// Creates and configures the annotation drawer, inserting it into the view hierarchy.
    private func configureAnnotationDrawer() {
        guard annotationDrawerView == nil else { return }

        let drawer = AnnotationTableDrawerView()
        drawer.translatesAutoresizingMaskIntoConstraints = false
        drawer.delegate = self
        view.addSubview(drawer)

        // The drawer sits between the viewer content area and the status bar.
        // We constrain its bottom to be just above the status bar, and use
        // a height constraint. The bottom offset starts at drawerHeight (hidden below view).
        let bottomConstraint = drawer.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: annotationDrawerHeight)

        NSLayoutConstraint.activate([
            drawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            drawer.heightAnchor.constraint(equalToConstant: annotationDrawerHeight),
            bottomConstraint,
        ])

        annotationDrawerView = drawer
        annotationDrawerBottomConstraint = bottomConstraint
        isAnnotationDrawerOpen = false

        // Update the viewer and header bottom constraints to sit above the drawer
        // We need to find and update the existing bottom constraints
        updateViewerBottomConstraints()

        // Populate if index is ready, otherwise drawer defaults to loading state
        if let index = annotationSearchIndex, !index.isBuilding {
            drawer.setSearchIndex(index)
        }

        annotDrawerLogger.info("configureAnnotationDrawer: Created annotation drawer")
    }

    /// Updates the viewer/header bottom constraints to account for the drawer.
    private func updateViewerBottomConstraints() {
        guard let drawer = annotationDrawerView else { return }

        // Find and update constraints that pin views to statusBar.topAnchor
        for constraint in view.constraints {
            // Update viewerView.bottomAnchor == statusBar.topAnchor
            if constraint.firstItem === viewerView,
               constraint.firstAttribute == .bottom,
               constraint.secondItem === statusBar,
               constraint.secondAttribute == .top {
                constraint.isActive = false
                viewerView.bottomAnchor.constraint(equalTo: drawer.topAnchor).isActive = true
                continue
            }
            // Update headerView.bottomAnchor == statusBar.topAnchor
            if constraint.firstItem === headerView,
               constraint.firstAttribute == .bottom,
               constraint.secondItem === statusBar,
               constraint.secondAttribute == .top {
                constraint.isActive = false
                headerView.bottomAnchor.constraint(equalTo: drawer.topAnchor).isActive = true
                continue
            }
        }
    }

    // MARK: - AnnotationTableDrawerDelegate

    public func annotationDrawer(_ drawer: AnnotationTableDrawerView, didSelectAnnotation result: AnnotationSearchIndex.SearchResult) {
        annotDrawerLogger.info("annotationDrawer: Navigating to '\(result.name, privacy: .public)' type=\(result.type, privacy: .public) at \(result.chromosome, privacy: .public):\(result.start)-\(result.end) strand=\(result.strand, privacy: .public)")

        let buffer = 1000 // 1kb buffer on each side

        // Clear any previous sequence fetch error so the new region can be fetched
        viewerView.clearSequenceFetchError()

        // Log current viewer state before navigation
        let currentChrom = referenceFrame?.chromosome ?? "nil"
        let currentScale = referenceFrame?.scale ?? 0
        annotDrawerLogger.info("annotationDrawer: Pre-nav state: currentChrom=\(currentChrom, privacy: .public), scale=\(currentScale, format: .fixed(precision: 2)) bp/px")

        if let provider = currentBundleDataProvider,
           let chromInfo = provider.chromosomeInfo(named: result.chromosome) {
            annotDrawerLogger.info("annotationDrawer: Using bundle provider, chromLength=\(chromInfo.length)")
            navigateToChromosomeAndPosition(
                chromosome: result.chromosome,
                chromosomeLength: Int(chromInfo.length),
                start: max(0, result.start - buffer),
                end: min(Int(chromInfo.length), result.end + buffer)
            )
        } else {
            annotDrawerLogger.info("annotationDrawer: No bundle provider, using navigateToPosition")
            navigateToPosition(
                chromosome: result.chromosome,
                start: max(0, result.start - buffer),
                end: result.end + buffer
            )
        }

        // Look up the full annotation record from SQLite (preserves BED12 exon blocks).
        // Falls back to a flat single-interval annotation if the database lookup fails.
        let annotation: SequenceAnnotation
        if let record = annotationSearchIndex?.annotationDatabase?.lookupAnnotation(
            name: result.name,
            chromosome: result.chromosome,
            start: result.start,
            end: result.end
        ) {
            annotation = record.toAnnotation()
        } else {
            let strand: Strand = switch result.strand {
            case "+": .forward
            case "-": .reverse
            default: .unknown
            }
            let annotationType = AnnotationType.from(rawString: result.type) ?? .gene
            annotation = SequenceAnnotation(
                type: annotationType,
                name: result.name,
                chromosome: result.chromosome,
                intervals: [AnnotationInterval(start: result.start, end: result.end)],
                strand: strand
            )
        }
        viewerView.selectedAnnotation = annotation
        viewerView.postAnnotationSelectedNotification(annotation)
        viewerView.setNeedsDisplay(viewerView.bounds)
    }
}

// MARK: - ViewerViewController Stored Properties for Annotation Drawer

extension ViewerViewController {

    private static var annotationDrawerViewKey: UInt8 = 0
    private static var annotationDrawerBottomKey: UInt8 = 0
    private static var annotationDrawerOpenKey: UInt8 = 0
    private static var annotationSearchIndexKey: UInt8 = 0

    var annotationDrawerView: AnnotationTableDrawerView? {
        get { objc_getAssociatedObject(self, &Self.annotationDrawerViewKey) as? AnnotationTableDrawerView }
        set { objc_setAssociatedObject(self, &Self.annotationDrawerViewKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var annotationDrawerBottomConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &Self.annotationDrawerBottomKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &Self.annotationDrawerBottomKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var isAnnotationDrawerOpen: Bool {
        get { (objc_getAssociatedObject(self, &Self.annotationDrawerOpenKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &Self.annotationDrawerOpenKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    public var annotationSearchIndex: AnnotationSearchIndex? {
        get { objc_getAssociatedObject(self, &Self.annotationSearchIndexKey) as? AnnotationSearchIndex }
        set {
            objc_setAssociatedObject(self, &Self.annotationSearchIndexKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // If the drawer exists and index is ready, populate it
            if let index = newValue, !index.isBuilding, let drawer = annotationDrawerView {
                drawer.setSearchIndex(index)
            }
        }
    }
}
