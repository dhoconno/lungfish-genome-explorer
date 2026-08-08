// SidebarReassembleProvenanceTests.swift - Reassemble… with corrupt assembly provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task E4 (2026-08-08 repo review fix campaign, finding AS19): the
// "Reassemble…" sidebar context-menu item is enabled purely on the
// presence of assembly/provenance.json (bundleHasAssemblyProvenance only
// checks file existence, not validity). If AssemblyProvenance.load(from:)
// throws (corrupt/partial JSON), contextMenuReassemble() used to log an
// error and return with zero user-facing alert -- clicking a visibly
// enabled menu item produced no effect at all. These tests pin down that
// the menu item stays visible/enabled for a corrupt provenance file (so
// the finding's premise holds) and that firing the action does not crash.

import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class SidebarReassembleProvenanceTests: XCTestCase {

    func testReassembleMenuItemIsEnabledForCorruptProvenanceFile() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarReassemble-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Sample.lungfishref", isDirectory: true)

        try Self.writeReferenceBundleWithCorruptProvenance(at: bundleURL)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }
        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        let items = sidebar.testContextMenuItems(for: sidebar.selectedItems())
        let reassembleItem = try XCTUnwrap(items.first { $0.title == "Reassemble\u{2026}" })
        XCTAssertTrue(reassembleItem.isEnabled, "Reassemble… must stay enabled since bundleHasAssemblyProvenance only checks file existence, not validity — this is the finding's premise.")

        // Firing the action with corrupt provenance must not crash and
        // must not throw; the fix's guard should return early with a
        // beep + alert instead of silently no-oping.
        if let action = reassembleItem.action {
            NSApp.sendAction(action, to: reassembleItem.target, from: reassembleItem)
        }
    }

    static func writeReferenceBundleWithCorruptProvenance(at bundleURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifestJSON = """
        {
          "formatVersion": 1,
          "name": "Sample",
          "identifier": "\(UUID().uuidString)",
          "createdDate": "2026-01-01T00:00:00Z",
          "modifiedDate": "2026-01-01T00:00:00Z",
          "annotations": [],
          "variants": [],
          "tracks": []
        }
        """
        try Data(manifestJSON.utf8).write(to: bundleURL.appendingPathComponent("manifest.json"))

        let assemblyDir = bundleURL.appendingPathComponent("assembly")
        try fm.createDirectory(at: assemblyDir, withIntermediateDirectories: true)
        // Deliberately malformed JSON: AssemblyProvenance.load(from:) must throw.
        try Data("{ not valid json".utf8).write(to: assemblyDir.appendingPathComponent("provenance.json"))
    }
}
