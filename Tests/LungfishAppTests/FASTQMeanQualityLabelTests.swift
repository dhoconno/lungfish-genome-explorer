// FASTQMeanQualityLabelTests.swift - Every surface that shows the dataset Mean Q says which mean it is
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import ViewInspector
import LungfishIO
@testable import LungfishApp

/// The dataset Mean Q is the Phred value of the mean error probability of all bases, the figure seqkit reports as
/// `AvgQual` (BIO-MEANQ, owner row 36). A reader trained on FastQC takes "Mean Q" alone for the typical Phred score of a
/// base, so the Inspector row and the statistics card carry the one label that lives in `FASTQStatisticsDisplayRules`,
/// and the words say what the figure is. The stored key stays `meanQuality` and its value is not touched here.
@MainActor
final class FASTQMeanQualityLabelTests: XCTestCase {

    private static let scored = FASTQDatasetStatistics(
        readCount: 2, baseCount: 20,
        meanReadLength: 10, minReadLength: 10, maxReadLength: 10,
        medianReadLength: 10, n50ReadLength: 10,
        meanQuality: 5.01, q20Percentage: 50, q30Percentage: 50, gcContent: 0.5,
        readLengthHistogram: [10: 2], qualityScoreHistogram: [2: 10, 40: 10],
        perPositionQuality: []
    )

    func testMeanQualityLabelNamesErrorProbabilityMean() throws {
        let label = FASTQStatisticsDisplayRules.meanQualityLabel
        XCTAssertTrue(
            label.localizedCaseInsensitiveContains("error"),
            "the shared label is \"\(label)\" and does not say which mean it is"
        )

        // The help text says what is averaged, names seqkit's figure and points to Q20 and Q30.
        let help = FASTQStatisticsDisplayRules.meanQualityHelp
        XCTAssertTrue(help.contains("error probability"), "the help text must say what is averaged: \"\(help)\"")
        XCTAssertTrue(help.contains("AvgQual"), "the help text must name the figure seqkit reports: \"\(help)\"")
        XCTAssertTrue(help.contains("Q20") && help.contains("Q30"), "the help text must point to Q20 and Q30: \"\(help)\"")

        // The statistics card carries the shared label, and so do its spoken summary and its accessibility help.
        let bar = FASTQSummaryBar()
        bar.update(with: Self.scored)
        let cardLabels = bar.cards.map(\.label)
        XCTAssertTrue(cardLabels.contains(label), "the card labels are \(cardLabels)")
        XCTAssertFalse(cardLabels.contains("Mean Q"), "a card still says Mean Q alone")
        let spoken = (bar.accessibilityValue() as? String) ?? ""
        XCTAssertTrue(spoken.contains(label), "the spoken summary is \"\(spoken)\"")
        XCTAssertEqual(bar.accessibilityHelp(), help)

        // The Inspector row carries the shared label too.
        let viewModel = DocumentSectionViewModel()
        viewModel.updateFASTQStatistics(Self.scored)
        let section = try DocumentSection(viewModel: viewModel).inspect()
        XCTAssertNoThrow(try section.find(text: label), "the Inspector has no row named \"\(label)\"")
        XCTAssertThrowsError(try section.find(text: "Mean Q"), "the Inspector row still says Mean Q alone")
    }
}
