// MultipleSequenceAlignmentViewController+BottomPane.swift - The MSA bottom pane: annotation table and distance matrix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO

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

    func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {
        guard let heightConstraint = annotationDrawerHeightConstraint else { return }
        let availableHeight = max(160, view.bounds.height - 140)
        heightConstraint.constant = min(max(heightConstraint.constant + deltaY, 96), availableHeight)
        view.layoutSubtreeIfNeeded()
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
