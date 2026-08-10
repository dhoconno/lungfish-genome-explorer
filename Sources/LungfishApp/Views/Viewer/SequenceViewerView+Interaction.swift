// SequenceViewerView+Interaction.swift - Extracted from SequenceViewerView.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit
import UniformTypeIdentifiers
import Quartz
import PDFKit
import os.log

enum SequenceViewerContextTarget {
    case read(AlignedRead)
    case variant(AnnotationSearchIndex.SearchResult)
    case annotation(SequenceAnnotation)
    case alignment([AlignmentFileMenuEntry])
    case sequence
}

extension SequenceViewerView {

    // MARK: - Annotation Hit-Testing

    /// Finds the annotation at the given point, if any.
    ///
    /// - Parameter point: The point in view coordinates to test.
    /// - Returns: The annotation at that point, or nil if no annotation is at the point.
    func annotationAtPoint(_ point: NSPoint) -> SequenceAnnotation? {
        guard let frame = viewController?.referenceFrame else { return nil }

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)

        // Track row assignments to find correct Y positions (must match drawAnnotations logic)
        var rowEndPositions: [CGFloat] = []

        // Use filtered annotations for hit testing
        let displayAnnotations = filteredAnnotations()

        for annotation in displayAnnotations {
            // Use bounding region for both continuous and discontiguous annotations
            let annotStart = annotation.start
            let annotEnd = annotation.end

            // Check if annotation is visible
            if annotEnd < visibleStart || annotStart > visibleEnd {
                continue
            }

            // Calculate screen coordinates (must match drawAnnotations logic exactly)
            let rawStartX = frame.leadingInset + CGFloat(annotStart - visibleStart) * pixelsPerBase
            let endX = frame.leadingInset + CGFloat(annotEnd - visibleStart) * pixelsPerBase
            // Clamp startX to data area start
            let startX = max(frame.leadingInset, rawStartX)
            let width = max(2, endX - startX)

            // Find row assignment (same logic as drawAnnotations)
            var row = 0
            for (i, endPos) in rowEndPositions.enumerated() {
                if startX >= endPos + 2 {
                    row = i
                    break
                }
                row = i + 1
            }

            while rowEndPositions.count <= row {
                rowEndPositions.append(0)
            }
            rowEndPositions[row] = startX + width

            let y = annotationTrackY + CGFloat(row) * (annotationHeight + annotationRowSpacing)

            // Create bounding rect for this annotation
            let annotRect = CGRect(x: startX, y: y, width: width, height: annotationHeight)

            // Check if point is within this annotation's rect
            if annotRect.contains(point) {
                return annotation
            }
        }

