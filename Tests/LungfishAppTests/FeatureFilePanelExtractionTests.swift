// FeatureFilePanelExtractionTests.swift - source guards for feature panel helper extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

final class FeatureFilePanelExtractionTests: XCTestCase {
    func testTargetFeatureFilesDoNotConstructPanelsInline() throws {
        let root = repositoryRoot()
        let targetFiles = [
            "Sources/LungfishApp/Views/Inspector/InspectorViewController.swift",
            "Sources/LungfishApp/Views/Inspector/Sections/AttachmentsSection.swift",
            "Sources/LungfishApp/Views/Inspector/Sections/FASTQMetadataSection.swift",
            "Sources/LungfishApp/Views/Sidebar/FolderMetadataEditorSheet.swift",
            "Sources/LungfishApp/Views/Sidebar/ProjectMetadataExportImport.swift",
            "Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift",
            "Sources/LungfishApp/Views/Metagenomics/NvdImportSheet.swift",
            "Sources/LungfishApp/Views/Metagenomics/CzIdImportSheet.swift",
            "Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift",
            "Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift",
            "Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift",
            "Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift",
            "Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift",
            "Sources/LungfishApp/Views/Metagenomics/BlastResultsDrawerTab.swift",
            "Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction.swift",
        ]

        for targetFile in targetFiles {
            let source = try String(contentsOf: root.appendingPathComponent(targetFile), encoding: .utf8)
            XCTAssertFalse(source.contains("NSOpenPanel("), "\(targetFile) should use a panel helper")
            XCTAssertFalse(source.contains("NSSavePanel("), "\(targetFile) should use a panel helper")
        }
    }

    func testFeaturePanelHelperFilesExist() {
        let root = repositoryRoot()
        let helperFiles = [
            "Sources/LungfishApp/Views/Shared/FeatureFilePanelFactory.swift",
            "Sources/LungfishApp/Views/Metagenomics/MetagenomicsFilePanelFactory.swift",
        ]

        for helperFile in helperFiles {
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
