// TaxTriageWizardSheet+SampleNames.swift - The dialog refuses two sample names that the pipeline turns into one name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTCONTROLS, row TAXTRIAGE-NAMES-THAT-MEET-LOSE-ROWS. The words and the rule are
// ``TaxTriageSample/namesThatMeetWords(in:)``, which the run's own refusal says too.

import Foundation
import LungfishWorkflow

extension TaxTriageWizardSheet {

    /// Pure, testable helper: non-nil when two sample names become one name once the pipeline removes spaces and
    /// symbols, with what to do. The names are trimmed as the run trims them.
    static func sampleNamesValidationMessage(_ names: [String]) -> String? {
        TaxTriageSample.namesThatMeetWords(in: names.map { $0.trimmingCharacters(in: .whitespaces) })
    }
}
