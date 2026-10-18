// MappingWorkflowFilePanelFactoryTests.swift - mapping and workflow panel coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import LungfishApp

@MainActor
final class MappingWorkflowFilePanelFactoryTests: XCTestCase {
    func testReferenceFASTAPanelUsesReadableFASTATypes() throws {
        let panel = MappingWorkflowFilePanelFactory.referenceFASTAPanel(
            title: "Select Reference FASTA",
            message: "Select a reference FASTA file"
        )

        XCTAssertEqual(panel.title, "Select Reference FASTA")
        XCTAssertEqual(panel.message, "Select a reference FASTA file")
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        let contentTypes = try XCTUnwrap(panel.allowedContentTypes)
        XCTAssertFalse(contentTypes.isEmpty)
        for expectedType in [UTType(filenameExtension: "fa"), UTType(filenameExtension: "fasta"), .gzip] {
            XCTAssertTrue(contentTypes.contains(try XCTUnwrap(expectedType)))
        }
    }

    func testGFFAnnotationPanelAcceptsItemsOnly() {
        let panel = MappingWorkflowFilePanelFactory.gffAnnotationPanel(title: "Select SARS-CoV-2 GFF Annotation")

        XCTAssertEqual(panel.title, "Select SARS-CoV-2 GFF Annotation")
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.allowedContentTypes, [.item])
    }

    func testWorkflowOpenPanelAcceptsWorkflowBundleDirectories() {
        let panel = MappingWorkflowFilePanelFactory.workflowOpenPanel(
            contentTypes: [.folder]
        )

        XCTAssertEqual(panel.allowedContentTypes, [.folder])
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertEqual(panel.message, "Select a Lungfish workflow bundle")
    }
}
