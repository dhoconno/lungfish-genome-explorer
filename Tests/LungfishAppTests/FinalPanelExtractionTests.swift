// FinalPanelExtractionTests.swift - source guards for final direct panel cleanup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

final class FinalPanelExtractionTests: XCTestCase {
    func testRemainingTargetFilesDoNotConstructPanelsInline() throws {
        let root = repositoryRoot()
        let targetFiles = [
            "Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift",
            "Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift",
        ]

        for targetFile in targetFiles {
            let source = try String(contentsOf: root.appendingPathComponent(targetFile), encoding: .utf8)
            XCTAssertFalse(source.contains("NSOpenPanel("), "\(targetFile) should use a panel helper")
            XCTAssertFalse(source.contains("NSSavePanel("), "\(targetFile) should use a panel helper")
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
