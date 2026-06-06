import XCTest
import LungfishIO

final class GenotypeHaplotypeAnalyzerTests: XCTestCase {
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
}
