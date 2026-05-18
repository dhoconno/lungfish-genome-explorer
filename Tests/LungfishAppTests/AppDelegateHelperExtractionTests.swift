// AppDelegateHelperExtractionTests.swift - source guards for AppDelegate helper extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

final class AppDelegateHelperExtractionTests: XCTestCase {
    func testStandaloneHelpersDoNotLiveInAppDelegateSource() throws {
        let root = repositoryRoot()
        let appDelegate = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(appDelegate.contains("class GenBankParser"))
        XCTAssertFalse(appDelegate.contains("class ExportFilenameUpdater"))
        XCTAssertFalse(appDelegate.contains("enum NvdImportError"))
        XCTAssertFalse(appDelegate.contains("enum SequenceExportFormat"))
        XCTAssertFalse(appDelegate.contains("enum SequenceExportCompression"))
        XCTAssertFalse(appDelegate.contains("NSOpenPanel("))
        XCTAssertFalse(appDelegate.contains("NSSavePanel("))

        let expectedHelperFiles = [
            "Sources/LungfishApp/App/GenBankSynchronousParser.swift",
            "Sources/LungfishApp/App/ExportFilenameUpdater.swift",
            "Sources/LungfishApp/App/AppFilePanelFactory.swift",
            "Sources/LungfishApp/App/ViewerGraphicsExportPanelController.swift",
            "Sources/LungfishApp/App/ViewerGraphicsExportOptions.swift",
            "Sources/LungfishApp/App/ProjectSampleMetadataModalRouter.swift",
            "Sources/LungfishApp/App/SequenceExportOptions.swift",
            "Sources/LungfishApp/App/SequenceExportPanelController.swift",
            "Sources/LungfishApp/Views/Metagenomics/NVDImportErrors.swift",
        ]
        for helperFile in expectedHelperFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(helperFile).path),
                "Missing extracted helper file: \(helperFile)"
            )
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
