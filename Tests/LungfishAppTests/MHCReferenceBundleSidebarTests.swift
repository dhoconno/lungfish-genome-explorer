// MHCReferenceBundleSidebarTests.swift - Sidebar recognition of .lungfishmhcref bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

/// Regression tests around the sidebar's recognition of `.lungfishmhcref`
/// MHC amplicon reference bundles as opaque, non-expandable units.
///
/// Mirrors `PrimerSchemeSidebarTests` (contract pins) and
/// `SidebarViewControllerSelectionTests` (a real tree built from a temp
/// project directory).
@MainActor
final class MHCReferenceBundleSidebarTests: XCTestCase {

    // MARK: - Contract pins (mirrors PrimerSchemeSidebarTests)

    func testMHCReferenceBundleTypeIsOpaque() {
        XCTAssertTrue(
            SidebarItemType.mhcReferenceBundle.isBundle,
            "mhcReferenceBundle must be treated as an opaque bundle so its reference.fa / haplotypes are not exposed as children."
        )
    }

    func testLungfishMHCRefExtensionIsRecognized() {
        // The production detection logic in SidebarViewController keys on
        // url.pathExtension.lowercased() == MHCAmpliconReferenceBundle.directoryExtension.
        // This pins that contract: renaming the extension breaks this.
        let bundleURL = URL(fileURLWithPath: "/tmp/MCM.lungfishmhcref", isDirectory: true)
        XCTAssertEqual(bundleURL.pathExtension.lowercased(), MHCAmpliconReferenceBundle.directoryExtension)
    }

    func testMHCReferenceBundleDisplayNameStripsExtension() {
        // SidebarViewController strips the bundle extension for display.
        let bundleURL = URL(fileURLWithPath: "/tmp/MCM-MHC.lungfishmhcref", isDirectory: true)
        let displayName = bundleURL.deletingPathExtension().lastPathComponent
        XCTAssertEqual(displayName, "MCM-MHC")
    }

    // MARK: - Real tree (mirrors SidebarViewControllerSelectionTests)

    func testMHCReferenceBundleAppearsAsOpaqueBundleNotExpandableFolder() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarMHCReferenceBundle-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)

        try Self.writeMHCReferenceBundle(at: bundleURL, name: "MCM")

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        let item = try XCTUnwrap(sidebar.selectedItems().first)
        XCTAssertEqual(item.type, .mhcReferenceBundle)
        XCTAssertTrue(item.type.isBundle)
        XCTAssertEqual(item.title, "MCM")
        XCTAssertEqual(item.url?.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertTrue(
            item.children.isEmpty,
            "An MHC reference bundle must not expose its internal files (reference.fa / haplotypes/) as children."
        )
    }

    // MARK: - Inspector document population

    func testUpdateMHCReferenceBundleDocumentPopulatesStateFromManifest() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCReferenceInspector-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try Self.writeMHCReferenceBundle(
            at: bundleURL,
            name: "MCM",
            warnings: [
                MHCReferenceBundleWarning(
                    category: "genbank.annotation.skipped",
                    message: "Skipped malformed CDS",
                    recordIdentifier: "M1",
                    featureType: "CDS"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        inspector.updateMHCReferenceBundleDocument(bundleURL)

        let state = try XCTUnwrap(
            inspector.viewModel.documentSectionViewModel.mhcReferenceBundleDocument
        )
        XCTAssertEqual(state.name, "MCM MHC")
        XCTAssertEqual(state.kind, "mhc-reference")
        XCTAssertEqual(state.referenceCount, 1)
        XCTAssertEqual(state.haplotypeDefinitionCount, 1)
        XCTAssertEqual(state.defaultDefinitionID, "mcm-mhc")
        XCTAssertEqual(state.bundleURL?.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(state.warningRows.map(\.message), ["Skipped malformed CDS"])
        XCTAssertTrue(
            state.definitionRows.contains { $0.displayName.contains("MCM MHC") && $0.loci.contains("MHC-B") },
            "Embedded haplotype definition should surface its species name and loci."
        )

        // Selecting the metadata-only bundle should make the Bundle tab the active inspector tab
        // and mark content present.
        XCTAssertEqual(inspector.viewModel.selectedTab, .bundle)
        XCTAssertTrue(inspector.viewModel.documentSectionViewModel.hasAnyContent)
        XCTAssertEqual(
            inspector.viewModel.provenanceSectionViewModel.currentItem?.sidebarType,
            .mhcReferenceBundle
        )
    }

    // MARK: - Fixture authoring

    /// Writes a minimal valid `.lungfishmhcref` directory bundle (manifest +
    /// reference.fa + one haplotype definition), mirroring
    /// `MHCAmpliconReferenceBundleTests`.
    static func writeMHCReferenceBundle(
        at bundleURL: URL,
        name: String,
        warnings: [MHCReferenceBundleWarning] = []
    ) throws {
        let haplotypeURL = bundleURL.appendingPathComponent("haplotypes/\(name.lowercased()).json")
        try FileManager.default.createDirectory(
            at: haplotypeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ">M1\nACGT\n".write(
            to: bundleURL.appendingPathComponent("reference.fa"),
            atomically: true,
            encoding: .utf8
        )

        let definition = GenotypeHaplotypeDefinitionSet(
            id: "\(name.lowercased())-mhc",
            assayID: "MHC-exon2-miSeq",
            displayName: "\(name) MHC",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: name,
            prefix: "MHC",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "MHC-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1", diagnosticAlleles: ["M1"])
                    ]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: haplotypeURL)

        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "\(name) MHC",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: ["haplotypes/\(name.lowercased()).json"],
            defaultHaplotypeDefinitionID: definition.id,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 1),
            provenancePath: ".lungfish-provenance.json",
            warnings: warnings,
            createdAt: "2026-05-30T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)
    }
}