        return nil
    }

    /// Returns the bounding rect of the annotation at the given point.
    ///
    /// This method uses the same logic as `annotationAtPoint` but returns the rect
    /// for anchoring popovers.
    ///
    /// - Parameter point: The point to test in view coordinates
    /// - Returns: The bounding rect of the annotation at the point, or nil if none found
    func annotationRectAtPoint(_ point: NSPoint) -> CGRect? {
        guard let frame = viewController?.referenceFrame else { return nil }

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)

        var rowEndPositions: [CGFloat] = []
        let displayAnnotations = filteredAnnotations()

        for annotation in displayAnnotations {
            let annotStart = annotation.start
            let annotEnd = annotation.end

            if annotEnd < visibleStart || annotStart > visibleEnd {
                continue
            }

            let rawStartX = frame.leadingInset + CGFloat(annotStart - visibleStart) * pixelsPerBase
            let endX = frame.leadingInset + CGFloat(annotEnd - visibleStart) * pixelsPerBase
            let startX = max(frame.leadingInset, rawStartX)
            let width = max(2, endX - startX)

            var row = 0
            for (i, endPos) in rowEndPositions.enumerated() {
                if startX >= endPos + 2 {
                    row = i
                    break
                }
                row = i + 1
            }

            while rowEndPositions.count <= row {
                rowEndPositions.append(0)
            }
            rowEndPositions[row] = startX + width

            let y = annotationTrackY + CGFloat(row) * (annotationHeight + annotationRowSpacing)
            let annotRect = CGRect(x: startX, y: y, width: width, height: annotationHeight)

            if annotRect.contains(point) {
                return annotRect
            }
        }

        return nil
    }

    /// Posts a notification that an annotation was selected.
    /// Internal so the AnnotationDrawer extension can post from table selection.
    func postAnnotationSelectedNotification(_ annotation: SequenceAnnotation?) {
        if let annotation = annotation {
            NotificationCenter.default.post(
                name: .annotationSelected,
                object: self,
                userInfo: windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
            )
            postVariantSelectedNotificationIfNeeded(annotation)
            sequenceViewerLogger.info("Posted annotationSelected notification for '\(annotation.name, privacy: .public)'")
        } else {
            // Post notification with nil to indicate deselection
            NotificationCenter.default.post(
                name: .annotationSelected,
                object: self,
                userInfo: windowScopedUserInfo([NotificationUserInfoKey.inspectorTab: "selection"])
            )
            NotificationCenter.default.post(name: .variantSelected, object: self, userInfo: windowScopedUserInfo())
            sequenceViewerLogger.info("Posted annotationSelected notification (deselection)")
        }
    }

    /// Posts a variant selection notification when the selected annotation is a variant.
    @discardableResult
    func postVariantSelectedNotificationIfNeeded(_ annotation: SequenceAnnotation) -> Bool {
        guard let result = variantSearchResult(for: annotation) else { return false }
        NotificationCenter.default.post(
            name: .variantSelected,
            object: self,
            userInfo: windowScopedUserInfo([NotificationUserInfoKey.searchResult: result])
        )
        return true
    }

    /// Builds a `SearchResult` payload for a variant-like annotation.
    func variantSearchResult(for annotation: SequenceAnnotation) -> AnnotationSearchIndex.SearchResult? {
        let variantTypes: Set<AnnotationType> = [.snp, .insertion, .deletion, .variation]
        let isVariantByType = variantTypes.contains(annotation.type)
        let isVariantByQualifiers = annotation.qualifiers["variant_row_id"] != nil
            || annotation.qualifiers["variant_type"] != nil
            || annotation.qualifiers["ref"] != nil
            || annotation.qualifiers["alt"] != nil
        guard isVariantByType || isVariantByQualifiers else { return nil }
        guard let chromosome = annotation.chromosome else { return nil }

        let rowId = annotation.qualifiers["variant_row_id"]?.values.first.flatMap { Int64($0) }
        let trackId = annotation.qualifiers["variant_track_id"]?.values.first ?? ""
        let variantType = annotation.qualifiers["variant_type"]?.values.first ?? annotation.type.rawValue
        let ref = annotation.qualifiers["ref"]?.values.first
        let alt = annotation.qualifiers["alt"]?.values.first
        let quality = annotation.qualifiers["quality"]?.values.first.flatMap(Double.init)
        let filter = annotation.qualifiers["filter"]?.values.first
        let sampleCount = annotation.qualifiers["sample_count"]?.values.first.flatMap(Int.init)

        return AnnotationSearchIndex.SearchResult(
            name: annotation.name,
            chromosome: chromosome,
            start: annotation.start,
            end: annotation.end,
            trackId: trackId,
            type: variantType,
            strand: annotation.strand.rawValue,
            ref: ref,
            alt: alt,
            quality: quality,
            filter: filter,
            sampleCount: sampleCount,
            variantRowId: rowId
        )
    }

    /// Shows a popover with annotation details at the specified location.
    ///
    /// - Parameters:
    ///   - annotation: The annotation to display details for
    ///   - rect: The bounding rectangle to anchor the popover to
    func showAnnotationPopover(for annotation: SequenceAnnotation, at rect: CGRect) {
        // Close any existing popover
        annotationPopover?.close()

        // Create popover content
        let contentView = NSHostingView(rootView: AnnotationPopoverView(annotation: annotation))
        let popoverController = NSViewController()
        popoverController.view = contentView
        contentView.frame = NSRect(x: 0, y: 0, width: 280, height: 200)

        // Create and configure popover
        let popover = NSPopover()
        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.animates = true

        // Show popover
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        annotationPopover = popover

        sequenceViewerLogger.info("Showing annotation popover for '\(annotation.name, privacy: .public)'")
    }

    // MARK: - Drag and Drop

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sequenceViewerLogger.info("SequenceViewerView.draggingEntered: Drag entered view")
        let canAccept = canAcceptDrag(sender)
        sequenceViewerLogger.info("SequenceViewerView.draggingEntered: canAcceptDrag = \(canAccept)")
        if canAccept {
            isDragActive = true
            setNeedsDisplay(bounds)
            return .copy
        }
        return []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return canAcceptDrag(sender) ? .copy : []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        sequenceViewerLogger.info("SequenceViewerView.draggingExited: Drag exited view")
        isDragActive = false
        setNeedsDisplay(bounds)
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let canAccept = canAcceptDrag(sender)
        sequenceViewerLogger.info("SequenceViewerView.prepareForDragOperation: Preparing, canAccept = \(canAccept)")
        return canAccept
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sequenceViewerLogger.info("SequenceViewerView.performDragOperation: Starting drop operation")
        isDragActive = false

        guard let urls = getURLsFromDrag(sender) else {
            sequenceViewerLogger.warning("SequenceViewerView.performDragOperation: No URLs from drag")
            return false
        }

        sequenceViewerLogger.info("SequenceViewerView.performDragOperation: Got \(urls.count) URLs from drag")
        for (index, url) in urls.enumerated() {
            sequenceViewerLogger.info("SequenceViewerView.performDragOperation: URL[\(index)] = '\(url.path, privacy: .public)'")
        }

        // Filter to supported file types
        let supportedURLs = urls.filter { url in
            let detected = DocumentType.detect(from: url)
            sequenceViewerLogger.info("SequenceViewerView.performDragOperation: '\(url.lastPathComponent, privacy: .public)' -> type=\(detected?.rawValue ?? "nil", privacy: .public)")
            return detected != nil
        }

        sequenceViewerLogger.info("SequenceViewerView.performDragOperation: \(supportedURLs.count) supported URLs after filtering")

        guard !supportedURLs.isEmpty else {
            sequenceViewerLogger.warning("SequenceViewerView.performDragOperation: No supported file types found")
            return false
        }

        // Hand off to view controller
        if let vc = viewController {
            sequenceViewerLogger.info("SequenceViewerView.performDragOperation: Handing off to viewController.handleFileDrop")
            vc.handleFileDrop(supportedURLs)
        } else {
            sequenceViewerLogger.error("SequenceViewerView.performDragOperation: viewController is nil!")
            return false
        }
        return true
    }

    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        sequenceViewerLogger.info("SequenceViewerView.concludeDragOperation: Drag operation concluded")
        isDragActive = false
        setNeedsDisplay(bounds)
    }

    func canAcceptDrag(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = getURLsFromDrag(sender) else {
            sequenceViewerLogger.debug("SequenceViewerView.canAcceptDrag: No URLs in pasteboard")
            return false
        }
        let hasSupported = urls.contains { DocumentType.detect(from: $0) != nil }
        sequenceViewerLogger.debug("SequenceViewerView.canAcceptDrag: hasSupported = \(hasSupported)")
        return hasSupported
    }

    func getURLsFromDrag(_ sender: NSDraggingInfo) -> [URL]? {
        let pasteboard = sender.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL]
        sequenceViewerLogger.debug("SequenceViewerView.getURLsFromDrag: Got \(urls?.count ?? 0) URLs from pasteboard")
        return urls
    }

    // MARK: - Keyboard

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if zoomShortcutHandler.handleZoomShortcut(event) {
            return
        }

        switch event.keyCode {
        case 123: // Left arrow - pan left (use bounded pan)
            viewController?.referenceFrame?.pan(by: -100)
            setNeedsDisplay(bounds)
            viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
            viewController?.updateStatusBar()
        case 124: // Right arrow - pan right (use bounded pan)
            viewController?.referenceFrame?.pan(by: 100)
            setNeedsDisplay(bounds)
            viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
            viewController?.updateStatusBar()
        case 126: // Up arrow
            viewController?.zoomIn()
        case 125: // Down arrow
            viewController?.zoomOut()
        case 8: // 'C' key - copy selection
            if event.modifierFlags.contains(.command) {
                copySelectionToClipboard()
            } else {
                super.keyDown(with: event)
            }
        case 0: // 'A' key - select all
            if event.modifierFlags.contains(.command) {
                selectAll()
            } else {
                super.keyDown(with: event)
            }
        case 53: // Escape - clear selection
            clearSelection()
            // Also clear annotation selection
            if selectedAnnotation != nil {
                selectedAnnotation = nil
                postAnnotationSelectedNotification(nil)
                setNeedsDisplay(bounds)
            }
        default:
            super.keyDown(with: event)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if zoomShortcutHandler.handleZoomShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Gutter Edge Drag

    /// Returns the X position of the gutter right edge, or nil if no genotype rows are showing.
    /// Uses `variantDataStartX` (cached) minus the label-to-data margin.
    func gutterEdgeX() -> CGFloat? {
        let dataStartX = variantDataStartX
        guard dataStartX > 0 else { return nil }
        return dataStartX - VariantTrackRenderer.sampleLabelToDataMargin
    }

    /// Returns true if the point is within 6px of the gutter right edge and in the genotype area.
    func isNearGutterEdge(at point: NSPoint) -> Bool {
        guard let edgeX = gutterEdgeX() else { return false }
        let genotypeTopY = variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
        guard point.y >= genotypeTopY else { return false }
        return abs(point.x - edgeX) <= 6
    }

    /// Returns the sample name if the point is within the gutter label area.
    func sampleNameAtGutterPoint(_ point: NSPoint) -> String? {
        guard let edgeX = gutterEdgeX(),
              point.x < edgeX,
              let genotypeData = filteredVisibleGenotypeData(),
              !genotypeData.sampleNames.isEmpty else { return nil }
        let genotypeTopY = variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
        guard point.y >= genotypeTopY else { return nil }
        let rowH = sampleDisplayState.rowHeight
        guard rowH >= 8 else { return nil }
        let relativeY = point.y - genotypeTopY + genotypeScrollOffset
        let sampleIdx = Int(relativeY / rowH)
        guard sampleIdx >= 0, sampleIdx < genotypeData.sampleNames.count else { return nil }
        return genotypeData.sampleNames[sampleIdx]
    }

    // MARK: - Mouse Selection

    public override func mouseDown(with event: NSEvent) {
        guard let frame = viewController?.referenceFrame else { return }

        let location = convert(event.locationInWindow, from: nil)

        // Check gutter edge drag FIRST — double-click resets to auto-size
        if isNearGutterEdge(at: location) {
            if event.clickCount == 2 {
                sampleDisplayState.sampleGutterWidthOverride = nil
                invalidateGutterWidth()
                setNeedsDisplay(bounds)
                viewController?.scheduleViewStateSave()
            } else {
                isDraggingGutterEdge = true
            }
            return
        }

        let isDoubleClick = event.clickCount == 2
        let hasCmd = event.modifierFlags.contains(.command)
        let hasShift = event.modifierFlags.contains(.shift)

        // 1. Read track click — with Cmd/Shift modifier support for multi-select
        if let read = readAtPoint(location) {
            if hasCmd {
                // Cmd+click: toggle read in/out of selection
                if selectedReadIDs.contains(read.id) {
                    selectedReadIDs.remove(read.id)
                } else {
                    selectedReadIDs.insert(read.id)
                }
            } else if hasShift {
                // Shift+click: add to selection
                selectedReadIDs.insert(read.id)
            } else {
                // Plain click: replace selection with this read
                selectedReadIDs = [read.id]
            }
            NotificationCenter.default.post(
                name: .readSelected,
                object: self,
                userInfo: selectedRead.map { windowScopedUserInfo([NotificationUserInfoKey.alignedRead: $0]) ?? [:] }
            )
            isSelecting = false
            setNeedsDisplay(bounds)
            updateSelectionStatus()
            return
        }
        // Clear read selection if clicking elsewhere (unless modifier held)
        if !selectedReadIDs.isEmpty && !hasCmd && !hasShift {
            selectedReadIDs.removeAll()
            NotificationCenter.default.post(name: .readSelected, object: self, userInfo: windowScopedUserInfo())
        }

        // 2. Variant track click — route to variant selection
        if let variant = variantAtPoint(location) {
            selectedAnnotation = variant
            postVariantSelectedNotificationIfNeeded(variant)
            isSelecting = false
            setNeedsDisplay(bounds)
            updateSelectionStatus()
            return
        }

        // 3. Check for annotation click — bundle mode, multi-sequence mode, or single-sequence mode
        if currentReferenceBundle != nil {
            if let annotation = bundleAnnotationAtPoint(location) {
                selectedAnnotation = annotation
                postAnnotationSelectedNotification(annotation)
                viewController?.selectAnnotationInDrawer(annotation)
                isSelecting = false
                setNeedsDisplay(bounds)
                updateSelectionStatus()

                if isDoubleClick {
                    showAnnotationPopover(for: annotation, at: CGRect(origin: location, size: CGSize(width: 1, height: 1)))
                }
                return
            }
        } else if isMultiSequenceMode, let state = multiSequenceState {
            for stackedInfo in state.stackedSequences {
                if let annotation = annotationAtPoint(location, forSequence: stackedInfo, frame: frame) {
                    selectedAnnotation = annotation
                    postAnnotationSelectedNotification(annotation)
                    viewController?.selectAnnotationInDrawer(annotation)
                    isSelecting = false
                    setNeedsDisplay(bounds)
                    updateSelectionStatus()

                    if isDoubleClick {
                        let annotRect = annotationRectAtPoint(location, forSequence: stackedInfo, frame: frame)
                        showAnnotationPopover(for: annotation, at: annotRect ?? CGRect(origin: location, size: CGSize(width: 1, height: 1)))
                    }
                    return
                }
            }
        } else {
            if let annotation = annotationAtPoint(location) {
                selectedAnnotation = annotation
                postAnnotationSelectedNotification(annotation)
                viewController?.selectAnnotationInDrawer(annotation)
                isSelecting = false
                setNeedsDisplay(bounds)
                updateSelectionStatus()

                if isDoubleClick {
                    let annotRect = annotationRectAtPoint(location)
                    showAnnotationPopover(for: annotation, at: annotRect ?? CGRect(origin: location, size: CGSize(width: 1, height: 1)))
                }
                return
            }
        }

        // Clear annotation selection if clicking in annotation area but not on one
        if selectedAnnotation != nil {
            var inAnnotationArea = false
            if isMultiSequenceMode, let state = multiSequenceState {
                for stackedInfo in state.stackedSequences {
                    if isPointInAnnotationArea(location, forSequence: stackedInfo) {
                        inAnnotationArea = true
                        break
                    }
                }
            } else {
                inAnnotationArea = location.y >= annotationTrackY
            }

            if inAnnotationArea {
                selectedAnnotation = nil
                postAnnotationSelectedNotification(nil)
            }
        }

        // 4. No object hit — begin column selection
        let clickedBase = basePositionAt(x: location.x, frame: frame)
        columnDragStartBase = clickedBase
        isUserColumnSelection = true
        selectionRange = clickedBase..<(clickedBase + 1)
        isSelecting = true
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    public override func mouseDragged(with event: NSEvent) {
        if isDraggingGutterEdge {
            let location = convert(event.locationInWindow, from: nil)
            let newWidth = max(40, min(400, location.x))
            sampleDisplayState.sampleGutterWidthOverride = newWidth
            invalidateGutterWidth()
            // Update frame inset immediately so ruler stays in sync
            if let frame = viewController?.referenceFrame {
                frame.leadingInset = variantDataStartX
            }
            setNeedsDisplay(bounds)
            viewController?.enhancedRulerView.needsDisplay = true
            return
        }

        guard isSelecting,
              let frame = viewController?.referenceFrame,
              let dragStart = columnDragStartBase else { return }

        let location = convert(event.locationInWindow, from: nil)
        let currentBase = basePositionAt(x: location.x, frame: frame)

        let lower = min(dragStart, currentBase)
        let upper = max(dragStart, currentBase) + 1
        selectionRange = lower..<upper
        isUserColumnSelection = true

        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    public override func mouseUp(with event: NSEvent) {
        if isDraggingGutterEdge {
            isDraggingGutterEdge = false
            viewController?.scheduleViewStateSave()
            return
        }
        isSelecting = false
        columnDragStartBase = nil
    }

    // MARK: - Right-Click Context Menu

    func buildContextMenu(
        for target: SequenceViewerContextTarget,
        clickedTrackIndex: Int? = nil
    ) -> NSMenu {
        let menu: NSMenu
        switch target {
        case .sequence:
            menu = buildSequenceContextMenu(clickedTrackIndex: clickedTrackIndex)
        case .read(let read):
            menu = buildReadContextMenu(for: read) ?? NSMenu(title: "Read Selection")
        case .alignment(let entries):
            menu = buildAlignmentContextMenu(for: entries)
        case .variant(let result):
            menu = buildVariantContextMenu(for: result)
        case .annotation(let annotation):
            menu = buildAnnotationContextMenu(for: annotation)
        }

        if selectionRange != nil {
            appendSelectedRangeMenuItems(to: menu)
        }
        normalizeContextMenuSeparators(in: menu)
        return menu
    }

    private func buildSequenceContextMenu(clickedTrackIndex: Int?) -> NSMenu {
        let menu = NSMenu(title: "Sequence")

        guard selectionRange == nil else { return menu }

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        menu.addItem(NSMenuItem.separator())
        if selectionRange == nil {
            addCenterViewMenuItem(to: menu)
        }

        let zoomFitItem = NSMenuItem(title: "Zoom to Fit", action: #selector(zoomToFitAction(_:)), keyEquivalent: "")
        zoomFitItem.target = self
        menu.addItem(zoomFitItem)

        if isMultiSequenceMode, let state = multiSequenceState {
            if selectionRange == nil,
               let clickedTrackIndex,
               state.stackedSequences.indices.contains(clickedTrackIndex) {
                let clickedInfo = state.stackedSequences[clickedTrackIndex]
                menu.addItem(NSMenuItem.separator())

                let translationTitle = clickedInfo.showTranslation ? "Hide Translation" : "Show Translation"
                let translationItem = NSMenuItem(title: translationTitle, action: #selector(toggleTrackTranslation(_:)), keyEquivalent: "")
                translationItem.target = self
                translationItem.representedObject = clickedTrackIndex as NSNumber
                menu.addItem(translationItem)
            }

            menu.addItem(NSMenuItem.separator())
            let anyShowing = state.stackedSequences.contains { $0.showTranslation }
            let globalTitle = anyShowing ? "Hide All Translations" : "Show All Translations"
            let globalItem = NSMenuItem(title: globalTitle, action: #selector(toggleAllTranslations(_:)), keyEquivalent: "")
            globalItem.target = self
            menu.addItem(globalItem)
        }

        menu.addItem(NSMenuItem.separator())
        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showDocumentInInspector(_:)), keyEquivalent: "")
        inspectorItem.target = self
        menu.addItem(inspectorItem)

        return menu
    }

    private func appendSelectedRangeMenuItems(to menu: NSMenu) {
        if let last = menu.items.last, !last.isSeparatorItem {
            menu.addItem(NSMenuItem.separator())
        }

        let copyItem = NSMenuItem(title: "Copy Visible Region", action: #selector(copySelectionAction(_:)), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        addSelectionExtractionMenuItems(to: menu)
        menu.addItem(NSMenuItem.separator())
        addCenterViewMenuItem(to: menu)

        let zoomItem = NSMenuItem(title: "Zoom to Selected Region", action: #selector(zoomToSelectionAction(_:)), keyEquivalent: "")
        zoomItem.target = self
        menu.addItem(zoomItem)
    }

    private func normalizeContextMenuSeparators(in menu: NSMenu) {
        while let first = menu.items.first, first.isSeparatorItem {
            menu.removeItem(first)
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }

        var previousWasSeparator = false
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator {
                    menu.removeItem(item)
                }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
        }
    }

    /// Handles right-click/control-click to show contextual menu
    public override func rightMouseDown(with event: NSEvent) {
        guard let frame = viewController?.referenceFrame else { return }
        let location = convert(event.locationInWindow, from: nil)
        contextMenuGenomicPosition = clampedContextMenuPosition(for: location, frame: frame)

        // Read track right-click takes priority over annotation/selection menus:
        // if the cursor is over a read, show the read-selection actions menu.
        if let read = readAtPoint(location), let readMenu = buildReadContextMenu(for: read) {
            NSMenu.popUpContextMenu(readMenu, with: event, for: self)
            return
        }

        // Variant context menu takes priority over generic annotation menus.
        let hoveredVariantResult = genotypeTooltipAtPoint(location)?.variantSearchResult
        if let variant = variantAtPoint(location),
           let variantResult = variantSearchResult(for: variant) ?? hoveredVariantResult {
            if selectedAnnotation?.id != variant.id {
                selectedAnnotation = variant
                postAnnotationSelectedNotification(variant)
                setNeedsDisplay(bounds)
            }
            showVariantContextMenu(for: variantResult, at: event)
            return
        } else if let variantResult = hoveredVariantResult {
            showVariantContextMenu(for: variantResult, at: event)
            return
        }

        // Check if right-clicking on an annotation — bundle mode, multi-sequence mode, or single-sequence mode
        var clickedAnnotation: SequenceAnnotation?
        if currentReferenceBundle != nil {
            clickedAnnotation = bundleAnnotationAtPoint(location)
        } else if isMultiSequenceMode, let state = multiSequenceState {
            for stackedInfo in state.stackedSequences {
                if let annotation = annotationAtPoint(location, forSequence: stackedInfo, frame: frame) {
                    clickedAnnotation = annotation
                    break
                }
            }
        } else {
            clickedAnnotation = annotationAtPoint(location)
        }

        if let annotation = clickedAnnotation {
            // Select the annotation if not already selected
            if selectedAnnotation?.id != annotation.id {
                selectedAnnotation = annotation
                postAnnotationSelectedNotification(annotation)
                viewController?.selectAnnotationInDrawer(annotation)
                setNeedsDisplay(bounds)
            }
            // Show annotation context menu
            showAnnotationContextMenu(for: annotation, at: event)
            return
        }

        if let alignmentMenu = alignmentFileContextMenu(at: location) {
            NSMenu.popUpContextMenu(alignmentMenu, with: event, for: self)
            return
        }

        // Check if right-clicking on a selection
        if selectionRange != nil {
            showSelectionContextMenu(at: event)
            return
        }

        // No selection - show general context menu
        showGeneralContextMenu(at: event)
    }

    // MARK: - Read Selection Context Menu

    /// Builds the read-track right-click context menu for the read under the
    /// cursor, updating the selection first when the right-clicked read isn't
    /// already part of it — matching the existing table right-click-selects
    /// convention elsewhere in the app. Returns `nil` when `read` is `nil`
    /// (caller falls through to the annotation/selection/general menus).
    ///
    /// Exposed as a plain (non-private) method so it can be driven directly
    /// from tests via `testBuildReadContextMenu(forRead:)`, without needing
    /// to synthesize `NSEvent`/pixel coordinates.
    func buildReadContextMenu(for read: AlignedRead?) -> NSMenu? {
        guard let read else { return nil }

        if !selectedReadIDs.contains(read.id) {
            selectedReadIDs = [read.id]
            setNeedsDisplay(bounds)
            updateSelectionStatus()
        }

        let reads = selectedReads
        let handlers = ReadSelectionActionHandlers(
            onCopyAsFASTA: { [weak self] in self?.copySelectedReadsAsFASTA(to: .general) },
            onExtractReads: { [weak self] in self?.viewController?.extractSelectedReads(reads) }
        )
        return ReadSelectionActionMenuBuilder.buildMenu(selectionCount: reads.count, handlers: handlers)
    }

    /// Formats the currently selected reads as aligned-orientation FASTA and
    /// writes the result to `pasteboard`. When one or more selected reads are
    /// skipped (empty/`"*"` SEQ, e.g. secondary alignments), reports the skip
    /// count via the status bar rather than a blocking alert.
    func copySelectedReadsAsFASTA(to pasteboard: NSPasteboard) {
        let reads = selectedReads
        guard !reads.isEmpty else { return }

        let result = AlignedReadFASTAFormatter.format(reads)
        guard !result.fasta.isEmpty else {
            viewController?.reportReadCopySkip(skippedCount: result.skippedCount, copiedCount: 0)
            return
        }

        pasteboard.clearContents()
        pasteboard.setString(result.fasta, forType: .string)

        if result.skippedCount > 0 {
            let copiedCount = reads.count - result.skippedCount
            viewController?.reportReadCopySkip(skippedCount: result.skippedCount, copiedCount: copiedCount)
        }
    }

    func alignmentFileContextMenu(at location: NSPoint) -> NSMenu? {
        guard isPointInAlignmentTrack(location) else { return nil }
        let entries = alignmentFileMenuEntriesForContext(at: location)
        return buildAlignmentContextMenu(for: entries)
    }

    func buildAlignmentContextMenu(for entries: [AlignmentFileMenuEntry]) -> NSMenu {
        let menu = NSMenu(title: "Alignment")
        if entries.count == 1, let entry = entries.first {
            let item = NSMenuItem(
                title: alignmentRevealTitle(for: entry.url),
                action: #selector(showAlignmentFileInFinderAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.url
            menu.addItem(item)
        } else if entries.count > 1 {
            let revealMenu = NSMenu(title: "Show Alignment File in Finder")
            for entry in entries {
                let item = NSMenuItem(
                    title: entry.title,
                    action: #selector(showAlignmentFileInFinderAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.url
                revealMenu.addItem(item)
            }
            let revealItem = NSMenuItem(title: "Show Alignment File in Finder", action: nil, keyEquivalent: "")
            revealItem.submenu = revealMenu
            menu.addItem(revealItem)
        }

        if selectionRange == nil {
            menu.addItem(NSMenuItem.separator())
            addCenterViewMenuItem(to: menu)
        }
        return menu
    }

    func alignmentFileMenuEntriesForContext(at location: NSPoint) -> [AlignmentFileMenuEntry] {
        guard isPointInAlignmentTrack(location) else { return [] }
        return Self.alignmentFileMenuEntries(
            bundle: currentReferenceBundle,
            activeTrackIds: activeAlignmentProviders().map(\.trackId)
        )
    }

    func isPointInAlignmentTrack(_ point: NSPoint) -> Bool {
        guard showReads,
              !alignmentDataProviders.isEmpty,
              lastRenderedCoverageY > 0 else {
            return false
        }

        let coverageMaxY = lastRenderedCoverageY + coverageStripHeight
        let readMaxY = lastRenderedReadY > 0
            ? lastRenderedReadY + max(readContentHeight, coverageStripHeight)
            : coverageMaxY
        let trackMaxY = min(bounds.maxY, max(coverageMaxY, readMaxY))
        return point.y >= lastRenderedCoverageY && point.y <= trackMaxY
    }

    func alignmentRevealTitle(for url: URL) -> String {
        url.pathExtension.lowercased() == "bam" ? "Show BAM in Finder" : "Show Alignment File in Finder"
    }

    @objc func showAlignmentFileInFinderAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Creates and shows context menu for variant actions.
    func showVariantContextMenu(for result: AnnotationSearchIndex.SearchResult, at event: NSEvent) {
        let menu = buildContextMenu(for: .variant(result))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func buildVariantContextMenu(for result: AnnotationSearchIndex.SearchResult) -> NSMenu {
        let menu = NSMenu(title: "Variant")

        let viewVariantItem = NSMenuItem(title: "View Variant in Table", action: #selector(viewVariantInTableAction(_:)), keyEquivalent: "")
        viewVariantItem.target = self
        viewVariantItem.representedObject = result
        menu.addItem(viewVariantItem)

        let viewGenotypesItem = NSMenuItem(title: "View Genotypes at Site", action: #selector(viewVariantGenotypesAction(_:)), keyEquivalent: "")
        viewGenotypesItem.target = self
        viewGenotypesItem.representedObject = result
        menu.addItem(viewGenotypesItem)

        if selectionRange == nil {
            menu.addItem(NSMenuItem.separator())
            addCenterViewMenuItem(to: menu)
        }
        return menu
    }

    /// Creates and shows context menu for annotation
    func showAnnotationContextMenu(for annotation: SequenceAnnotation, at event: NSEvent) {
        let menu = buildContextMenu(for: .annotation(annotation))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func buildAnnotationContextMenu(for annotation: SequenceAnnotation) -> NSMenu {
        let menu = NSMenu(title: "Annotation")

        // --- Copy submenu ---
        let copyMenu = NSMenu(title: "Copy")

        let copyNameItem = NSMenuItem(title: "Copy Name", action: #selector(copyAnnotationName(_:)), keyEquivalent: "")
        copyNameItem.target = self
        copyNameItem.representedObject = annotation
        copyMenu.addItem(copyNameItem)

        let copyCoordItem = NSMenuItem(title: "Copy Coordinates", action: #selector(copyAnnotationCoordinates(_:)), keyEquivalent: "")
        copyCoordItem.target = self
        copyCoordItem.representedObject = annotation
        copyMenu.addItem(copyCoordItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copySeqItem = NSMenuItem(title: "Copy Sequence", action: #selector(copyAnnotationSequence(_:)), keyEquivalent: "")
        copySeqItem.target = self
        copySeqItem.representedObject = annotation
        copyMenu.addItem(copySeqItem)

        let copyCompItem = NSMenuItem(title: "Copy Complement", action: #selector(copyAnnotationComplement(_:)), keyEquivalent: "")
        copyCompItem.target = self
        copyCompItem.representedObject = annotation
        copyMenu.addItem(copyCompItem)

        let copyRevCompItem = NSMenuItem(title: "Copy Reverse Complement", action: #selector(copyAnnotationReverseComplement(_:)), keyEquivalent: "")
        copyRevCompItem.target = self
        copyRevCompItem.representedObject = annotation
        copyMenu.addItem(copyRevCompItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copyFASTAItem = NSMenuItem(title: "Copy as FASTA", action: #selector(copyAnnotationAsFASTA(_:)), keyEquivalent: "")
        copyFASTAItem.target = self
        copyFASTAItem.representedObject = annotation
        copyMenu.addItem(copyFASTAItem)

        if annotation.type == .cds {
            let copyProteinItem = NSMenuItem(title: "Copy Translation as FASTA", action: #selector(copyAnnotationTranslationAsFASTA(_:)), keyEquivalent: "")
            copyProteinItem.target = self
            copyProteinItem.representedObject = annotation
            copyMenu.addItem(copyProteinItem)
        }

        let copyMenuItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyMenuItem.submenu = copyMenu
        menu.addItem(copyMenuItem)

        // --- Extract ---
        let extractItem = NSMenuItem(title: "Extract Sequence\u{2026}", action: #selector(extractAnnotationSequence(_:)), keyEquivalent: "")
        extractItem.target = self
        extractItem.representedObject = annotation
        menu.addItem(extractItem)

        let runOperationItem = NSMenuItem(title: "Run FASTQ/FASTA Operation\u{2026}", action: #selector(runAnnotationFASTAOperationAction(_:)), keyEquivalent: "")
        runOperationItem.target = self
        runOperationItem.representedObject = annotation
        menu.addItem(runOperationItem)

        menu.addItem(NSMenuItem.separator())

        // --- Navigation ---
        if selectionRange == nil {
            addCenterViewMenuItem(to: menu)
        }

        let zoomItem = NSMenuItem(title: "Zoom to Annotation", action: #selector(zoomToAnnotationAction(_:)), keyEquivalent: "")
        zoomItem.target = self
        zoomItem.representedObject = annotation
        if let reason = viewController?.mappingZoomUnavailableReason(for: annotation) {
            zoomItem.isEnabled = false
            zoomItem.title = "Zoom to Annotation Unavailable: \(reason)"
        }
        menu.addItem(zoomItem)

        if viewController?.activeMappingViewportController?.currentResult != nil {
            let extractReadsItem = NSMenuItem(
                title: "Extract Overlapping Reads\u{2026}",
                action: #selector(extractOverlappingReadsAction(_:)),
                keyEquivalent: ""
            )
            extractReadsItem.target = self
            extractReadsItem.representedObject = annotation
            if let reason = viewController?.mappingExtractionUnavailableReason(for: annotation) {
                extractReadsItem.isEnabled = false
                extractReadsItem.title = "Extract Overlapping Reads Unavailable: \(reason)"
            }
            menu.addItem(extractReadsItem)
        }

        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showAnnotationInInspector(_:)), keyEquivalent: "")
        inspectorItem.target = self
        inspectorItem.representedObject = annotation
        menu.addItem(inspectorItem)

        menu.addItem(NSMenuItem.separator())

        // --- Edit/Delete ---
        let editItem = NSMenuItem(title: "Edit Annotation\u{2026}", action: #selector(editAnnotationAction(_:)), keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = annotation
        menu.addItem(editItem)

        let deleteItem = NSMenuItem(title: "Delete Annotation", action: #selector(deleteAnnotationAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = annotation
        menu.addItem(deleteItem)

        return menu
    }

    /// Creates and shows context menu for visible-region actions.
    func showSelectionContextMenu(at event: NSEvent) {
        let menu = NSMenu(title: "Visible Region")

        // Copy visible region bases.
        let copyItem = NSMenuItem(title: "Copy Visible Region", action: #selector(copySelectionAction(_:)), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        // Extraction actions
        addSelectionExtractionMenuItems(to: menu)

        menu.addItem(NSMenuItem.separator())

        // View navigation helper.
        addCenterViewMenuItem(to: menu)

        let zoomItem = NSMenuItem(title: "Zoom to Selected Region", action: #selector(zoomToSelectionAction(_:)), keyEquivalent: "")
        zoomItem.target = self
        menu.addItem(zoomItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Creates and shows general context menu (no selection)
    func showGeneralContextMenu(at event: NSEvent) {
        let menu = NSMenu(title: "Sequence")

        // Select All
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        menu.addItem(NSMenuItem.separator())

        addCenterViewMenuItem(to: menu)

        // Zoom to Fit
        let zoomFitItem = NSMenuItem(title: "Zoom to Fit", action: #selector(zoomToFitAction(_:)), keyEquivalent: "")
        zoomFitItem.target = self
        menu.addItem(zoomFitItem)

        // Multi-sequence translation toggle
        if isMultiSequenceMode, let state = multiSequenceState {
            let location = convert(event.locationInWindow, from: nil)
            if let clickedInfo = stackedSequenceAtPoint(location) {
                menu.addItem(NSMenuItem.separator())

                // Per-track translation toggle
                let translationTitle = clickedInfo.showTranslation ? "Hide Translation" : "Show Translation"
                let translationItem = NSMenuItem(title: translationTitle, action: #selector(toggleTrackTranslation(_:)), keyEquivalent: "")
                translationItem.target = self
                translationItem.representedObject = clickedInfo.trackIndex as NSNumber
                menu.addItem(translationItem)
            }

            // Global translation toggle (show/hide all)
            menu.addItem(NSMenuItem.separator())
            let anyShowing = state.stackedSequences.contains { $0.showTranslation }
            let globalTitle = anyShowing ? "Hide All Translations" : "Show All Translations"
            let globalItem = NSMenuItem(title: globalTitle, action: #selector(toggleAllTranslations(_:)), keyEquivalent: "")
            globalItem.target = self
            menu.addItem(globalItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Show in Inspector (Document tab)
        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showDocumentInInspector(_:)), keyEquivalent: "")
        inspectorItem.target = self
        menu.addItem(inspectorItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func clampedContextMenuPosition(for location: NSPoint, frame: ReferenceFrame) -> Int {
        let dataMinX = frame.leadingInset
        let dataMaxX = max(dataMinX, min(bounds.width - frame.trailingInset, bounds.width))
        let clampedX = max(dataMinX, min(location.x, dataMaxX))
        let genomicPos = Int(frame.genomicPosition(for: clampedX).rounded(.down))
        let maxPos = max(0, frame.sequenceLength - 1)
        return max(0, min(maxPos, genomicPos))
    }

    func addCenterViewMenuItem(to menu: NSMenu) {
        guard let position = contextMenuGenomicPosition else { return }
        let item = NSMenuItem(title: "Center View Here", action: #selector(centerViewHereAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = NSNumber(value: position)
        menu.addItem(item)
    }

    // MARK: - Context Menu Actions

    @objc func copySelectionAction(_ sender: Any?) {
        copySelectionToClipboard()
    }

    @objc func selectAllAction(_ sender: Any?) {
        selectAll()
    }

    @objc func zoomToFitAction(_ sender: Any?) {
        viewController?.zoomToFit()
    }

    @objc func centerViewHereAction(_ sender: NSMenuItem?) {
        guard let frame = viewController?.referenceFrame else { return }

        let targetPos: Int
        if let encodedPos = sender?.representedObject as? NSNumber {
            targetPos = encodedPos.intValue
        } else if let cachedPos = contextMenuGenomicPosition {
            targetPos = cachedPos
        } else {
            return
        }

        let maxPos = max(0, frame.sequenceLength - 1)
        let clampedPos = max(0, min(maxPos, targetPos))
        let windowLength = max(1.0, frame.end - frame.start)

        var newStart = Double(clampedPos) - (windowLength / 2.0)
        var newEnd = newStart + windowLength

        if newStart < 0 {
            newStart = 0
            newEnd = min(Double(frame.sequenceLength), windowLength)
        }
        if newEnd > Double(frame.sequenceLength) {
            newEnd = Double(frame.sequenceLength)
            newStart = max(0, newEnd - windowLength)
        }

        frame.start = newStart
        frame.end = newEnd
        setNeedsDisplay(bounds)
        viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
        viewController?.updateStatusBar()
    }

    @objc func zoomToSelectionAction(_ sender: Any?) {
        guard let range = selectionRange,
              let frame = viewController?.referenceFrame else { return }
        frame.start = Double(range.lowerBound)
        frame.end = Double(range.upperBound)
        setNeedsDisplay(bounds)
        viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
        viewController?.updateStatusBar()
    }

    @objc func viewVariantInTableAction(_ sender: NSMenuItem?) {
        guard let result = sender?.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        NotificationCenter.default.post(
            name: .variantSelected,
            object: self,
            userInfo: windowScopedUserInfo([
                NotificationUserInfoKey.searchResult: result,
                NotificationUserInfoKey.variantSelectionMode: "calls",
            ])
        )
    }

    @objc func viewVariantGenotypesAction(_ sender: NSMenuItem?) {
        guard let result = sender?.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        NotificationCenter.default.post(
            name: .variantSelected,
            object: self,
            userInfo: windowScopedUserInfo([
                NotificationUserInfoKey.searchResult: result,
                NotificationUserInfoKey.variantSelectionMode: "genotypes",
            ])
        )
    }

    @objc func createAnnotationFromSelection(_ sender: Any?) {
        guard let range = selectionRange else { return }
        // Post notification for AppDelegate to handle with dialog
        NotificationCenter.default.post(
            name: NSNotification.Name("createAnnotationFromSelection"),
            object: self,
            userInfo: windowScopedUserInfo(["range": range])
        )
    }

    @objc func copyComplementAction(_ sender: Any?) {
        guard let seq = sequence,
              let range = selectionRange else {
            NSSound.beep()
            return
        }

        let start = max(0, range.lowerBound)
        let end = min(seq.length, range.upperBound)
        let selectedBases = seq[start..<end]

        // Compute complement
        let complement = selectedBases.map { base -> Character in
            switch base.uppercased() {
            case "A": return "T"
            case "T": return "A"
            case "G": return "C"
            case "C": return "G"
            default: return base
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(complement), forType: .string)
        sequenceViewerLogger.info("Copied \(end - start) bases (complement) to clipboard")
    }

    @objc func copyReverseComplementAction(_ sender: Any?) {
        guard let seq = sequence,
              let range = selectionRange else {
            NSSound.beep()
            return
        }

        let start = max(0, range.lowerBound)
        let end = min(seq.length, range.upperBound)
        let selectedBases = seq[start..<end]

        // Compute reverse complement
        let reverseComplement = selectedBases.reversed().map { base -> Character in
            switch base.uppercased() {
            case "A": return "T"
            case "T": return "A"
            case "G": return "C"
            case "C": return "G"
            default: return base
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(reverseComplement), forType: .string)
        sequenceViewerLogger.info("Copied \(end - start) bases (reverse complement) to clipboard")
    }

    @objc func editAnnotationAction(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        // Select the annotation - the inspector will show edit controls
        selectedAnnotation = annotation
        postAnnotationSelectedNotification(annotation)
        setNeedsDisplay(bounds)
        // Open the inspector if not already visible
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: windowScopedUserInfo([NotificationUserInfoKey.inspectorTab: "selection"])
        )
    }

    @objc func copyAnnotationName(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(annotation.name, forType: .string)
        sequenceViewerLogger.info("Copied annotation name '\(annotation.name)' to clipboard")
    }

    @objc func copyAnnotationSequence(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        fastaOperationFetchGeneration += 1
        let thisGeneration = fastaOperationFetchGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let bases = await self.fetchAnnotationBasesAsync(annotation) else {
                guard thisGeneration == self.fastaOperationFetchGeneration else { return }
                NSSound.beep()
                return
            }
            guard thisGeneration == self.fastaOperationFetchGeneration else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(bases, forType: .string)
            sequenceViewerLogger.info("Copied \(bases.count) bases from annotation '\(annotation.name)' to clipboard")
        }
    }

    @objc func copyAnnotationCoordinates(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        let chrom = annotation.chromosome ?? viewController?.referenceFrame?.chromosome ?? ""
        let coordString = "\(chrom):\(annotation.start)-\(annotation.end)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(coordString, forType: .string)
        sequenceViewerLogger.info("Copied coordinates '\(coordString)' to clipboard")
    }

    @objc func copyAnnotationComplement(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        fastaOperationFetchGeneration += 1
        let thisGeneration = fastaOperationFetchGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let bases = await self.fetchAnnotationBasesAsync(annotation) else {
                guard thisGeneration == self.fastaOperationFetchGeneration else { return }
                NSSound.beep()
                return
            }
            guard thisGeneration == self.fastaOperationFetchGeneration else { return }
            let complement = self.complementString(bases)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(complement, forType: .string)
            sequenceViewerLogger.info("Copied \(complement.count) bases (complement) from annotation '\(annotation.name)' to clipboard")
        }
    }

    @objc func copyAnnotationReverseComplement(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        fastaOperationFetchGeneration += 1
        let thisGeneration = fastaOperationFetchGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let bases = await self.fetchAnnotationBasesAsync(annotation) else {
                guard thisGeneration == self.fastaOperationFetchGeneration else { return }
                NSSound.beep()
                return
            }
            guard thisGeneration == self.fastaOperationFetchGeneration else { return }
            let revComp = self.reverseComplementString(bases)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(revComp, forType: .string)
            sequenceViewerLogger.info("Copied \(revComp.count) bases (reverse complement) from annotation '\(annotation.name)' to clipboard")
        }
    }

    @objc func zoomToAnnotationAction(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        zoomToAnnotation(annotation)
    }

    @objc func extractOverlappingReadsAction(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        viewController?.extractOverlappingReads(from: annotation)
    }

    @objc func runAnnotationFASTAOperationAction(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        runAnnotationFASTAOperationImpl(annotation)
    }

    /// Zooms the viewer to show the given annotation (callable from notification handlers).
    func zoomToAnnotation(_ annotation: SequenceAnnotation) {
        if viewController?.activeMappingViewportController?.currentResult != nil {
            viewController?.zoomToMappingAnnotation(annotation)
            return
        }
        guard let frame = viewController?.referenceFrame else { return }
        let annotationLength = max(1, annotation.end - annotation.start)
        let padding = max(10, Double(annotationLength) * 0.05)
        let windowLength = Double(annotationLength) + 2 * padding
        let maxPixelWidth = max(1, frame.pixelWidth)
        let insetPixels = min(Double(navigationLeadingInsetPixels), Double(maxPixelWidth - 1))
        let leadingInsetBP = windowLength * insetPixels / Double(maxPixelWidth)
        var newStart = Double(annotation.start) - padding - leadingInsetBP
        var newEnd = newStart + windowLength
        if newStart < 0 {
            newStart = 0
            newEnd = min(Double(frame.sequenceLength), windowLength)
        }
        if newEnd > Double(frame.sequenceLength) {
            newEnd = Double(frame.sequenceLength)
            newStart = max(0, newEnd - windowLength)
        }
        frame.start = newStart
        frame.end = newEnd
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
        viewController?.updateStatusBar()
    }

    /// Copies the annotation's raw sequence to the clipboard (callable from notification handlers).
    func copyAnnotationSequenceImpl(_ annotation: SequenceAnnotation) {
        fastaOperationFetchGeneration += 1
        let thisGeneration = fastaOperationFetchGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let bases = await self.fetchAnnotationBasesAsync(annotation) else {
                guard thisGeneration == self.fastaOperationFetchGeneration else { return }
                NSSound.beep()
                return
            }
            guard thisGeneration == self.fastaOperationFetchGeneration else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(bases, forType: .string)
            sequenceViewerLogger.info("Copied \(bases.count) bases from annotation '\(annotation.name)' to clipboard")
        }
    }

    struct FASTAOperationInput {
        let records: [String]
        let suggestedName: String
    }

    enum FASTAOperationInputError: LocalizedError {
        case noSequence
        case emptyRange

        var errorDescription: String? {
            switch self {
            case .noSequence:
                return "No sequence is available for this operation."
            case .emptyRange:
                return "Select a non-empty sequence range before running this operation."
            }
        }
    }

    /// Opens the generic FASTQ/FASTA Operations dialog for the current sequence selection.
    ///
    /// Called from a synchronous `@objc` menu-action context (no `async` entry point exists
    /// on the AppKit call side), so this kicks off its own `Task` and applies the result back
    /// on the main actor. A generation guard discards the result if a newer request has
    /// superseded this one (e.g. rapid repeated menu invocations) before it resolves.
    func runSelectedSequenceFASTAOperation(toolID: FASTQOperationToolID) {
        fastaOperationFetchGeneration += 1
        let thisGeneration = fastaOperationFetchGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let input = try await self.selectedFASTAOperationInput()
                guard thisGeneration == self.fastaOperationFetchGeneration else { return }
                self.viewController?.presentFASTAOperationDialog(
                    records: input.records,
                    suggestedName: input.suggestedName,
                    initialCategory: toolID.categoryID,
                    initialToolID: toolID
                )
            } catch {
                guard thisGeneration == self.fastaOperationFetchGeneration else { return }
                self.presentFASTAOperationInputError(error)
            }
        }
    }

    func canRunSelectedSequenceFASTAOperation() -> Bool {
        guard viewController?.contentMode == .genomics, !isHidden else {
            return false
        }

        if let seq = activeSequence ?? sequence {
            return hasNonEmptySelectedOrVisibleSequenceRange(sequenceLength: seq.length)
        }

        guard let bundle = currentReferenceBundle,
              let frame = viewController?.referenceFrame,
              let chromosome = viewController?.currentBundleDataProvider?.chromosomeInfo(named: frame.chromosome)
                ?? bundle.chromosome(named: frame.chromosome) else {
            return false
        }

        return hasNonEmptySelectedOrVisibleSequenceRange(sequenceLength: Int(chromosome.length))
    }

    /// Resolves the FASTA input for the current selection/visible range.
    ///
    /// For bundle-backed chromosomes this performs real file I/O (bgzip decompression or
    /// indexed-FASTA seek+read). That work is dispatched to the cooperative thread pool via
    /// `Task.detached` in `fetchBundleRegionsOffMain` so it never runs on the main thread —
    /// a nonisolated `async` function with no internal `await` before its synchronous body
    /// inherits the *caller's* thread when awaited from `@MainActor` code, so the detached
    /// hop is required, not incidental. See `Sources/LungfishKit/AsyncFileReader.swift` for
    /// the same pattern applied to whole-file reads.
    func selectedFASTAOperationInput() async throws -> FASTAOperationInput {
        if let seq = activeSequence ?? sequence {
            let range = selectedOrVisibleSequenceRange(sequenceLength: seq.length)
            let start = max(0, range.lowerBound)
            let end = min(seq.length, range.upperBound)
            guard start < end else {
                throw FASTAOperationInputError.emptyRange
            }

            let sequenceName = selectedSequenceName(start: start, end: end)
            let fasta = formatFASTA(name: sequenceName, sequence: seq[start..<end])
            return FASTAOperationInput(records: [fasta], suggestedName: sequenceName)
        }

        guard let bundle = currentReferenceBundle,
              let frame = viewController?.referenceFrame,
              let chromosome = viewController?.currentBundleDataProvider?.chromosomeInfo(named: frame.chromosome)
                ?? bundle.chromosome(named: frame.chromosome) else {
            throw FASTAOperationInputError.noSequence
        }
        let sequenceLength = Int(chromosome.length)
        let range = selectedOrVisibleSequenceRange(sequenceLength: sequenceLength)
        let start = max(0, range.lowerBound)
        let end = min(sequenceLength, range.upperBound)
        guard start < end else {
            throw FASTAOperationInputError.emptyRange
        }

        let region = GenomicRegion(chromosome: chromosome.name, start: start, end: end)
        let bases = try await Self.fetchBundleRegionOffMain(bundle: bundle, region: region)
        let sequenceName = selectedSequenceName(chromosome: chromosome.name, start: start, end: end)
        let fasta = formatFASTA(name: sequenceName, sequence: bases)
        return FASTAOperationInput(records: [fasta], suggestedName: sequenceName)
    }

    private func hasNonEmptySelectedOrVisibleSequenceRange(sequenceLength: Int) -> Bool {
        let range = selectedOrVisibleSequenceRange(sequenceLength: sequenceLength)
        let start = max(0, range.lowerBound)
        let end = min(sequenceLength, range.upperBound)
        return start < end
    }

    func selectedOrVisibleSequenceRange(sequenceLength: Int) -> Range<Int> {
        if let range = selectionRange, !range.isEmpty {
            return range
        }
        if let frame = viewController?.referenceFrame {
            let lower = min(max(0, Int(frame.start)), sequenceLength)
            let upper = min(max(lower, Int(ceil(frame.end))), sequenceLength)
            if lower < upper {
                return lower..<upper
            }
        }
        return 0..<sequenceLength
    }

    func presentFASTAOperationInputError(_ error: Error) {
        NSSound.beep()
        guard let window else {
            sequenceViewerLogger.warning("Unable to prepare FASTA operation input: \(error.localizedDescription, privacy: .public)")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Sequence Operation Unavailable"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    func selectedSequenceName(chromosome: String, start: Int, end: Int) -> String {
        "\(chromosome)_\(start + 1)_\(end)"
    }

    func selectedSequenceName(start: Int, end: Int) -> String {
        let chromosome = activeSequence?.name
            ?? viewController?.referenceFrame?.chromosome
            ?? sequence?.name
            ?? "selection"
        return selectedSequenceName(chromosome: chromosome, start: start, end: end)
    }

    func formatFASTA(name: String, sequence: String) -> String {
        var output = ">\(name)\n"
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let end = sequence.index(index, offsetBy: 60, limitedBy: sequence.endIndex) ?? sequence.endIndex
            output += String(sequence[index..<end]) + "\n"
            index = end
        }
        return output
    }

    /// Copies the annotation's reverse complement to the clipboard (callable from notification handlers).
    func copyAnnotationReverseComplementImpl(_ annotation: SequenceAnnotation) {
        fastaOperationFetchGeneration += 1
        let thisGeneration = fastaOperationFetchGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let bases = await self.fetchAnnotationBasesAsync(annotation) else {
                guard thisGeneration == self.fastaOperationFetchGeneration else { return }
                NSSound.beep()
                return
            }
            guard thisGeneration == self.fastaOperationFetchGeneration else { return }
            let revComp = self.reverseComplementString(bases)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(revComp, forType: .string)
            sequenceViewerLogger.info("Copied \(revComp.count) bases (reverse complement) from annotation '\(annotation.name)' to clipboard")
        }
    }

    /// Returns the complement of a DNA string.
    func complementString(_ s: String) -> String {
        String(TranslationEngine.reverseComplement(String(s.reversed())))
    }

    /// Returns the reverse complement of a DNA string.
    func reverseComplementString(_ s: String) -> String {
        TranslationEngine.reverseComplement(s)
    }

    /// Fetches the full sequence bases for an annotation, handling multi-block and bundle-backed sequences.
    ///
    /// Bundle-backed fetches are dispatched off the main actor (see `fetchBundleRegionOffMain`);
    /// single-sequence mode is an in-memory string slice and stays synchronous on the caller.
    func fetchAnnotationBasesAsync(_ annotation: SequenceAnnotation) async -> String? {
        if let bundle = currentReferenceBundle {
            // Bundle mode: fetch each interval and concatenate
            let chrom = annotation.chromosome ?? bundle.chromosomeNames.first ?? ""
            var allBases = ""
            for interval in annotation.intervals {
                let start = max(0, interval.start)
                let end = interval.end
                let region = GenomicRegion(chromosome: chrom, start: start, end: end)
                if let bases = try? await Self.fetchBundleRegionOffMain(bundle: bundle, region: region) {
                    allBases += bases
                }
            }
            return allBases.isEmpty ? nil : allBases
        } else if let seq = sequence {
            // Single-sequence mode: pure in-memory slicing, no I/O.
            var allBases = ""
            for interval in annotation.intervals {
                let start = max(0, interval.start)
                let end = min(seq.length, interval.end)
                guard start < end else { continue }
                allBases += seq[start..<end]
            }
            return allBases.isEmpty ? nil : allBases
        }
        return nil
    }

    #if DEBUG
    /// Test seam: fires once at the start of the detached body in `fetchBundleRegionOffMain`,
    /// before any bundle I/O runs. Lets tests assert the heavy work actually left the main
    /// thread. `nonisolated(unsafe)` (not `@unchecked Sendable`) matches the existing pattern
    /// in `ReferenceBundleAnnotationImportService.threadingProbe`. Debug-only; compiled out of
    /// release builds.
    nonisolated(unsafe) static var fastaOperationThreadingProbe: (@Sendable () -> Void)?

    /// Test seam: an optional async gate awaited inside the detached body in
    /// `fetchBundleRegionOffMain`, immediately after `fastaOperationThreadingProbe` fires and
    /// before the real bundle I/O runs. Lets tests deterministically hold one in-flight fetch
    /// suspended (e.g. via a `CheckedContinuation` the test controls) while a second,
    /// superseding request runs to completion and bumps `fastaOperationFetchGeneration` — then
    /// release the first fetch and assert its stale result is discarded by the generation guard
    /// at each `@objc` call site. `nil` by default (no-op), so it does not affect any test that
    /// doesn't set it. Debug-only; compiled out of release builds.
    nonisolated(unsafe) static var fastaOperationFetchGate: (@Sendable () async -> Void)?
    #endif

    /// Fetches a single genomic region from `bundle` on the cooperative thread pool.
    ///
    /// `ReferenceBundle.fetchSequence(region:)` is a nonisolated `async` function whose body
    /// (bgzip block decompression or indexed-FASTA seek+read) has no internal `await` before
    /// touching the filesystem. Swift does not guarantee an executor hop for a nonisolated
    /// `async` callee with no internal suspension point — when awaited directly from
    /// `@MainActor` code it can inherit the caller's (main) thread. `Task.detached`
    /// unconditionally schedules its body on the cooperative thread pool regardless of the
    /// caller's actor or the callee's suspension behavior, so it is the structural guarantee
    /// this needs (see `Sources/LungfishKit/AsyncFileReader.swift` for the same pattern).
    nonisolated private static func fetchBundleRegionOffMain(
        bundle: ReferenceBundle,
        region: GenomicRegion
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            #if DEBUG
            fastaOperationThreadingProbe?()
            await fastaOperationFetchGate?()
            #endif
            return try await bundle.fetchSequence(region: region)
        }.value
    }

    @objc func deleteAnnotationAction(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        // Post deletion notification
        NotificationCenter.default.post(
            name: .annotationDeleted,
            object: self,
            userInfo: windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
        )
        // Clear selection if it was the selected annotation
        if selectedAnnotation?.id == annotation.id {
            selectedAnnotation = nil
            postAnnotationSelectedNotification(nil)
        }
        setNeedsDisplay(bounds)
    }

    /// Shows the selected annotation in the inspector panel.
    @objc func showAnnotationInInspector(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        // Ensure annotation is selected
        selectedAnnotation = annotation
        postAnnotationSelectedNotification(annotation)
        setNeedsDisplay(bounds)
        // Request inspector to show with Selection tab
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: windowScopedUserInfo([NotificationUserInfoKey.inspectorTab: "selection"])
        )
        sequenceViewerLogger.info("Show in Inspector: annotation '\(annotation.name)'")
    }

    /// Shows the document info in the inspector panel.
    @objc func showDocumentInInspector(_ sender: NSMenuItem?) {
        // Request inspector to show with Document tab
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: windowScopedUserInfo([NotificationUserInfoKey.inspectorTab: "document"])
        )
        sequenceViewerLogger.info("Show in Inspector: document tab")
    }

    /// Toggles translation visibility for a specific track in multi-sequence mode.
    @objc func toggleTrackTranslation(_ sender: NSMenuItem?) {
        guard let trackIndex = sender?.representedObject as? NSNumber,
              let state = multiSequenceState else { return }
        state.toggleTranslationVisibility(at: trackIndex.intValue)
        setNeedsDisplay(bounds)
    }

    /// Toggles translation visibility for all tracks in multi-sequence mode.
    @objc func toggleAllTranslations(_ sender: Any?) {
        guard let state = multiSequenceState else { return }
        let anyShowing = state.stackedSequences.contains { $0.showTranslation }
        if anyShowing {
            state.hideAllTranslations()
        } else {
            state.showAllTranslations()
        }
        setNeedsDisplay(bounds)
    }

    /// Scroll wheel for zooming and panning.
    /// Pan events are coalesced at 60fps to avoid redundant redraws.
    public override func magnify(with event: NSEvent) {
        let factor = Self.pinchZoomFactor(magnification: event.magnification)
        guard abs(factor - 1.0) > 0.001 else { return }
        let location = convert(event.locationInWindow, from: nil)
        viewController?.zoomByPinchFactor(factor, anchorX: location.x)
        invalidateAnnotationTile()
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let frame = viewController?.referenceFrame else { return }

        // Respect per-axis app settings and fall back to system preference when requested.
        let settings = AppSettings.shared
        let verticalSign = Self.scrollDirectionSign(
            for: settings.verticalScrollDirection,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
        )

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            // Zoom with Cmd+scroll or Option+scroll
            // Convention: physical scroll/swipe up = zoom in, regardless of natural scrolling.
            if event.scrollingDeltaY > 0 {
                viewController?.zoomIn()
            } else if event.scrollingDeltaY < 0 {
                viewController?.zoomOut()
            }
            invalidateAnnotationTile()
        } else {
            // Check if mouse is in genotype row area for vertical scrolling
            let location = convert(event.locationInWindow, from: nil)
            let genotypeTopY = variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
            let hasLoadedGenotypeRows = {
                guard sampleDisplayState.showGenotypeRows,
                      let data = filteredVisibleGenotypeData() else { return false }
                return !data.sampleNames.isEmpty && !data.sites.isEmpty
            }()
            let inGenotypeArea = showVariants && hasLoadedGenotypeRows
                && location.y >= genotypeTopY && location.y <= bounds.height

            if inGenotypeArea && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                // Vertical scroll in genotype area — scroll through sample rows
                let rowH = sampleDisplayState.rowHeight
                guard rowH > 0 else { return }
                let maxOffset = maxGenotypeScrollOffset(frame: frame)
                let deltaScale: CGFloat = event.hasPreciseScrollingDeltas
                    ? 1.0
                    : max(8, rowH * 0.9)
                let proposedOffset = max(0, min(maxOffset, genotypeScrollOffset + verticalSign * event.scrollingDeltaY * deltaScale))
                guard abs(proposedOffset - genotypeScrollOffset) > 0.1 else { return }
                genotypeScrollOffset = proposedOffset
                setNeedsDisplay(bounds)
                viewController?.updateStatusBar()
                viewController?.scheduleViewStateSave()
                return
            }

            // Check if mouse is in read track area for vertical scrolling
            let rY = lastRenderedReadY
            let readAvailHeight = bounds.height - rY
            let readVisibleHeight = min(readContentHeight, max(readAvailHeight, maxReadTrackHeight))
            let inReadArea = !cachedPackedReads.isEmpty && readContentHeight > readVisibleHeight
                && location.y >= rY && location.y < rY + readVisibleHeight

            if inReadArea && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                // Vertical scroll in read track area — scroll through read rows
                let maxScroll = max(0, readContentHeight - readVisibleHeight)
                let deltaScale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
                let proposedOffset = max(0, min(maxScroll, readScrollOffset + verticalSign * event.scrollingDeltaY * deltaScale))
                guard abs(proposedOffset - readScrollOffset) > 0.1 else { return }
                readScrollOffset = proposedOffset
                setNeedsDisplay(bounds)
                return
            }

            if abs(event.scrollingDeltaX) > 0 || abs(event.scrollingDeltaY) > 0 {
                if hasLoadedGenotypeRows && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                    // Avoid converting pure vertical scroll into horizontal pan in genotype mode.
                    return
                }
            }

            // Horizontal pan — update coordinates immediately, coalesce redraw at 60fps
            let panAmount = Self.horizontalPanAmount(
                deltaX: event.scrollingDeltaX,
                scale: frame.scale,
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                preference: Self.effectiveHorizontalScrollDirection(
                    bundleOverride: horizontalScrollDirectionOverride,
                    globalPreference: settings.horizontalScrollDirection
                ),
                isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
            )
            frame.pan(by: panAmount)

            scrollRedrawTimer?.invalidate()
            scrollRedrawTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.setNeedsDisplay(self.bounds)
                        self.viewController?.enhancedRulerView.setNeedsDisplay(self.viewController?.enhancedRulerView.bounds ?? .zero)
                        self.viewController?.updateStatusBar()
                        self.viewController?.scheduleViewStateSave()
                    }
                }
            }
        }
    }

    // MARK: - Selection Helpers

    /// Converts screen X coordinate to base position using the reference frame.
    /// Works in both single-sequence mode and bundle mode.
    func basePositionAt(x: CGFloat, frame: ReferenceFrame) -> Int {
        let pos = Int(frame.genomicPosition(for: x))
        return max(0, min(frame.sequenceLength - 1, pos))
    }

    /// Selects the entire sequence
    public func selectAll() {
        let length: Int
        if let seq = sequence {
            length = seq.length
        } else if let frame = viewController?.referenceFrame {
            length = frame.sequenceLength
        } else {
            return
        }
        selectionRange = 0..<length
        isUserColumnSelection = true
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    /// Selects the currently visible viewport range.
    ///
    /// Used as a fallback for extraction and copy flows when no explicit range is set.
    public func selectVisibleRegion() {
        guard let frame = viewController?.referenceFrame else { return }
        let lower = max(0, Int(frame.start))
        let upper = max(lower + 1, Int(ceil(frame.end)))
        selectionRange = lower..<upper
        selectionStartBase = lower
        isSelecting = false
        isUserColumnSelection = false
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    /// Clears the current selection (column, read, and annotation).
    public func clearSelection() {
        selectionRange = nil
        selectionStartBase = nil
        isUserColumnSelection = false
        columnDragStartBase = nil
        if !selectedReadIDs.isEmpty {
            selectedReadIDs.removeAll()
            NotificationCenter.default.post(name: .readSelected, object: self, userInfo: windowScopedUserInfo())
        }
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    func clearUserColumnSelection() {
        guard isUserColumnSelection else { return }
        selectionRange = nil
        selectionStartBase = nil
        isSelecting = false
        isUserColumnSelection = false
        columnDragStartBase = nil
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    /// Copies the selected sequence to the clipboard
    public func copySelectionToClipboard() {
        guard let seq = sequence else {
            NSSound.beep()
            return
        }
        if selectionRange == nil {
            selectVisibleRegion()
        }
        guard let range = selectionRange else {
            NSSound.beep()
            return
        }

        // Extract the selected bases
        let start = max(0, range.lowerBound)
        let end = min(seq.length, range.upperBound)
        let selectedBases = seq[start..<end]

        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedBases, forType: .string)

        sequenceViewerLogger.info("Copied \(end - start) bases to clipboard")
    }

    /// Updates the status bar with selection info.
    func updateSelectionStatus() {
        let selectionText = currentSelectionStatusText()
        viewController?.statusBar.update(
            position: viewController?.statusBar.positionLabel.stringValue,
            selection: selectionText,
            scale: viewController?.referenceFrame?.scale ?? 1.0
        )
        viewController?.notifySequenceRegionSelectionIfAvailable()
    }

    func currentSelectionStatusText() -> String? {
        var parts: [String] = []

        if isUserColumnSelection, let range = selectionRange {
            let length = range.upperBound - range.lowerBound
            parts.append("Selected: \(range.lowerBound + 1)-\(range.upperBound) (\(length.formatted()) bp)")
        } else if let range = selectionRange {
            let length = range.upperBound - range.lowerBound
            parts.append("Visible: \(range.lowerBound + 1)-\(range.upperBound) (\(length.formatted()) bp)")
        }

        if !selectedReadIDs.isEmpty {
            let count = selectedReadIDs.count
            parts.append("\(count) read\(count == 1 ? "" : "s") selected")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }

}
