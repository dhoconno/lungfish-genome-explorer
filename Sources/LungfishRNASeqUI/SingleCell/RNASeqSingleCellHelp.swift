// RNASeqSingleCellHelp.swift - The help items of the single-cell view, one behind each info button (5.6 A1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view builds its items here from its own words (`RNASeqSingleCellWords`) and does not add them to the Kit catalog.
// `RNASeqSingleCellViewTests` runs the Kit's catalog check on `items`.

import LungfishKit

/// The explanations of the single-cell view that are true of every single-cell result.
public enum RNASeqSingleCellHelp {
    /// Beside the rank plot's heading, since a reader who knows Cell Ranger's rank plot expects the empty-droplet tail.
    public static let rankPlot = LungfishHelpContent.HelpItem(
        id: "rnaseq.singleCell.rankPlot",
        summary: RNASeqSingleCellWords.rankPlotSummary,
        detail: RNASeqSingleCellWords.rankPlot,
        audience: .benchScientist)

    /// After the line that names Import Embedding….
    public static let cellMap = LungfishHelpContent.HelpItem(
        id: "rnaseq.singleCell.cellMapRoutes",
        summary: RNASeqSingleCellWords.cellMapSummary,
        detail: RNASeqSingleCellWords.cellMapRoutes,
        audience: .benchScientist)

    public static let items = [rankPlot, cellMap]
}
