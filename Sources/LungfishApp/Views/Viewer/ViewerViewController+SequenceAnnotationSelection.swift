// ViewerViewController+SequenceAnnotationSelection.swift - sequence-region annotation selection routing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

struct SequenceAnnotationDraftContext: Equatable {
    let bundleURL: URL?
    let chromosome: String
    let range: Range<Int>
    let sequenceLength: Int?
}

extension ViewerViewController {
    func currentSequenceAnnotationDraftContext() -> SequenceAnnotationDraftContext? {
        if let referenceBundleViewportController,
           let context = referenceBundleViewportController.currentSequenceAnnotationDraftContext() {
            return context
        }
        return localSequenceAnnotationDraftContext
    }

    var localSequenceAnnotationDraftContext: SequenceAnnotationDraftContext? {
        guard let range = viewerView.explicitUserSelectionRange else { return nil }

        let chromosome = referenceFrame?.chromosome
            ?? viewerView.sequence?.name
            ?? currentBundleDataProvider?.chromosomes.first?.name
            ?? ""
        guard !chromosome.isEmpty else { return nil }

        let length = referenceFrame?.sequenceLength
            ?? viewerView.sequence?.length
            ?? currentBundleDataProvider?.chromosomeInfo(named: chromosome).map { Int($0.length) }

        return SequenceAnnotationDraftContext(
            bundleURL: (currentBundleURL ?? viewerView.currentReferenceBundle?.url)?.standardizedFileURL,
            chromosome: chromosome,
            range: range,
            sequenceLength: length
        )
    }

    func currentSequenceRegionSelectionState() -> SequenceRegionSelectionState? {
        guard let context = localSequenceAnnotationDraftContext else { return nil }
        let length = context.range.upperBound - context.range.lowerBound
        let coordinateLabel = "\(context.chromosome):\(context.range.lowerBound + 1)-\(context.range.upperBound)"
        var rows: [(String, String)] = [
            ("Sequence", context.chromosome),
            ("Range", "\(context.range.lowerBound + 1)-\(context.range.upperBound)"),
            ("Length", "\(length.formatted()) bp"),
        ]
        if let sequenceLength = context.sequenceLength {
            rows.append(("Sequence Length", "\(sequenceLength.formatted()) bp"))
        }

        return SequenceRegionSelectionState(
            title: "Selected Region",
            subtitle: coordinateLabel,
            detailRows: rows
        )
    }

    func notifySequenceRegionSelectionIfAvailable() {
        onSequenceRegionSelectionChanged?(currentSequenceRegionSelectionState())
    }
}

extension SequenceViewerView {
    var explicitUserSelectionRange: Range<Int>? {
        guard isUserColumnSelection,
              let range = selectionRange,
              !range.isEmpty else {
            return nil
        }
        return range
    }
}
