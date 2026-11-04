// TaxTriageWizardSheet+SampleNames.swift - The dialog refuses two sample names that the pipeline turns into one name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTCONTROLS, row TAXTRIAGE-NAMES-THAT-MEET-LOSE-ROWS. The words and the rule are
// ``TaxTriageSample/namesThatMeetWords(in:)``, which the run's own refusal says too. The same file shows the errors
// of the other settings under their fields (row WIZARD-ERRORS-NOT-SHOWN), since the sheet gives its host a Bool only.

import Foundation
import LungfishWorkflow
import SwiftUI

extension TaxTriageWizardSheet {

    /// Pure, testable helper: non-nil when two sample names become one name once the pipeline removes spaces and
    /// symbols, with what to do. The names are trimmed as the run trims them.
    static func sampleNamesValidationMessage(_ names: [String]) -> String? {
        TaxTriageSample.namesThatMeetWords(in: names.map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// An error of the settings in caption type, shown under the field it belongs to. The embedded form has no footer
    /// of its own and its host prints a generic line (`Finish the settings above to continue`), so these words reach
    /// a person only here (lane TTCONTROLS, UX review blocker B1, and row WIZARD-ERRORS-NOT-SHOWN). Without an error it
    /// takes no room.
    @ViewBuilder
    static func settingsErrorNotice(_ words: String?) -> some View {
        if let words {
            Text(words)
                .font(.caption)
                .foregroundStyle(Color.lungfishOrangeFallback)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The refusal of two sample names that become one name, under the sample list.
    static func sampleNamesNotice(_ names: [String]) -> some View {
        settingsErrorNotice(Self.sampleNamesValidationMessage(names))
    }

    /// The error of an invalid "Exclude host taxa" list, under the field.
    static func taxidsNotice(_ text: String) -> some View {
        settingsErrorNotice(Self.removeTaxidsValidationMessage(text))
    }

    /// The error of an advanced-arguments string that does not parse, under the Advanced Settings.
    static func advancedArgumentsNotice(_ text: String) -> some View {
        settingsErrorNotice(Self.advancedArgumentsParseError(text))
    }
}
