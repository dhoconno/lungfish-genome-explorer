// DatabaseBrowserFilePanelFactoryTests.swift - Database Browser file panel configuration coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import LungfishApp

@MainActor
final class DatabaseBrowserFilePanelFactoryTests: XCTestCase {
    func testAccessionListImportPanelAcceptsSingleDelimitedTextFile() throws {
        let panel = DatabaseBrowserFilePanelFactory.accessionListImportPanel()

        XCTAssertEqual(panel.title, "Import Accession List")
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(panel.canChooseFiles)

        let contentTypes = try XCTUnwrap(panel.allowedContentTypes)
        XCTAssertTrue(contentTypes.contains(.commaSeparatedText))
        XCTAssertTrue(contentTypes.contains(.plainText))
    }
}
