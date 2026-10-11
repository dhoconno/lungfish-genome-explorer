// WorkflowLibraryIdentifierPinTests.swift - Freeze of the ids the Workflow Library derives from titles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A group id and a user section id are the title in lowercase with each space turned into a hyphen
// (WorkflowLibrary.swift, the initializers of WorkflowLibraryGroup and WorkflowLibraryUserGroup and
// the id of WorkflowLibraryUserSection). A built-in group takes its title from the display name of
// a FASTQ operation category, so a new display name would rename the id the panel uses as its
// SwiftUI identity and, through a slug, as an accessibility identifier. This suite freezes the ids
// of every built-in group and section, the rule that derives them, the user section and the ids
// of the items the enablement store keeps in UserDefaults. A retitle shows up here first.

import LungfishWorkflow
import XCTest
@testable import LungfishApp

final class WorkflowLibraryIdentifierPinTests: XCTestCase {
    // MARK: - Built-in sections

    func testBuiltInSectionIDsAndTitles() {
        let sections = WorkflowLibraryCatalog.builtInSections
        XCTAssertEqual(sections.map(\.id), ["core", "specialized"])
        XCTAssertEqual(sections.map(\.title), ["Core Tools", "Specialized Workflows"])
        XCTAssertEqual(sections.map(\.kind), [.core, .specialized])
    }

    func testSectionKindRawValues() {
        XCTAssertEqual(WorkflowLibrarySectionKind.core.rawValue, "core")
        XCTAssertEqual(WorkflowLibrarySectionKind.specialized.rawValue, "specialized")
        XCTAssertEqual(WorkflowLibrarySectionKind.user.rawValue, "user")
    }

    // MARK: - Built-in groups

    /// Ordered as the panel lists them. There is no core Genotyping group, because both genotyping
    /// workflows are specialized.
    func testCoreGroupIDsAreTheLowercasedCategoryNames() throws {
        let core = try XCTUnwrap(WorkflowLibraryCatalog.builtInSections.first { $0.kind == .core })
        XCTAssertEqual(core.groups.map(\.id), [
            "alignment-&-phylogenetics", "assembly", "classification", "clustering",
            "decontamination", "demultiplexing", "mapping", "qc-&-reporting",
            "read-processing", "search-&-subsetting", "trimming-&-filtering", "variant-calling",
        ])
    }

    func testSpecializedGroupIDsAreTheLowercasedCategoryNames() throws {
        let specialized = try XCTUnwrap(WorkflowLibraryCatalog.builtInSections.first { $0.kind == .specialized })
        XCTAssertEqual(specialized.groups.map(\.id), ["classification", "genotyping"])
    }

    func testEveryCategoryDerivesItsGroupIDFromItsDisplayName() {
        let expected: [FASTQOperationCategoryID: (title: String, id: String)] = [
            .qcReporting: ("QC & Reporting", "qc-&-reporting"),
            .demultiplexing: ("Demultiplexing", "demultiplexing"),
            .trimmingFiltering: ("Trimming & Filtering", "trimming-&-filtering"),
            .decontamination: ("Decontamination", "decontamination"),
            .readProcessing: ("Read Processing", "read-processing"),
            .searchSubsetting: ("Search & Subsetting", "search-&-subsetting"),
            .mapping: ("Mapping", "mapping"),
            .variantCalling: ("Variant Calling", "variant-calling"),
            .assembly: ("Assembly", "assembly"),
            .clustering: ("Clustering", "clustering"),
            .classification: ("Classification", "classification"),
            .genotyping: ("Genotyping", "genotyping"),
            .alignment: ("Alignment & Phylogenetics", "alignment-&-phylogenetics"),
        ]
        XCTAssertEqual(Set(expected.keys), Set(FASTQOperationCategoryID.allCases), "a category has no row")
        for (category, row) in expected {
            XCTAssertEqual(category.displayName, row.title)
            XCTAssertEqual(WorkflowLibraryGroup(title: category.displayName, items: []).id, row.id, row.title)
        }
    }

    // MARK: - The derivation rule

