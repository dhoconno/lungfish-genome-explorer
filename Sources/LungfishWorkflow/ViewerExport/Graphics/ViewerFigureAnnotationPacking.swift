// ViewerFigureAnnotationPacking.swift - The live annotation row packing as value functions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import LungfishCore

/// The annotation track's packing and display rules, copied from the live
/// `SequenceViewerView+AnnotationRendering.swift` (`packAnnotationsLayered`,
/// `packAnnotationsLayeredWithinTrack`, `packAnnotationsPixelBased`, `orderedAnnotationTrackIDs`,
/// `displayLabel` and `shouldRenderExpandedLabel`) as functions of `Sendable` values.
/// `AnnotationTrackParityTests` in LungfishAppWorkflowTests holds them equal to the live methods
/// on the annotations `AnnotationPackingPinTests` pinned first. Change neither copy alone.
public enum ViewerFigureAnnotationPacking {
    /// Rows of annotations, top first, each left to right, and the count no row could take.
    public typealias Packed = (rows: [[SequenceAnnotation]], overflow: Int)

    /// The qualifier that names an annotation's track, as the live view tags merged tracks.
    public static let trackQualifier = "annotation_db_track_id"
    /// The track of an annotation with no track qualifier.
    public static let defaultTrackID = "annotations"
    /// The gap two features in one row keep, in points.
    public static let minPixelGap: CGFloat = 2
    /// The narrowest a feature counts for packing, in points.
    public static let minFeatureWidth: CGFloat = 3
    /// A label is drawn only on a feature at least this wide, in points.
    public static let minExpandedLabelWidth: CGFloat = 72
    /// Labels are drawn only when the track has at most this many rows.
    public static let maxLabeledRows = 12

    public static func trackID(for annotation: SequenceAnnotation) -> String {
        annotation.qualifiers[trackQualifier]?.values.first ?? defaultTrackID
    }

    /// SNPs, variations, insertions and deletions, packed beneath the other features.
    public static func isVariant(_ type: AnnotationType) -> Bool {
        switch type {
        case .snp, .variation, .insertion, .deletion: true
        default: false
        }
    }

    /// The track ids in `order` that occur, then the others in the order they are met.
    public static func orderedTrackIDs(for annotations: [SequenceAnnotation], order: [String] = []) -> [String] {
        var discovered: [String] = []
        var seen: Set<String> = []
        for annotation in annotations {
            let id = trackID(for: annotation)
            guard seen.insert(id).inserted else { continue }
            discovered.append(id)
        }
        let discoveredSet = Set(discovered)
        var ordered = order.filter { discoveredSet.contains($0) }
        let orderedSet = Set(ordered)
        ordered.append(contentsOf: discovered.filter { !orderedSet.contains($0) })
        return ordered
    }

    /// Each track packed on its own, `maxRows` rows each, stacked in track order.
    public static func packLayered(
        _ annotations: [SequenceAnnotation], frame: ViewerFigureFrame, maxRows: Int, order: [String] = []
    ) -> Packed {
        let ids = orderedTrackIDs(for: annotations, order: order)
        guard ids.count > 1 else { return packWithinTrack(annotations, frame: frame, maxRows: maxRows) }
        var rows: [[SequenceAnnotation]] = []
        var overflow = 0
        for id in ids {
            let packed = packWithinTrack(annotations.filter { trackID(for: $0) == id }, frame: frame, maxRows: maxRows)
            rows.append(contentsOf: packed.rows)
            overflow += packed.overflow
        }
        return (rows, overflow)
    }

    /// The landmarks first, then the variants in the rows left over.
    public static func packWithinTrack(_ annotations: [SequenceAnnotation], frame: ViewerFigureFrame, maxRows: Int) -> Packed {
        guard maxRows > 0 else { return ([], annotations.count) }
        let landmarks = packPixelBased(annotations.filter { !isVariant($0.type) }, frame: frame, maxRows: maxRows)
        let variants = packPixelBased(
            annotations.filter { isVariant($0.type) }, frame: frame, maxRows: max(0, maxRows - landmarks.rows.count)
        )
        return (landmarks.rows + variants.rows, landmarks.overflow + variants.overflow)
    }

    /// First fit by start, end and name, each feature at least three points wide and two apart.
    public static func packPixelBased(_ annotations: [SequenceAnnotation], frame: ViewerFigureFrame, maxRows: Int) -> Packed {
        let sorted = annotations.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
        var rows: [[SequenceAnnotation]] = []
        var rowEnds: [CGFloat] = []
        var overflow = 0
        for annotation in sorted {
            let startX = frame.screenPosition(for: Double(annotation.start))
            let endX = max(frame.screenPosition(for: Double(annotation.end)), startX + minFeatureWidth)
            if let row = rowEnds.indices.first(where: { startX >= rowEnds[$0] + minPixelGap }) {
                rows[row].append(annotation)
                rowEnds[row] = endX
            } else if rows.count < maxRows {
                rows.append([annotation])
                rowEnds.append(endX)
            } else {
                overflow += 1
            }
        }
        return (rows, overflow)
    }

    /// The name on one line with runs of white space collapsed, or the type when it is empty.
    public static func displayLabel(for annotation: SequenceAnnotation) -> String {
        let collapsed = annotation.name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? annotation.type.rawValue : collapsed
    }

    /// Genes, mRNAs, transcripts and CDSs get a label when wide enough and the rows few enough.
    public static func shouldRenderExpandedLabel(for annotation: SequenceAnnotation, width: CGFloat, rowCount: Int) -> Bool {
        guard rowCount <= maxLabeledRows, width >= minExpandedLabelWidth else { return false }
        return takesLabel(annotation.type)
    }

    /// The types the expanded rows label.
    public static func takesLabel(_ type: AnnotationType) -> Bool {
        switch type {
        case .gene, .mRNA, .transcript, .cds: true
        default: false
        }
    }
}
