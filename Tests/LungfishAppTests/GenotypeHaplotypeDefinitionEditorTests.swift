import XCTest
import AppKit
import SwiftUI
@testable import LungfishApp
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO

final class GenotypeHaplotypeDefinitionEditorTests: XCTestCase {
    func testDraftingPreservesSetMetadataAndHaplotypeDetailsWhenRenamingHaplotype() {
        let set = makeDefinitionSet()

        let updated = GenotypeHaplotypeDefinitionDrafting.renamingHaplotype(
            in: set,
            locusIndex: 0,
            haplotypeIndex: 0,
            name: "M1A edited"
        )

        XCTAssertEqual(updated.schemaVersion, 7)
        XCTAssertEqual(updated.lastModified, "2026-05-22T00:00:00Z")
        XCTAssertEqual(updated.changeNote, "curated")
        let haplotype = updated.locusDefinitions[0].haplotypes[0]
        XCTAssertEqual(haplotype.name, "M1A edited")
        XCTAssertEqual(haplotype.minimumMatches, 2)
        XCTAssertEqual(haplotype.colorTokenIndex, 3)
        XCTAssertEqual(haplotype.colorOverride, AnnotationColor(hex: "#12AB34"))
        XCTAssertEqual(haplotype.primaryAlleles, ["A1"])
        XCTAssertEqual(haplotype.evidenceWeights, ["A1": 2])
    }

    func testDraftingCanApplyAndClearHaplotypeColorOverride() {
        let haplotype = makeDefinitionSet().locusDefinitions[0].haplotypes[0]
        let override = AnnotationColor(hex: "#F4CE23")

        let updated = GenotypeHaplotypeDefinitionDrafting.withColorOverride(haplotype, color: override)
        let cleared = GenotypeHaplotypeDefinitionDrafting.withColorOverride(updated, color: nil)

        XCTAssertEqual(updated.colorOverride, override)
        XCTAssertNil(cleared.colorOverride)
        XCTAssertEqual(cleared.colorTokenIndex, haplotype.colorTokenIndex)
    }

    func testUncheckingDiagnosticAlleleRetainsFullAssociatedSetAndOtherEvidence() {
        let associated = (1...18).map { "A\($0)" }
        let haplotype = GenotypeHaplotypeDefinition(
            name: "M1A",
            diagnosticAlleles: ["A1", "A2"],
            associatedAlleles: associated,
            primaryAlleles: ["A1"],
            evidenceWeights: ["A1": 0.5, "A2": 2],
            minimumMatches: 1
        )

        let updated = GenotypeHaplotypeDefinitionDrafting.withDiagnostic(
            haplotype,
            allele: "A1",
            isDiagnostic: false
        )

        XCTAssertEqual(updated.effectiveAssociatedAlleles, associated)
        XCTAssertEqual(updated.diagnosticAlleles, ["A2"])
        XCTAssertEqual(updated.primaryAlleles, ["A1"])
        XCTAssertEqual(updated.evidenceWeights, ["A1": 0.5, "A2": 2])
    }

    func testAssociatedAlleleDefaultsToUncheckedDiagnostic() {
        let haplotype = GenotypeHaplotypeDefinition(name: "M1A", diagnosticAlleles: ["A1"])

        let updated = GenotypeHaplotypeDefinitionDrafting.addingAssociatedAllele(haplotype, allele: "A2")

        XCTAssertEqual(updated.effectiveAssociatedAlleles, ["A1", "A2"])
        XCTAssertEqual(updated.diagnosticAlleles, ["A1"])
    }

    func testMembershipEditsRetainDiagnosticAllelesWhenAssociatedSupportIsPresent() {
        let haplotype = GenotypeHaplotypeDefinition(
            name: "M1A",
            diagnosticAlleles: ["A1", "A2"],
            associatedAlleles: ["support"]
        )

        let updated = GenotypeHaplotypeDefinitionDrafting.withDiagnostic(
            haplotype,
            allele: "support",
            isDiagnostic: false
        )

        XCTAssertEqual(updated.effectiveAssociatedAlleles, ["support", "A1", "A2"])
        XCTAssertEqual(updated.diagnosticAlleles, ["A1", "A2"])
    }

    func testMetadataEditsPreserveLegacyNilAssociatedAlleles() {
        let haplotype = GenotypeHaplotypeDefinition(name: "M1A", diagnosticAlleles: ["A1"])
        let set = GenotypeHaplotypeDefinitionSet(
            id: "test", assayID: "assay", displayName: "Test",
            speciesName: "Species", speciesCode: "SP", prefix: "P",
            locusDefinitions: [GenotypeHaplotypeLocusDefinition(
                locus: "MHC-A", sourceLocus: "A", haplotypes: [haplotype]
            )]
        )

        let renamed = GenotypeHaplotypeDefinitionDrafting.renamingHaplotype(
            in: set, locusIndex: 0, haplotypeIndex: 0, name: "M1A-renamed"
        )

        XCTAssertNil(renamed.locusDefinitions[0].haplotypes[0].associatedAlleles)
    }