    /// The rule lowercases and swaps each space for a hyphen. It keeps `&`, never collapses a run
    /// of spaces and touches no other character, which differs from the accessibility slug.
    func testTheThreeInitializersShareOneDerivationRule() {
        let cases: [(title: String, id: String)] = [
            ("Trimming & Filtering", "trimming-&-filtering"),
            ("Two  Spaces", "two--spaces"),
            (" Padded ", "-padded-"),
            ("Step 2 Assembly", "step-2-assembly"),
            ("Already-Hyphenated", "already-hyphenated"),
            ("Tab\tStays", "tab\tstays"),
            ("Café Ünits", "café-ünits"),
            ("", ""),
        ]
        for (title, id) in cases {
            XCTAssertEqual(WorkflowLibraryGroup(title: title, items: []).id, id, "built-in group \(title.debugDescription)")
            XCTAssertEqual(WorkflowLibraryUserGroup(title: title, packages: []).id, id, "user group \(title.debugDescription)")
            XCTAssertEqual(WorkflowLibraryUserSection(title: title, groups: []).id, id, "user section \(title.debugDescription)")
        }
    }

    // MARK: - User sections

    func testNoUserSectionWithoutPackages() {
        XCTAssertTrue(WorkflowLibraryCatalog.userSections(for: []).isEmpty)
    }

    func testUserSectionAndUserGroupIDs() throws {
        let sections = WorkflowLibraryCatalog.userSections(for: [
            makePackage(id: "first", category: "Examples"),
            makePackage(id: "second", category: "Custom Pipelines"),
            makePackage(id: "third", category: "Examples"),
        ])
        XCTAssertEqual(sections.count, 1)
        let section = try XCTUnwrap(sections.first)
        XCTAssertEqual(section.title, "User Workflows")
        XCTAssertEqual(section.id, "user-workflows")
        XCTAssertEqual(section.groups.map(\.title), ["Custom Pipelines", "Examples"])
        XCTAssertEqual(section.groups.map(\.id), ["custom-pipelines", "examples"])
    }

    // MARK: - Item ids

    /// The enablement store saves these in UserDefaults, because only a specialized item can be
    /// switched on or off. A core item's id is not saved.
    func testSpecializedItemsKeepTheIDsTheEnablementStoreSaves() {
        let specialized = WorkflowLibraryCatalog.builtIn.filter { $0.maturity != .core }.map(\.id)
        XCTAssertEqual(specialized.count, 3)
        XCTAssertEqual(Set(specialized), [
            "ontGenotyping",
            "builtin.full-length-ont-mhc-genotyping",
            "builtin.12s-amplicon-matching",
        ])
        XCTAssertEqual(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID, "builtin.full-length-ont-mhc-genotyping")
        XCTAssertEqual(WorkflowLibraryCatalog.twelveSAmpliconMatchingID, "builtin.12s-amplicon-matching")
    }

    func testToolItemsTakeTheirIDFromTheToolRawValueAndEveryIDIsUnique() {
        let items = WorkflowLibraryCatalog.builtIn
        for item in items {
            if let tool = item.toolID {
                XCTAssertEqual(item.id, tool.rawValue, item.title)
            }
        }
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "two items share an id")
        XCTAssertEqual(FASTQOperationToolID.bwaMem2.rawValue, "bwa-mem2")
        XCTAssertEqual(FASTQOperationToolID.esViritu.rawValue, "esViritu")
        XCTAssertEqual(FASTQOperationToolID.taxTriage.rawValue, "taxTriage")
    }

    // MARK: - Helpers

    /// A validated package that never touches the disk, because the catalog only reads its manifest.
    private func makePackage(id: String, category: String) -> WorkflowPackageValidationResult {
        let packageURL = URL(fileURLWithPath: "/nonexistent/\(id).lungfishflowpkg", isDirectory: true)
        let manifest = WorkflowPackageManifest(
            id: id,
            name: id,
            version: "1.0.0",
            category: category,
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [],
            outputs: []
        )
        return WorkflowPackageValidationResult(
            packageURL: packageURL,
            manifestURL: packageURL.appendingPathComponent("manifest.json"),
            manifest: manifest
        )
    }
}
