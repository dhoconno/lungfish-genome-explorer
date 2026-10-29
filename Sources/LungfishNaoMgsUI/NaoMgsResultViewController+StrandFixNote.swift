// NaoMgsResultViewController+StrandFixNote.swift - The miniBAM note for a result whose BAM is old or missing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

/// What the check of the displayed sample's BAM found. A missing file is an answer of its own, apart from a header that
/// cannot be read, since each gets different words (ruling UX-NAO-BAM-STALE R4, lane NAO-BAM-MISSING).
private enum StrandFixFinding: Sendable, Equatable {
    /// The header says which side of the strand fix the BAM is on.
    case orientation(NaoMgsBamOrientation)
    /// There is no file where the result keeps the sample's BAM.
    case missing
    /// samtools is not found or the header cannot be read, so nothing is known about the BAM.
    case unreadable
}

extension NaoMgsResultViewController {

    /// The note under the miniBAM header, which a fixed BAM, a running check and an unreadable header all keep.
    static let miniBAMReferenceNoteWords =
        "Top references by unique read count. Drag a panel handle downward to make it taller."

    /// The note when the check found the sample's BAM made before the strand fix (ruling UX-NAO-BAM-STALE 4b). It says
    /// what happened and what to do, and it is true for a BAM at `VN:1.0` and for one with no marker.
    static let miniBAMStrandFixNoteWords =
        "These read panels come from an earlier NAO-MGS import, which stored reads that map to the reverse strand the "
        + "wrong way round, so many reads show false mismatches. To see them correctly, import the same NAO-MGS "
        + "results file again in the Import Center (NAO-MGS Results). The counts and read IDs are right."

    /// The note when the sample's BAM is missing and the on-demand fallback could not make it again (ruling
    /// UX-NAO-BAM-STALE R4). It names the file, says what that means for the panels and says what to try. It does not
    /// say why the file is gone, since a removal by hand and an import that never wrote it look the same.
    static func miniBAMMissingBAMNoteWords(file: String) -> String {
        "The alignment file \(file) is missing from this result, so the read panels are empty. "
            + "Lungfish could not rebuild it. To see the reads, import the same NAO-MGS results file again in the "
            + "Import Center (NAO-MGS Results)."
    }

    /// Builds the note label in today's words, adds it to `container` and keeps it, so that a strand-fix check that
    /// ends later can change it. Called once for each build of the miniBAM list.
    func makeMiniBAMNoteLabel(in container: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: Self.miniBAMReferenceNoteWords)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        miniBAMNoteLabel = label
        return label
    }

    /// Reads the header of the sample's BAM off the main actor, in a detached task like the missing-BAM fallback's, and
    /// changes the note only when it finds the BAM made before the strand fix or, with `afterFallback`, still missing,
    /// and `generation` is still the current load, so a check of an earlier selection never sets a later one's note.
    /// A file missing at load is not final, since the fallback may still make it, so the load-time call leaves the note
    /// alone and the fallback calls again with `afterFallback` when it ends and the file is still not there. Nothing
    /// rebuilds or writes the BAM here.
    func startStrandFixCheck(sample: String, bamRelativePath: String?, generation: Int, afterFallback: Bool = false) {
        guard let database else { return }
        let resultURL = database.databaseURL.deletingLastPathComponent()
        let shownPath = bamRelativePath.flatMap { $0.isEmpty ? nil : $0 } ?? "bams/\(sample).bam"
        let bamURL: URL = {
            if let bamRelativePath, !bamRelativePath.isEmpty {
                return resultURL.appendingPathComponent(bamRelativePath)
            }
            return resultURL.appendingPathComponent("bams").appendingPathComponent("\(sample).bam")
        }()
        Task.detached { [weak self] in
            let finding: StrandFixFinding
#if DEBUG
            if let hook = await self?.testStrandFixOrientationHook {
                finding = await hook(generation).map(StrandFixFinding.orientation) ?? .unreadable
            } else {
                finding = Self.strandFixOrientation(of: bamURL)
            }
#else
            finding = Self.strandFixOrientation(of: bamURL)
#endif
            await self?.applyStrandFixCheck(finding, file: shownPath, generation: generation, afterFallback: afterFallback)
        }
    }

    /// The orientation of the BAM, or `.missing` when there is no file, or `.unreadable` when samtools is not found or
    /// the header cannot be read.
    nonisolated private static func strandFixOrientation(of bamURL: URL) -> StrandFixFinding {
        guard FileManager.default.fileExists(atPath: bamURL.path) else { return .missing }
        guard let samtoolsPath = naomgsLocateSamtools(),
              let orientation = try? NaoMgsBamMaterializer.orientation(ofBAM: bamURL, samtoolsPath: samtoolsPath)
        else { return .unreadable }
        return .orientation(orientation)
    }

    /// Sets the note through its one label and its one generation guard. A BAM made before the strand fix gets the
    /// re-import words, and a file that is missing once the fallback has ended gets the missing-file words. Every other
    /// answer keeps today's note, so the note makes no claim the check did not make.
    private func applyStrandFixCheck(_ finding: StrandFixFinding, file: String, generation: Int, afterFallback: Bool) {
        let words: String?
        switch finding {
        case .orientation(.beforeStrandFix): words = Self.miniBAMStrandFixNoteWords
        case .missing where afterFallback: words = Self.miniBAMMissingBAMNoteWords(file: file)
        case .orientation(.referenceStrand), .missing, .unreadable: words = nil
        }
        let applies = words != nil && generation == miniBAMLoadGeneration && miniBAMNoteLabel != nil
        if applies, let words, let label = miniBAMNoteLabel {
            label.stringValue = words
            label.textColor = .labelColor
        }
#if DEBUG
        testStrandFixOutcomes.append((generation: generation, applied: applies))
#endif
    }
}
