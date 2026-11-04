// SequenceViewerView+AnnotationSequenceFailure.swift - Words for an annotation sequence that could not be read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

extension SequenceViewerView {
    /// What a person asked for when an annotation's sequence could not be read.
    enum AnnotationSequenceStep {
        case copySequence
        case copyComplement
        case copyReverseComplement
        case showTranslation

        var failedStep: String {
            switch self {
            case .copySequence: return "Copy the annotation sequence"
            case .copyComplement: return "Copy the complement of the annotation"
            case .copyReverseComplement: return "Copy the reverse complement of the annotation"
            case .showTranslation: return "Show the translation"
            }
        }

        /// What did not happen because the read failed.
        var consequence: String {
            self == .showTranslation ? "so its translation is not shown" : "so nothing was copied"
        }

        /// What to do once the reference is fixed.
        var retry: String {
            self == .showTranslation ? "then show the translation again" : "then copy the sequence again"
        }
    }

    /// The words for an annotation whose sequence could not be read from the open reference. One failed interval
    /// fails the whole read (`fetchAnnotationBasesAsync`), so a copy never holds some exons and lacks others.
    static func annotationSequenceFailureReport(name: String, step: AnnotationSequenceStep) -> FailureReport {
        FailureReport(
            failedStep: step.failedStep,
            whatHappened: "Lungfish could not read the sequence of \"\(name)\" from the reference, \(step.consequence). The reference's sequence file may be missing, or it may have been changed or cut after it was indexed.",
            nextStep: "Check that the reference is still in the project. If its sequence file was changed, import the original FASTA again, \(step.retry).",
            underlying: nil
        )
    }

    /// Shows why an annotation's sequence was not copied or translated, in place of the beep a failed read used to give.
    /// The words go through `ViewerRefusalSeam`, so a test binds a recording presenter to read them and no alert opens.
    func presentAnnotationSequenceFailure(_ annotation: SequenceAnnotation, step: AnnotationSequenceStep) {
        ViewerRefusalSeam.present(Self.annotationSequenceFailureReport(name: annotation.name, step: step), in: window)
    }
}
