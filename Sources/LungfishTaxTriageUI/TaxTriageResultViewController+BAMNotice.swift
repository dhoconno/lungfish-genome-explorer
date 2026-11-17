// TaxTriageResultViewController+BAMNotice.swift - The words that say a sample's BAM is a file that a fit of its name gave it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishWorkflow

extension TaxTriageResultViewController {
    /// The words that say the BAM behind `sample`'s alignment is a file that a fit of its name gave the sample and can be
    /// another sample's, or nil when it is the sample's own file. The view, the Inspector and BLAST Verify read one layer,
    /// ``ClassifierReadResolver/taxTriageRecordedBAMNotice(sampleId:resultPath:bam:)``, so Extract Reads says the same
    /// words (BIO-WALK-T2-VIEW).
    func bamNotice(forSample sample: String?) -> String? {
        guard let sample, let bam = bamFilesBySample[sample], let resultURL = batchGroupURL else { return nil }
        return ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: sample, resultPath: resultURL, bam: bam)
    }

    /// Puts ``bamNotice(forSample:)`` in the action bar's info line, and in its tooltip for the part that a narrow bar cuts
    /// off. A selection of a sample with no notice takes back the one an earlier selection put there.
    func showBAMNotice(forSample sample: String?) {
        let label = actionBar.infoLabel
        if let notice = bamNotice(forSample: sample) {
            actionBar.updateInfoText(notice)
            label.toolTip = notice
        } else if let shown = label.toolTip {
            label.toolTip = nil
            if label.stringValue == shown { actionBar.updateInfoText("") }
        }
    }
}
