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
        XCTAssertEqual(
            GenotypeHaplotypeLocusResolver.canonicalLocusName("01_Mamu-A1*004:01:01:01"),
            "MHC-A"
        )
    }

    func testDiagnosticMatcherIgnoresLeadingNumericRunPrefix() {
        XCTAssertTrue(
            GenotypeHaplotypeDiagnosticMatcher.matches(
                genotype: "M1_G_02_07_2mis_156bp",
                diagnosticAllele: "02_M1_G_02_07_2mis_156bp"
            )
        )
    }

    func testAnalyzerMatchesDiagnosticAlleleAcrossLeadingNumericRunPrefix() throws {
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
                            diagnosticAlleles: ["02_M1_G_02_07_2mis_156bp"],
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
                    genotype: "M1_G_02_07_2mis_156bp|haplotype_groups=MHC-A",
                    reads: 42
                )
            ],
            definitionSet: definition
        )

        let sample = try XCTUnwrap(analysis.samples.first)
        let a = try XCTUnwrap(sample.calls.first { $0.locus == "MHC-A" })
        XCTAssertEqual(a.status, .called)
        XCTAssertEqual(a.haplotype1, "M1A")
        XCTAssertEqual(a.haplotype2, "-")
        XCTAssertEqual(a.matchedHaplotypes.map(\.name), ["M1A"])
    }

    func testAssociatedOnlyObservationDoesNotCauseHaplotypeCall() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "test",
            assayID: "test",
            displayName: "Test",
            speciesName: "Test",
            speciesCode: "TEST",
            prefix: "Test",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "MHC-A",
                    haplotypes: [GenotypeHaplotypeDefinition(
                        name: "H1",
                        diagnosticAlleles: ["diagnostic"],
                        associatedAlleles: ["associated"],
                        minimumMatches: 1
                    )]
                )
            ]
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [Self.call(sample: "S1", genotype: "associated|haplotype_groups=MHC-A", reads: 10)],
            definitionSet: definition
        )

        let call = try XCTUnwrap(analysis.samples.first?.calls.first)
        XCTAssertEqual(call.status, .noHaplotype)
        XCTAssertTrue(call.matchedHaplotypes.isEmpty)
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

    func testDropoutThresholdCollapsesVeryWeakHeterozygousTailToSingleHaplotypeCall() throws {
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DR",
                    sourceLocus: "MHC-DR",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1DR",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0169", "MCM_MHC_MiSeq_0166"],
                            minimumMatches: 2
                        ),
                        GenotypeHaplotypeDefinition(
                            name: "M5DR",
                            diagnosticAlleles: ["MCM_MHC_MiSeq_0175"],
                            minimumMatches: 1
                        ),
                    ]
                )
            ]
        )

        let calls = [
            Self.call(sample: "DW474b", genotype: "MCM_MHC_MiSeq_0169|haplotype_groups=MHC-DR", reads: 1_800),
            Self.call(sample: "DW474b", genotype: "MCM_MHC_MiSeq_0166|haplotype_groups=MHC-DR", reads: 1_646),
            Self.call(sample: "DW474b", genotype: "MCM_MHC_MiSeq_0175|haplotype_groups=MHC-DR", reads: 3),
        ]

        let unfiltered = GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definition)
        let filtered = GenotypeHaplotypeAnalyzer.analyze(
            calls: calls,
            definitionSet: definition,
            dropoutFilter: GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: 0.01)
        )

        let unfilteredDR = try XCTUnwrap(unfiltered.samples.first?.calls.first { $0.locus == "MHC-DR" })
        XCTAssertEqual(unfilteredDR.haplotype1, "M1DR")
        XCTAssertEqual(unfilteredDR.haplotype2, "M5DR")
        XCTAssertEqual(unfilteredDR.status, .called)

        let filteredDR = try XCTUnwrap(filtered.samples.first?.calls.first { $0.locus == "MHC-DR" })
        XCTAssertEqual(filteredDR.haplotype1, "M1DR")
        XCTAssertEqual(filteredDR.haplotype2, "-")
        XCTAssertEqual(filteredDR.status, .called)
        XCTAssertEqual(filteredDR.observedGenotypes, [
            "MCM_MHC_MiSeq_0166|haplotype_groups=MHC-DR",
            "MCM_MHC_MiSeq_0169|haplotype_groups=MHC-DR",
        ])
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

    func testMCMIntactHaplotypeIsH1BeforeRecombinantRegardlessOfFamilyNumber() throws {
        let definition = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(
                """
                {
                  "id": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques.intact-first",
                  "assayID": "MHC-exon2-miSeq",
                  "displayName": "MCM intact-first test",
                  "speciesName": "Mauritian cynomolgus macaque",
                  "speciesCode": "MCM",
                  "prefix": "Mafa",
                  "locusDefinitions": [{
                    "locus": "MHC-DQ",
                    "sourceLocus": "MHC-DQ",
                    "haplotypes": [
                      { "name": "recM1M2DQ", "diagnosticAlleles": ["rec_marker"], "minimumMatches": 1 },
                      { "name": "M3DQ", "diagnosticAlleles": ["M3_marker"], "minimumMatches": 1 }
                    ]
                  }]
                }
                """.utf8
            )
        )

        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "LF0002", genotype: "rec_marker|source_loci=MHC-DQA1|haplotype_groups=MHC-DQ", reads: 120),
                Self.call(sample: "LF0002", genotype: "M3_marker|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 110),
            ],
            definitionSet: definition
        )

        let dq = try XCTUnwrap(analysis.samples.first?.calls.first)
        XCTAssertEqual(dq.haplotype1, "M3DQ")
        XCTAssertEqual(dq.haplotype2, "recM1M2DQ")
        XCTAssertEqual(dq.matchedHaplotypes.map(\.name), ["M3DQ", "recM1M2DQ"])
    }

    func testMCMIntactFamilyStaysH1AcrossRecombinantRegions() throws {
        let sample = try analyzeMCMFamilyPairs([[1, 2], [1, 2], [2, 3], [2, 3], [2, 3]])
        XCTAssertEqual(sample.calls.map(\.haplotype1), ["M2A", "M2B", "M2DR", "M2DQ", "M2DP"])
        XCTAssertEqual(sample.calls.map(\.haplotype2), ["M1A", "M1B", "M3DR", "M3DQ", "M3DP"])
        XCTAssertEqual(sample.calls[0].matchedHaplotypes.map(\.name), ["M2A", "M1A"])
    }

    func testFalsePositiveRecomputesFromRemainingReferenceDiagnostics() throws {
        // Shared DQB evidence is not the reference's defining M2 diagnostic:
        // its independent DQA marker must remain authoritative until reviewed.
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "mcm-dq-review", assayID: "MHC-exon2-miSeq", displayName: "DQ review",
            speciesName: "Mauritian cynomolgus macaque", speciesCode: "MCM", prefix: "Mafa",
            locusDefinitions: [.init(locus: "MHC-DQ", sourceLocus: "MHC-DQ", haplotypes: [
                .init(name: "M2DQ", diagnosticAlleles: ["M2_DQA_marker"]),
                .init(name: "M4DQ", diagnosticAlleles: ["M4_DQA_marker", "M4_DQB_marker"]),
            ])]
        )
        let m2DQA = Self.call(sample: "sample", genotype: "M2_DQA_marker|source_loci=MHC-DQA1|haplotype_groups=MHC-DQ", reads: 1)
        let m2DQB = Self.call(sample: "sample", genotype: "shared_M2_M6_DQB_marker|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 1)
        let calls = [
            m2DQA, m2DQB,
            Self.call(sample: "sample", genotype: "M4_DQA_marker|source_loci=MHC-DQA1|haplotype_groups=MHC-DQ", reads: 796),
            Self.call(sample: "sample", genotype: "M4_DQB_marker|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ", reads: 54),
        ]
        func falsePositive(_ call: ONTGenotypeCall) -> GenotypeAnnotationSidecar.MatrixReviewAnnotation {
            .init(target: .cell(locus: call.locusGroup, genotype: call.genotype, sample: call.sample),
                  disposition: .falsePositive, author: "analyst", timestamp: "2026-09-11T00:00:00Z")
        }
        let dqAfterSharedReview = try XCTUnwrap(GenotypeHaplotypeAnalyzer.analyze(
            calls: calls, definitionSet: definition, generatedAt: nil, dropoutFilter: nil,
            matrixReviews: [falsePositive(m2DQB)]
        ).samples.first?.calls.first)
        XCTAssertEqual(dqAfterSharedReview.matchedHaplotypes.map(\.name), ["M2DQ", "M4DQ"])
        XCTAssertFalse(dqAfterSharedReview.observedGenotypes.contains(m2DQB.genotype))
        XCTAssertTrue(dqAfterSharedReview.observedGenotypes.contains(m2DQA.genotype))

        let dqAfterDiagnosticReview = try XCTUnwrap(GenotypeHaplotypeAnalyzer.analyze(
            calls: calls, definitionSet: definition, generatedAt: nil, dropoutFilter: nil,
            matrixReviews: [falsePositive(m2DQB), falsePositive(m2DQA)]
        ).samples.first?.calls.first)
        XCTAssertEqual(dqAfterDiagnosticReview.haplotype1, "M4DQ")
        XCTAssertEqual(dqAfterDiagnosticReview.haplotype2, "-")
        XCTAssertEqual(dqAfterDiagnosticReview.observedGenotypeCount, 2)
    }

    func testMCMSingleHaplotypeRegionsAnchorIntactH1() throws {
        for (pairs, expectedH1) in [
            ([[2], [2], [1, 2], [1, 2], [1, 2]], ["M2A", "M2B", "M2DR", "M2DQ", "M2DP"]),
            ([[3], [1, 3], [1, 3], [1, 3], [1, 3]], ["M3A", "M3B", "M3DR", "M3DQ", "M3DP"]),
            ([[1, 2], [1, 2], [2], [2], [2]], ["M2A", "M2B", "M2DR", "M2DQ", "M2DP"]),
            ([[2, 4], [4], [4], [4], [4]], ["M4A", "M4B", "M4DR", "M4DQ", "M4DP"]),
        ] {
            let sample = try analyzeMCMFamilyPairs(pairs)
            XCTAssertEqual(sample.calls.map(\.haplotype1), expectedH1)
            for (index, families) in pairs.enumerated() where families.count == 1 {
                XCTAssertEqual(sample.calls[index].haplotype2, "-", "Do not synthesize a second call")
            }
        }
    }

    func testMCMTwoIntactFamiliesUseNumericOrderAndNoIntactFamilyUsesLocalFallback() throws {
        let twoIntact = try analyzeMCMFamilyPairs([[4, 3], [4, 3], [4, 3], [4, 3], [4, 3]])
        XCTAssertEqual(twoIntact.calls.map(\.haplotype1), ["M3A", "M3B", "M3DR", "M3DQ", "M3DP"])
        let noIntact = try analyzeMCMFamilyPairs([[1], [1], [5, 2], [5, 2], [5, 2]])
        XCTAssertEqual(noIntact.calls.map(\.haplotype1), ["M1A", "M1B", "M2DR", "M2DQ", "M2DP"])
    }

    private func analyzeMCMFamilyPairs(_ pairs: [[Int]]) throws -> GenotypeHaplotypeSampleAnalysis {
        let suffixes = ["A", "B", "DR", "DQ", "DP"]
        let definitions = zip(suffixes, pairs).map { suffix, families in
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-\(suffix)", sourceLocus: "MHC-\(suffix)",
                haplotypes: families.map { family in
                    .init(name: "M\(family)\(suffix)", diagnosticAlleles: ["M\(family)\(suffix)_marker"])
                }
            )
        }
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "mcm-biomerelike", assayID: "MHC-exon2-miSeq", displayName: "MCM regions",
            speciesName: "Mauritian cynomolgus macaque", speciesCode: "MCM", prefix: "Mafa",
            locusDefinitions: definitions
        )
        let calls = zip(suffixes, pairs).flatMap { suffix, families in
            families.map { family in
                Self.call(sample: "cohort-sample", genotype: "M\(family)\(suffix)_marker|haplotype_groups=MHC-\(suffix)", reads: 100)
            }
        }
        return try XCTUnwrap(GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definition).samples.first)
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

    // MARK: - GEN-02 (2026-09-23 best-practices audit)

    /// Loads the shipped MCM MiSeq haplotype definition set exactly as the
    /// app ships it, from `Sources/LungfishWorkflow/Resources/MCMHaplotyping`.
    /// `LungfishIOTests` has no dependency on `LungfishWorkflow`, so this
    /// reads the file directly by its known repo-relative path (the same
    /// pattern `GenBankReaderTests` uses for reading Swift source as a
    /// fixture), rather than adding a cross-module resource dependency for
    /// one test.
    private static func shippedMCMDefinitionSet() throws -> GenotypeHaplotypeDefinitionSet {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/LungfishWorkflow/Resources/MCMHaplotyping/MCM-MHC-miSeq-20260617.lungfishmhcref/haplotypes/mcm-mhc-miseq-20260617.lungfishhaplotypedef.json"
            )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: data)
    }

    // MARK: - GEN-02 golden table (all 28 genotypes per MCM locus)

    /// One outcome per synthetic genotype: "status h1 / h2".
    static func shippedMCMGoldenOutcomes(
        loci: [String] = ["MHC-A", "MHC-B", "MHC-DP", "MHC-DQ", "MHC-DR"]
    ) throws -> [(key: String, outcome: String)] {
        let definitionSet = try shippedMCMDefinitionSet()
        let headers = try shippedMCMReferenceHeadersByID()
        var rows: [(key: String, outcome: String)] = []
        for locusDefinition in definitionSet.locusDefinitions where loci.contains(locusDefinition.locus) {
            let haplotypes = locusDefinition.haplotypes
            for i in 0..<haplotypes.count {
                for j in i..<haplotypes.count {
                    let first = haplotypes[i]
                    let second = haplotypes[j]
                    var observedAlleles: [String] = []
                    for haplotype in [first, second] {
                        for allele in haplotype.diagnosticAlleles where !observedAlleles.contains(allele) {
                            observedAlleles.append(allele)
                        }
                    }
                    // 100 reads per diagnostic allele per haplotype copy.
                    let calls = observedAlleles.map { allele -> ONTGenotypeCall in
                        let copies = [first, second].filter { $0.diagnosticAlleles.contains(allele) }.count
                        return call(
                            sample: "LF0001",
                            genotype: headers[allele] ?? "\(allele)|haplotype_groups=\(locusDefinition.sourceLocus)",
                            reads: 100 * copies
                        )
                    }
                    let analysis = GenotypeHaplotypeAnalyzer.analyze(
                        calls: calls,
                        definitionSet: GenotypeHaplotypeDefinitionSet(
                            id: definitionSet.id,
                            assayID: definitionSet.assayID,
                            displayName: definitionSet.displayName,
                            speciesName: definitionSet.speciesName,
                            speciesCode: definitionSet.speciesCode,
                            prefix: definitionSet.prefix,
                            locusDefinitions: [locusDefinition]
                        )
                    )
                    let locusCall = analysis.samples.first?.calls.first { $0.locus == locusDefinition.locus }
                    let outcome = locusCall.map { "\($0.status.rawValue) \($0.haplotype1) / \($0.haplotype2)" } ?? "missing"
                    rows.append((key: "\(locusDefinition.locus) \(first.name)/\(second.name)", outcome: outcome))
                }
            }
        }
        return rows
    }

    /// Maps each shipped MCM reference ID to its full FASTA header (the
    /// genotype label the pipeline reports), so synthetic calls carry the
    /// real `source_loci` metadata the class II TMG rule groups by.
    static func shippedMCMReferenceHeadersByID() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/LungfishWorkflow/Resources/MCMHaplotyping/MCM-MHC-miSeq-20260617.lungfishmhcref/mcm_mhc_miseq_reference.trimmed.unique.fasta"
            )
        let text = try String(contentsOf: url, encoding: .utf8)
        var headers: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix(">") {
            let header = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            let id = header.split(separator: "|", maxSplits: 1).first.map(String.init) ?? header
            headers[id] = header
        }
        return headers
    }

    /// GEN-02 (D11) golden: every homozygous and heterozygous genotype
    /// (28 per locus) at MCM MHC-DP, DQ and DR, synthesized from the
    /// shipped definition and reference headers (100 reads per diagnostic
    /// allele per haplotype copy) and run through the real analyzer.
    ///
    /// Before the D11 rule (pre-audit): DQ M2/M2 and M6/M6 were called
    /// "M2 / M6", DR M4/M4 and M5/M5 "M4 / M5", DP M4/M4 and M7/M7
    /// "M4 / M7". The interim mitigation turned those six into
    /// `ambiguous`. Now DQ and DR are 28/28 correct (homozygotes carry the
    /// "-" second-haplotype placeholder that displays as "M2 / M2"), and
    /// every DP genotype involving the identical definitions M4/M7 or
    /// M5/M6 is an explicit ambiguity token.
    func testMCMShippedDefinitionClassIIGoldenGenotypeTable() throws {
        let expected: [String: String] = [
            "MHC-DP M1/M1": "called M1 / -",
            "MHC-DP M1/M2": "called M1 / M2",
            "MHC-DP M1/M3": "called M1 / M3",
            "MHC-DP M1/M4": "ambiguous M1 / M4|M7",
            "MHC-DP M1/M5": "ambiguous M1 / M5|M6",
            "MHC-DP M1/M6": "ambiguous M1 / M5|M6",
            "MHC-DP M1/M7": "ambiguous M1 / M4|M7",
            "MHC-DP M2/M2": "called M2 / -",
            "MHC-DP M2/M3": "called M2 / M3",
            "MHC-DP M2/M4": "ambiguous M2 / M4|M7",
            "MHC-DP M2/M5": "ambiguous M2 / M5|M6",
            "MHC-DP M2/M6": "ambiguous M2 / M5|M6",
            "MHC-DP M2/M7": "ambiguous M2 / M4|M7",
            "MHC-DP M3/M3": "called M3 / -",
            "MHC-DP M3/M4": "ambiguous M3 / M4|M7",
            "MHC-DP M3/M5": "ambiguous M3 / M5|M6",
            "MHC-DP M3/M6": "ambiguous M3 / M5|M6",
            "MHC-DP M3/M7": "ambiguous M3 / M4|M7",
            "MHC-DP M4/M4": "ambiguous M4|M7 / M4|M7",
            "MHC-DP M4/M5": "ambiguous M4|M7 / M5|M6",
            "MHC-DP M4/M6": "ambiguous M4|M7 / M5|M6",
            "MHC-DP M4/M7": "ambiguous M4|M7 / M4|M7",
            "MHC-DP M5/M5": "ambiguous M5|M6 / M5|M6",
            "MHC-DP M5/M6": "ambiguous M5|M6 / M5|M6",
            "MHC-DP M5/M7": "ambiguous M4|M7 / M5|M6",
            "MHC-DP M6/M6": "ambiguous M5|M6 / M5|M6",
            "MHC-DP M6/M7": "ambiguous M4|M7 / M5|M6",
            "MHC-DP M7/M7": "ambiguous M4|M7 / M4|M7",
            "MHC-DQ M1/M1": "called M1 / -",
            "MHC-DQ M1/M2": "called M1 / M2",
            "MHC-DQ M1/M3": "called M1 / M3",
            "MHC-DQ M1/M4": "called M1 / M4",
            "MHC-DQ M1/M5": "called M1 / M5",
            "MHC-DQ M1/M6": "called M1 / M6",
            "MHC-DQ M1/M7": "called M1 / M7",
            "MHC-DQ M2/M2": "called M2 / -",
            "MHC-DQ M2/M3": "called M2 / M3",
            "MHC-DQ M2/M4": "called M2 / M4",
            "MHC-DQ M2/M5": "called M2 / M5",
            "MHC-DQ M2/M6": "called M2 / M6",
            "MHC-DQ M2/M7": "called M2 / M7",
            "MHC-DQ M3/M3": "called M3 / -",
            "MHC-DQ M3/M4": "called M3 / M4",
            "MHC-DQ M3/M5": "called M3 / M5",
            "MHC-DQ M3/M6": "called M3 / M6",
            "MHC-DQ M3/M7": "called M3 / M7",
            "MHC-DQ M4/M4": "called M4 / -",
            "MHC-DQ M4/M5": "called M4 / M5",
            "MHC-DQ M4/M6": "called M4 / M6",
            "MHC-DQ M4/M7": "called M4 / M7",
            "MHC-DQ M5/M5": "called M5 / -",
            "MHC-DQ M5/M6": "called M5 / M6",
            "MHC-DQ M5/M7": "called M5 / M7",
            "MHC-DQ M6/M6": "called M6 / -",
            "MHC-DQ M6/M7": "called M6 / M7",
            "MHC-DQ M7/M7": "called M7 / -",
            "MHC-DR M1/M1": "called M1 / -",
            "MHC-DR M1/M2": "called M1 / M2",
            "MHC-DR M1/M3": "called M1 / M3",
            "MHC-DR M1/M4": "called M1 / M4",
            "MHC-DR M1/M5": "called M1 / M5",
            "MHC-DR M1/M6": "called M1 / M6",
            "MHC-DR M1/M7": "called M1 / M7",
            "MHC-DR M2/M2": "called M2 / -",
            "MHC-DR M2/M3": "called M2 / M3",
            "MHC-DR M2/M4": "called M2 / M4",
            "MHC-DR M2/M5": "called M2 / M5",
            "MHC-DR M2/M6": "called M2 / M6",
            "MHC-DR M2/M7": "called M2 / M7",
            "MHC-DR M3/M3": "called M3 / -",
            "MHC-DR M3/M4": "called M3 / M4",
            "MHC-DR M3/M5": "called M3 / M5",
            "MHC-DR M3/M6": "called M3 / M6",
            "MHC-DR M3/M7": "called M3 / M7",
            "MHC-DR M4/M4": "called M4 / -",
            "MHC-DR M4/M5": "called M4 / M5",
            "MHC-DR M4/M6": "called M4 / M6",
            "MHC-DR M4/M7": "called M4 / M7",
            "MHC-DR M5/M5": "called M5 / -",
            "MHC-DR M5/M6": "called M5 / M6",
            "MHC-DR M5/M7": "called M5 / M7",
            "MHC-DR M6/M6": "called M6 / -",
            "MHC-DR M6/M7": "called M6 / M7",
            "MHC-DR M7/M7": "called M7 / -"
        ]
        let actual = try Self.shippedMCMGoldenOutcomes(loci: ["MHC-DP", "MHC-DQ", "MHC-DR"])
        XCTAssertEqual(actual.count, 84)
        for row in actual {
            XCTAssertEqual(row.outcome, expected[row.key], row.key)
        }
    }

    /// GEN-02 (D11): no genotype at any MCM locus, class I included, may be
    /// `called` with a haplotype pair other than the truth, and every
    /// `ambiguous` call must be compatible with the truth.
    func testMCMShippedDefinitionNeverCallsWrongPairAtAnyLocus() throws {
        for row in try Self.shippedMCMGoldenOutcomes() {
            let pair = row.key.split(separator: " ")[1].split(separator: "/").map(String.init)
            let parts = row.outcome.split(separator: " ", maxSplits: 1).map(String.init)
            let slots = parts[1].components(separatedBy: " / ")
            switch parts[0] {
            case GenotypeHaplotypeCallStatus.called.rawValue:
                let second = slots[1] == "-" ? slots[0] : slots[1]
                XCTAssertEqual(Set([slots[0], second]), Set(pair), row.key)
                XCTAssertEqual([slots[0], second].sorted(), pair.sorted(), row.key)
            case GenotypeHaplotypeCallStatus.ambiguous.rawValue:
                let first = Set(slots[0].split(separator: "|").map(String.init))
                let second = Set(slots[1].split(separator: "|").map(String.init))
                XCTAssertTrue(
                    (first.contains(pair[0]) && second.contains(pair[1]))
                        || (first.contains(pair[1]) && second.contains(pair[0])),
                    "\(row.key): \(row.outcome)"
                )
            case GenotypeHaplotypeCallStatus.tooManyHaplotypes.rawValue,
                 GenotypeHaplotypeCallStatus.tooManyGenotypes.rawValue:
                break
            default:
                XCTFail("\(row.key): unexpected outcome \(row.outcome)")
            }
        }
    }

    /// GEN-02 (D11): a dropped candidate is explained in the call notes, and
    /// a true heterozygote sharing an allele is still called.
    func testSharedAlleleHomozygoteIsCalledHomozygousWithNote() throws {
        let definitionSet = try Self.shippedMCMDefinitionSet()
        let dq = try XCTUnwrap(definitionSet.locusDefinitions.first { $0.locus == "MHC-DQ" })
        let set = GenotypeHaplotypeDefinitionSet(
            id: definitionSet.id,
            assayID: definitionSet.assayID,
            displayName: definitionSet.displayName,
            speciesName: definitionSet.speciesName,
            speciesCode: definitionSet.speciesCode,
            prefix: definitionSet.prefix,
            locusDefinitions: [dq]
        )
        let homozygous = GenotypeHaplotypeAnalyzer.analyze(
            calls: [
                Self.call(sample: "S1", genotype: "MCM_MHC_MiSeq_0025|haplotype_groups=MHC-DQ", reads: 200),
                Self.call(sample: "S1", genotype: "MCM_MHC_MiSeq_0178|haplotype_groups=MHC-DQ", reads: 200),
            ],
            definitionSet: set
        )
        let homozygousCall = try XCTUnwrap(homozygous.samples.first?.calls.first)
        XCTAssertEqual(homozygousCall.status, .called)
        XCTAssertEqual(homozygousCall.haplotype1, "M2")
        XCTAssertEqual(homozygousCall.haplotype2, "-")
        XCTAssertEqual(homozygousCall.matchedHaplotypes.map(\.name), ["M2"])
        XCTAssertTrue(homozygousCall.notes.contains("M6 (explained by M2)"), homozygousCall.notes)
    }
}