    func testThresholdLabelClampsToCurrentDiagnosticAlleleCount() {
        let haplotype = GenotypeHaplotypeDefinition(
            name: "M1A",
            diagnosticAlleles: ["A1", "A2"],
            minimumMatches: 1
        )

        XCTAssertEqual(
            GenotypeHaplotypeDefinitionDrafting.minimumMatchesLabel(for: haplotype, requested: 18),
            "Require 2 of 2 diagnostic alleles"
        )
    }

    func testRemovingAssociatedAlleleRemovesItFromDiagnosticEvidence() {
        let haplotype = GenotypeHaplotypeDefinition(
            name: "M1A",
            diagnosticAlleles: ["A1", "A2"],
            associatedAlleles: ["A1", "A2", "A3"]
        )

        let updated = GenotypeHaplotypeDefinitionDrafting.removingAssociatedAllele(haplotype, allele: "A2")

        XCTAssertEqual(updated.effectiveAssociatedAlleles, ["A1", "A3"])
        XCTAssertEqual(updated.diagnosticAlleles, ["A1"])
    }

    func testDraftingValidationBlocksEmptyAndDuplicateDefinitions() {
        let invalid = GenotypeHaplotypeDefinitionSet(
            id: "test",
            assayID: "assay",
            displayName: "Test",
            speciesName: "Test species",
            speciesCode: "TEST",
            prefix: "Test",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Test-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "H1", diagnosticAlleles: []),
                        GenotypeHaplotypeDefinition(name: "H1", diagnosticAlleles: ["A1"]),
                    ]
                ),
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Test-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "", diagnosticAlleles: ["A2"]),
                    ]
                ),
            ]
        )

        let messages = GenotypeHaplotypeDefinitionDrafting.validationMessages(for: invalid)

        XCTAssertTrue(messages.contains { $0.contains("Duplicate locus") })
        XCTAssertTrue(messages.contains { $0.contains("Duplicate haplotype") })
        XCTAssertTrue(messages.contains { $0.contains("diagnostic allele") })
        XCTAssertTrue(messages.contains { $0.contains("Haplotype name") })
    }

    @MainActor
    func testEditorLayoutAtCompactDefaultAndLargeSizes() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_HAPLOTYPE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set LUNGFISH_HAPLOTYPE_LAYOUT_SNAPSHOTS for visual layout verification")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let alleles = (1...18).map { "A\($0)*01:01:01:01/A\($0)*02:01:01:01" }
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "mcm-mhc-miseq-example", assayID: "MHC-exon2-miSeq",
            displayName: "MCM MHC MiSeq haplotypes — 22 September 2026",
            speciesName: "Mauritian cynomolgus macaque", speciesCode: "MCM", prefix: "MHC",
            locusDefinitions: ["A", "E", "B", "DR", "DQ", "DP"].map { locus in
                .init(locus: "MHC-" + locus, sourceLocus: "MHC-" + locus,
                      haplotypes: [.init(name: "M1" + locus, diagnosticAlleles: alleles)])
            })
        let editor = GenotypeHaplotypeDefinitionEditor(
            draft: definition, allowsMetadataEditing: true, requiresReferenceFASTA: true,
            onSave: { _ in }, onCancel: {})
        let hosting = NSHostingController(rootView: editor)
        hosting.sizingOptions = []
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting
        panel.appearance = NSAppearance(named: .aqua)
        defer { panel.close() }
        for size in [NSSize(width: 760, height: 560), NSSize(width: 1000, height: 740), NSSize(width: 1400, height: 950)] {
            panel.setContentSize(size)
            hosting.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(180))
            hosting.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.view.bounds.size, size)
            let bitmap = try XCTUnwrap(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
            hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("haplotype-editor-\(Int(size.width)).png"))
        }
    }

    private func makeDefinitionSet() -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: "test",
            assayID: "assay",
            displayName: "Test",
            speciesName: "Test species",
            speciesCode: "TEST",
            prefix: "Test",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Test-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1A",
                            diagnosticAlleles: ["A1", "A2", "A3"],
                            primaryAlleles: ["A1"],
                            evidenceWeights: ["A1": 2],
                            colorTokenIndex: 3,
                            colorOverride: AnnotationColor(hex: "#12AB34"),
                            minimumMatches: 2
                        )
                    ]
                )
            ],
            schemaVersion: 7,
            lastModified: "2026-05-22T00:00:00Z",
            changeNote: "curated"
        )
    }
}
