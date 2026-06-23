import XCTest
import LungfishIO

final class GenotypeHaplotypeAnalyzerTests: XCTestCase {
    func testCanonicalLocusNameNormalizesFullLengthMacaqueAlleles() {
        XCTAssertEqual(
            GenotypeHaplotypeLocusResolver.canonicalLocusName("Mamu-A1*004:01:01:01"),
            "MHC-A"
        )
        XCTAssertEqual(
            GenotypeHaplotypeLocusResolver.canonicalLocusName("Mamu-A4*14:03:01:01"),
            "MHC-A"
        )
        XCTAssertEqual(
            GenotypeHaplotypeLocusResolver.canonicalLocusName("Mamu-B02Ps*01:07:01:01"),
            "MHC-B"
        )
        XCTAssertEqual(
            GenotypeHaplotypeLocusResolver.canonicalLocusName("Mamu-AG3*02:06:02:01"),
            "MHC-AG"
        )
    }

    func testMCMAnalyzerOmitsMHCEFromDeterministicHaplotypeCalls() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "MHC-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1A",
                            diagnosticAlleles: ["M1A_marker"],
                            minimumMatches: 1
                        )
                    ]
                ),
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-E",
                    sourceLocus: "MHC-E",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1E",
                            diagnosticAlleles: ["M1E_marker"],
                            minimumMatches: 1
                        )
                    ]
                ),
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "M1A_marker", reads: 100),
                Self.call(sample: "LF0001", genotype: "M1E_marker", reads: 100),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        XCTAssertEqual(sample.calls.map(\.locus), ["MHC-A"])
    }

    func testMCMClassIIDPUsesLinkedDQToResolveM5M6Ambiguity() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DQ",
                    sourceLocus: "Mafa-DQ",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M6DQ",
                            diagnosticAlleles: ["14_M6_DQA1_01", "14_M6_DQB1_01"],
                            minimumMatches: 2
                        )
                    ]
                ),
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DP",
                    sourceLocus: "Mafa-DP",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M5/M6DP",
                            diagnosticAlleles: ["15_M5M6_DPA1_01", "15_M5M6_DPB1_01"],
                            minimumMatches: 2
                        )
                    ]
                ),
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "14_M6_DQA1_01", reads: 120),
                Self.call(sample: "LF0001", genotype: "14_M6_DQB1_01", reads: 110),
                Self.call(sample: "LF0001", genotype: "15_M5M6_DPA1_01", reads: 100),
                Self.call(sample: "LF0001", genotype: "15_M5M6_DPB1_01", reads: 90),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let dp = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-DP" })
        XCTAssertEqual(dp.haplotype1, "M6DP")
        XCTAssertEqual(dp.haplotype2, "-")
        XCTAssertEqual(dp.status, .called)
        XCTAssertTrue(dp.notes.contains("linked MHC-DQ"))
    }

    func testMCMClassIIDPUsesLinkedDQToResolveM4M7Ambiguity() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DQ",
                    sourceLocus: "Mafa-DQ",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M4DQ",
                            diagnosticAlleles: ["14_M4_DQA1_01_07_01", "14_M4_DQB1_06_08"],
                            minimumMatches: 2
                        )
                    ]
                ),
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DP",
                    sourceLocus: "Mafa-DP",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M4/M7DP",
                            diagnosticAlleles: ["15_M4M7_DPA1_04_01", "15_M4M7_DPB1_03_03"],
                            minimumMatches: 2
                        )
                    ]
                ),
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "14_M4_DQA1_01_07_01", reads: 120),
                Self.call(sample: "LF0001", genotype: "14_M4_DQB1_06_08", reads: 110),
                Self.call(sample: "LF0001", genotype: "15_M4M7_DPA1_04_01", reads: 100),
                Self.call(sample: "LF0001", genotype: "15_M4M7_DPB1_03_03", reads: 90),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let dp = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-DP" })
        XCTAssertEqual(dp.haplotype1, "M4DP")
        XCTAssertEqual(dp.haplotype2, "-")
        XCTAssertEqual(dp.status, .called)
        XCTAssertTrue(dp.notes.contains("linked MHC-DQ"))
    }

    func testMCMClassIIDPUsesLinkedDQToPruneConcreteM4M7Overcall() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DQ",
                    sourceLocus: "Mafa-DQ",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M4DQ",
                            diagnosticAlleles: ["14_M4_DQA1_01_07_01", "14_M4_DQB1_06_08"],
                            minimumMatches: 2
                        )
                    ]
                ),
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DP",
                    sourceLocus: "Mafa-DP",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M4DP",
                            diagnosticAlleles: ["15_M4M7_DPB1_03_03"],
                            minimumMatches: 1
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M7DP",
                            diagnosticAlleles: ["15_M4M7_DPB1_03_03"],
                            minimumMatches: 1
                        ),
                    ]
                ),
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "14_M4_DQA1_01_07_01", reads: 120),
                Self.call(sample: "LF0001", genotype: "14_M4_DQB1_06_08", reads: 110),
                Self.call(sample: "LF0001", genotype: "15_M4M7_DPB1_03_03", reads: 90),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let dp = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-DP" })
        XCTAssertEqual(dp.haplotype1, "M4DP")
        XCTAssertEqual(dp.haplotype2, "-")
        XCTAssertEqual(dp.status, .called)
        XCTAssertEqual(dp.matchedHaplotypes.map(\.name), ["M4DP"])
        XCTAssertTrue(dp.notes.contains("linked MHC-DQ"))
    }

    func testMCMADiagnosticsCanUseGAndAGGenotypes() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1A",
                            diagnosticAlleles: [
                                "02_M1_G_02_07_2mis_156bp",
                                "04_M1_AG_05_3mis_156bp",
                            ],
                            minimumMatches: 2
                        )
                    ]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "02_M1_G_02_07_2mis_156bp", reads: 50),
                Self.call(sample: "LF0001", genotype: "04_M1_AG_05_3mis_156bp", reads: 45),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let a = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-A" })
        XCTAssertEqual(a.haplotype1, "M1A")
        XCTAssertEqual(a.haplotype2, "-")
        XCTAssertEqual(a.status, .called)
    }

    func testNewReferenceHeaderHaplotypeGroupOverridesSourceLocusForMCMADiagnostics() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "MHC-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0010"],
                            minimumMatches: 1
                        )
                    ]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(
                    sample: "LF0001",
                    genotype: "MCM_MHC_MiSeq_0010|source_loci=MHC-E|haplotype_groups=MHC-A|haplotypes=M1|alleles=Mafa-E_02:19:01:01",
                    reads: 50
                )
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let a = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-A" })
        XCTAssertEqual(a.haplotype1, "M1")
        XCTAssertEqual(a.haplotype2, "-")
        XCTAssertEqual(a.status, .called)
        XCTAssertEqual(a.observedGenotypeCount, 1)
        XCTAssertFalse(a.notes.contains("not observed anywhere"))
    }

    func testDropoutThresholdOmitsLowSupportDiagnosticFromHaplotypeAssignmentOnly() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DQ",
                    sourceLocus: "Mafa-DQ",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1DQ",
                            diagnosticAlleles: [
                                "14_M1_DQA1_24_03",
                                "14_M1_DQB1_18_01_01",
                            ],
                            minimumMatches: 2
                        )
                    ]
                )
            ]
        )

        let calls = [
            Self.call(sample: "LF0001", genotype: "14_M1_DQA1_24_03", reads: 50),
            Self.call(sample: "LF0001", genotype: "14_M1_DQB1_18_01_01", reads: 3),
        ]
        let unfiltered = GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definition)
        let filtered = GenotypeHaplotypeAnalyzer.analyze(
            calls: calls,
            definitionSet: definition,
            dropoutFilter: GenotypeDropoutEvaluator(absolute: 10, sampleFraction: nil, locusFraction: nil)
        )

        let unfilteredDQ = try XCTUnwrap(unfiltered.samples.first?.calls.first { $0.locus == "MHC-DQ" })
        XCTAssertEqual(unfilteredDQ.haplotype1, "M1DQ")
        XCTAssertEqual(unfilteredDQ.status, .called)

        let filteredDQ = try XCTUnwrap(filtered.samples.first?.calls.first { $0.locus == "MHC-DQ" })
        XCTAssertEqual(filteredDQ.haplotype1, "ERR: NO HAP")
        XCTAssertEqual(filteredDQ.status, GenotypeHaplotypeCallStatus.noHaplotype)
        XCTAssertEqual(filteredDQ.observedGenotypes, ["14_M1_DQA1_24_03"])
    }

    func testMCMASingleSpecificGOrAGDiagnosticResolvesA1063UnderStrictDefinition() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1A",
                            diagnosticAlleles: [
                                "02_M1_G_02_07_2mis_156bp",
                                "04_M1_AG_05_3mis_156bp",
                            ],
                            minimumMatches: 2
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M3A",
                            diagnosticAlleles: [
                                "02_M3_G_02_03_5mis_156bp",
                                "02_M3_G_02_0508_g48c_156bp",
                            ],
                            minimumMatches: 2
                        )
                    ]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "05_M1M2M3_A1_063g", reads: 90),
                Self.call(sample: "LF0001", genotype: "04_M1_AG_05_3mis_156bp", reads: 40),
                Self.call(sample: "LF0002", genotype: "05_M1M2M3_A1_063g", reads: 90),
                Self.call(sample: "LF0002", genotype: "02_M3_G_02_0508_g48c_156bp", reads: 40),
            ],
            definitionSet: definition
        )

        let sample1 = try XCTUnwrap(analysis.samples.first { $0.sample == "LF0001" })
        let sample1A = try XCTUnwrap(sample1.calls.first { $0.locus == "MHC-A" })
        XCTAssertEqual(sample1A.haplotype1, "M1A")
        XCTAssertEqual(sample1A.haplotype2, "-")
        XCTAssertEqual(sample1A.status, .called)

        let sample2 = try XCTUnwrap(analysis.samples.first { $0.sample == "LF0002" })
        let sample2A = try XCTUnwrap(sample2.calls.first { $0.locus == "MHC-A" })
        XCTAssertEqual(sample2A.haplotype1, "M3A")
        XCTAssertEqual(sample2A.haplotype2, "-")
        XCTAssertEqual(sample2A.status, .called)
    }

    func testMCMARescueDoesNotCreateThirdHaplotypeWhenTwoStrictHaplotypesMatch() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M2A",
                            diagnosticAlleles: ["02_M2_G_02_06_156bp"],
                            minimumMatches: 1
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M3A",
                            diagnosticAlleles: [
                                "02_M3_G_02_03_5mis_156bp",
                                "02_M3_G_02_0508_g48c_156bp",
                            ],
                            minimumMatches: 2
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M5A",
                            diagnosticAlleles: ["05_M5_A1_033_01"],
                            minimumMatches: 1
                        ),
                    ]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "02_M2_G_02_06_156bp", reads: 50),
                Self.call(sample: "LF0001", genotype: "05_M5_A1_033_01", reads: 50),
                Self.call(sample: "LF0001", genotype: "02_M3_G_02_0508_g48c_156bp", reads: 28),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let a = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-A" })
        XCTAssertEqual(a.haplotype1, "M2A")
        XCTAssertEqual(a.haplotype2, "M5A")
        XCTAssertEqual(a.status, .called)
        XCTAssertEqual(a.matchedHaplotypes.map(\.name), ["M2A", "M5A"])
    }

    func testAnalyzerStripsBOMFromSampleIDs() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1B", diagnosticAlleles: ["03_M1_B_001"])
                    ]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "\u{FEFF}LF0001", genotype: "03_M1_B_001", reads: 50),
            ],
            definitionSet: definition
        )

        XCTAssertEqual(analysis.samples.map(\.sample), ["LF0001"])
        let sample = try XCTUnwrap(analysis.samples.first)
        let b = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-B" })
        XCTAssertEqual(b.haplotype1, "M1B")
    }

    func testDeterministicMCMCallUsesReadDominanceToPruneLowSupportThirdHaplotype() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1B", diagnosticAlleles: ["M1B_1", "M1B_2"], minimumMatches: 2),
                        GenotypeHaplotypeDefinition(name: "M2B", diagnosticAlleles: ["M2B_1", "M2B_2"], minimumMatches: 2),
                        GenotypeHaplotypeDefinition(name: "M3B", diagnosticAlleles: ["M3B_1", "M3B_2"], minimumMatches: 2),
                    ]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "M1B_1|haplotype_groups=MHC-B", reads: 600),
                Self.call(sample: "LF0001", genotype: "M1B_2|haplotype_groups=MHC-B", reads: 500),
                Self.call(sample: "LF0001", genotype: "M2B_1|haplotype_groups=MHC-B", reads: 550),
                Self.call(sample: "LF0001", genotype: "M2B_2|haplotype_groups=MHC-B", reads: 450),
                Self.call(sample: "LF0001", genotype: "M3B_1|haplotype_groups=MHC-B", reads: 40),
                Self.call(sample: "LF0001", genotype: "M3B_2|haplotype_groups=MHC-B", reads: 35),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let b = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-B" })
        XCTAssertEqual(b.haplotype1, "M1B")
        XCTAssertEqual(b.haplotype2, "M2B")
        XCTAssertEqual(b.status, .called)
        XCTAssertEqual(b.matchedHaplotypes.map(\.name), ["M1B", "M2B"])
        XCTAssertTrue(b.notes.contains("10x"))
    }

    func testDeterministicMCMCallKeepsTooManyHaplotypesWhenThirdSupportIsWithinTenFold() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1B", diagnosticAlleles: ["M1B_1", "M1B_2"], minimumMatches: 2),
                        GenotypeHaplotypeDefinition(name: "M2B", diagnosticAlleles: ["M2B_1", "M2B_2"], minimumMatches: 2),
                        GenotypeHaplotypeDefinition(name: "M3B", diagnosticAlleles: ["M3B_1", "M3B_2"], minimumMatches: 2),
                    ]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "M1B_1|haplotype_groups=MHC-B", reads: 600),
                Self.call(sample: "LF0001", genotype: "M1B_2|haplotype_groups=MHC-B", reads: 500),
                Self.call(sample: "LF0001", genotype: "M2B_1|haplotype_groups=MHC-B", reads: 550),
                Self.call(sample: "LF0001", genotype: "M2B_2|haplotype_groups=MHC-B", reads: 450),
                Self.call(sample: "LF0001", genotype: "M3B_1|haplotype_groups=MHC-B", reads: 70),
                Self.call(sample: "LF0001", genotype: "M3B_2|haplotype_groups=MHC-B", reads: 60),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let b = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-B" })
        XCTAssertEqual(b.status, .tooManyHaplotypes)
    }

    func testMHCBDominantCompleteHaplotypeSuppressesSingletonSecondHaplotype() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "MHC-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1B",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0073", "MCM_MHC_MiSeq_0065"],
                            minimumMatches: 2
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M4B",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0074"],
                            minimumMatches: 1
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M6B",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0125", "MCM_MHC_MiSeq_0097"],
                            minimumMatches: 2
                        ),
                    ]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF2830", genotype: "MCM_MHC_MiSeq_0073|source_loci=MHC-B|haplotype_groups=MHC-B", reads: 61),
                Self.call(sample: "LF2830", genotype: "MCM_MHC_MiSeq_0065|source_loci=MHC-B|haplotype_groups=MHC-B", reads: 28),
                Self.call(sample: "LF2830", genotype: "MCM_MHC_MiSeq_0074|source_loci=MHC-B|haplotype_groups=MHC-B", reads: 1),
                Self.call(sample: "LF2830", genotype: "MCM_MHC_MiSeq_0125|source_loci=MHC-B17|haplotype_groups=MHC-B", reads: 1),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let b = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-B" })
        XCTAssertEqual(b.haplotype1, "M1B")
        XCTAssertEqual(b.haplotype2, "-")
        XCTAssertEqual(b.status, .called)
        XCTAssertEqual(b.matchedHaplotypes.map(\.name), ["M1B"])
        XCTAssertTrue(b.notes.contains("singleton"))
    }

    func testMHCBHeterozygousCallIsNotCollapsedWhenIncompleteAlternativeHasSupport() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "MHC-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1B",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0073", "MCM_MHC_MiSeq_0065"],
                            minimumMatches: 2
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M4B",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0074"],
                            minimumMatches: 1
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M6B",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0125", "MCM_MHC_MiSeq_0097"],
                            minimumMatches: 2
                        ),
                    ]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF2858", genotype: "MCM_MHC_MiSeq_0073|source_loci=MHC-B|haplotype_groups=MHC-B", reads: 104),
                Self.call(sample: "LF2858", genotype: "MCM_MHC_MiSeq_0065|source_loci=MHC-B|haplotype_groups=MHC-B", reads: 28),
                Self.call(sample: "LF2858", genotype: "MCM_MHC_MiSeq_0125|source_loci=MHC-B17|haplotype_groups=MHC-B", reads: 42),
                Self.call(sample: "LF2858", genotype: "MCM_MHC_MiSeq_0074|source_loci=MHC-B|haplotype_groups=MHC-B", reads: 1),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let b = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-B" })
        XCTAssertEqual(b.haplotype1, "M1B")
        XCTAssertEqual(b.haplotype2, "M4B")
        XCTAssertEqual(b.status, .called)
        XCTAssertEqual(b.matchedHaplotypes.map(\.name), ["M1B", "M4B"])
    }

    func testDeterministicMCMClassIIDQDoesNotVetoDominantTopTwoWithLowSupportThirdGenotype() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DQ",
                    sourceLocus: "Mafa-DQ",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1DQ", diagnosticAlleles: ["MCM_MHC_MiSeq_0173"], minimumMatches: 1),
                        GenotypeHaplotypeDefinition(name: "M2DQ", diagnosticAlleles: ["MCM_MHC_MiSeq_0025"], minimumMatches: 1),
                        GenotypeHaplotypeDefinition(
                            name: "M4DQ",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0023", "MCM_MHC_MiSeq_0179"],
                            minimumMatches: 2
                        ),
                    ]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF2829", genotype: "MCM_MHC_MiSeq_0173|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 412),
                Self.call(sample: "LF2829", genotype: "MCM_MHC_MiSeq_0025|source_loci=MHC-DQA1|haplotype_groups=MHC-DQ", reads: 325),
                Self.call(sample: "LF2829", genotype: "MCM_MHC_MiSeq_0179|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 13),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let dq = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-DQ" })
        XCTAssertEqual(dq.haplotype1, "M1DQ")
        XCTAssertEqual(dq.haplotype2, "M2DQ")
        XCTAssertEqual(dq.status, .called)
        XCTAssertEqual(dq.matchedHaplotypes.map(\.name), ["M1DQ", "M2DQ"])
        XCTAssertFalse(dq.notes.contains("ERR"))
    }

    func testDeterministicMCMClassIIDPDoesNotCollapseDPAAndDPBIntoTooManyGenotypes() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DQ",
                    sourceLocus: "MHC-DQ",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1DQ",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0173"],
                            minimumMatches: 1
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M6DQ",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0022"],
                            minimumMatches: 1
                        ),
                    ]
                ),
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DP",
                    sourceLocus: "MHC-DP",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1DP",
                            diagnosticAlleles: [
                                "MCM_MHC_MiSeq_0007",
                                "MCM_MHC_MiSeq_0154",
                                "MCM_MHC_MiSeq_0173",
                            ],
                            minimumMatches: 3
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M5DP",
                            diagnosticAlleles: [
                                "MCM_MHC_MiSeq_0156",
                                "MCM_MHC_MiSeq_0024",
                                "MCM_MHC_MiSeq_0188",
                            ],
                            minimumMatches: 3
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M6DP",
                            diagnosticAlleles: [
                                "MCM_MHC_MiSeq_0156",
                                "MCM_MHC_MiSeq_0022",
                            ],
                            minimumMatches: 2
                        ),
                    ]
                ),
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF2824", genotype: "MCM_MHC_MiSeq_0173|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 637),
                Self.call(sample: "LF2824", genotype: "MCM_MHC_MiSeq_0022|source_loci=MHC-DQA1|haplotype_groups=MHC-DQ", reads: 608),
                Self.call(sample: "LF2824", genotype: "MCM_MHC_MiSeq_0154|source_loci=MHC-DPB1|haplotype_groups=MHC-DP", reads: 305),
                Self.call(sample: "LF2824", genotype: "MCM_MHC_MiSeq_0156|source_loci=MHC-DPB1|haplotype_groups=MHC-DP", reads: 169),
                Self.call(sample: "LF2824", genotype: "MCM_MHC_MiSeq_0007|source_loci=MHC-DPA1|haplotype_groups=MHC-DP", reads: 91),
                Self.call(sample: "LF2824", genotype: "MCM_MHC_MiSeq_0179|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 1),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let dp = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-DP" })
        XCTAssertEqual(dp.haplotype1, "M1DP")
        XCTAssertEqual(dp.haplotype2, "M6DP")
        XCTAssertEqual(dp.status, .called)
        XCTAssertEqual(dp.matchedHaplotypes.map(\.name), ["M1DP", "M6DP"])
    }

    func testClassIITMGUsesDominantCompleteHaplotypesWithoutCountingSharedResidualAlleles() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DP",
                    sourceLocus: "MHC-DP",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M2DP",
                            diagnosticAlleles: [
                                "MCM_MHC_MiSeq_0187",
                                "MCM_MHC_MiSeq_0153",
                                "MCM_MHC_MiSeq_0025",
                            ],
                            minimumMatches: 3
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M5DP",
                            diagnosticAlleles: [
                                "MCM_MHC_MiSeq_0156",
                                "MCM_MHC_MiSeq_0024",
                                "MCM_MHC_MiSeq_0188",
                            ],
                            minimumMatches: 3
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M6DP",
                            diagnosticAlleles: [
                                "MCM_MHC_MiSeq_0156",
                                "MCM_MHC_MiSeq_0022",
                            ],
                            minimumMatches: 2
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M1DP",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0154"],
                            minimumMatches: 1
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M4DP",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0179"],
                            minimumMatches: 1
                        ),
                    ]
                ),
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF2836", genotype: "MCM_MHC_MiSeq_0025|source_loci=MHC-DQA1|haplotype_groups=MHC-DQ", reads: 345),
                Self.call(sample: "LF2836", genotype: "MCM_MHC_MiSeq_0153|source_loci=MHC-DPB1|haplotype_groups=MHC-DP", reads: 240),
                Self.call(sample: "LF2836", genotype: "MCM_MHC_MiSeq_0156|source_loci=MHC-DPB1|haplotype_groups=MHC-DP", reads: 136),
                Self.call(sample: "LF2836", genotype: "MCM_MHC_MiSeq_0024|source_loci=MHC-DQA1|haplotype_groups=MHC-DQ", reads: 119),
                Self.call(sample: "LF2836", genotype: "MCM_MHC_MiSeq_0187|source_loci=MHC-DPA1|haplotype_groups=MHC-DP", reads: 84),
                Self.call(sample: "LF2836", genotype: "MCM_MHC_MiSeq_0188|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 9),
                Self.call(sample: "LF2836", genotype: "MCM_MHC_MiSeq_0154|source_loci=MHC-DPB1|haplotype_groups=MHC-DP", reads: 1),
                Self.call(sample: "LF2836", genotype: "MCM_MHC_MiSeq_0179|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 1),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let dp = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-DP" })
        XCTAssertEqual(dp.haplotype1, "M2DP")
        XCTAssertEqual(dp.haplotype2, "M5DP")
        XCTAssertEqual(dp.status, .called)
        XCTAssertEqual(dp.matchedHaplotypes.map(\.name), ["M2DP", "M5DP"])
        XCTAssertTrue(dp.notes.contains("residual"))
    }

    func testSupportOnlyMCMMarkerDoesNotCallHaplotypeByItself() throws {
        let definition = try Self.weightedMHCEDefinition()
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(
                    sample: "LF0001",
                    genotype: "MCM_MHC_MiSeq_0012|source_loci=MHC-E|haplotype_groups=MHC-E|haplotypes=M2,M3|evidence_classes=support_only_pseudogene_or_null",
                    reads: 100
                ),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        XCTAssertFalse(sample.calls.contains { $0.locus == "MHC-E" })
    }

    func testSupportOnlyMCMMarkerIsNotRequiredForPrimaryHaplotypeCall() throws {
        let definition = try Self.weightedMHCEDefinition()
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(
                    sample: "LF0001",
                    genotype: "MCM_MHC_MiSeq_0018|source_loci=MHC-E|haplotype_groups=MHC-E|haplotypes=M3|evidence_classes=primary_expressed",
                    reads: 80
                ),
                Self.call(
                    sample: "LF0001",
                    genotype: "MCM_MHC_MiSeq_0137|source_loci=MHC-E|haplotype_groups=MHC-E|haplotypes=M3|evidence_classes=primary_expressed",
                    reads: 70
                ),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        XCTAssertFalse(sample.calls.contains { $0.locus == "MHC-E" })
    }

    func testLinkedMCMAResolvesSupportOnlyM2EMarker() throws {
        let definition = try Self.linkedMHCAMHCEDefinition()
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "M2A_marker|haplotype_groups=MHC-A", reads: 120),
                Self.call(
                    sample: "LF0001",
                    genotype: "MCM_MHC_MiSeq_0012|source_loci=MHC-E|haplotype_groups=MHC-E|haplotypes=M2,M3|evidence_classes=support_only_pseudogene_or_null",
                    reads: 100
                ),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        XCTAssertNotNil(sample.calls.first { $0.locus == "MHC-A" })
        XCTAssertFalse(sample.calls.contains { $0.locus == "MHC-E" })
    }

    func testLinkedMCMAResolvesSupportOnlyM3EMarker() throws {
        let definition = try Self.linkedMHCAMHCEDefinition()
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "M3A_marker|haplotype_groups=MHC-A", reads: 120),
                Self.call(
                    sample: "LF0001",
                    genotype: "MCM_MHC_MiSeq_0012|source_loci=MHC-E|haplotype_groups=MHC-E|haplotypes=M2,M3|evidence_classes=support_only_pseudogene_or_null",
                    reads: 100
                ),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        XCTAssertNotNil(sample.calls.first { $0.locus == "MHC-A" })
        XCTAssertFalse(sample.calls.contains { $0.locus == "MHC-E" })
    }

    func testLinkedMCMADoesNotInventMHCEWithoutObservedMHCEEvidence() throws {
        let definition = try Self.linkedMHCAMHCEDefinition()
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "M2A_marker|haplotype_groups=MHC-A", reads: 120),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        XCTAssertNotNil(sample.calls.first { $0.locus == "MHC-A" })
        XCTAssertFalse(sample.calls.contains { $0.locus == "MHC-E" })
    }

    func testLinkedMCMADoesNotOverwriteDirectMHCEEvidence() throws {
        let definition = try Self.linkedMHCAMHCEDefinition()
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "M2A_marker|haplotype_groups=MHC-A", reads: 120),
                Self.call(
                    sample: "LF0001",
                    genotype: "MCM_MHC_MiSeq_0018|source_loci=MHC-E|haplotype_groups=MHC-E|haplotypes=M3|evidence_classes=primary_expressed",
                    reads: 80
                ),
                Self.call(
                    sample: "LF0001",
                    genotype: "MCM_MHC_MiSeq_0137|source_loci=MHC-E|haplotype_groups=MHC-E|haplotypes=M3|evidence_classes=primary_expressed",
                    reads: 70
                ),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        XCTAssertNotNil(sample.calls.first { $0.locus == "MHC-A" })
        XCTAssertFalse(sample.calls.contains { $0.locus == "MHC-E" })
    }

    func testLinkedMCMALeavesSupportOnlyMHCEAmbiguousWhenMHCADoesNotDisambiguate() throws {
        let definition = try Self.linkedMHCAMHCEDefinition()
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "M2A_marker|haplotype_groups=MHC-A", reads: 120),
                Self.call(sample: "LF0001", genotype: "M3A_marker|haplotype_groups=MHC-A", reads: 110),
                Self.call(
                    sample: "LF0001",
                    genotype: "MCM_MHC_MiSeq_0012|source_loci=MHC-E|haplotype_groups=MHC-E|haplotypes=M2,M3|evidence_classes=support_only_pseudogene_or_null",
                    reads: 100
                ),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        XCTAssertNotNil(sample.calls.first { $0.locus == "MHC-A" })
        XCTAssertFalse(sample.calls.contains { $0.locus == "MHC-E" })
    }

    func testMCMClassIIHaplotypeSlotsFollowClassIAndDRContiguity() throws {
        let definition = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(
                """
                {
                  "id": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
                  "assayID": "MHC-exon2-miSeq",
                  "displayName": "MCM test",
                  "speciesName": "Mauritian cynomolgus macaque",
                  "speciesCode": "MCM",
                  "prefix": "Mafa",
                  "locusDefinitions": [
                    {
                      "locus": "MHC-B",
                      "sourceLocus": "MHC-B",
                      "haplotypes": [
                        { "name": "M2B", "diagnosticAlleles": ["M2B_marker"], "minimumMatches": 1 },
                        { "name": "M4B", "diagnosticAlleles": ["M4B_marker"], "minimumMatches": 1 }
                      ]
                    },
                    {
                      "locus": "MHC-DR",
                      "sourceLocus": "MHC-DR",
                      "haplotypes": [
                        { "name": "M2DR", "diagnosticAlleles": ["M2DR_marker"], "minimumMatches": 1 },
                        { "name": "M4DR", "diagnosticAlleles": ["M4DR_marker"], "minimumMatches": 1 }
                      ]
                    },
                    {
                      "locus": "MHC-DQ",
                      "sourceLocus": "MHC-DQ",
                      "haplotypes": [
                        { "name": "M4DQ", "diagnosticAlleles": ["M4DQ_marker"], "minimumMatches": 1 },
                        { "name": "M2DQ", "diagnosticAlleles": ["M2DQ_marker"], "minimumMatches": 1 }
                      ]
                    },
                    {
                      "locus": "MHC-DP",
                      "sourceLocus": "MHC-DP",
                      "haplotypes": [
                        { "name": "M4DP", "diagnosticAlleles": ["M4DP_marker"], "minimumMatches": 1 },
                        { "name": "M2DP", "diagnosticAlleles": ["M2DP_marker"], "minimumMatches": 1 }
                      ]
                    }
                  ]
                }
                """.utf8
            )
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF2823", genotype: "M2B_marker|haplotype_groups=MHC-B", reads: 120),
                Self.call(sample: "LF2823", genotype: "M4B_marker|haplotype_groups=MHC-B", reads: 110),
                Self.call(sample: "LF2823", genotype: "M2DR_marker|haplotype_groups=MHC-DR", reads: 100),
                Self.call(sample: "LF2823", genotype: "M4DR_marker|haplotype_groups=MHC-DR", reads: 90),
                Self.call(sample: "LF2823", genotype: "M4DQ_marker|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 80),
                Self.call(sample: "LF2823", genotype: "M2DQ_marker|source_loci=MHC-DQA1|haplotype_groups=MHC-DQ", reads: 70),
                Self.call(sample: "LF2823", genotype: "M4DP_marker|source_loci=MHC-DPB1|haplotype_groups=MHC-DP", reads: 60),
                Self.call(sample: "LF2823", genotype: "M2DP_marker|source_loci=MHC-DPA1|haplotype_groups=MHC-DP", reads: 50),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let dq = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-DQ" })
        let dp = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-DP" })
        XCTAssertEqual(dq.haplotype1, "M2DQ")
        XCTAssertEqual(dq.haplotype2, "M4DQ")
        XCTAssertEqual(dq.matchedHaplotypes.map(\.name), ["M2DQ", "M4DQ"])
        XCTAssertEqual(dp.haplotype1, "M2DP")
        XCTAssertEqual(dp.haplotype2, "M4DP")
        XCTAssertEqual(dp.matchedHaplotypes.map(\.name), ["M2DP", "M4DP"])
        XCTAssertTrue(dq.notes.contains("MCM haplotype-slot contiguity"))
        XCTAssertTrue(dp.notes.contains("MCM haplotype-slot contiguity"))
    }

    func testMCMLowerNumberedHaplotypeIsH1WithoutLinkedAnchor() throws {
        let definition = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(
                """
                {
                  "id": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
                  "assayID": "MHC-exon2-miSeq",
                  "displayName": "MCM test",
                  "speciesName": "Mauritian cynomolgus macaque",
                  "speciesCode": "MCM",
                  "prefix": "Mafa",
                  "locusDefinitions": [
                    {
                      "locus": "MHC-DQ",
                      "sourceLocus": "MHC-DQ",
                      "haplotypes": [
                        { "name": "M2DQ", "diagnosticAlleles": ["M2DQ_marker"], "minimumMatches": 1 },
                        { "name": "M1DQ", "diagnosticAlleles": ["M1DQ_marker"], "minimumMatches": 1 }
                      ]
                    }
                  ]
                }
                """.utf8
            )
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "M2DQ_marker|source_loci=MHC-DQA1|haplotype_groups=MHC-DQ", reads: 120),
                Self.call(sample: "LF0001", genotype: "M1DQ_marker|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 110),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let dq = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-DQ" })
        XCTAssertEqual(dq.haplotype1, "M1DQ")
        XCTAssertEqual(dq.haplotype2, "M2DQ")
        XCTAssertEqual(dq.matchedHaplotypes.map(\.name), ["M1DQ", "M2DQ"])
    }

    func testReadDominanceDoesNotCallIncompletePrimaryHaplotypesFromSharedMCMAMarker() throws {
        let definition = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(
                """
                {
                  "id": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
                  "assayID": "MHC-exon2-miSeq",
                  "displayName": "MCM test",
                  "speciesName": "Mauritian cynomolgus macaque",
                  "speciesCode": "MCM",
                  "prefix": "Mafa",
                  "locusDefinitions": [
                    {
                      "locus": "MHC-A",
                      "sourceLocus": "Mafa-A",
                      "haplotypes": [
                        {
                          "name": "M1A",
                          "diagnosticAlleles": ["MCM_MHC_MiSeq_0068", "MCM_MHC_MiSeq_0129", "MCM_MHC_MiSeq_0079"],
                          "primaryAlleles": ["MCM_MHC_MiSeq_0068", "MCM_MHC_MiSeq_0129", "MCM_MHC_MiSeq_0079"],
                          "minimumMatches": 1
                        },
                        {
                          "name": "M2A",
                          "diagnosticAlleles": ["MCM_MHC_MiSeq_0068", "MCM_MHC_MiSeq_0129", "MCM_MHC_MiSeq_0145"],
                          "primaryAlleles": ["MCM_MHC_MiSeq_0068", "MCM_MHC_MiSeq_0129", "MCM_MHC_MiSeq_0145"],
                          "minimumMatches": 1
                        },
                        {
                          "name": "M3A",
                          "diagnosticAlleles": ["MCM_MHC_MiSeq_0068", "MCM_MHC_MiSeq_0127"],
                          "primaryAlleles": ["MCM_MHC_MiSeq_0068", "MCM_MHC_MiSeq_0127"],
                          "minimumMatches": 1
                        }
                      ]
                    }
                  ]
                }
                """.utf8
            )
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0001", genotype: "MCM_MHC_MiSeq_0068|source_loci=MHC-A1|haplotype_groups=MHC-A", reads: 1_000),
                Self.call(sample: "LF0001", genotype: "MCM_MHC_MiSeq_0129|source_loci=MHC-K|haplotype_groups=MHC-A", reads: 900),
                Self.call(sample: "LF0001", genotype: "MCM_MHC_MiSeq_0127|source_loci=MHC-K|haplotype_groups=MHC-A", reads: 20),
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let a = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-A" })
        XCTAssertEqual(a.status, .tooManyHaplotypes)
        XCTAssertTrue(a.haplotype1.contains("ERR: TMH"))
    }

    private static func call(sample: String, genotype: String, reads: Int) -> ONTGenotypeCall {
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

    private static func weightedMHCEDefinition() throws -> GenotypeHaplotypeDefinitionSet {
        try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(
                """
                {
                  "id": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
                  "assayID": "MHC-exon2-miSeq",
                  "displayName": "MCM test",
                  "speciesName": "Mauritian cynomolgus macaque",
                  "speciesCode": "MCM",
                  "prefix": "Mafa",
                  "locusDefinitions": [
                    {
                      "locus": "MHC-E",
                      "sourceLocus": "MHC-E",
                      "haplotypes": [
                        {
                          "name": "M2E",
                          "diagnosticAlleles": ["MCM_MHC_MiSeq_0012"],
                          "evidenceWeights": {
                            "MCM_MHC_MiSeq_0012": 0.25
                          },
                          "minimumMatches": 1
                        },
                        {
                          "name": "M3E",
                          "diagnosticAlleles": [
                            "MCM_MHC_MiSeq_0018",
                            "MCM_MHC_MiSeq_0137",
                            "MCM_MHC_MiSeq_0012"
                          ],
                          "evidenceWeights": {
                            "MCM_MHC_MiSeq_0018": 1.0,
                            "MCM_MHC_MiSeq_0137": 1.0,
                            "MCM_MHC_MiSeq_0012": 0.25
                          },
                          "minimumMatches": 3
                        }
                      ]
                    }
                  ]
                }
                """.utf8
            )
        )
    }

    private static func linkedMHCAMHCEDefinition() throws -> GenotypeHaplotypeDefinitionSet {
        try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(
                """
                {
                  "id": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
                  "assayID": "MHC-exon2-miSeq",
                  "displayName": "MCM test",
                  "speciesName": "Mauritian cynomolgus macaque",
                  "speciesCode": "MCM",
                  "prefix": "Mafa",
                  "locusDefinitions": [
                    {
                      "locus": "MHC-A",
                      "sourceLocus": "MHC-A",
                      "haplotypes": [
                        {
                          "name": "M2A",
                          "diagnosticAlleles": ["M2A_marker"],
                          "minimumMatches": 1
                        },
                        {
                          "name": "M3A",
                          "diagnosticAlleles": ["M3A_marker"],
                          "minimumMatches": 1
                        }
                      ]
                    },
                    {
                      "locus": "MHC-E",
                      "sourceLocus": "MHC-E",
                      "haplotypes": [
                        {
                          "name": "M2E",
                          "diagnosticAlleles": ["MCM_MHC_MiSeq_0012"],
                          "evidenceWeights": {
                            "MCM_MHC_MiSeq_0012": 0.25
                          },
                          "minimumMatches": 1
                        },
                        {
                          "name": "M3E",
                          "diagnosticAlleles": [
                            "MCM_MHC_MiSeq_0018",
                            "MCM_MHC_MiSeq_0137",
                            "MCM_MHC_MiSeq_0012"
                          ],
                          "evidenceWeights": {
                            "MCM_MHC_MiSeq_0018": 1.0,
                            "MCM_MHC_MiSeq_0137": 1.0,
                            "MCM_MHC_MiSeq_0012": 0.25
                          },
                          "minimumMatches": 3
                        }
                      ]
                    }
                  ]
                }
                """.utf8
            )
        )
    }
}
