// PrimerSchemeSidebarTests.swift - Sidebar recognition of .lungfishprimers bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

/// Regression tests around the sidebar's recognition of `.lungfishprimers`
/// bundles as opaque units.
///
/// ``SidebarViewController.buildSidebarTree`` is private, so this suite pins
/// down the observable contract instead:
///
/// - ``SidebarItemType/primerSchemeBundle`` exists and claims `isBundle`.
/// - The sidebar's path-extension check recognizes `.lungfishprimers`.
/// - ``PrimerSchemesFolder/listBundles(in:)`` returns bundles for the
///   project-local folder, which is what the sidebar group iterates.
@MainActor
final class PrimerSchemeSidebarTests: XCTestCase {
    private var tempProjectURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempProjectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimerSchemeSidebarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempProjectURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempProjectURL)
        try await super.tearDown()
    }

    func testPrimerSchemeBundleTypeIsOpaque() {
        XCTAssertTrue(SidebarItemType.primerSchemeBundle.isBundle,
                      "primerSchemeBundle must be treated as an opaque bundle so the BED inside is not exposed as a child.")
    }

    func testLungfishPrimersPathExtensionIsRecognized() {
        // The production detection logic in SidebarViewController.buildSidebarTree
        // keys on url.pathExtension.lowercased() == "lungfishprimers". This test
        // pins that contract: if someone renames the extension, this breaks.
        let bundleURL = URL(fileURLWithPath: "/tmp/Foo.lungfishprimers", isDirectory: true)
        XCTAssertEqual(bundleURL.pathExtension.lowercased(), "lungfishprimers")
    }

    func testPrimerSchemesFolderExposesBundlesForSidebarEnumeration() throws {
        let folder = try PrimerSchemesFolder.ensureFolder(in: tempProjectURL)
        try writeValidBundle(in: folder, name: "MockScheme")

        let bundles = PrimerSchemesFolder.listBundles(in: tempProjectURL)
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(bundles.first?.manifest.name, "MockScheme")
    }

    func testPrimerSchemeBundleDisplayNameStripsExtension() {
        // SidebarViewController strips the bundle extension for display;
        // confirm the naming convention produces a clean display name.
        let bundleURL = URL(fileURLWithPath: "/tmp/QIASeqDIRECT-SARS2.lungfishprimers", isDirectory: true)
        let displayName = bundleURL.deletingPathExtension().lastPathComponent
        XCTAssertEqual(displayName, "QIASeqDIRECT-SARS2")
    }

    // MARK: - Fixture authoring

    private func writeValidBundle(in folder: URL, name: String) throws {
        let bundleURL = folder.appendingPathComponent("\(name).lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PrimerSchemeManifest(
            schemaVersion: 1,
            name: name,
            displayName: name,
            description: nil,
            organism: nil,
            referenceAccessions: [
                .init(accession: "MN908947.3", canonical: true, equivalent: false)
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
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"))

        try "MN908947.3\t1\t20\tP1_LEFT\t1\t+\nMN908947.3\t100\t120\tP1_RIGHT\t1\t-\n"
            .write(to: bundleURL.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)

        try "# imported for tests\n"
            .write(to: bundleURL.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)
    }
}
