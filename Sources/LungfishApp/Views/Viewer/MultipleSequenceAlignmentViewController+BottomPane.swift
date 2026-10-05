// MultipleSequenceAlignmentViewController+BottomPane.swift - The MSA bottom pane: annotation table and distance matrix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishAlignmentUI

extension MultipleSequenceAlignmentViewController: AnnotationTableDrawerDelegate {
    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        didSelectAnnotation result: AnnotationSearchIndex.SearchResult
    ) {
        guard let annotation = drawerAnnotationByResultID[result.id] else { return }
        selectAnnotation(annotation, zoom: false)
    }

    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        didRequestExtract annotations: [SequenceAnnotation]
    ) {
        var records: [String] = []
        var extractedAnnotations: [String: [SequenceAnnotation]] = [:]
        for annotation in annotations {
            guard let rowName = annotation.chromosome,
                  let row = alignmentRows.first(where: { $0.name == rowName }) else { continue }
            let sequence = row.ungappedSequenceString
            let intervals = annotation.intervals
            let extracted = intervals.compactMap { interval -> String? in
                guard interval.start >= 0,
                      interval.end <= sequence.count,
                      interval.end > interval.start else { return nil }
                let startIndex = sequence.index(sequence.startIndex, offsetBy: interval.start)
                let endIndex = sequence.index(sequence.startIndex, offsetBy: interval.end)
                return String(sequence[startIndex..<endIndex])
            }.joined()
            guard !extracted.isEmpty else { continue }

            let recordName = "\(rowName)_\(Self.sanitizedFASTAComponent(annotation.name))"
            records.append(Self.fastaRecord(name: recordName, sequence: extracted))
            extractedAnnotations[recordName] = [
                SequenceAnnotation(
                    type: annotation.type,
                    name: annotation.name,
                    chromosome: recordName,
                    intervals: Self.rebasedIntervals(intervals),
                    strand: annotation.strand,
                    qualifiers: annotation.qualifiers,
                    note: annotation.note
                ),
            ]
        }
        guard !records.isEmpty else { return }
        onExtractAnnotatedSequenceRequested?(
            records,
            bundle?.manifest.name ?? "alignment-annotations",
            extractedAnnotations
        )
    }

    func annotationDrawerSelectedSequenceRegion(
        _ drawer: AnnotationTableDrawerView
    ) -> AnnotationTableDrawerSelectionRegion? {
        nil
    }

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int) {}

    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        didResolveGeneRegions regions: [GeneRegion]
    ) {}

    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        didUpdateVisibleVariantRenderKeys keys: Set<String>?
    ) {}

    /// The embedded drawer hides its own handle, so this only runs if a
    /// caller resizes through the drawer. The bottom pane owns the height.
    func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {
        bottomPane.resize(by: deltaY)
    }

    func annotationDrawerDidFinishDraggingDivider(_ drawer: AnnotationTableDrawerView) {}

    private static func sanitizedFASTAComponent(_ value: String) -> String {
        let replaced = value.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+",
            with: "_",
            options: .regularExpression
        )
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "annotation" : trimmed
    }

    private static func rebasedIntervals(_ intervals: [AnnotationInterval]) -> [AnnotationInterval] {
        var offset = 0
        return intervals.map { interval in
            let length = max(0, interval.end - interval.start)
            defer { offset += length }
            return AnnotationInterval(start: offset, end: offset + length)
        }
    }

    func refreshAnnotationDrawer() {
        let rows = annotationDrawerRows()
        drawerAnnotationByResultID = Dictionary(uniqueKeysWithValues: rows.map { ($0.result.id, $0.annotation) })
        annotationDrawer.setAnnotations(rows.map(\.result))
    }

    private func annotationDrawerRows() -> [(result: AnnotationSearchIndex.SearchResult, annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord)] {
        annotationStore.allAnnotations.map { annotation in
            let resultID = UUID()
            return (
                AnnotationSearchIndex.SearchResult(
                    id: resultID,
                    name: annotation.name,
                    chromosome: annotation.rowName,
                    start: annotation.sourceIntervals.map(\.start).min() ?? 0,
                    end: annotation.sourceIntervals.map(\.end).max() ?? 0,
                    trackId: annotation.sourceTrackID,
                    type: annotation.type,
                    strand: annotation.strand,
                    attributes: drawerAttributes(for: annotation)
                ),
                annotation
            )
        }
    }

    private func drawerAttributes(
        for annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord
    ) -> [String: String] {
        var attributes = annotation.qualifiers.mapValues { $0.joined(separator: ", ") }
        attributes["source_coordinates"] = coordinateText(
            sequenceName: annotation.sourceSequenceName,
            intervals: annotation.sourceIntervals
        )
        attributes["alignment_columns"] = intervalText(annotation.alignedIntervals, oneBased: true)
        attributes["consensus_columns"] = intervalText(annotation.alignedIntervals, oneBased: true)
        attributes["alignment_row"] = annotation.rowName
        attributes["source_sequence"] = annotation.sourceSequenceName
        attributes["source_track"] = annotation.sourceTrackName
        attributes["origin"] = annotation.origin.rawValue
        return attributes
    }

    func coordinateText(
        sequenceName: String,
        intervals: [AnnotationInterval]
    ) -> String {
        let spans = intervalText(intervals, oneBased: true)
        return spans.isEmpty ? sequenceName : "\(sequenceName):\(spans)"
    }

    func intervalText(
        _ intervals: [AnnotationInterval],
        oneBased: Bool
    ) -> String {
        intervals.map { interval in
            let start = oneBased ? interval.start + 1 : interval.start
            return "\(start)-\(interval.end)"
        }.joined(separator: ",")
    }
}

