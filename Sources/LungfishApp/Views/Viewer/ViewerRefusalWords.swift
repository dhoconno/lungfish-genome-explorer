// ViewerRefusalWords.swift - The words a refused viewer command shows in place of a beep (Phase 3.2, BEEPS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishKit

/// Where the words of a refused viewer command reach the screen (row BEEP-SWEEP, Phase 3.2).
///
/// The live presenter shows a `FailureReport` as a sheet on the window it is given, as `FailurePresenter` does. A test
/// binds a recording presenter with `ViewerRefusalSeam.$presenter.withValue`, so no alert opens in the tier and the
/// test reads the words instead. The seam is task-local, so nothing can assign it and it cannot leak between tests.
protocol ViewerRefusalPresenting: Sendable {
    @MainActor func present(_ report: FailureReport, in window: NSWindow?)
}

/// The presenter the app runs with.
struct LiveViewerRefusalPresenter: ViewerRefusalPresenting {
    @MainActor func present(_ report: FailureReport, in window: NSWindow?) {
        FailurePresenter.present(report, in: window)
    }
}

enum ViewerRefusalSeam {
    @TaskLocal static var presenter: any ViewerRefusalPresenting = LiveViewerRefusalPresenter()

    /// Shows the words of a refusal on `window`, or on the key window when there is none.
    @MainActor static func present(_ report: FailureReport, in window: NSWindow?) {
        presenter.present(report, in: window)
    }
}

/// The words of the refusals that used to beep. Each says what was missing and what to try next, in the shape
/// `FailureReport` asks for: `step` starts with a verb and the alert title reads "Could not" and the step.
enum ViewerRefusalReports {
    // MARK: - The drawer's Add Annotation and Edit Annotation forms

    /// The first thing wrong with an annotation form, in words, or nil when the form is complete. Start and End are
    /// the 1-based closed values the form shows.
    static func annotationFormProblem(name: String, type: String, chromosome: String, start: String, end: String) -> String? {
        func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isBlank(name) { return "The Name box is empty" }
        if isBlank(type) { return "The Type box is empty" }
        if isBlank(chromosome) { return "The Chromosome box is empty" }
        let startText = start.trimmingCharacters(in: .whitespacesAndNewlines)
        let endText = end.trimmingCharacters(in: .whitespacesAndNewlines)
        if startText.isEmpty { return "The Start box is empty" }
        guard let startValue = Int(startText) else { return "Start must be a whole number, and \"\(startText)\" is not one" }
        if endText.isEmpty { return "The End box is empty" }
        guard let endValue = Int(endText) else { return "End must be a whole number, and \"\(endText)\" is not one" }
        if startValue < 1 { return "Start must be 1 or more, and it is \(startValue)" }
        if endValue < startValue { return "End (\(endValue)) comes before Start (\(startValue))" }
        return nil
    }

