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
    public static let reading = "Reading the quality numbers, after checking each file of the result against its sha256. "
        + "A result of many samples can take a while, and the count tables can be read meanwhile."

    /// The scale line under the correlation plot. It keeps the lowest value of the table and the grey key in view.
    public static func scale(lowest: String) -> String {
        "On a scale from the lowest value of the table, \(lowest), to 1. A grey square reads Not recorded."
    }

    /// What the correlation plot's info button opens.
    public static let correlationColour = "A stronger blue square is a higher value."
    /// What the button explains, the "<thing>" of its VoiceOver label "About <thing>".
    public static let correlationSubject = "the correlation squares"
}

/// The explanations of the quality tabs that are true of every bulk result.
public enum RNASeqBulkHelp {
    /// Beside the scale line under the correlation plot.
    public static let correlationColour = LungfishHelpContent.HelpItem(
        id: "rnaseq.bulk.correlationColour",
        summary: RNASeqBulkWords.correlationColour,
        audience: .benchScientist)

    public static let items = [correlationColour]
}