// MARK: - Bottom pane and distance matrix (rulings U1, U2, U7)

extension MultipleSequenceAlignmentViewController {
    /// Wires the Distances pane callbacks once, when the view loads.
    func configureBottomPane() {
        let pane = bottomPane.distancePane
        pane.onSequencesSelected = { [weak self] records in
            guard let self else { return }
            self.bottomPane.isDrivingAlignmentSelection = true
            defer { self.bottomPane.isDrivingAlignmentSelection = false }
            self.applyDistanceMatrixRowSelection(records, reveal: false)
        }
        pane.onRevealPair = { [weak self] first, second in
            guard let self else { return }
            self.bottomPane.isDrivingAlignmentSelection = true
            defer { self.bottomPane.isDrivingAlignmentSelection = false }
            self.applyDistanceMatrixRowSelection(IndexSet([first, second]), reveal: true)
        }
        pane.onExportRequested = { [weak self] options in
            guard let self, let bundleURL = self.bundleURL else { return }
            self.onExportDistanceMatrixRequested?(bundleURL, options)
        }
        pane.onFocusedPairChanged = { [weak self] detail, rowName, columnName in
            guard let self else { return }
            let focus = detail.map {
                MSAFocusedDistancePair(
                    rowName: rowName,
                    columnName: columnName,
                    model: pane.model.effectiveModel,
                    detail: $0
                )
            }
            self.onFocusedDistancePairChanged?(focus)
        }
        bottomPane.onOpenStateChanged = { [weak self] _ in self?.bottomPaneStateDidChange() }
        bottomPane.onTabChanged = { [weak self] _ in self?.bottomPaneStateDidChange() }
    }