    /// An Add or Edit form the drawer would not take. The sheet has closed by then, so the words name the first box
    /// that is wrong, or the failed write when every box is fine, and say which command to choose again.
    static func annotationForm(
        step: String, command: String, name: String, type: String, chromosome: String, start: String, end: String
    ) -> FailureReport {
        guard let problem = annotationFormProblem(name: name, type: type, chromosome: chromosome, start: start, end: end) else {
            return annotationNotWritten(step: step, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return FailureReport(
            failedStep: step,
            whatHappened: "\(problem), so the annotation was not saved.",
            nextStep: "Choose \(command) again and correct the form.",
            underlying: nil
        )
    }

    /// The annotation database refused the write.
    static func annotationNotWritten(step: String, name: String) -> FailureReport {
        FailureReport(
            failedStep: step,
            whatHappened: "Lungfish could not write the annotation \"\(name)\" to this bundle's annotation database, so it was not saved.",
            nextStep: "Check that the bundle is in a folder you can write to, then try again.",
            underlying: nil
        )
    }

    /// The annotation has no record in an open annotation database, so it cannot be changed.
    static func annotationNotEditable(step: String) -> FailureReport {
        FailureReport(
            failedStep: step,
            whatHappened: "Lungfish can change an annotation only when it is stored in this bundle's annotation database, and it found no record of this one there, so nothing was changed.",
            nextStep: "Select an annotation from a track stored in the bundle, then try again.",
            underlying: nil
        )
    }

    // MARK: - Deleting annotations and annotation tracks

    /// None of the selected rows has a record in the annotation database.
    static func nothingToDelete(count: Int) -> FailureReport {
        FailureReport(
            failedStep: count == 1 ? "Delete the selected annotation" : "Delete the selected annotations",
            whatHappened: count == 1
                ? "The selected annotation is not stored in this bundle's annotation database, so it cannot be deleted."
                : "None of the \(count) selected annotations is stored in this bundle's annotation database, so none can be deleted.",
            nextStep: "Select annotations from a track stored in the bundle, then delete them again.",
            underlying: nil
        )
    }

    /// The viewer has no reference bundle open to delete from.
    static func noBundleToDeleteFrom(step: String) -> FailureReport {
        FailureReport(
            failedStep: step,
            whatHappened: "The viewer has no reference bundle open to delete from, so nothing was deleted.",
            nextStep: "Open the bundle that holds the annotations, then try again.",
            underlying: nil
        )
    }

    // MARK: - The ruler's position box

    /// The text typed in the position box is no position, no range and no sequence name.
    static func locusNotRead(input: String) -> FailureReport {
        FailureReport(
            failedStep: "Go to the position",
            whatHappened: "Lungfish could not read \"\(shortened(input))\" as a position, a range or a sequence name, so the view did not move.",
            nextStep: "Type a position such as chr1:1000, a range such as chr1:1000-2000, or the name of a sequence, then press Return again.",
            underlying: nil
        )
    }

    /// The text typed in the position box names a sequence the document does not have.
    static func sequenceNotFound(name: String, knownChromosomes: [String]) -> FailureReport {
        guard !knownChromosomes.isEmpty else {
            return FailureReport(
                failedStep: "Go to the sequence",
                whatHappened: "No sequence is open, so the view cannot go to \"\(shortened(name))\".",
                nextStep: "Open a sequence or a reference bundle, then type the name again.",
                underlying: nil
            )
        }
        let shown = knownChromosomes.prefix(5).map { "\"\($0)\"" }.joined(separator: ", ")
        let rest = knownChromosomes.count > 5 ? " and \(knownChromosomes.count - 5) more" : ""
        return FailureReport(
            failedStep: "Go to the sequence",
            whatHappened: "There is no sequence called \"\(shortened(name))\" in this document, so the view did not move. The sequences here are \(shown)\(rest).",
            nextStep: "Check the spelling of the name, then type it again.",
            underlying: nil
        )
    }

    // MARK: - Copying the selection

    /// The viewer holds no sequence to copy from.
    static func noSequenceToCopy(step: String) -> FailureReport {
        FailureReport(
            failedStep: step,
            whatHappened: "The viewer holds no sequence, so there was nothing to copy.",
            nextStep: "Open a sequence, select the bases you want, then try again.",
            underlying: nil
        )
    }

    /// The viewer holds a sequence but no bases are selected and no region is shown to take them from.
    static func noSelectionToCopy(step: String) -> FailureReport {
        FailureReport(
            failedStep: step,
            whatHappened: "No bases are selected and the viewer shows no region to take them from, so nothing was copied.",
            nextStep: "Select the bases you want, then try again.",
            underlying: nil
        )
    }

    // MARK: - The metadata export and import sheets, which show these in their own label

    /// Export was pressed with no sample ticked.
    static let metadataNothingToExport = "Tick at least one sample, then choose Export again."

    /// Import was pressed and no row of the file matches a sample of the project.
    static let metadataNothingToImport = "No sample name in this file matches a sample in the project, so there is nothing to import. Check the sample names in the file, then choose the file again."

    private static func shortened(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(60)) + "..." : text
    }
}

extension AnnotationTableDrawerView {
    /// Shows the words of a refused Add, Edit or Delete on the drawer's window.
    func presentAnnotationRefusal(_ report: FailureReport) {
        ViewerRefusalSeam.present(report, in: window)
    }

    /// Shows the words for an Add or Edit form the drawer would not take.
    func presentAnnotationFormRefusal(_ form: AnnotationEditForm, step: String, command: String) {
        presentAnnotationRefusal(ViewerRefusalReports.annotationForm(
            step: step,
            command: command,
            name: form.nameField.stringValue,
            type: form.typeField.stringValue,
            chromosome: form.chromosomeField.stringValue,
            start: form.startField.stringValue,
            end: form.endField.stringValue
        ))
    }
}

extension ViewerViewController {
    /// Shows the words of a refused viewer command on the viewer's window.
    func presentViewerRefusal(_ report: FailureReport) {
        ViewerRefusalSeam.present(report, in: view.window)
    }
}

extension SequenceViewerView {
    /// Shows why a copy had nothing to copy, on the viewer's window.
    func presentSelectionRefusal(step: String) {
        let report = sequence == nil
            ? ViewerRefusalReports.noSequenceToCopy(step: step)
            : ViewerRefusalReports.noSelectionToCopy(step: step)
        ViewerRefusalSeam.present(report, in: window)
    }
}
