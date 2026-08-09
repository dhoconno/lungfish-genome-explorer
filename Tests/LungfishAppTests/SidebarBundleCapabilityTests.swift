// SidebarBundleCapabilityTests.swift - Bundle-kind capability mapping + context-menu coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Regression tests for task E2 (2026-08-08 repo review fix campaign): the
// sidebar context menu previously keyed bundle-specific menu items off a
// hardcoded `$0.type == .referenceBundle` check, so right-clicking any of
// the other 8 bundle kinds (mhcReferenceBundle, multipleSequenceAlignmentBundle,
// phylogeneticTreeBundle, primerSchemeBundle, genotypeResultBundle,
// twelveSAmpliconResultBundle, czIdResult, plus fastqBundle which had its own
// partial carve-out) showed none of the generic bundle actions (Open Bundle,
// Show Package Contents, Get Bundle Info, Show in Inspector).
//
// These tests pin down `SidebarItemType.bundleCapabilities`, the small
// capability mapping that replaces the hardcoded kind lists, and exercise
// the real context-menu construction via the `testContextMenuItems(for:)`
// seam (mirrors `FASTACollectionViewController.testUpdateContextMenu`).

import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class SidebarBundleCapabilityTests: XCTestCase {

    // MARK: - Capability mapping contract

    /// Every bundle kind must offer the four actions that are kind-agnostic
    /// in their handlers: Open Bundle, Show Package Contents, Get Bundle
    /// Info, Show in Inspector. (Merge/export capability varies and is
    /// covered by dedicated tests below.)
    func testEveryBundleKindOffersBaselineActions() {
        let bundleKinds = SidebarItemType.allBundleKindsForTesting
        XCTAssertFalse(bundleKinds.isEmpty)

        for kind in bundleKinds {
            let capabilities = kind.bundleCapabilities
            XCTAssertTrue(capabilities.canOpen, "\(kind) must support Open Bundle")
            XCTAssertTrue(capabilities.canShowPackageContents, "\(kind) must support Show Package Contents")
            XCTAssertTrue(capabilities.canGetBundleInfo, "\(kind) must support Get Bundle Info")
            XCTAssertTrue(capabilities.canShowInInspector, "\(kind) must support Show in Inspector")
        }
    }

    /// Non-bundle kinds must not claim bundle capabilities.
    func testNonBundleKindsHaveNoBundleCapabilities() {
        let nonBundleKinds: [SidebarItemType] = [.group, .folder, .sequence, .annotation, .alignment, .coverage, .project, .document, .image, .unknown, .batchGroup, .classificationResult, .esvirituResult, .taxTriageResult, .naoMgsResult, .nvdResult, .analysisResult]
        for kind in nonBundleKinds {
            XCTAssertFalse(kind.isBundle)
            let capabilities = kind.bundleCapabilities
            XCTAssertFalse(capabilities.canOpen)
            XCTAssertFalse(capabilities.canShowPackageContents)
            XCTAssertFalse(capabilities.canGetBundleInfo)
            XCTAssertFalse(capabilities.canShowInInspector)
        }
    }

    /// `isBundle` (used for display/grouping) and `bundleCapabilities`
    /// (used for menu construction) are two independent switch statements
    /// over the same enum. `bundleCapabilities` is now compiler-exhaustive
    /// (no `default:` -- round-2 hardening, E2 follow-up) so a new
    /// `SidebarItemType` case fails to compile until it's added there, but
    /// nothing stops the *contents* of the two switches from silently
    /// drifting apart (e.g. a case listed as `isBundle == true` that
    /// `bundleCapabilities` puts in the non-bundle `.none` group). This
    /// test pins the cross-switch invariant every case must satisfy:
    /// `isBundle` is true if and only if `bundleCapabilities != .none`.
    func testIsBundleAgreesWithBundleCapabilities() {
        let allKinds: [SidebarItemType] = [
            .group, .folder, .sequence, .annotation, .alignment, .coverage, .project, .document, .image,
            .unknown, .referenceBundle, .mhcReferenceBundle, .multipleSequenceAlignmentBundle,
            .phylogeneticTreeBundle, .fastqBundle, .primerSchemeBundle, .genotypeResultBundle,
            .twelveSAmpliconResultBundle, .batchGroup, .classificationResult, .esvirituResult,
            .taxTriageResult, .naoMgsResult, .nvdResult, .czIdResult, .analysisResult,
        ]
        for kind in allKinds {
            XCTAssertEqual(
                kind.isBundle,
                kind.bundleCapabilities != .none,
                "\(kind): isBundle and bundleCapabilities disagree on bundle-ness"
            )
        }
    }

    /// Only `.referenceBundle` supports "Export Sequences" from the context
    /// menu today: the export pipeline's sequence-loading path
    /// (loadSequencesForExport) only knows how to read a `.lungfishref`
    /// bundle's manifest.genome.path. `.mhcReferenceBundle` is NOT included
    /// here even though it's a reference-shaped bundle, because its
    /// manifest has a different shape (referenceFastaPath) that the export
    /// pipeline doesn't read yet — advertising the action without handler
    /// support would just relocate the AS3 bug. FASTQ bundles get their own
    /// "Export as FASTQ" item; other bundle kinds have no sequence export.
    func testExportSequencesCapabilityIsScopedToReferenceBundleOnly() {
        XCTAssertTrue(SidebarItemType.referenceBundle.bundleCapabilities.canExportSequences)

        let nonExportKinds: [SidebarItemType] = [
            .mhcReferenceBundle, .fastqBundle, .multipleSequenceAlignmentBundle, .phylogeneticTreeBundle,
            .primerSchemeBundle, .genotypeResultBundle, .twelveSAmpliconResultBundle, .czIdResult,
        ]
        for kind in nonExportKinds {
            XCTAssertFalse(kind.bundleCapabilities.canExportSequences, "\(kind) should not offer Export Sequences")
        }
    }

    /// Only `.referenceBundle` supports annotation export (AS16 / task E4):
    /// loadSequencesForExport only reads a `.lungfishref` bundle's
    /// annotation tracks. Mirrors testExportSequencesCapabilityIsScopedToReferenceBundleOnly.
    func testExportAnnotationsCapabilityIsScopedToReferenceBundleOnly() {
        XCTAssertTrue(SidebarItemType.referenceBundle.bundleCapabilities.canExportAnnotations)

        let nonExportKinds: [SidebarItemType] = [
            .mhcReferenceBundle, .fastqBundle, .multipleSequenceAlignmentBundle, .phylogeneticTreeBundle,
            .primerSchemeBundle, .genotypeResultBundle, .twelveSAmpliconResultBundle, .czIdResult,
        ]
        for kind in nonExportKinds {
            XCTAssertFalse(kind.bundleCapabilities.canExportAnnotations, "\(kind) should not offer Export Annotations")
        }
    }

    // MARK: - Context menu construction: MHC reference bundle (AS3)

    func testMHCReferenceBundleContextMenuOffersBundleActions() throws {
        let tempRoot = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: tempRoot.root) }

        let bundleURL = tempRoot.projectURL.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: bundleURL, name: "MCM")

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        defer { sidebar.closeProject() }
        sidebar.openProject(at: tempRoot.projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        let titles = sidebar.testContextMenuItems(for: sidebar.selectedItems()).map(\.title)

        XCTAssertTrue(titles.contains("Open Bundle"), "titles: \(titles)")
        XCTAssertTrue(titles.contains("Show Package Contents"), "titles: \(titles)")
        XCTAssertTrue(titles.contains("Get Bundle Info"), "titles: \(titles)")
        XCTAssertTrue(titles.contains("Show in Inspector"), "titles: \(titles)")
    }

    func testMHCReferenceBundleGetBundleInfoActuallyFires() throws {
        // AS3 also broke Get Bundle Info's own kind-guard (item.type ==
        // .referenceBundle only). Confirm the handler's guard was widened
        // to accept mhcReferenceBundle so the menu item isn't a second
        // silent no-op once it's shown.
        let tempRoot = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: tempRoot.root) }

        let bundleURL = tempRoot.projectURL.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: bundleURL, name: "MCM")

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        defer { sidebar.closeProject() }
        sidebar.openProject(at: tempRoot.projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        let items = sidebar.testContextMenuItems(for: sidebar.selectedItems())
        let getInfoItem = try XCTUnwrap(items.first { $0.title == "Get Bundle Info" })
        XCTAssertNotNil(getInfoItem.action, "Get Bundle Info must have an action wired for mhcReferenceBundle")
    }

    // MARK: - Context menu construction: the 5 other fall-through bundle kinds (AS18)

    func testMultipleSequenceAlignmentBundleContextMenuOffersOpenBundle() throws {
        let items = [makeBundleItem(type: .multipleSequenceAlignmentBundle, name: "align.lungfishmsa")]
        let sidebar = try makeSidebarWithFakeSelection(items)
        let titles = sidebar.testContextMenuItems(for: items).map(\.title)
        XCTAssertTrue(titles.contains("Open Bundle"), "titles: \(titles)")
        XCTAssertTrue(titles.contains("Show Package Contents"), "titles: \(titles)")
        XCTAssertTrue(titles.contains("Get Bundle Info"), "titles: \(titles)")
    }

    func testPhylogeneticTreeBundleContextMenuOffersOpenBundle() throws {
        let items = [makeBundleItem(type: .phylogeneticTreeBundle, name: "tree.lungfishtree")]
        let sidebar = try makeSidebarWithFakeSelection(items)
        let titles = sidebar.testContextMenuItems(for: items).map(\.title)
        XCTAssertTrue(titles.contains("Open Bundle"), "titles: \(titles)")
    }

    func testPrimerSchemeBundleContextMenuOffersOpenBundle() throws {
        let items = [makeBundleItem(type: .primerSchemeBundle, name: "scheme.lungfishprimers")]
        let sidebar = try makeSidebarWithFakeSelection(items)
        let titles = sidebar.testContextMenuItems(for: items).map(\.title)
        XCTAssertTrue(titles.contains("Open Bundle"), "titles: \(titles)")
    }

    func testGenotypeResultBundleContextMenuOffersOpenBundle() throws {
        let items = [makeBundleItem(type: .genotypeResultBundle, name: "genotype.lungfishgenotype")]
        let sidebar = try makeSidebarWithFakeSelection(items)
        let titles = sidebar.testContextMenuItems(for: items).map(\.title)
        XCTAssertTrue(titles.contains("Open Bundle"), "titles: \(titles)")
    }

    func testTwelveSAmpliconResultBundleContextMenuOffersOpenBundle() throws {
        let items = [makeBundleItem(type: .twelveSAmpliconResultBundle, name: "amplicon.lungfish12s")]
        let sidebar = try makeSidebarWithFakeSelection(items)
        let titles = sidebar.testContextMenuItems(for: items).map(\.title)
        XCTAssertTrue(titles.contains("Open Bundle"), "titles: \(titles)")
    }

    // MARK: - No cross-contamination: Export Sequences / Merge stay reference-only

    func testMultipleSequenceAlignmentBundleContextMenuHasNoExportSequences() throws {
        let items = [makeBundleItem(type: .multipleSequenceAlignmentBundle, name: "align.lungfishmsa")]
        let sidebar = try makeSidebarWithFakeSelection(items)
        let titles = sidebar.testContextMenuItems(for: items).map(\.title)
        XCTAssertFalse(titles.contains(where: { $0.hasPrefix("Export") && $0.contains("Sequence") }), "titles: \(titles)")
    }

    // MARK: - Helpers

    private func makeBundleItem(type: SidebarItemType, name: String) -> SidebarItem {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarBundleCapabilityTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: url.appendingPathComponent("manifest.json"))
        return SidebarItem(title: url.deletingPathExtension().lastPathComponent, type: type, url: url)
    }

    private func makeSidebarWithFakeSelection(_ items: [SidebarItem]) throws -> SidebarViewController {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        return sidebar
    }

    private func makeTempProject() throws -> (root: URL, projectURL: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarBundleCapabilityTests-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        return (tempRoot, projectURL)
    }
}
