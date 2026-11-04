// TranslationReadWords.swift - The words for a protein read from fewer bases than its annotation names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO

/// The words every route shows for a CDS translation that a sequence end clipped, or whose bases could not be
/// read (Phase 3.2 row FASTA-CLAMPED-TRUNCATED). The figures come from `TranslationResult` and
/// `TranslationEngine.annotatedCodingLength(of:)`, never from the route, so the Inspector, the viewer track and the
/// hover cannot disagree.
enum TranslationReadWords {
    /// The Inspector line under a protein built from fewer bases than the annotation names. It ends with the step
    /// for the one cause a person can fix, an annotation from another assembly of the reference.
    static func clippedNotice(read: Int, annotated: Int) -> String {
        "The sequence ends inside this annotation, so only \(read) of its \(annotated) coding bases were read. The protein shown is built from those bases alone. If the annotation should lie wholly inside this sequence, check that the annotation and the reference are from the same assembly."
    }

    /// The Inspector line for a CDS whose bases could not be read, in place of a protein.
    static func unreadNotice(name: String) -> String {
        "Lungfish could not read the bases of \"\(name)\" from the reference, so no protein is shown. Check that the reference's sequence file is still in the project, or import the original FASTA again."
    }

    /// The label of the viewer's translation track, which names the figure when the protein covers part of the CDS.
    static func trackLabel(for result: TranslationResult) -> String {
        guard result.isClipped else { return "Translation" }
        return "Translation (\(result.codingBasesRead) of \(result.annotatedCodingLength) bases read)"
    }

    /// The hover line for a CDS whose protein was built from fewer bases than the annotation names.
    static func hoverClippedLine(label: String, read: Int, annotated: Int) -> String {
        "\(label): protein built from \(read) of \(annotated) coding bases, the sequence ends inside this annotation"
    }

    /// The hover line for a CDS whose bases could not be read.
    static func hoverUnreadLine(label: String) -> String {
        "\(label): no protein effect shown, the coding bases could not be read"
    }
}

extension SelectionSectionViewModel {
    /// Reads the bases of `annotation` from the reference bundle and translates them. A CDS that a sequence end
    /// clips still gives its protein, with the words that say how much was read, and a read that fails gives the
    /// words that say so. With no reference bundle there is nothing to read and no words.
    func translationReading(for annotation: SequenceAnnotation) -> (protein: String?, notice: String?) {
        guard let bundle = referenceBundle else { return (nil, nil) }
        let provider = ClampedSequenceProvider(bundle: bundle).basesProvider(
            chromosome: annotation.chromosome ?? bundle.firstChromosomeName ?? ""
        )
        guard let result = TranslationEngine.translateCDS(annotation: annotation, sequenceProvider: provider) else {
            return (nil, TranslationReadWords.unreadNotice(name: annotation.name))
        }
        let notice = result.isClipped
            ? TranslationReadWords.clippedNotice(read: result.codingBasesRead, annotated: result.annotatedCodingLength)
            : nil
        return (result.protein, notice)
    }
}

extension TranslationTrackRenderer {
    /// The label drawn at the left edge of the CDS translation track.
    static func label(for result: TranslationResult) -> String {
        TranslationReadWords.trackLabel(for: result)
    }
}

extension SequenceViewerView {
    /// The coding context of `cds` for a hover, and in `details` the line that says its bases were not all read or
    /// could not be read. The figures are the engine's, the bases the context holds and the bases the annotation names.
    func cdsCodingContext(for cds: SequenceAnnotation, noting details: inout [String]) -> CDSCodingContext? {
        let context = cdsCodingContext(for: cds)
        let label = Self.codingFeatureLabel(for: cds)
        let annotated = TranslationEngine.annotatedCodingLength(of: cds)
        let line: String?
        if let context {
            let read = context.codingBases.count
            line = read < annotated
                ? TranslationReadWords.hoverClippedLine(label: label, read: read, annotated: annotated)
                : nil
        } else {
            line = TranslationReadWords.hoverUnreadLine(label: label)
        }
        if let line, !details.contains(line) {
            details.append(line)
        }
        return context
    }
}
