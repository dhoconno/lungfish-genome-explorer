import XCTest
@testable import LungfishIO

final class GenotypeHaplotypeRegistryTests: XCTestCase {
    func testBuiltInRegistryScopesDefinitionsByAssayAndSpeciesName() throws {
        let registry = GenotypeHaplotypeDefinitionRegistry.builtIn
        let assay = try XCTUnwrap(registry.assay(id: "MHC-exon2-miSeq"))

        XCTAssertEqual(assay.displayName, "MHC exon 2 MiSeq")
        XCTAssertNil(registry.defaultDefinitionSetID)
        XCTAssertEqual(
            assay.definitionSets.map(\.displayName),
            ["Mauritian cynomolgus macaques", "Rhesus macaques", "Pig-tailed macaques"]
        )
        XCTAssertEqual(
            registry.definitionSet(id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")?.speciesName,
            "Mauritian cynomolgus macaques"
        )
    }

    func testDeterministicMCMHaplotypeCallsUseNotebookRules() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )
        let calls = [
            makeCall(sample: "DW472", genotype: "05_M1M2M3_A1_063g"),
            makeCall(sample: "DW472", genotype: "07_M1M2_70_156bp"),
            makeCall(sample: "DW472", genotype: "02_M2_G_02_06_156bp"),
        ]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definitionSet)
        let sample = try XCTUnwrap(analysis.samples.first)
        let mhcA = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-A" })

        XCTAssertEqual(mhcA.haplotype1, "M2A")
        XCTAssertEqual(mhcA.haplotype2, "-")
        XCTAssertEqual(mhcA.status, .called)
        XCTAssertEqual(mhcA.matchedHaplotypes.map(\.name), ["M2A"])
        // M2A's diagnostic set is one high-specificity Mafa-G allele
        // (single-M-tag); the K-of-N rule means observing that one
        // allele is sufficient. Earlier definitions used 3 multi-M-tag
        // alleles which caused false TMH on real bundles.
        XCTAssertGreaterThanOrEqual(mhcA.matchedHaplotypes.first?.observedDiagnosticAlleles.count ?? 0, 1)
    }

    func testMCMUndercalledA1063SpecialCaseIsPreserved() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )
        let calls = [makeCall(sample: "DW472", genotype: "05_M1M2M3_A1_063g")]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definitionSet)
        let mhcA = try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-A" })

        XCTAssertEqual(mhcA.haplotype1, "A1_063")
        XCTAssertEqual(mhcA.haplotype2, "-")
        XCTAssertEqual(mhcA.status, .specialCase)
        XCTAssertTrue(mhcA.notes.contains("A1_063"))
    }

    func testDiploidClassIILociFlagUnexpectedExtraAlleleSequences() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.rhesus-macaques"
            )
        )
        let calls = [
            makeCall(sample: "Rh01", genotype: "01_Mamu_DQB1_06_01"),
            makeCall(sample: "Rh01", genotype: "02_Mamu_DQB1_06_07"),
            makeCall(sample: "Rh01", genotype: "03_Mamu_DQB1_06_08"),
        ]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definitionSet)
        let dqb = try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-DQB" })

        XCTAssertEqual(dqb.haplotype1, "ERR: TMG")
        XCTAssertEqual(dqb.haplotype2, "ERR: TMG")
        XCTAssertEqual(dqb.status, .tooManyGenotypes)
        XCTAssertEqual(dqb.observedGenotypeCount, 3)
    }

    func testTooManyMatchingHaplotypesAreFlaggedForReview() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M1_B_134_02"),
            makeCall(sample: "DW472", genotype: "12_M1_B_152_01N"),
            makeCall(sample: "DW472", genotype: "12_M2_B_019_03"),
            makeCall(sample: "DW472", genotype: "12_M2_B_150_01_01"),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01"),
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01"),
        ]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definitionSet)
        let mhcB = try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-B" })

        XCTAssertEqual(mhcB.haplotype1, "ERR: TMH (M1B, M2B, M3B)")
        XCTAssertEqual(mhcB.haplotype2, "ERR: TMH (M1B, M2B, M3B)")
        XCTAssertEqual(mhcB.status, .tooManyHaplotypes)
    }

    private func makeCall(sample: String, genotype: String) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: 100,
            passedUniqueReads: 100,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }
}
