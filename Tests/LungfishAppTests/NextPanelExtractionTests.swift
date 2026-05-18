// NextPanelExtractionTests.swift - source guards for remaining panel helper extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

final class NextPanelExtractionTests: XCTestCase {
    func testNextSliceTargetFilesDoNotConstructPanelsInline() throws {
        let root = repositoryRoot()
        let targetFiles = [
            "Sources/LungfishApp/Services/ImportService.swift",
            "Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift",
            "Sources/LungfishApp/Views/ImportCenter/PrimerSchemeImportView.swift",
            "Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift",
            "Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift",
            "Sources/LungfishApp/Views/Shared/ReferenceSequencePickerView.swift",
            "Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift",
            "Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Bookmarks.swift",
            "Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Export.swift",
            "Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift",
            "Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift",
            "Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift",
            "Sources/LungfishApp/Views/Viewer/PhylogeneticTreeViewController.swift",
            "Sources/LungfishApp/Views/Viewer/SequenceViewerView+Drawing.swift",
        ]

        for targetFile in targetFiles {
            let source = try String(contentsOf: root.appendingPathComponent(targetFile), encoding: .utf8)
            XCTAssertFalse(source.contains("NSOpenPanel("), "\(targetFile) should use a panel helper")
            XCTAssertFalse(source.contains("NSSavePanel("), "\(targetFile) should use a panel helper")
        }
    }

    func testNextSliceHelperFilesExist() {
        let root = repositoryRoot()
        let helperFiles = [
            "Sources/LungfishApp/Views/ImportCenter/ImportFilePanelFactory.swift",
            "Sources/LungfishApp/Views/Mapping/MappingWorkflowFilePanelFactory.swift",
            "Sources/LungfishApp/Views/Viewer/ViewerFilePanelFactory.swift",
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
