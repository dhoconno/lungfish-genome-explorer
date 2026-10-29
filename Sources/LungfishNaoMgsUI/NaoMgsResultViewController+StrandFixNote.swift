// NaoMgsResultViewController+StrandFixNote.swift - The miniBAM note for a result made before the NAO-MGS strand fix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

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
    /// changes the note only when it finds the BAM made before the strand fix and `generation` is still the current
    /// load, so a check of an earlier selection never sets a later one's note. Nothing rebuilds or writes the BAM.
    func startStrandFixCheck(sample: String, bamRelativePath: String?, generation: Int) {
        guard let database else { return }
        let resultURL = database.databaseURL.deletingLastPathComponent()
        let bamURL: URL = {
            if let bamRelativePath, !bamRelativePath.isEmpty {
                return resultURL.appendingPathComponent(bamRelativePath)
            }
            return resultURL.appendingPathComponent("bams").appendingPathComponent("\(sample).bam")
        }()
        Task.detached { [weak self] in
            let orientation: NaoMgsBamOrientation?
#if DEBUG
            if let hook = await self?.testStrandFixOrientationHook {
                orientation = await hook(generation)
            } else {
                orientation = Self.strandFixOrientation(of: bamURL)
            }
#else
            orientation = Self.strandFixOrientation(of: bamURL)
#endif
            await self?.applyStrandFixCheck(orientation, generation: generation)
        }
    }

    /// The orientation of the BAM, or nil when it is missing, samtools is not found or the header cannot be read.
    nonisolated private static func strandFixOrientation(of bamURL: URL) -> NaoMgsBamOrientation? {
        guard FileManager.default.fileExists(atPath: bamURL.path), let samtoolsPath = naomgsLocateSamtools() else { return nil }
        return try? NaoMgsBamMaterializer.orientation(ofBAM: bamURL, samtoolsPath: samtoolsPath)
    }

    private func applyStrandFixCheck(_ orientation: NaoMgsBamOrientation?, generation: Int) {
        let applies = orientation == .beforeStrandFix && generation == miniBAMLoadGeneration && miniBAMNoteLabel != nil
        if applies, let label = miniBAMNoteLabel {
            label.stringValue = Self.miniBAMStrandFixNoteWords
            label.textColor = .labelColor
        }
#if DEBUG
        testStrandFixOutcomes.append((generation: generation, applied: applies))
#endif
    }
}
