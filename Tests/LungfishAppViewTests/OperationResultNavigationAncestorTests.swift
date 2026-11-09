// OperationResultNavigationAncestorTests.swift - The Results button selects the nearest listed ancestor
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

/// OPS-RESULTS-BLAST-ANCESTOR (Walk 34). A BLAST search started from a Kraken 2 result is saved inside that
/// result, where the sidebar lists no row for the search folder. The Results button then selects the nearest
/// folder the sidebar does list, so a click never ends in "Unable to show results" while the files are there.
/// The tests use a closure in place of the sidebar, as the backlog row asks.
@MainActor
final class OperationResultNavigationAncestorTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/Work/Study.lungfish", isDirectory: true)

    private var search: URL {
        project.appendingPathComponent("Analyses/kraken2-run/blast-verifications/search-1", isDirectory: true)
    }

    func testSelectionCandidatesWalkFromTheResultUpToTheProjectFolder() {
        let candidates = OperationResultNavigation.selectionCandidates(from: search, upTo: project)
        XCTAssertEqual(
            candidates.map(\.path),
            [
                "/Work/Study.lungfish/Analyses/kraken2-run/blast-verifications/search-1",
                "/Work/Study.lungfish/Analyses/kraken2-run/blast-verifications",
                "/Work/Study.lungfish/Analyses/kraken2-run",
                "/Work/Study.lungfish/Analyses",
            ],
            "the result first, then each parent below the project, and never the project folder itself"
        )

        XCTAssertEqual(
            OperationResultNavigation.selectionCandidates(from: search, upTo: nil).map(\.path),
            [search.path],
            "a route with no project has no bound to climb to, so only the result itself is asked for"
        )
        let elsewhere = URL(fileURLWithPath: "/Work/Other.lungfish/Analyses/run", isDirectory: true)
        XCTAssertEqual(
            OperationResultNavigation.selectionCandidates(from: elsewhere, upTo: project).map(\.path),
            [elsewhere.path],
            "a result outside the project never climbs into other folders"
        )
    }

    func testTheNearestListedAncestorIsSelected() {
        let listed: Set<String> = [
            "/Work/Study.lungfish/Analyses/kraken2-run",
            "/Work/Study.lungfish/Analyses",
        ]
        var asked: [String] = []
        let selected = OperationResultNavigation.selectNearestListedCandidate(from: search, upTo: project) { url in
            asked.append(url.path)
            return listed.contains(url.path)
        }

        XCTAssertTrue(selected, "the Kraken 2 result that holds the search is listed, so the button selects it")
        XCTAssertEqual(
            asked,
            [
                "/Work/Study.lungfish/Analyses/kraken2-run/blast-verifications/search-1",
                "/Work/Study.lungfish/Analyses/kraken2-run/blast-verifications",
                "/Work/Study.lungfish/Analyses/kraken2-run",
            ],
            "it asks nearest first and stops at the first listed row, so the farther Analyses folder is never selected"
        )

        let none = OperationResultNavigation.selectNearestListedCandidate(from: search, upTo: project) { _ in false }
        XCTAssertFalse(none, "with no listed folder the button reports that it found nothing to show")
    }
}
