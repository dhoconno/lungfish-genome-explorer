import XCTest
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
