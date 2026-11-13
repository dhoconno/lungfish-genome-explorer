// SequenceViewerView+BundleSelectionCopy.swift - Copy of a selection in a reference bundle view (BEEPS-COPY-SAYS-NO-SEQUENCE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

extension SequenceViewerView {
    /// Edit > Copy. The menu item is the standard `copy:` action, which nothing in the viewer answered, so the item
    /// stayed greyed out here and only the Command-C key reached the copy.
    @objc func copy(_ sender: Any?) {
        copySelectionToClipboard()
    }

    /// The bases of `range` on `chromosome` when the cached window holds all of them, or nil.
    nonisolated static func basesInCache(
        of range: Range<Int>, on chromosome: String, cached: String?, window: GenomicRegion?
    ) -> String? {
        guard let cached, let window, window.chromosome == chromosome,
              window.start <= range.lowerBound, range.upperBound <= window.end else { return nil }
        let bytes = cached.utf8
        let offset = range.lowerBound - window.start
        guard !range.isEmpty, offset + range.count <= bytes.count else { return nil }
        let lower = bytes.index(bytes.startIndex, offsetBy: offset)
        let upper = bytes.index(lower, offsetBy: range.count)
        return String(cached[lower..<upper])
    }

    /// Copies the selection of a view that holds no `sequence` because it fetches the bases it draws on demand. With
    /// nothing selected it takes the visible region, as a single sequence does. It reads the cached window when that
    /// holds the selection and the bundle otherwise, off the main actor.
    func copyBundleSelectionToClipboard(step: String) {
        // Every copy bumps the generation, so a slower fetch of an older copy that lands later is dropped.
        fastaOperationFetchGeneration += 1
        let generation = fastaOperationFetchGeneration
        if selectionRange == nil {
            selectVisibleRegion()
        }
        let frame = viewController?.referenceFrame
        guard let selected = selectionRange,
              let chromosome = frame?.chromosome ?? cachedSequenceRegion?.chromosome else {
            presentBundleSelectionRefusal(step: step)
            return
        }
        let length = currentReferenceBundle?.chromosomeLength(named: chromosome).map { Int($0) }
            ?? frame?.sequenceLength ?? cachedSequenceRegion?.end ?? 0
        let lower = max(0, selected.lowerBound)
        let upper = min(length, selected.upperBound)
        guard lower < upper else {
            presentBundleSelectionRefusal(step: step)
            return
        }
        if let bases = Self.basesInCache(
            of: lower..<upper, on: chromosome, cached: cachedBundleSequence, window: cachedSequenceRegion
        ) {
            writeCopiedBases(bases)
            return
        }
        guard let bundle = currentReferenceBundle else {
            ViewerRefusalSeam.present(ViewerRefusalReports.selectionBasesNotRead(step: step), in: window)
            return
        }
        let region = GenomicRegion(chromosome: chromosome, start: lower, end: upper)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let bases = try? await Self.fetchBundleRegionOffMain(bundle: bundle, region: region)
            guard generation == self.fastaOperationFetchGeneration else { return }
            guard let bases, !bases.isEmpty else {
                ViewerRefusalSeam.present(ViewerRefusalReports.selectionBasesNotRead(step: step), in: self.window)
                return
            }
            self.writeCopiedBases(bases)
        }
    }

    private func presentBundleSelectionRefusal(step: String) {
        ViewerRefusalSeam.present(ViewerRefusalReports.noSelectionToCopy(step: step), in: window)
    }

    private func writeCopiedBases(_ bases: String) {
        let pasteboard = copyPasteboard
        pasteboard.clearContents()
        pasteboard.setString(bases, forType: .string)
    }
}

extension ViewerRefusalReports {
    /// The selected bases could not be read from the open reference.
    static func selectionBasesNotRead(step: String) -> FailureReport {
        FailureReport(
            failedStep: step,
            whatHappened: "Lungfish could not read the selected bases from the reference, so nothing was copied. The reference's sequence file may be missing, or it may have been changed or cut after it was indexed.",
            nextStep: "Check that the reference is still in the project. If its sequence file was changed, import the original FASTA again, then copy the selection again.",
            underlying: nil
        )
    }
}
