// InspectorProjectSwitchResetTests.swift - Inspector resets when a window changes project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishIO

/// Opening a different project into an existing window must not leave the
/// previous project's selection in the Inspector (2026.9.40: a FASTQ's
/// statistics and a genotype Run Summary survived a project switch).
@MainActor
final class InspectorProjectSwitchResetTests: XCTestCase {
    private func makeProject(named name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: url, name: name)
        return url
    }

    private func writeScheme(in projectURL: URL) throws -> URL {
        let folder = try PrimerSchemesFolder.ensureFolder(in: projectURL)
        let bundleURL = folder.appendingPathComponent("Scheme.lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifest = PrimerSchemeManifest(
            schemaVersion: 1, name: "Scheme", displayName: "Scheme", description: nil, organism: nil,
            referenceAccessions: [.init(accession: "MN908947.3", canonical: true, equivalent: false)],
            primerCount: 2, ampliconCount: 1, source: "imported", sourceURL: nil, version: nil,
            created: Date(), imported: Date(), attachments: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent("manifest.json"))
        try "MN908947.3\t1\t20\tP1_LEFT\t1\t+\n"
            .write(to: bundleURL.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)
        try "# imported for tests\n"
            .write(to: bundleURL.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)
        return bundleURL
    }

    func testOpeningAnotherProjectInTheSameWindowResetsTheInspector() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InspectorProjectSwitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let demo = try makeProject(named: "Demo", in: root)
        let williams = try makeProject(named: "Williams", in: root)
        let schemeURL = try writeScheme(in: demo)

        let session = ProjectSession()
        try session.openProject(at: demo)
        let split = MainSplitViewController(projectSession: session)
        _ = split.view
        split.applyProjectSessionState()

        // Leave Demo-owned state in the Inspector: a document-tab selection and
        // a genotype View-tab summary.
        split.displayContent(for: SidebarItem(title: "Scheme", type: .primerSchemeBundle, url: schemeURL))
        let inspector = split.inspectorController.viewModel
        XCTAssertTrue(inspector.documentSectionViewModel.hasAnyContent)
        inspector.genotypeResultDisplaySectionViewModel.update(isAvailable: true)
        inspector.genotypeResultDisplaySectionViewModel.updateSummary(visibleRows: 7, totalRows: 9, hiddenCells: 2)
        inspector.selectedItem = "SRR36291587"

        try session.openProject(at: williams)
        split.applyProjectSessionState()

        XCTAssertFalse(
            inspector.documentSectionViewModel.hasAnyContent,
            "The Inspector must show No Bundle Loaded after the project changes"
        )
        XCTAssertNil(inspector.documentSectionViewModel.primerSchemeDocument)
        XCTAssertFalse(inspector.genotypeResultDisplaySectionViewModel.isAvailable)
        XCTAssertEqual(inspector.genotypeResultDisplaySectionViewModel.totalRowCount, 0)
        XCTAssertNil(inspector.selectedItem)
    }
}
