import XCTest
@testable import LungfishIO

final class GenotypeHaplotypeRegistryTests: XCTestCase {
    private func makeDefinitionSet() -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: "test-assay.sample",
            assayID: "test-assay",
            displayName: "Sample definition",
            speciesName: "Test species",
            speciesCode: "TEST",
            prefix: "Test",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Test-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "H1",
                            diagnosticAlleles: ["A1_001", "A1_002"],
                            colorTokenIndex: 0,
                            minimumMatches: 1
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "H2",
                            diagnosticAlleles: ["A1_003"],
                            colorTokenIndex: 1
                        ),
                    ]
                )
            ],
            schemaVersion: 3,
            lastModified: "2026-05-31T00:00:00Z",
            changeNote: "inline fixture"
        )
    }

    func testDefinitionSetEncodesAndDecodesLosslessly() throws {
        let original = makeDefinitionSet()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "test-assay.sample")
        XCTAssertEqual(decoded.assayID, "test-assay")
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.lastModified, "2026-05-31T00:00:00Z")
        XCTAssertEqual(decoded.changeNote, "inline fixture")
        XCTAssertEqual(decoded.locusDefinitions.count, 1)
        XCTAssertEqual(decoded.locusDefinitions.first?.haplotypes.map(\.name), ["H1", "H2"])
    }

    func testEffectiveMinimumMatchesDefaultsToDiagnosticAlleleCount() {
        let haplotype = GenotypeHaplotypeDefinition(
            name: "H1",
            diagnosticAlleles: ["A1_001", "A1_002", "A1_003"]
        )

        XCTAssertNil(haplotype.minimumMatches)
        XCTAssertEqual(haplotype.effectiveMinimumMatches, 3)
    }

    func testEffectiveMinimumMatchesClampsZeroToOne() {
        let haplotype = GenotypeHaplotypeDefinition(
            name: "H1",
            diagnosticAlleles: ["A1_001", "A1_002", "A1_003"],
            minimumMatches: 0
        )

        XCTAssertEqual(haplotype.minimumMatches, 0)
        XCTAssertEqual(haplotype.effectiveMinimumMatches, 1)
    }

    func testEffectiveMinimumMatchesReturnsValueWithinRange() {
        let haplotype = GenotypeHaplotypeDefinition(
            name: "H1",
            diagnosticAlleles: ["A1_001", "A1_002", "A1_003"],
            minimumMatches: 2
        )

        XCTAssertEqual(haplotype.effectiveMinimumMatches, 2)
    }

    func testEmptyRegistryHasNoDefinitionSets() {
        let registry = GenotypeHaplotypeDefinitionRegistry(assays: [], defaultDefinitionSetID: nil)

        XCTAssertTrue(registry.assays.isEmpty)
        XCTAssertNil(registry.defaultDefinitionSetID)
        XCTAssertNil(registry.definitionSet(id: "anything"))
        XCTAssertTrue(registry.definitionSets(assayID: "test-assay").isEmpty)
    }
}
