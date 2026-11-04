// SequenceViewerView+ExtractionRefusals.swift - The words of an extraction the viewer refuses before it starts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit

/// The words shown in place of a beep when an extraction action finds nothing to work from (UWORDS, Phase 3.2,
/// FASTAREAD review backlog item 8). Each report says what was missing and what to try next. `step` names the action
/// and starts with a verb, as `FailureReport.failedStep` asks, such as "Copy the annotation as FASTA".
enum ExtractionRefusalReports {
    /// The viewer holds neither a reference bundle nor a sequence to read an annotation's bases from.
    static func noSequence(step: String) -> FailureReport {
        FailureReport(
            failedStep: step,
            whatHappened: "The viewer holds no sequence to read this annotation's bases from, so nothing was copied or created.",
            nextStep: "Open the sequence or the reference bundle that the annotation belongs to, then try again.",
            underlying: nil
        )
    }

    /// The viewer shows no region, so a visible-region action has none to use.
    static func noRegion(step: String) -> FailureReport {
        FailureReport(
            failedStep: step,
            whatHappened: "The viewer shows no region, so there is nothing to copy or extract.",
            nextStep: "Open a sequence or a reference bundle and move to the region you want, then try again.",
            underlying: nil
        )
    }

    /// The extraction made no protein translation, which usually means the annotation is not a coding sequence.
    static func noProtein(step: String) -> FailureReport {
        FailureReport(
            failedStep: step,
            whatHappened: "Lungfish could not make a protein translation of this annotation, which usually means it is not a coding sequence (CDS), so nothing was copied or created.",
            nextStep: "Select a CDS annotation, then try again.",
            underlying: nil
        )
    }

    /// The sequence a region was extracted from is no longer open, so no bundle can be made from it.
    static func noDocumentSequence(step: String) -> FailureReport {
        FailureReport(
            failedStep: step,
            whatHappened: "The sequence this region was taken from is no longer open in the viewer, so no bundle was made.",
            nextStep: "Open the sequence again, then extract the region again.",
            underlying: nil
        )
    }

    /// Every selected annotation was left out, since the viewer holds no sequence for them or their bases could not be
    /// read, so the extraction dialog has no record to show. Annotations that were only some of the selection are named
    /// by `leftOutAnnotationsReport` instead.
    static func nothingToExtract(selected: Int, leftOut: [(name: String, error: any Error)]) -> FailureReport {
        let step = "Extract the selected annotations"
        guard let firstError = leftOut.first?.error else {
            return FailureReport(
                failedStep: step,
                whatHappened: "The viewer holds no sequence to read the selected annotations' bases from, so nothing was extracted.",
                nextStep: "Open the sequence or the reference bundle that the annotations belong to, then extract again.",
                underlying: nil
            )
        }
        let readFailed = leftOut.allSatisfy { entry -> Bool in
            if case LungfishCore.ExtractionError.sequenceNotAvailable = entry.error { return true }
            return false
        }
        let names = leftOut.prefix(3).map { "\"\($0.name)\"" }.joined(separator: ", ")
        let rest = leftOut.count > 3 ? " and \(leftOut.count - 3) more" : ""
        let which = selected == 1 ? "the selected annotation" : "the \(selected) selected annotations"
        return FailureReport(
            failedStep: step,
            whatHappened: readFailed
                ? "Lungfish could not read the bases of \(which) (\(names)\(rest)) from the reference, so nothing was extracted. The reference's sequence file may be missing, or it may have been changed or cut after it was indexed."
                : "Lungfish could not extract the sequence of \(which) (\(names)\(rest)), so nothing was extracted.",
            nextStep: readFailed
                ? "Check that the reference is still in the project. If its sequence file was changed, import the original FASTA again, then extract again."
                : "Check the annotations and the extraction options, then extract again.",
            underlying: firstError
        )
    }
}
