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

    func testDefinitionLookupCanBeScopedToAssay() throws {
        let registry = GenotypeHaplotypeDefinitionRegistry.builtIn

        let rhesus = try XCTUnwrap(registry.definitionSet(
            id: "MHC-exon2-miSeq.rhesus-macaques",
            assayID: "MHC-exon2-miSeq"
        ))

        XCTAssertEqual(rhesus.speciesCode, "MAMU")
        XCTAssertNil(registry.definitionSet(
            id: "MHC-exon2-miSeq.rhesus-macaques",
            assayID: "unsupported-assay"
        ))
    }

    func testDefinitionSetsAreFilteredByAssayAndSpecies() {
        let registry = GenotypeHaplotypeDefinitionRegistry.builtIn

        XCTAssertEqual(
            registry.definitionSets(assayID: "MHC-exon2-miSeq", speciesCode: "MAMU").map(\.id),
            ["MHC-exon2-miSeq.rhesus-macaques"]
        )
        XCTAssertEqual(
            registry.definitionSets(assayID: "MHC-exon2-miSeq", speciesCode: "MCM").map(\.id),
            ["MHC-exon2-miSeq.mauritian-cynomolgus-macaques"]
        )
        XCTAssertTrue(registry.definitionSets(assayID: "unsupported-assay", speciesCode: "MAMU").isEmpty)
    }

    func testLegacyDefinitionSetJSONDefaultsToMHCExon2MiSeqAssay() throws {
        let json = Data("""
        {
          "id": "MHC-exon2-miSeq.legacy-mcm",
          "displayName": "Legacy MCM",
          "speciesName": "Mauritian cynomolgus macaques",
          "speciesCode": "MCM",
          "prefix": "Mafa",
          "locusDefinitions": [
            {
              "locus": "MHC-A",
              "sourceLocus": "Mafa-A",
              "haplotypes": [
                {"name": "M1A", "diagnosticAlleles": ["01_M1_F_01_w_06"]}
              ]
            }
          ]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: json)

        XCTAssertEqual(decoded.assayID, "MHC-exon2-miSeq")
        XCTAssertEqual(decoded.displayName, "Legacy MCM")
    }

    func testLegacyHaplotypeAnalysisJSONDefaultsToMHCExon2MiSeqAssay() throws {
        let json = Data("""
        {
          "schemaVersion": 1,
          "definitionSetID": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
          "definitionSetName": "Mauritian cynomolgus macaques",
          "speciesName": "Mauritian cynomolgus macaques",
          "samples": []
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(GenotypeHaplotypeAnalysis.self, from: json)

        XCTAssertEqual(decoded.assayID, "MHC-exon2-miSeq")
        XCTAssertEqual(decoded.definitionSetID, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
    }

    func testBuiltInMCMLociUseCombinedDQAndDPDefinitions() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )

        let loci = definitionSet.locusDefinitions.map(\.locus)
        XCTAssertEqual(loci, ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQ", "MHC-DP"])
        XCTAssertFalse(loci.contains("MHC-DQA"))
        XCTAssertFalse(loci.contains("MHC-DQB"))
        XCTAssertFalse(loci.contains("MHC-DPA"))
        XCTAssertFalse(loci.contains("MHC-DPB"))

        let dq = try XCTUnwrap(definitionSet.locusDefinitions.first { $0.locus == "MHC-DQ" })
        let m3dq = try XCTUnwrap(dq.haplotypes.first { $0.name == "M3DQ" })
        XCTAssertTrue(m3dq.diagnosticAlleles.contains("14_M3_DQA1_05_03_01"))
        XCTAssertTrue(m3dq.diagnosticAlleles.contains("14_M3_DQB1_16_01"))

        let dp = try XCTUnwrap(definitionSet.locusDefinitions.first { $0.locus == "MHC-DP" })
        let m2dp = try XCTUnwrap(dp.haplotypes.first { $0.name == "M2DP" })
        XCTAssertTrue(m2dp.diagnosticAlleles.contains("15_M2_DPA1_07_01"))
        XCTAssertTrue(m2dp.diagnosticAlleles.contains("15_M2_DPB1_20_01"))
    }

    func testBuiltInRhesusDefinitionsKeepClassIISubLociSeparate() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.rhesus-macaques",
                assayID: "MHC-exon2-miSeq"
            )
        )

        let loci = definitionSet.locusDefinitions.map(\.locus)
        XCTAssertEqual(loci, ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"])
        XCTAssertFalse(loci.contains("MHC-DQ"))
        XCTAssertFalse(loci.contains("MHC-DP"))

        let haplotypeCounts = Dictionary(
            uniqueKeysWithValues: definitionSet.locusDefinitions.map { ($0.locus, $0.haplotypes.count) }
        )
        XCTAssertEqual(haplotypeCounts["MHC-A"], 23)
        XCTAssertEqual(haplotypeCounts["MHC-B"], 31)
        XCTAssertEqual(haplotypeCounts["MHC-DRB"], 38)
        XCTAssertEqual(haplotypeCounts["MHC-DQA"], 25)
        XCTAssertEqual(haplotypeCounts["MHC-DQB"], 30)
        XCTAssertEqual(haplotypeCounts["MHC-DPA"], 25)
        XCTAssertEqual(haplotypeCounts["MHC-DPB"], 32)

        XCTAssertTrue(definitionSet.locusDefinitions.first { $0.locus == "MHC-DQA" }?.haplotypes.contains { $0.name == "01g1" } == true)
        XCTAssertTrue(definitionSet.locusDefinitions.first { $0.locus == "MHC-DQB" }?.haplotypes.contains { $0.name == "18g3" } == true)
        XCTAssertTrue(definitionSet.locusDefinitions.first { $0.locus == "MHC-DPA" }?.haplotypes.contains { $0.name == "07g1" } == true)
        XCTAssertTrue(definitionSet.locusDefinitions.first { $0.locus == "MHC-DPB" }?.haplotypes.contains { $0.name == "01g1" } == true)
    }

    func testCombinedMCMClassIIDQUsesAlphaAndBetaAllelesForCalls() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )
        let calls = [
            makeCall(sample: "DW472", genotype: "14_M2_DQA1_01_04", reads: 120),
            makeCall(sample: "DW472", genotype: "14_M2M6_DQB1_06g:14_M_DQB1_06_01_01", reads: 110),
            makeCall(sample: "DW472", genotype: "14_M3_DQA1_05_03_01", reads: 130),
            makeCall(sample: "DW472", genotype: "14_M3_DQB1_16_01", reads: 140),
        ]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definitionSet)
        let dq = try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-DQ" })

        XCTAssertEqual(dq.status, .called)
        XCTAssertEqual(dq.haplotype1, "M2DQ")
        XCTAssertEqual(dq.haplotype2, "M3DQ")
        XCTAssertEqual(dq.matchedHaplotypes.map(\.name), ["M2DQ", "M3DQ"])
        XCTAssertEqual(Set(dq.observedGenotypes), Set(calls.map(\.genotype)))
    }

    func testCombinedMCMClassIIDQCountsTooManyGenotypesPerSubLocus() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )
        let diploidAcrossAlphaAndBeta = [
            makeCall(sample: "DW472", genotype: "14_M2_DQA1_01_04", reads: 120),
            makeCall(sample: "DW472", genotype: "14_M3_DQA1_05_03_01", reads: 130),
            makeCall(sample: "DW472", genotype: "14_M2M6_DQB1_06g:14_M_DQB1_06_01_01", reads: 110),
            makeCall(sample: "DW472", genotype: "14_M3_DQB1_16_01", reads: 140),
        ]
        let tooManyDQA = diploidAcrossAlphaAndBeta + [
            makeCall(sample: "DW472", genotype: "14_M4_DQA1_01_07_01", reads: 100),
        ]

        let diploidAnalysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: diploidAcrossAlphaAndBeta,
            definitionSet: definitionSet
        )
        XCTAssertNotEqual(
            diploidAnalysis.samples.first?.calls.first { $0.locus == "MHC-DQ" }?.status,
            .tooManyGenotypes
        )

        let tmgAnalysis = GenotypeHaplotypeAnalyzer.analyze(calls: tooManyDQA, definitionSet: definitionSet)
        let dq = try XCTUnwrap(tmgAnalysis.samples.first?.calls.first { $0.locus == "MHC-DQ" })
        XCTAssertEqual(dq.status, .tooManyGenotypes)
    }

    func testDW472bLikeMHCBEvidenceCallsTwoCompleteHaplotypesWithDropout() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )
        let evaluator = GenotypeDropoutEvaluator(absolute: 50, sampleFraction: nil, locusFraction: 0.05)
        let calls = [
            makeCall(sample: "DW472b", genotype: "12_M3_B_165_01", reads: 150),
            makeCall(sample: "DW472b", genotype: "12_M2_B_109_04", reads: 100),
            makeCall(sample: "DW472b", genotype: "12_M2_B_109_06", reads: 84),
            makeCall(sample: "DW472b", genotype: "12_M2_B_019_03", reads: 75),
            makeCall(sample: "DW472b", genotype: "12_M3_B_075_01", reads: 69),
            makeCall(sample: "DW472b", genotype: "12_M2_B_162", reads: 33),
            makeCall(sample: "DW472b", genotype: "12_M2_B_150_01_01", reads: 26),
            makeCall(sample: "DW472b", genotype: "12_M2M5_B_098g|B_098_01,_B_098_04", reads: 22),
            makeCall(sample: "DW472b", genotype: "12_M3_B_098_05", reads: 20),
            makeCall(sample: "DW472b", genotype: "12_M2M3_B_079g", reads: 15),
        ]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: calls,
            definitionSet: definitionSet,
            dropoutFilter: evaluator
        )
        let mhcB = try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-B" })

        XCTAssertEqual(mhcB.status, .called)
        XCTAssertEqual(mhcB.haplotype1, "M2B")
        XCTAssertEqual(mhcB.haplotype2, "M3B")
        XCTAssertEqual(mhcB.matchedHaplotypes.map(\.name), ["M2B", "M3B"])
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

    func testDropoutPreservesSupportedHaplotypeDiagnosticsAfterFilteringLowAlleles() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )
        let evaluator = GenotypeDropoutEvaluator(absolute: 50, sampleFraction: nil, locusFraction: 0.01)
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M2_B_019_03", reads: 123),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
            makeCall(sample: "DW472", genotype: "12_M3_B_098_05", reads: 58),
            makeCall(sample: "DW472", genotype: "12_M2_B_162", reads: 55),
            makeCall(sample: "DW472", genotype: "12_M2_B_150_01_01", reads: 52),
            makeCall(sample: "DW472", genotype: "12_M2_B_109_04", reads: 17),
            makeCall(sample: "DW472", genotype: "12_M1_B_134_02", reads: 1_551),
        ]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: calls,
            definitionSet: definitionSet,
            dropoutFilter: evaluator
        )
        let mhcB = try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-B" })

        XCTAssertEqual(mhcB.haplotype1, "M2B")
        XCTAssertEqual(mhcB.haplotype2, "M3B")
        XCTAssertEqual(mhcB.status, .called)
        XCTAssertEqual(mhcB.matchedHaplotypes.map(\.name), ["M2B", "M3B"])
    }

    func testDropoutDoesNotRetainIndividuallyLowDiagnosticAllelesByAggregateSupport() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )
        let evaluator = GenotypeDropoutEvaluator(absolute: 50, sampleFraction: nil, locusFraction: 0.05)
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M2_B_019_03", reads: 123),
            makeCall(sample: "DW472", genotype: "12_M2_B_162", reads: 55),
            makeCall(sample: "DW472", genotype: "12_M2_B_150_01_01", reads: 52),
            makeCall(sample: "DW472", genotype: "12_M2_B_109_04", reads: 17),
        ]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: calls,
            definitionSet: definitionSet,
            dropoutFilter: evaluator
        )
        let mhcB = try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-B" })
        let m2b = try XCTUnwrap(mhcB.matchedHaplotypes.first { $0.name == "M2B" })

        XCTAssertEqual(mhcB.status, .called)
        XCTAssertFalse(m2b.observedDiagnosticAlleles.contains("12_M2_B_109_04"))
        XCTAssertEqual(m2b.observedDiagnosticAlleles.sorted(), [
            "12_M2_B_019_03",
            "12_M2_B_150_01_01",
            "12_M2_B_162",
        ].sorted())
    }

    func testDropoutKeepsSampleVisibleWhenAllCallsAtObservedLocusAreLowSupport() throws {
        let definitionSet = GenotypeHaplotypeDefinitionSet(
            id: "test",
            assayID: "assay",
            displayName: "Test",
            speciesName: "Test species",
            speciesCode: "TEST",
            prefix: "M",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1B", diagnosticAlleles: ["12_M1_B_001_01"])
                    ]
                )
            ]
        )
        let evaluator = GenotypeDropoutEvaluator(absolute: 50, sampleFraction: nil, locusFraction: nil)

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [makeCall(sample: "DW472", genotype: "12_M1_B_001_01", reads: 10)],
            definitionSet: definitionSet,
            dropoutFilter: evaluator
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        XCTAssertEqual(sample.sample, "DW472")
        let mhcB = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-B" })
        XCTAssertEqual(mhcB.status, .noHaplotype)
        XCTAssertNotEqual(mhcB.status, .notAssayed)
    }

    func testDropoutPreservesDominantHomozygoteDiagnosticsAcrossSupportedFamilies() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )
        let evaluator = GenotypeDropoutEvaluator(absolute: 50, sampleFraction: nil, locusFraction: 0.05)
        let calls = [
            makeCall(sample: "DW474", genotype: "11_M1_E_02g3", reads: 2_030),
            makeCall(sample: "DW474", genotype: "04_M1_AG_05_3mis_156bp", reads: 253),
            makeCall(sample: "DW474", genotype: "02_M1_G_02_07_2mis_156bp", reads: 91),
            makeCall(sample: "DW474", genotype: "01_M1_F_01_w_06", reads: 55),
            makeCall(sample: "DW474", genotype: "02_M2_G_02_06_156bp", reads: 1),
        ]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: calls,
            definitionSet: definitionSet,
            dropoutFilter: evaluator
        )
        let mhcA = try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-A" })

        XCTAssertEqual(mhcA.haplotype1, "M1A")
        XCTAssertEqual(mhcA.haplotype2, "-")
        XCTAssertEqual(mhcA.status, .called)
        XCTAssertEqual(mhcA.matchedHaplotypes.map(\.name), ["M1A"])
    }

    func testMCMClassIObservedDiagnosticsDoNotAbsorbClassIIAlleles() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            )
        )
        let calls = [
            makeCall(sample: "DW474", genotype: "01_M1_F_01_w_06"),
            makeCall(sample: "DW474", genotype: "02_M1_G_02_07_2mis_156bp"),
            makeCall(sample: "DW474", genotype: "14_M2_DQA1_01_04"),
            makeCall(sample: "DW474", genotype: "15_M2_DPA1_07_01"),
        ]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definitionSet)
        let mhcA = try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-A" })

        XCTAssertEqual(mhcA.status, .called)
        XCTAssertEqual(mhcA.matchedHaplotypes.map(\.name), ["M1A"])
        XCTAssertEqual(mhcA.observedGenotypes, [
            "01_M1_F_01_w_06",
            "02_M1_G_02_07_2mis_156bp",
        ])
        XCTAssertFalse(mhcA.observedGenotypes.contains("14_M2_DQA1_01_04"))
        XCTAssertFalse(mhcA.observedGenotypes.contains("15_M2_DPA1_07_01"))
    }

    func testSpeciesPrefixedClassIIRawLociCanonicalizeForRhesus() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.rhesus-macaques"
            )
        )
        let dqaCall = makeCall(sample: "Rh01", genotype: "09_Mamu-DQA1_23_01")

        XCTAssertEqual(dqaCall.locusGroup, "MHC-MAMU-DQA1")
        XCTAssertEqual(
            GenotypeHaplotypeLocusResolver.canonicalLocus(for: dqaCall, definitionSet: definitionSet),
            "MHC-DQA"
        )
    }

    func testRhesusAGAliasesDoNotSupportClassicalADefinitions() throws {
        let definitionSet = try XCTUnwrap(
            GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(
                id: "MHC-exon2-miSeq.rhesus-macaques"
            )
        )
        let calls = [
            makeCall(
                sample: "Rh01",
                genotype: "01_Mamu-A1_999g|A1_999_01",
                reads: 600
            ),
            makeCall(
                sample: "Rh01",
                genotype: "15_Mamu-AG2_01g1|A1_006_02_01_01,A1_006_03",
                reads: 500
            )
        ]

        let analysis = GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definitionSet)
        let mhcA = try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-A" })

        XCTAssertEqual(mhcA.status, .noHaplotype)
        XCTAssertEqual(mhcA.matchedHaplotypes.map(\.name), [])
        XCTAssertEqual(mhcA.observedGenotypes, ["01_Mamu-A1_999g|A1_999_01"])
        XCTAssertFalse(mhcA.observedGenotypes.contains("15_Mamu-AG2_01g1|A1_006_02_01_01,A1_006_03"))
    }

    func testCohortWideUnobservedDefinitionLocusIsMarkedUnsupported() throws {
        let definitionSet = GenotypeHaplotypeDefinitionSet(
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
                    haplotypes: [GenotypeHaplotypeDefinition(name: "A1", diagnosticAlleles: ["A1"])]
                ),
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DPB",
                    sourceLocus: "Test-DPB",
                    haplotypes: [GenotypeHaplotypeDefinition(name: "DP1", diagnosticAlleles: ["DPB1_01"])]
                ),
            ]
        )
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                makeCall(sample: "Sample1", genotype: "01_Test-A1"),
                makeCall(sample: "Sample2", genotype: "01_Test-A1"),
            ],
            definitionSet: definitionSet
        )

        let dpbCalls = analysis.samples.compactMap { sample in
            sample.calls.first { $0.locus == "MHC-DPB" }
        }
        XCTAssertEqual(dpbCalls.map(\.status), [.notAssayed, .notAssayed])
        XCTAssertTrue(dpbCalls.allSatisfy { $0.notes.localizedCaseInsensitiveContains("not observed") })
    }

    func testHaplotypeDefinitionSaveWritesProvenanceSidecar() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = HaplotypeDefinitionStore(projectRoot: projectRoot)
        let set = GenotypeHaplotypeDefinitionSet(
            id: "test.definition",
            assayID: "test-assay",
            displayName: "Test Definition",
            speciesName: "Test species",
            speciesCode: "TEST",
            prefix: "M",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1A",
                            diagnosticAlleles: ["01_M1_A_001_01"],
                            colorTokenIndex: 0
                        )
                    ]
                )
            ]
        )

        try store.save(set, changeNote: "initial definition")

        let provenanceURL = try XCTUnwrap(store.provenanceURL(for: set.id))
        let provenance = try JSONDecoder().decode(
            HaplotypeDefinitionEditProvenance.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(provenance.workflowName, "Haplotype definition save")
        XCTAssertEqual(provenance.toolName, "Lungfish Genome Explorer")
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.options.explicit["definitionID"], "test.definition")
        XCTAssertEqual(provenance.options.resolvedDefaults["locusCount"], "1")
        XCTAssertEqual(provenance.outputs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenance.outputs[0].path))
        XCTAssertFalse(provenance.outputs[0].checksumSHA256.isEmpty)
        XCTAssertGreaterThan(provenance.outputs[0].fileSizeBytes, 0)
    }

    func testHaplotypeDefinitionDeleteWritesProvenanceTombstone() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = HaplotypeDefinitionStore(projectRoot: projectRoot)
        let set = GenotypeHaplotypeDefinitionSet(
            id: "test.definition",
            assayID: "test-assay",
            displayName: "Test Definition",
            speciesName: "Test species",
            speciesCode: "TEST",
            prefix: "M",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1A",
                            diagnosticAlleles: ["01_M1_A_001_01"],
                            colorTokenIndex: 0
                        )
                    ]
                )
            ]
        )
        try store.save(set, changeNote: "initial definition")

        try store.delete(id: set.id)

        let provenanceURL = try XCTUnwrap(store.provenanceURL(for: set.id))
        let provenance = try JSONDecoder().decode(
            HaplotypeDefinitionEditProvenance.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(provenance.workflowName, "Haplotype definition delete")
        XCTAssertEqual(provenance.options.explicit["definitionID"], "test.definition")
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.inputs.count, 1)
        XCTAssertTrue(provenance.outputs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: provenance.inputs[0].path))
        XCTAssertFalse(provenance.inputs[0].checksumSHA256.isEmpty)
    }

    func testHaplotypeDefinitionSaveRollsBackWhenProvenanceCannotBeWritten() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = HaplotypeDefinitionStore(projectRoot: projectRoot)
        let initial = makeDefinitionSet(displayName: "Initial Definition")
        try store.save(initial)

        let definitionURL = try XCTUnwrap(store.definitionURL(for: initial.id))
        let savedBefore = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(contentsOf: definitionURL)
        )
        let provenanceURL = try XCTUnwrap(store.provenanceURL(for: initial.id))
        try? FileManager.default.removeItem(at: provenanceURL)
        try FileManager.default.createDirectory(at: provenanceURL, withIntermediateDirectories: false)

        var updated = makeDefinitionSet(displayName: "Updated Definition")
        updated = GenotypeHaplotypeDefinitionSet(
            id: updated.id,
            assayID: updated.assayID,
            displayName: updated.displayName,
            speciesName: updated.speciesName,
            speciesCode: updated.speciesCode,
            prefix: updated.prefix,
            locusDefinitions: updated.locusDefinitions,
            schemaVersion: savedBefore.schemaVersion,
            lastModified: savedBefore.lastModified,
            changeNote: updated.changeNote
        )
        XCTAssertThrowsError(try store.save(updated))

        let restored = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(contentsOf: definitionURL)
        )
        XCTAssertEqual(restored.displayName, savedBefore.displayName)
        XCTAssertEqual(restored.schemaVersion, savedBefore.schemaVersion)
    }

    func testHaplotypeDefinitionDeleteRollsBackWhenProvenanceCannotBeWritten() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = HaplotypeDefinitionStore(projectRoot: projectRoot)
        let set = makeDefinitionSet(displayName: "Initial Definition")
        try store.save(set)

        let definitionURL = try XCTUnwrap(store.definitionURL(for: set.id))
        let savedBefore = try Data(contentsOf: definitionURL)
        let provenanceURL = try XCTUnwrap(store.provenanceURL(for: set.id))
        try? FileManager.default.removeItem(at: provenanceURL)
        try FileManager.default.createDirectory(at: provenanceURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.delete(id: set.id))

        XCTAssertTrue(FileManager.default.fileExists(atPath: definitionURL.path))
        XCTAssertEqual(try Data(contentsOf: definitionURL), savedBefore)
    }

    func testHaplotypeDefinitionLibraryMergesBuiltInGlobalAndProjectScopesWithPrecedence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionLibrary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let globalRoot = root.appendingPathComponent("global", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)

        let shadowedID = "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        let globalShadow = GenotypeHaplotypeDefinitionSet(
            id: shadowedID,
            assayID: "MHC-exon2-miSeq",
            displayName: "Global MCM Override",
            speciesName: "Mauritian cynomolgus macaques",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [GenotypeHaplotypeDefinition(name: "GLOBAL", diagnosticAlleles: ["global"])]
                )
            ]
        )
        let projectShadow = GenotypeHaplotypeDefinitionSet(
            id: shadowedID,
            assayID: "MHC-exon2-miSeq",
            displayName: "Project MCM Override",
            speciesName: "Mauritian cynomolgus macaques",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [GenotypeHaplotypeDefinition(name: "PROJECT", diagnosticAlleles: ["project"])]
                )
            ]
        )
        let globalUnique = makeDefinitionSet(displayName: "Global Unique Definition")

        try HaplotypeDefinitionStore(projectRoot: globalRoot).save(globalShadow)
        try HaplotypeDefinitionStore(projectRoot: globalRoot).save(globalUnique)
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(projectShadow)

        let library = HaplotypeDefinitionLibrary(projectRoot: projectRoot, globalRoot: globalRoot)
        let merged = library.mergedRegistry()
        let active = try XCTUnwrap(merged.definitionSet(id: shadowedID, assayID: "MHC-exon2-miSeq"))

        XCTAssertEqual(active.displayName, "Project MCM Override")
        XCTAssertEqual(
            merged.definitionSet(id: globalUnique.id, assayID: globalUnique.assayID)?.displayName,
            "Global Unique Definition"
        )

        let records = library.records()
        XCTAssertTrue(records.contains { $0.scope == .builtIn && $0.definitionSet.id == shadowedID && $0.isShadowed })
        XCTAssertTrue(records.contains { $0.scope == .global && $0.definitionSet.id == shadowedID && $0.isShadowed })
        XCTAssertTrue(records.contains { $0.scope == .project && $0.definitionSet.id == shadowedID && !$0.isShadowed })
    }

    func testHaplotypeDefinitionLibraryFiltersActiveRecordsByAssaySpeciesAndScope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionLibrary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let globalRoot = root.appendingPathComponent("global", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let projectDefinition = GenotypeHaplotypeDefinitionSet(
            id: "project.rhesus",
            assayID: "MHC-exon2-miSeq",
            displayName: "Project Rhesus",
            speciesName: "Rhesus macaques",
            speciesCode: "MAMU",
            prefix: "Mamu",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mamu-B",
                    haplotypes: [GenotypeHaplotypeDefinition(name: "B001", diagnosticAlleles: ["B_001"])]
                )
            ]
        )
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(projectDefinition)

        let library = HaplotypeDefinitionLibrary(projectRoot: projectRoot, globalRoot: globalRoot)
        let mamuProject = library.activeRecords(
            assayID: "MHC-exon2-miSeq",
            speciesCode: "MAMU",
            scope: .project
        )
        let mcmProject = library.activeRecords(
            assayID: "MHC-exon2-miSeq",
            speciesCode: "MCM",
            scope: .project
        )

        XCTAssertEqual(mamuProject.map(\.definitionSet.id), ["project.rhesus"])
        XCTAssertTrue(mcmProject.isEmpty)
        XCTAssertTrue(
            library.activeRecords(assayID: "MHC-exon2-miSeq", speciesCode: "MAMU", scope: nil)
                .contains { $0.definitionSet.id == "MHC-exon2-miSeq.rhesus-macaques" && $0.scope == .builtIn }
        )
    }

    func testHaplotypeDefinitionLibraryListsMHCReferenceBundleDefinitionsWhenRequested() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionLibrary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let globalRoot = root.appendingPathComponent("global", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project.lungfish", isDirectory: true)
        let bundleURL = projectRoot
            .appendingPathComponent("Reference allele databases", isDirectory: true)
            .appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        let definition = makeDefinitionSet(displayName: "Bundled MHC Definition")
        try writeMHCReferenceBundle(
            bundleURL: bundleURL,
            referenceContents: ">M1\nACGT\n",
            definition: definition
        )

        let library = HaplotypeDefinitionLibrary(projectRoot: projectRoot, globalRoot: globalRoot)

        XCTAssertFalse(library.records().contains { $0.referenceBundleURL == bundleURL.standardizedFileURL })
        let bundleRecord = try XCTUnwrap(
            library.records(includeReferenceBundles: true).first {
                $0.referenceBundleURL == bundleURL.standardizedFileURL
                    && $0.definitionSet.id == definition.id
            }
        )
        XCTAssertEqual(bundleRecord.referenceFASTAURL?.lastPathComponent, "reference.fa")
        XCTAssertEqual(bundleRecord.sourceDisplayName, "MHC Reference Bundle")
        XCTAssertFalse(bundleRecord.isShadowed)
    }

    func testActiveRecordsCanIncludeProjectMHCReferenceBundleDefinitions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionLibrary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let globalRoot = root.appendingPathComponent("global", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project.lungfish", isDirectory: true)
        let bundleURL = projectRoot
            .appendingPathComponent("Reference allele databases", isDirectory: true)
            .appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        let definition = makeDefinitionSet(displayName: "Bundled MHC Definition")
        try writeMHCReferenceBundle(
            bundleURL: bundleURL,
            referenceContents: ">M1\nACGT\n",
            definition: definition
        )

        let library = HaplotypeDefinitionLibrary(projectRoot: projectRoot, globalRoot: globalRoot)

        XCTAssertFalse(library.activeRecords().contains { $0.referenceBundleURL == bundleURL.standardizedFileURL })
        let activeWithBundles = library.activeRecords(
            assayID: definition.assayID,
            speciesCode: definition.speciesCode,
            includeReferenceBundles: true
        )
        XCTAssertTrue(activeWithBundles.contains { record in
            record.definitionSet.id == definition.id
                && record.referenceBundleURL == bundleURL.standardizedFileURL
                && record.sourceDisplayName == "MHC Reference Bundle"
        })
    }

    private func makeDefinitionSet(displayName: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: "test.definition",
            assayID: "test-assay",
            displayName: displayName,
            speciesName: "Test species",
            speciesCode: "TEST",
            prefix: "M",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1A",
                            diagnosticAlleles: ["01_M1_A_001_01"],
                            colorTokenIndex: 0
                        )
                    ]
                )
            ]
        )
    }

    private func writeMHCReferenceBundle(
        bundleURL: URL,
        referenceContents: String,
        definition: GenotypeHaplotypeDefinitionSet
    ) throws {
        let referenceURL = bundleURL.appendingPathComponent("reference.fa")
        let definitionURL = bundleURL.appendingPathComponent("haplotypes/test-definition.lungfishhaplotypedef.json")
        try FileManager.default.createDirectory(at: definitionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try referenceContents.write(to: referenceURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: definitionURL, options: .atomic)
        try MHCAmpliconReferenceBundle.writeManifest(
            MHCAmpliconReferenceBundleManifest(
                name: "MCM MHC",
                referenceFastaPath: "reference.fa",
                haplotypeDefinitionPaths: ["haplotypes/test-definition.lungfishhaplotypedef.json"],
                defaultHaplotypeDefinitionID: definition.id,
                metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 1),
                provenancePath: ".lungfish-provenance.json",
                createdAt: "2026-05-30T00:00:00Z"
            ),
            to: bundleURL
        )
    }

    private func makeCall(sample: String, genotype: String, reads: Int = 100) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }
}
