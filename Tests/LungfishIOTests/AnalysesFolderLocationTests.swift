// AnalysesFolderLocationTests.swift - Which folders a project's Analyses/ folder holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane A17, risk R11. The sidebar scan leaves a folder with analysis-metadata.json out of its
// generic listing because a dedicated row represents it, and a dedicated row exists only inside the
// project's Analyses folder. `isInsideAnalysesFolder` is the question the scan asks.

import XCTest
@testable import LungfishIO

final class AnalysesFolderLocationTests: XCTestCase {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    func testChildrenOfAnalysesAtAnyDepthAreInside() {
        XCTAssertTrue(AnalysesFolder.isInsideAnalysesFolder(url("/Users/me/Study.lungfish/Analyses/kraken2-2026-02-09T09-00-00")))
        XCTAssertTrue(AnalysesFolder.isInsideAnalysesFolder(url("/Users/me/Study.lungfish/Analyses/My Group/Sub/esviritu-batch-2026-02-09T09-00-00")))
        XCTAssertTrue(AnalysesFolder.isInsideAnalysesFolder(url("/tmp/plain-project/Analyses/Result")),
                      "a project folder without the .lungfish extension still has its Analyses folder")
    }

    func testFoldersElsewhereInTheProjectAreOutside() {
        XCTAssertFalse(AnalysesFolder.isInsideAnalysesFolder(url("/Users/me/Study.lungfish/Imports/Kraken2 result copy")))
        XCTAssertFalse(AnalysesFolder.isInsideAnalysesFolder(url("/Users/me/Study.lungfish/Results/Sub/Kraken2 result copy")))
        XCTAssertFalse(AnalysesFolder.isInsideAnalysesFolder(url("/Users/me/Study.lungfish/Analyses")),
                       "the Analyses folder itself is not inside itself")
        XCTAssertFalse(AnalysesFolder.isInsideAnalysesFolder(url("/Users/me/Study.lungfish")))
        XCTAssertFalse(AnalysesFolder.isInsideAnalysesFolder(url("/tmp/plain-project/Imports/Result")))
        XCTAssertFalse(AnalysesFolder.isInsideAnalysesFolder(url("/")))
    }

    func testAProjectInsideAFolderCalledAnalysesKeepsItsOwnFoldersOutside() {
        XCTAssertFalse(AnalysesFolder.isInsideAnalysesFolder(url("/Users/me/Analyses/Study.lungfish/Imports/Result")))
        XCTAssertTrue(AnalysesFolder.isInsideAnalysesFolder(url("/Users/me/Analyses/Study.lungfish/Analyses/Result")))
    }
}
