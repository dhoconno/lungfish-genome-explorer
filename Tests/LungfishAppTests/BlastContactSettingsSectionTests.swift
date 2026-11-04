// BlastContactSettingsSectionTests.swift - The contact address row of the General settings tab
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import ViewInspector
import XCTest
@testable import LungfishApp

/// Phase 3.2 lane BLASTNET, milestone N5 (UX-BLAST-WORDS Q6). The inspector runs neither `task` nor `onChange`, so
/// this test reads and writes no address.
@MainActor
final class BlastContactSettingsSectionTests: XCTestCase {
    func testTheGeneralTabHoldsTheContactRowWithItsWords() throws {
        let tab = try GeneralSettingsTab().inspect()
        let field = try tab.find(viewWithAccessibilityIdentifier: SettingsAccessibilityID.blastContactEmailField)
        XCTAssertEqual(try field.textField().labelView().text().string(), BlastContactAddress.Words.label)
        XCTAssertNoThrow(try tab.find(text: BlastContactAddress.Words.caption))
        XCTAssertNoThrow(try tab.find(text: BlastContactAddress.Words.state(.empty)), "an empty row says what NCBI gets")
    }

    /// UX review SF2. The model holds what the view's `task` and `onChange` do, so the load, the chained saves and the
    /// words of a failed save run here.
    func testTypingKeepsTheLastAddressAndAFailureShowsItsWords() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-contact-model-\(UUID().uuidString)", isDirectory: true)
        let locked = folder.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: folder)
        }

        let store = BlastContactAddressStore(file: folder.appendingPathComponent("good/\(BlastContactAddress.fileName)"))
        let model = BlastContactSettingsModel(store: store)
        await model.load()
        model.textChanged("a@example.org")
        model.textChanged("b@example.org")
        await model.settle()
        let kept = await store.savedText()
        XCTAssertEqual(kept, "b@example.org", "the last thing typed is what stays")
        XCTAssertNil(model.saveFailure)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let lockedStore = BlastContactAddressStore(file: locked.appendingPathComponent(BlastContactAddress.fileName))
        let blocked = BlastContactSettingsModel(store: lockedStore)
        await blocked.load()
        blocked.textChanged("c@example.org")
        await blocked.settle()
        XCTAssertEqual(blocked.saveFailure?.hasPrefix("LGE could not keep this address:"), true, blocked.saveFailure ?? "no words")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        blocked.textChanged("d@example.org")
        await blocked.settle()
        XCTAssertNil(blocked.saveFailure, "a later save that works clears the words")
        let again = await lockedStore.savedText()
        XCTAssertEqual(again, "d@example.org")
    }
}
