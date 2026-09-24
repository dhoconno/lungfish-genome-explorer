// PrimerSchemeSelectionRoutingTests.swift - Selecting a .lungfishprimers bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishIO

/// Selecting a primer scheme in the sidebar shows its manifest in the
/// Inspector. It must never be handed to the genomics-file loader, which
/// rejects `.lungfishprimers` as "Unsupported file format" (2026.9.40).
@MainActor
final class PrimerSchemeSelectionRoutingTests: XCTestCase {
    private func makeSchemeBundle(name: String = "QIASeqDIRECT-SARS2") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimerSchemeSelection-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("\(name).lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let manifest = PrimerSchemeManifest(
            schemaVersion: 1,
            name: name,
            displayName: "QIAseq DIRECT SARS-CoV-2",
            description: "Test scheme",
            organism: "SARS-CoV-2",
            referenceAccessions: [
                .init(accession: "MN908947.3", canonical: true, equivalent: false),
                .init(accession: "NC_045512.2", canonical: false, equivalent: true),
            ],
            primerCount: 2,
            ampliconCount: 1,
            source: "imported",
            sourceURL: nil,
            version: nil,
            created: Date(),
            imported: Date(),
            attachments: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent("manifest.json"))
        try "MN908947.3\t1\t20\tP1_LEFT\t1\t+\nMN908947.3\t100\t120\tP1_RIGHT\t1\t-\n"
            .write(to: bundleURL.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)
        try "# imported for tests\n"
            .write(to: bundleURL.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)
        return bundleURL
    }

    func testSelectingPrimerSchemeShowsItInTheInspectorInsteadOfOpeningIt() throws {
        let bundleURL = try makeSchemeBundle()
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.externalDocumentLoader = { url in
            XCTFail("Primer scheme must not be opened as a document: \(url.lastPathComponent)")
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        split.displayContent(for: SidebarItem(
            title: "QIASeqDIRECT-SARS2", type: .primerSchemeBundle, url: bundleURL
        ))

        let document = split.inspectorController.viewModel.documentSectionViewModel
        let scheme = try XCTUnwrap(document.primerSchemeDocument, "The Inspector must present the primer scheme")
        XCTAssertEqual(scheme.manifest.name, "QIASeqDIRECT-SARS2")
        XCTAssertEqual(scheme.manifest.primerCount, 2)
        XCTAssertEqual(scheme.manifest.canonicalAccession, "MN908947.3")
        XCTAssertEqual(scheme.manifest.equivalentAccessions, ["NC_045512.2"])
        XCTAssertTrue(document.hasAnyContent)
        XCTAssertEqual(split.viewerController.contentMode, .empty)
        XCTAssertNil(
            split.externalDocumentLoadTask,
            "A primer scheme is not a document; the document loader raises 'Unsupported file format'"
        )
    }

    func testSelectingAnotherItemClearsThePrimerScheme() throws {
        let bundleURL = try makeSchemeBundle()
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.externalDocumentLoader = { url in
            XCTFail("Primer scheme must not be opened as a document: \(url.lastPathComponent)")
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        split.displayContent(for: SidebarItem(
            title: "QIASeqDIRECT-SARS2", type: .primerSchemeBundle, url: bundleURL
        ))
        XCTAssertNotNil(split.inspectorController.viewModel.documentSectionViewModel.primerSchemeDocument)

        split.inspectorController.clearSelection()

        XCTAssertNil(split.inspectorController.viewModel.documentSectionViewModel.primerSchemeDocument)
        XCTAssertFalse(split.inspectorController.viewModel.documentSectionViewModel.hasAnyContent)
    }

    func testUnreadablePrimerSchemeClearsTheViewportWithoutAnAlertPath() throws {
        let bundleURL = try makeSchemeBundle()
        try FileManager.default.removeItem(at: bundleURL.appendingPathComponent("manifest.json"))
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.externalDocumentLoader = { url in
            XCTFail("Primer scheme must not be opened as a document: \(url.lastPathComponent)")
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        split.displayContent(for: SidebarItem(
            title: "QIASeqDIRECT-SARS2", type: .primerSchemeBundle, url: bundleURL
        ))

        XCTAssertNil(split.inspectorController.viewModel.documentSectionViewModel.primerSchemeDocument)
        XCTAssertEqual(split.viewerController.contentMode, .empty)
        XCTAssertNil(split.externalDocumentLoadTask)
    }
}