    func makeDistanceMatrixToggleButton() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(toggleDistanceMatrixFromToolbar(_:)))
        LungfishKitControlStyle.configureInspectorIconButton(
            button,
            symbolName: "tablecells",
            fallbackTitle: "Distances",
            accessibilityLabel: "Distance matrix"
        )
        button.setButtonType(.pushOnPushOff)
        button.toolTip = "Show or hide the pairwise distance matrix (Control-Command-M)"
        button.setAccessibilityIdentifier("multiple-sequence-alignment-distance-matrix-button")
        button.state = .off
        return button
    }

    @objc func toggleDistanceMatrixFromToolbar(_ sender: Any?) {
        toggleDistanceMatrix()
    }

    /// Hands the alignment to the Distances pane. The pane computes only when
    /// its tab is first shown, from the same parsed rows the viewport draws,
    /// so a matrix record index is always the viewport row index.
    func prepareDistanceMatrix(bundleURL: URL?, rows: [MSAAlignmentSequence]) {
        guard let bundleURL else {
            bottomPane.setDistanceInput(nil)
            bottomPane.isDistancesAvailable = false
            bottomPaneStateDidChange()
            return
        }
        let alphabet = (try? MSASequenceAlphabet.load(fromBundle: bundleURL)) ?? .nucleotide
        bottomPane.isDistancesAvailable = true
        bottomPane.setDistanceInput {
            (rows.map { MSAAlignedRecord(name: $0.name, sequence: $0.sequenceString) }, alphabet)
        }
        bottomPaneStateDidChange()
    }

    /// Reverse sync: an alignment selection made outside the matrix clears
    /// its cells and bolds the selected sequences' headers.
    func syncDistanceMatrixSelection(_ rows: IndexSet) {
        guard !bottomPane.isDrivingAlignmentSelection else { return }
        bottomPane.distancePane.reflectAlignmentSelection(rows)
    }

    // MARK: Show and hide

    var isBottomPaneOpen: Bool { bottomPane.isOpen }

    /// True when the pane is open on the Distances tab.
    var isDistanceMatrixShowing: Bool {
        bottomPane.isOpen && bottomPane.visibleTab == .distances
    }

    var isDistanceMatrixAvailable: Bool { bottomPane.isDistancesAvailable }

    /// View > Show Drawer (Control-Command-B) and the window toolbar drawer
    /// button: toggles the pane and keeps its last tab.
    func toggleBottomPane() {
        bottomPane.setOpen(!bottomPane.isOpen)
    }

    /// Opens the pane on the Distances tab and puts keyboard focus in the grid.
    func showDistanceMatrix() {
        guard bottomPane.isDistancesAvailable else { return }
        bottomPane.select(.distances)
        if !bottomPane.isOpen { bottomPane.setOpen(true) }
        view.window?.makeFirstResponder(bottomPane.distancePane.gridView)
    }

    /// View > Show / Hide Distance Matrix (Control-Command-M) and the MSA toolbar button.
    func toggleDistanceMatrix() {
        if isDistanceMatrixShowing {
            let focusWasInPane = (view.window?.firstResponder as? NSView)?.isDescendant(of: bottomPane) == true
            bottomPane.setOpen(false)
            if focusWasInPane { focusAlignment() }
        } else {
            showDistanceMatrix()
        }
    }

    /// View > Make Drawer Taller / Shorter: opens the pane first when closed.
    func adjustBottomPaneHeight(by delta: CGFloat) {
        if bottomPane.isOpen {
            bottomPane.resize(by: delta)
        } else {
            bottomPane.setOpen(true)
        }
    }

    // MARK: Matrix commands forwarded from the menu bar

    /// The grid that answers View > Distance Matrix commands while focus is
    /// elsewhere in the window; nil when the Distances tab is not showing.
    var distanceMatrixCommandTarget: MSADistanceMatrixGridView? {
        isDistanceMatrixShowing ? bottomPane.distancePane.gridView : nil
    }

    private func bottomPaneStateDidChange() {
        distanceMatrixToggleButton.state = isDistanceMatrixShowing ? .on : .off
        distanceMatrixToggleButton.isEnabled = bottomPane.isDistancesAvailable
        if isDistanceMatrixShowing { bottomPane.loadPendingDistanceInput() }
    }
}

/// The matrix cell that has keyboard focus, for the Inspector's Pairwise
/// Distance section.
struct MSAFocusedDistancePair: Equatable {
    let rowName: String
    let columnName: String
    let model: MSADistanceModel
    let detail: MSAPairDetail
}
