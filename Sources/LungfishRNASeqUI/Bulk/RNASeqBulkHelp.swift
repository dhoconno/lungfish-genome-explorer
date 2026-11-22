// RNASeqBulkHelp.swift - The words and the help item of the bulk view's quality tabs (5.6 A1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view builds its item here from its own words and does not add it to the Kit catalog. `RNASeqBulkQualityTests`
// runs the Kit's catalog check on `items`.

import LungfishKit

/// The words the quality tabs of the bulk view show in place of the numbers, and the words behind the info button.
public enum RNASeqBulkWords {
    /// The progress line of both quality tabs while the numbers are read.
    public static let reading = "Checking each file against its sha256 before showing quality numbers. Count tables are available. Many samples can take a while."

    /// The scale line under the correlation plot. It keeps the lowest value of the table and the grey key in view.
    public static func scale(lowest: String) -> String {
        "Table minimum \(lowest) to 1. A grey square means Not recorded."
    }

    /// The help tag of the correlation plot's info button.
    public static let correlationColourSummary = "Explains what the shade of blue means."
    /// What the correlation plot's info button opens.
    public static let correlationColour = "A deeper blue means a higher correlation."
    /// What the button explains, the "<thing>" of its VoiceOver label "About <thing>".
    public static let correlationSubject = "the correlation squares"
}

/// The explanations of the quality tabs that are true of every bulk result.
public enum RNASeqBulkHelp {
    /// Beside the scale line under the correlation plot.
    public static let correlationColour = LungfishHelpContent.HelpItem(
        id: "rnaseq.bulk.correlationColour",
        summary: RNASeqBulkWords.correlationColourSummary,
        detail: RNASeqBulkWords.correlationColour,
        audience: .benchScientist)

    public static let items = [correlationColour]
}
