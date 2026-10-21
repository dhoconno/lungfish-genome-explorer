// TaxTriageOrganismLayoutKeyTests.swift - An opened copy keys the organism table by its own folder only
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.52 (PREFS-SUITES), M866 (TT-RELOCATED-CONFIG-KEY). A result folder that was copied or moved keeps
// the sidecar of its run, and the sidecar names the folder the run wrote to. The view used to key the organism table
// by that folder as well, and then by the opened one, so opening a copy saved a layout under a key for a path the user
// never had. This class opens a copy with `configureFromDatabase` directly, on a defaults suite, since the parity
// class's helper used to clear the keys and hide the write from every test that went through it.

import AppKit
import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishTaxTriageUI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class TaxTriageOrganismLayoutKeyTests: XCTestCase {
    func testAnOpenedCopyKeysTheOrganismTableByItsOwnFolderOnly() throws {
        let scratch = try TestTempDirectory.make(prefix: "taxtriage-copy-key")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let original = scratch.appendingPathComponent("original", isDirectory: true)
        let copyRoot = scratch.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true)
        try TaxTriageExportCLIGUIParityReplayTests.makeResult(original)
        let folderName = TaxTriageExportCLIGUIParityReplayTests.resultFolderName
        let copyFolder = copyRoot.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.copyItem(
            at: original.appendingPathComponent(folderName, isDirectory: true), to: copyFolder
        )

        let suite = makeTestDefaultsSuite(prefix: "TaxTriageOrganismLayoutKeyTests")
        let view = TaxTriageResultViewController()
        view.layoutDefaults = suite.defaults
        _ = view.view
        let database = try TaxTriageDatabase(
            at: copyFolder.appendingPathComponent(TaxTriageExportLoader.databaseFileName)
        )
        view.configureFromDatabase(database, resultURL: copyFolder)

        let organisms = view.testOrganismTableView.metadataColumns
        XCTAssertEqual(
            organisms.persistenceKey, "taxtriage.organisms:\(copyFolder.standardizedFileURL.path)",
            "the table is keyed by the folder that was opened"
        )
        // A controller saves its layout under the key it holds when that key goes, so this makes the suite show
        // the key the copy ended with.
        organisms.persistenceKey = nil
        view.testBatchFlatTableView.metadataColumns.persistenceKey = nil

        let stored = (suite.defaults.persistentDomain(forName: suite.name) ?? [:]).keys.sorted()
        XCTAssertTrue(
            stored.contains { $0.contains("taxtriage.organisms:") && $0.hasSuffix("/copy/\(folderName)") },
            "the layout is saved under the copy's folder, the suite holds \(stored)"
        )
        XCTAssertEqual(
            stored.filter { $0.contains("/original/\(folderName)") }, [],
            "no layout is saved under the folder the sidecar names, a folder the user never opened"
        )
    }
}
