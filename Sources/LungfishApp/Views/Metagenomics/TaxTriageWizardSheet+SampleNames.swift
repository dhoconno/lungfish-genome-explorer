// TaxTriageWizardSheet+SampleNames.swift - The dialog refuses two sample names that the pipeline turns into one name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTCONTROLS, row TAXTRIAGE-NAMES-THAT-MEET-LOSE-ROWS. The words and the rule are
// ``TaxTriageSample/namesThatMeetWords(in:)``, which the run's own refusal says too.

import Foundation
import LungfishWorkflow
import SwiftUI

extension TaxTriageWizardSheet {

    /// Pure, testable helper: non-nil when two sample names become one name once the pipeline removes spaces and
    /// symbols, with what to do. The names are trimmed as the run trims them.
    static func sampleNamesValidationMessage(_ names: [String]) -> String? {
        TaxTriageSample.namesThatMeetWords(in: names.map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// The refusal under the sample list, so the Operations dialog shows it as the standalone footer does (lane
    /// TTCONTROLS, UX review, blocker B1). The embedded form has no footer of its own and its host prints a generic
    /// line, so these words reach a person only here. It takes no room when the names stay different.
    @ViewBuilder
    static func sampleNamesNotice(_ names: [String]) -> some View {
        if let words = sampleNamesValidationMessage(names) {
            Text(words)
                .font(.caption)
                .foregroundStyle(Color.lungfishOrangeFallback)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
