// ImportCenterLinuxCardTests.swift - The words of the Import Center's two Linux cards (CHTC C5 lane US, O41)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

/// Owner O41: the tool is generic, so neither card names a site, and HTCondor is one launcher beside the plain one. The
/// result card takes a returned plan folder or a returned batch folder, and its hint quotes the README's copy step.
@MainActor
final class ImportCenterLinuxCardTests: XCTestCase {
    private static let siteWords = ["CHTC", "chtc", "wisc", "/staging/groups", "cluster", "sample.sub", "run.dag"]

    private func card(_ id: String) throws -> ImportCardInfo {
        try XCTUnwrap(ImportCenterViewModel.linuxRunCards.first { $0.id == id }, id)
    }

    /// The card half of `testHelpAndCardsNameNoSite`; lane CMD owns the help half.
    func testHelpAndCardsNameNoSite() throws {
        let plan = try card("fastq-linux-plan")
        let result = try card("linux-run-result")
        XCTAssertEqual(
            plan.description,
            "Write the files that reorder, compress and count FASTQ reads on a Linux machine, run with HTCondor or with "
                + "the plain launcher. Nothing is imported."
        )
        XCTAssertEqual(
            result.description,
            "Import a plan folder that a run on a Linux machine returned, as one FASTQ bundle a sample with the run's record."
        )
        let model = ImportCenterViewModel()
        for card in [plan, result] {
            let words = [card.title, card.description, card.fileHint ?? "", model.panelMessage(for: card.importAction)]
            for word in Self.siteWords {
                XCTAssertFalse(words.contains { $0.contains(word) }, "\(card.id) names \(word): \(words)")
            }
        }
    }

    /// The result card takes one folder, a plan folder or a batch folder, and its hint quotes the README's copy step
    /// for a batch in one sentence.
    func testResultCardTakesABatchFolderAndQuotesTheCopyStep() throws {
        let result = try card("linux-run-result")
        XCTAssertEqual(
            result.fileHint,
            "a returned plan folder, or a returned batch folder: for every sample, copy the files inside result/ into "
                + "that sample's folder on the Mac, next to plan.json"
        )
        XCTAssertEqual(
            ImportCenterViewModel().panelMessage(for: .linuxRunResult),
            "Select a plan folder or a batch folder that a Linux run returned"
        )
    }
}
