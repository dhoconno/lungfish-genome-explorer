import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
import LungfishIO

final class GenotypeHaplotypeDefinitionEditorTests: XCTestCase {
    func testDraftingPreservesSetMetadataAndMinimumMatchesWhenRenamingHaplotype() {
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
                            colorTokenIndex: 3,
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
