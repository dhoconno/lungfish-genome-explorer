import Foundation

extension GenotypeHaplotypeDefinitionRegistry {
    public static let builtIn = GenotypeHaplotypeDefinitionRegistry(
        assays: [
            GenotypeHaplotypeAssay(
                id: "MHC-exon2-miSeq",
                displayName: "MHC exon 2 MiSeq",
                definitionSets: [
                    mauritianCynomolgusMacaqueMHCExon2MiSeq,
                    rhesusMacaqueMHCExon2MiSeq,
                    pigTailedMacaqueMHCExon2MiSeq,
                ]
            )
        ],
        defaultDefinitionSetID: nil
    )

    public static let mauritianCynomolgusMacaqueMHCExon2MiSeq = GenotypeHaplotypeDefinitionSet(
        id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
        assayID: "MHC-exon2-miSeq",
        displayName: "Mauritian cynomolgus macaques",
        speciesName: "Mauritian cynomolgus macaques",
        speciesCode: "MCM",
        prefix: "Mafa",
        locusDefinitions: [
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-A",
                sourceLocus: "Mafa-A",
                haplotypes: [
                    // Multi-family diagnostic allele sets derived from the
                    // manual MCM haplotyping reference workbook
                    // (/Users/dho/Downloads/pbaa.xlsx, rows 22-86). Single
                    // M-tag alleles preferred; multi-M alleles included
                    // only when no single-M allele exists in the family.
                    // `minimumMatches: 2` lets a call succeed when ≥2 of
                    // the N alleles are observed — so dropout in one or
                    // two families doesn't kill the call.
                    // Only single-M-tagged alleles — multi-M alleles like
                    // 07_M1M2_70_156bp cause false TMH because they
                    // substring-match across haplotypes. Each list is
                    // pure single-M markers from multiple gene families.
                    GenotypeHaplotypeDefinition(name: "M1A", diagnosticAlleles: ["01_M1_F_01_w_06", "02_M1_G_02_07_2mis_156bp", "04_M1_AG_05_3mis_156bp", "11_M1_E_02g3"], minimumMatches: 2),
                    GenotypeHaplotypeDefinition(name: "M2A", diagnosticAlleles: ["02_M2_G_02_06_156bp"], minimumMatches: 1),
                    GenotypeHaplotypeDefinition(name: "M3A", diagnosticAlleles: ["02_M3_G_02_0508_g48c_156bp", "04_M3_AG_04g1_156bp", "04_M3_AG_d_Ctg27ex", "07_M3_70_156bp"], minimumMatches: 2),
                    GenotypeHaplotypeDefinition(name: "M4A", diagnosticAlleles: ["04_M4_AG_02_w_01_156bp", "05_M4_A1_031_01", "07_M4_70_156bp"], minimumMatches: 2),
                    GenotypeHaplotypeDefinition(name: "M5A", diagnosticAlleles: ["02_M5_G_02_03_4mis_156bp", "05_M5_A1_033_01"], minimumMatches: 1),
                    GenotypeHaplotypeDefinition(name: "M6A", diagnosticAlleles: ["01_M6_F_01_07", "04_M6_AG_w_02_g93a_156bp", "05_M6_A1_032_01", "05_M6_A1_047_01", "07_M6_70a_156bp", "07_M6_70b_156bp", "11_M6_E_02_nov_07", "11_M6_E_02_nov_15"], minimumMatches: 2),
                    GenotypeHaplotypeDefinition(name: "M7A", diagnosticAlleles: ["02_M7_G_02_03_4mis_156bp", "04_M7_Mafa-AG_05_156bp", "05_M7_A1_060_05", "07_M7_70_156bp", "11_M7_E_02_nov_18"], minimumMatches: 2)
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-B",
                sourceLocus: "Mafa-B",
                haplotypes: [
                    // MCM MHC-B diagnostic alleles from pbaa.xlsx rows
                    // 88-134 (Mafa-B + Mafa-B11L + Mafa-I families).
                    // ≥2 of N matches, single-M tags only.
                    GenotypeHaplotypeDefinition(name: "M1B", diagnosticAlleles: ["12_M1_B_057_02", "12_M1_B_134_02", "12_M1_B_144_02", "12_M1_B_152_01N"], minimumMatches: 2),
                    GenotypeHaplotypeDefinition(name: "M2B", diagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04", "12_M2_B_150_01_01", "12_M2_B_162"], minimumMatches: 2),
                    GenotypeHaplotypeDefinition(name: "M3B", diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_098_05", "12_M3_B_165_01"], minimumMatches: 2),
                    GenotypeHaplotypeDefinition(name: "M4B", diagnosticAlleles: ["12_M4_B_088_01", "12_M4_B_127_nov_01", "12_M4_B_147_01"], minimumMatches: 2),
                    GenotypeHaplotypeDefinition(name: "M5B", diagnosticAlleles: ["12_M5_B_045_01", "12_M5_B_050_04", "12_M5_B_051_04", "12_M5_B_149_01", "12_M5_B_167_01N"], minimumMatches: 2),
                    GenotypeHaplotypeDefinition(name: "M6B", diagnosticAlleles: ["12_M6_B_033_01", "12_M6_B_045_03", "12_M6_B_095_01", "12_M6_B_098_06"], minimumMatches: 2),
                    GenotypeHaplotypeDefinition(name: "M7B", diagnosticAlleles: ["12_M7_B_072_02", "12_M7_B_164_02", "12_M7_B_166_01"], minimumMatches: 2)
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DRB",
                sourceLocus: "Mafa-DRB",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "M1DR", diagnosticAlleles: ["13_M1_DRB_W21_01", "13_M1_DRB_W5_01"]),
                    GenotypeHaplotypeDefinition(name: "M2DR", diagnosticAlleles: ["13_M2_DRB1_10_01", "13_M2_DRB_W4_02"]),
                    GenotypeHaplotypeDefinition(name: "M3DR", diagnosticAlleles: ["13_M3_DRB1_10_02", "13_M3_DRB_W49_01_01"]),
                    GenotypeHaplotypeDefinition(name: "M4DR", diagnosticAlleles: ["13_M4_DRB4_01_01"]),
                    GenotypeHaplotypeDefinition(name: "M5DR", diagnosticAlleles: ["13_M5_DRB4_01_02"]),
                    GenotypeHaplotypeDefinition(name: "M6DR", diagnosticAlleles: ["13_M6_DRB1_04_02_01", "13_M6_DRB_W4_01"]),
                    GenotypeHaplotypeDefinition(name: "M7DR", diagnosticAlleles: ["13_M7_DRB_W1_03", "13_M7_DRB_W36_05"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DQA",
                sourceLocus: "Mafa-DQA",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "M1DQ", diagnosticAlleles: ["14_M1_DQB1_18_01_01"]),
                    GenotypeHaplotypeDefinition(name: "M2DQ", diagnosticAlleles: ["14_M2_DQA1_01_04"]),
                    GenotypeHaplotypeDefinition(name: "M3DQ", diagnosticAlleles: ["14_M3_DQB1_16_01", "14_M3_DQA1_05_03_01"]),
                    GenotypeHaplotypeDefinition(name: "M4DQ", diagnosticAlleles: ["14_M4_DQB1_06_08", "14_M4_DQA1_01_07_01"]),
                    GenotypeHaplotypeDefinition(name: "M5DQ", diagnosticAlleles: ["14_M5_DQA1_01_06", "14_M5_DQB1_06_11"]),
                    GenotypeHaplotypeDefinition(name: "M6DQ", diagnosticAlleles: ["14_M6_DQA1_01_08_01"]),
                    GenotypeHaplotypeDefinition(name: "M7DQ", diagnosticAlleles: ["14_M7_DQA1_23_01", "14_M7_DQB1_18_14"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DQB",
                sourceLocus: "Mafa-DQB",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "M1DQ", diagnosticAlleles: ["14_M1_DQB1_18_01_01"]),
                    GenotypeHaplotypeDefinition(name: "M2DQ", diagnosticAlleles: ["14_M2_DQA1_01_04"]),
                    GenotypeHaplotypeDefinition(name: "M3DQ", diagnosticAlleles: ["14_M3_DQB1_16_01", "14_M3_DQA1_05_03_01"]),
                    GenotypeHaplotypeDefinition(name: "M4DQ", diagnosticAlleles: ["14_M4_DQB1_06_08", "14_M4_DQA1_01_07_01"]),
                    GenotypeHaplotypeDefinition(name: "M5DQ", diagnosticAlleles: ["14_M5_DQA1_01_06", "14_M5_DQB1_06_11"]),
                    GenotypeHaplotypeDefinition(name: "M6DQ", diagnosticAlleles: ["14_M6_DQA1_01_08_01"]),
                    GenotypeHaplotypeDefinition(name: "M7DQ", diagnosticAlleles: ["14_M7_DQA1_23_01", "14_M7_DQB1_18_14"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DPA",
                sourceLocus: "Mafa-DPA",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "M1DP", diagnosticAlleles: ["15_M1_DPA1_07_02", "15_M1_DPB1_19_03"]),
                    GenotypeHaplotypeDefinition(name: "M2DP", diagnosticAlleles: ["15_M2_DPA1_07_01", "15_M2_DPB1_20_01"]),
                    GenotypeHaplotypeDefinition(name: "M3DP", diagnosticAlleles: ["15_M3_DPB1_09_02"]),
                    GenotypeHaplotypeDefinition(name: "M4M7DP", diagnosticAlleles: ["15_M4M7_DPB1_03_03"]),
                    GenotypeHaplotypeDefinition(name: "M5M6DP", diagnosticAlleles: ["15_M5M6_DPB1_04_01"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DPB",
                sourceLocus: "Mafa-DPB",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "M1DP", diagnosticAlleles: ["15_M1_DPA1_07_02", "15_M1_DPB1_19_03"]),
                    GenotypeHaplotypeDefinition(name: "M2DP", diagnosticAlleles: ["15_M2_DPA1_07_01", "15_M2_DPB1_20_01"]),
                    GenotypeHaplotypeDefinition(name: "M3DP", diagnosticAlleles: ["15_M3_DPB1_09_02"]),
                    GenotypeHaplotypeDefinition(name: "M4M7DP", diagnosticAlleles: ["15_M4M7_DPB1_03_03"]),
                    GenotypeHaplotypeDefinition(name: "M5M6DP", diagnosticAlleles: ["15_M5M6_DPB1_04_01"])
                ]
            )
        ]
    )

    public static let rhesusMacaqueMHCExon2MiSeq = GenotypeHaplotypeDefinitionSet(
        id: "MHC-exon2-miSeq.rhesus-macaques",
        assayID: "MHC-exon2-miSeq",
        displayName: "Rhesus macaques",
        speciesName: "Rhesus macaques",
        speciesCode: "MAMU",
        prefix: "Mamu",
        locusDefinitions: [
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-A",
                sourceLocus: "Mamu-A",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "A001.01", diagnosticAlleles: ["A1_001"]),
                    GenotypeHaplotypeDefinition(name: "A002.01", diagnosticAlleles: ["A1_002_01"]),
                    GenotypeHaplotypeDefinition(name: "A003.01", diagnosticAlleles: ["A1_003"]),
                    GenotypeHaplotypeDefinition(name: "A004.01", diagnosticAlleles: ["A1_004"]),
                    GenotypeHaplotypeDefinition(name: "A006.01", diagnosticAlleles: ["A1_006"]),
                    GenotypeHaplotypeDefinition(name: "A007.01", diagnosticAlleles: ["A1_007"]),
                    GenotypeHaplotypeDefinition(name: "A008.01", diagnosticAlleles: ["A1_008"]),
                    GenotypeHaplotypeDefinition(name: "A011.01", diagnosticAlleles: ["A1_011"]),
                    GenotypeHaplotypeDefinition(name: "A012.01", diagnosticAlleles: ["A1_012"]),
                    GenotypeHaplotypeDefinition(name: "A016.01", diagnosticAlleles: ["A1_016"]),
                    GenotypeHaplotypeDefinition(name: "A018.01", diagnosticAlleles: ["A1_018"]),
                    GenotypeHaplotypeDefinition(name: "A018.02", diagnosticAlleles: ["A1_018", "A2_01"]),
                    GenotypeHaplotypeDefinition(name: "A019.01", diagnosticAlleles: ["A1_019"]),
                    GenotypeHaplotypeDefinition(name: "A019.02", diagnosticAlleles: ["A1_019_11", "A1_003"]),
                    GenotypeHaplotypeDefinition(name: "A022.01", diagnosticAlleles: ["A1_022"]),
                    GenotypeHaplotypeDefinition(name: "A023.01", diagnosticAlleles: ["A1_023"]),
                    GenotypeHaplotypeDefinition(name: "A025.01", diagnosticAlleles: ["A1_025"]),
                    GenotypeHaplotypeDefinition(name: "A026.01", diagnosticAlleles: ["A1_026"]),
                    GenotypeHaplotypeDefinition(name: "A028.01", diagnosticAlleles: ["A1_028g"]),
                    GenotypeHaplotypeDefinition(name: "A055.01", diagnosticAlleles: ["A1_055"]),
                    GenotypeHaplotypeDefinition(name: "A074.01", diagnosticAlleles: ["A1_074"]),
                    GenotypeHaplotypeDefinition(name: "A110-A111.01", diagnosticAlleles: ["A1_110_A1_111"]),
                    GenotypeHaplotypeDefinition(name: "A224.01", diagnosticAlleles: ["A2_24", "A1_003"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-B",
                sourceLocus: "Mamu-B",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "B001.01", diagnosticAlleles: ["B_001", "B_007", "B_030"]),
                    GenotypeHaplotypeDefinition(name: "B001.03", diagnosticAlleles: ["B_001_02", "B_094", "B_095"]),
                    GenotypeHaplotypeDefinition(name: "B002.01", diagnosticAlleles: ["B_002"]),
                    GenotypeHaplotypeDefinition(name: "B008.01", diagnosticAlleles: ["B_008", "B_006"]),
                    GenotypeHaplotypeDefinition(name: "B012.01", diagnosticAlleles: ["B_012", "B_030", "B_082"]),
                    GenotypeHaplotypeDefinition(name: "B012.02", diagnosticAlleles: ["B_012", "B_022", "B_030"]),
                    GenotypeHaplotypeDefinition(name: "B012.03", diagnosticAlleles: ["B_012", "B_022", "B_030", "B_031g"]),
                    GenotypeHaplotypeDefinition(name: "B015.01", diagnosticAlleles: ["B_015g2", "B_005g"]),
                    GenotypeHaplotypeDefinition(name: "B015.02", diagnosticAlleles: ["B_015g2", "B_068g1"]),
                    GenotypeHaplotypeDefinition(name: "B015.03", diagnosticAlleles: ["B_015g2", "B_031g", "B_068g1"]),
                    GenotypeHaplotypeDefinition(name: "B017.01", diagnosticAlleles: ["B_017", "B_029"]),
                    GenotypeHaplotypeDefinition(name: "B017.02", diagnosticAlleles: ["B_017", "B_065", "B_083"]),
                    GenotypeHaplotypeDefinition(name: "B017.04", diagnosticAlleles: ["B_017", "B_065", "B_068", "B_083"]),
                    GenotypeHaplotypeDefinition(name: "B024.01", diagnosticAlleles: ["B_024", "B_019"]),
                    GenotypeHaplotypeDefinition(name: "B028.01", diagnosticAlleles: ["B_028", "B_021"]),
                    GenotypeHaplotypeDefinition(name: "B043.01", diagnosticAlleles: ["B_043", "B_030"]),
                    GenotypeHaplotypeDefinition(name: "B043.02", diagnosticAlleles: ["B_043", "B_030", "B_031_03", "B_073"]),
                    GenotypeHaplotypeDefinition(name: "B043.03", diagnosticAlleles: ["B_043", "B_030", "B_073"]),
                    GenotypeHaplotypeDefinition(name: "B045.01", diagnosticAlleles: ["B_045", "B_037"]),
                    GenotypeHaplotypeDefinition(name: "B047.01", diagnosticAlleles: ["B_047"]),
                    GenotypeHaplotypeDefinition(name: "B048.01", diagnosticAlleles: ["B_048", "B_041"]),
                    GenotypeHaplotypeDefinition(name: "B055.01", diagnosticAlleles: ["B_055", "B_052", "B_058"]),
                    GenotypeHaplotypeDefinition(name: "B056.01", diagnosticAlleles: ["B_056", "B_067"]),
                    GenotypeHaplotypeDefinition(name: "B056.02", diagnosticAlleles: ["B_056", "B_066", "B_068"]),
                    GenotypeHaplotypeDefinition(name: "B069.01", diagnosticAlleles: ["B_069", "B_065"]),
                    GenotypeHaplotypeDefinition(name: "B069.02", diagnosticAlleles: ["B_069", "B_068", "B_075"]),
                    GenotypeHaplotypeDefinition(name: "B071.01", diagnosticAlleles: ["B_047_B_071", "B_006"]),
                    GenotypeHaplotypeDefinition(name: "B080.01", diagnosticAlleles: ["B_080", "B_081"]),
                    GenotypeHaplotypeDefinition(name: "B091.01", diagnosticAlleles: ["B_091", "B_068"]),
                    GenotypeHaplotypeDefinition(name: "B093.01", diagnosticAlleles: ["B_093"]),
                    GenotypeHaplotypeDefinition(name: "B106.01", diagnosticAlleles: ["B_106", "B_033"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DRB",
                sourceLocus: "Mamu-DRB",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "DR01.01", diagnosticAlleles: ["DRB1_04_06_01", "DRB5_03_01"]),
                    GenotypeHaplotypeDefinition(name: "DR01.03", diagnosticAlleles: ["DRB1_04_11", "DRB5_03_09"]),
                    GenotypeHaplotypeDefinition(name: "DR01.04", diagnosticAlleles: ["DRB1_04_06_01", "DRB5_03_09"]),
                    GenotypeHaplotypeDefinition(name: "DR02.01", diagnosticAlleles: ["DRB3_04_03", "DRB_W003_05"]),
                    GenotypeHaplotypeDefinition(name: "DR03.01", diagnosticAlleles: ["DRB1_03_03_01", "DRB1_10_07"]),
                    GenotypeHaplotypeDefinition(name: "DR03.02", diagnosticAlleles: ["DRB1_03_12", "DRB1_10_07"]),
                    GenotypeHaplotypeDefinition(name: "DR03.03", diagnosticAlleles: ["DRB1_03_17", "DRB1_10_08"]),
                    GenotypeHaplotypeDefinition(name: "DR03.04", diagnosticAlleles: ["DRB1_03_18", "DRB1_10_03"]),
                    GenotypeHaplotypeDefinition(name: "DR03.05", diagnosticAlleles: ["DRB1_03_06", "DRB1_10_07"]),
                    GenotypeHaplotypeDefinition(name: "DR03.06", diagnosticAlleles: ["DRB1_03_06", "DRB1_10_03"]),
                    GenotypeHaplotypeDefinition(name: "DR03.07", diagnosticAlleles: ["DRB1_03_19", "DRB1_10_03"]),
                    GenotypeHaplotypeDefinition(name: "DR03.08", diagnosticAlleles: ["DRB1_03_03_01", "DRB1_10_03"]),
                    GenotypeHaplotypeDefinition(name: "DR03.09", diagnosticAlleles: ["DRB1_03_20", "DRB1_10_02_02"]),
                    GenotypeHaplotypeDefinition(name: "DR04.01", diagnosticAlleles: ["DRB1_03_09", "DRB_W002_01"]),
                    GenotypeHaplotypeDefinition(name: "DR04.02", diagnosticAlleles: ["DRB1_03_18", "DRB_W002_01"]),
                    GenotypeHaplotypeDefinition(name: "DR04.03", diagnosticAlleles: ["DRB1_03_09", "DRB_W002_03"]),
                    GenotypeHaplotypeDefinition(name: "DR05.01", diagnosticAlleles: ["DRB1_04_03", "DRB_W005_01"]),
                    GenotypeHaplotypeDefinition(name: "DR05.02", diagnosticAlleles: ["DRB1_04_03", "DRB_W005_02"]),
                    GenotypeHaplotypeDefinition(name: "DR06.01", diagnosticAlleles: ["DRB_W003_03", "DRB_W004_01"]),
                    GenotypeHaplotypeDefinition(name: "DR08.01", diagnosticAlleles: ["DRB_W028_01", "DRB3_04_09", "DRB5_03_07"]),
                    GenotypeHaplotypeDefinition(name: "DR09.01", diagnosticAlleles: ["DRB1_04_04", "DRB_W007_02_01", "DRB_W003_07"]),
                    GenotypeHaplotypeDefinition(name: "DR09.02", diagnosticAlleles: ["DRB1_04_08", "DRB_W007_01"]),
                    GenotypeHaplotypeDefinition(name: "DR10.01", diagnosticAlleles: ["DRB1_07_01", "DRB3_04_05", "DRB5_03_03"]),
                    GenotypeHaplotypeDefinition(name: "DR10.02", diagnosticAlleles: ["DRB1_07_01", "DRB3_04_05", "DRB5_03_01"]),
                    GenotypeHaplotypeDefinition(name: "DR11.01", diagnosticAlleles: ["DRB_W025_01"]),
                    GenotypeHaplotypeDefinition(name: "DR11.02", diagnosticAlleles: ["DRB_W205_w_01"]),
                    GenotypeHaplotypeDefinition(name: "DR11.03", diagnosticAlleles: ["DRB_W025_05", "DRB1_07_04"]),
                    GenotypeHaplotypeDefinition(name: "DR13.01", diagnosticAlleles: ["DRB1_03_18", "DRB_W006_03", "DRB_W006_04"]),
                    GenotypeHaplotypeDefinition(name: "DR13.02", diagnosticAlleles: ["DRB1_03_18", "DRB_W006_11", "DRB_W006_04"]),
                    GenotypeHaplotypeDefinition(name: "DR14.01", diagnosticAlleles: ["DRB3_04_10", "DRB_W004_02", "DRB_W027_01"]),
                    GenotypeHaplotypeDefinition(name: "DR14.02", diagnosticAlleles: ["DRB3_04_10", "DRB_W004_02", "DRB_W027_02"]),
                    GenotypeHaplotypeDefinition(name: "DR15.01/02", diagnosticAlleles: ["DRB_W006_06", "DRB_W021_04", "DRB_W026g"]),
                    GenotypeHaplotypeDefinition(name: "DR15.03", diagnosticAlleles: ["DRB_W006_06", "DRB_W021_04", "DRB_W002_01"]),
                    GenotypeHaplotypeDefinition(name: "DR16.01", diagnosticAlleles: ["DRB1_03_10", "DRB_W001_01", "DRB_W006_02", "DRB_W006_09_01"]),
                    GenotypeHaplotypeDefinition(name: "DR18.01", diagnosticAlleles: ["DRB4_01_02", "DRB5_03_06"]),
                    GenotypeHaplotypeDefinition(name: "DR28.01", diagnosticAlleles: ["DRB1_07g", "DRB4_01_04", "DRB_W102_01"]),
                    GenotypeHaplotypeDefinition(name: "DR29.01", diagnosticAlleles: ["DRB1_10_11", "DRB_W001_05"]),
                    GenotypeHaplotypeDefinition(name: "DR30.01", diagnosticAlleles: ["DRB1_07_05", "DRB_W002_03"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DQA",
                sourceLocus: "Mamu-DQA",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "01_02", diagnosticAlleles: ["DQA1_01_02"]),
                    GenotypeHaplotypeDefinition(name: "01_07", diagnosticAlleles: ["DQA1_01_07"]),
                    GenotypeHaplotypeDefinition(name: "01_09", diagnosticAlleles: ["DQA1_01_09"]),
                    GenotypeHaplotypeDefinition(name: "01g1", diagnosticAlleles: ["DQA1_01g1"]),
                    GenotypeHaplotypeDefinition(name: "01g2", diagnosticAlleles: ["DQA1_01g2"]),
                    GenotypeHaplotypeDefinition(name: "01g3", diagnosticAlleles: ["DQA1_01g3"]),
                    GenotypeHaplotypeDefinition(name: "01g4", diagnosticAlleles: ["DQA1_01g4"]),
                    GenotypeHaplotypeDefinition(name: "05_01", diagnosticAlleles: ["DQA1_05_01"]),
                    GenotypeHaplotypeDefinition(name: "05_02", diagnosticAlleles: ["DQA1_05_02"]),
                    GenotypeHaplotypeDefinition(name: "05_03", diagnosticAlleles: ["DQA1_05_03"]),
                    GenotypeHaplotypeDefinition(name: "05_04", diagnosticAlleles: ["DQA1_05_04"]),
                    GenotypeHaplotypeDefinition(name: "05_05", diagnosticAlleles: ["DQA1_05_05"]),
                    GenotypeHaplotypeDefinition(name: "05_06", diagnosticAlleles: ["DQA1_05_06"]),
                    GenotypeHaplotypeDefinition(name: "05_07", diagnosticAlleles: ["DQA1_05_07"]),
                    GenotypeHaplotypeDefinition(name: "23_01", diagnosticAlleles: ["DQA1_23_01"]),
                    GenotypeHaplotypeDefinition(name: "23_02", diagnosticAlleles: ["DQA1_23_02"]),
                    GenotypeHaplotypeDefinition(name: "23_03", diagnosticAlleles: ["DQA1_23_03"]),
                    GenotypeHaplotypeDefinition(name: "24_02", diagnosticAlleles: ["DQA1_24_02"]),
                    GenotypeHaplotypeDefinition(name: "24_04", diagnosticAlleles: ["DQA1_24_04"]),
                    GenotypeHaplotypeDefinition(name: "24_08", diagnosticAlleles: ["DQA1_24_08"]),
                    GenotypeHaplotypeDefinition(name: "24g1", diagnosticAlleles: ["DQA1_24g1"]),
                    GenotypeHaplotypeDefinition(name: "24g2", diagnosticAlleles: ["DQA1_24g2"]),
                    GenotypeHaplotypeDefinition(name: "26_01", diagnosticAlleles: ["DQA1_26_01"]),
                    GenotypeHaplotypeDefinition(name: "26g1", diagnosticAlleles: ["DQA1_26g1"]),
                    GenotypeHaplotypeDefinition(name: "26g2", diagnosticAlleles: ["DQA1_26g2"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DQB",
                sourceLocus: "Mamu-DQB",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "06_01", diagnosticAlleles: ["DQB1_06_01"]),
                    GenotypeHaplotypeDefinition(name: "06_07", diagnosticAlleles: ["DQB1_06_07"]),
                    GenotypeHaplotypeDefinition(name: "06_08", diagnosticAlleles: ["DQB1_06_08"]),
                    GenotypeHaplotypeDefinition(name: "06_09", diagnosticAlleles: ["DQB1_06_09"]),
                    GenotypeHaplotypeDefinition(name: "06_10", diagnosticAlleles: ["DQB1_06_10"]),
                    GenotypeHaplotypeDefinition(name: "06_13_01", diagnosticAlleles: ["DQB1_06_13_01"]),
                    GenotypeHaplotypeDefinition(name: "06g1", diagnosticAlleles: ["DQB1_06g1"]),
                    GenotypeHaplotypeDefinition(name: "06g2", diagnosticAlleles: ["DQB1_06g2"]),
                    GenotypeHaplotypeDefinition(name: "06g3", diagnosticAlleles: ["DQB1_06g3"]),
                    GenotypeHaplotypeDefinition(name: "06g4", diagnosticAlleles: ["DQB1_06g4"]),
                    GenotypeHaplotypeDefinition(name: "15_02", diagnosticAlleles: ["DQB1_15_02"]),
                    GenotypeHaplotypeDefinition(name: "15g1", diagnosticAlleles: ["DQB1_15g1"]),
                    GenotypeHaplotypeDefinition(name: "15g2", diagnosticAlleles: ["DQB1_15g2"]),
                    GenotypeHaplotypeDefinition(name: "16_01", diagnosticAlleles: ["DQB1_16_01"]),
                    GenotypeHaplotypeDefinition(name: "16_03", diagnosticAlleles: ["DQB1_16_03"]),
                    GenotypeHaplotypeDefinition(name: "17_03", diagnosticAlleles: ["DQB1_17_03"]),
                    GenotypeHaplotypeDefinition(name: "17g1", diagnosticAlleles: ["DQB1_17g1"]),
                    GenotypeHaplotypeDefinition(name: "17g2", diagnosticAlleles: ["DQB1_17g2"]),
                    GenotypeHaplotypeDefinition(name: "17g3", diagnosticAlleles: ["DQB1_17g3"]),
                    GenotypeHaplotypeDefinition(name: "18_08", diagnosticAlleles: ["DQB1_18_08"]),
                    GenotypeHaplotypeDefinition(name: "18_10", diagnosticAlleles: ["DQB1_18_10"]),
                    GenotypeHaplotypeDefinition(name: "18_12", diagnosticAlleles: ["DQB1_18_12"]),
                    GenotypeHaplotypeDefinition(name: "18_17", diagnosticAlleles: ["DQB1_18_17"]),
                    GenotypeHaplotypeDefinition(name: "18_20", diagnosticAlleles: ["DQB1_18_20"]),
                    GenotypeHaplotypeDefinition(name: "18_24", diagnosticAlleles: ["DQB1_18_24"]),
                    GenotypeHaplotypeDefinition(name: "18g3", diagnosticAlleles: ["DQB1_18g3"]),
                    GenotypeHaplotypeDefinition(name: "18g4", diagnosticAlleles: ["DQB1_18g4"]),
                    GenotypeHaplotypeDefinition(name: "18g5", diagnosticAlleles: ["DQB1_18g5"]),
                    GenotypeHaplotypeDefinition(name: "24_01", diagnosticAlleles: ["DQB1_24_01"]),
                    GenotypeHaplotypeDefinition(name: "27g", diagnosticAlleles: ["DQB1_27g"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DPA",
                sourceLocus: "Mamu-DPA",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "02_03", diagnosticAlleles: ["DPA1_02_03"]),
                    GenotypeHaplotypeDefinition(name: "02_08", diagnosticAlleles: ["DPA1_02_08"]),
                    GenotypeHaplotypeDefinition(name: "02_13", diagnosticAlleles: ["DPA1_02_13"]),
                    GenotypeHaplotypeDefinition(name: "02_14", diagnosticAlleles: ["DPA1_02_14"]),
                    GenotypeHaplotypeDefinition(name: "02_15", diagnosticAlleles: ["DPA1_02_15"]),
                    GenotypeHaplotypeDefinition(name: "02_16", diagnosticAlleles: ["DPA1_02_16"]),
                    GenotypeHaplotypeDefinition(name: "02_20", diagnosticAlleles: ["DPA1_02_20"]),
                    GenotypeHaplotypeDefinition(name: "02g1", diagnosticAlleles: ["DPA1_02g1"]),
                    GenotypeHaplotypeDefinition(name: "02g2", diagnosticAlleles: ["DPA1_02g2"]),
                    GenotypeHaplotypeDefinition(name: "02g3", diagnosticAlleles: ["DPA1_02g3"]),
                    GenotypeHaplotypeDefinition(name: "02g4", diagnosticAlleles: ["DPA1_02g4"]),
                    GenotypeHaplotypeDefinition(name: "04_01", diagnosticAlleles: ["DPA1_04_01"]),
                    GenotypeHaplotypeDefinition(name: "04_04", diagnosticAlleles: ["DPA1_04_04"]),
                    GenotypeHaplotypeDefinition(name: "04g", diagnosticAlleles: ["DPA1_04g"]),
                    GenotypeHaplotypeDefinition(name: "06g", diagnosticAlleles: ["DPA1_06g"]),
                    GenotypeHaplotypeDefinition(name: "07_01", diagnosticAlleles: ["DPA1_07_01"]),
                    GenotypeHaplotypeDefinition(name: "07_04", diagnosticAlleles: ["DPA1_07_04"]),
                    GenotypeHaplotypeDefinition(name: "07_09", diagnosticAlleles: ["DPA1_07_09"]),
                    GenotypeHaplotypeDefinition(name: "07g1", diagnosticAlleles: ["DPA1_07g1"]),
                    GenotypeHaplotypeDefinition(name: "07g2", diagnosticAlleles: ["DPA1_07g2"]),
                    GenotypeHaplotypeDefinition(name: "07g3", diagnosticAlleles: ["DPA1_07g3"]),
                    GenotypeHaplotypeDefinition(name: "08g", diagnosticAlleles: ["DPA1_08g"]),
                    GenotypeHaplotypeDefinition(name: "09_01", diagnosticAlleles: ["DPA1_09_01"]),
                    GenotypeHaplotypeDefinition(name: "10_01", diagnosticAlleles: ["DPA1_10_01"]),
                    GenotypeHaplotypeDefinition(name: "11_01", diagnosticAlleles: ["DPA1_11_01"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DPB",
                sourceLocus: "Mamu-DPB",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "01g1", diagnosticAlleles: ["DPB1_01g1"]),
                    GenotypeHaplotypeDefinition(name: "01g2", diagnosticAlleles: ["DPB1_01g2"]),
                    GenotypeHaplotypeDefinition(name: "01g3", diagnosticAlleles: ["DPB1_01g3"]),
                    GenotypeHaplotypeDefinition(name: "01g4", diagnosticAlleles: ["DPB1_01g4"]),
                    GenotypeHaplotypeDefinition(name: "01g5", diagnosticAlleles: ["DPB1_01g5"]),
                    GenotypeHaplotypeDefinition(name: "02_02", diagnosticAlleles: ["DPB1_02_02"]),
                    GenotypeHaplotypeDefinition(name: "02g", diagnosticAlleles: ["DPB1_02g"]),
                    GenotypeHaplotypeDefinition(name: "03g", diagnosticAlleles: ["DPB1_03g"]),
                    GenotypeHaplotypeDefinition(name: "04_01", diagnosticAlleles: ["DPB1_04_01"]),
                    GenotypeHaplotypeDefinition(name: "05_01", diagnosticAlleles: ["DPB1_05_01"]),
                    GenotypeHaplotypeDefinition(name: "05_02", diagnosticAlleles: ["DPB1_05_02"]),
                    GenotypeHaplotypeDefinition(name: "06_04", diagnosticAlleles: ["DPB1_06_04"]),
                    GenotypeHaplotypeDefinition(name: "06g", diagnosticAlleles: ["DPB1_06g"]),
                    GenotypeHaplotypeDefinition(name: "07g1", diagnosticAlleles: ["DPB1_07g1"]),
                    GenotypeHaplotypeDefinition(name: "07g2", diagnosticAlleles: ["DPB1_07g2"]),
                    GenotypeHaplotypeDefinition(name: "08_01", diagnosticAlleles: ["DPB1_08_01"]),
                    GenotypeHaplotypeDefinition(name: "08_02", diagnosticAlleles: ["DPB1_08_02"]),
                    GenotypeHaplotypeDefinition(name: "15_03", diagnosticAlleles: ["DPB1_15_03"]),
                    GenotypeHaplotypeDefinition(name: "15g", diagnosticAlleles: ["DPB1_15g"]),
                    GenotypeHaplotypeDefinition(name: "16_01", diagnosticAlleles: ["DPB1_16_01"]),
                    GenotypeHaplotypeDefinition(name: "17_01", diagnosticAlleles: ["DPB1_17_01"]),
                    GenotypeHaplotypeDefinition(name: "18_01", diagnosticAlleles: ["DPB1_18_01"]),
                    GenotypeHaplotypeDefinition(name: "19_02", diagnosticAlleles: ["DPB1_19_02"]),
                    GenotypeHaplotypeDefinition(name: "19_06", diagnosticAlleles: ["DPB1_19_06"]),
                    GenotypeHaplotypeDefinition(name: "19g1", diagnosticAlleles: ["DPB1_19g1"]),
                    GenotypeHaplotypeDefinition(name: "19g2", diagnosticAlleles: ["DPB1_19g2"]),
                    GenotypeHaplotypeDefinition(name: "21_01", diagnosticAlleles: ["DPB1_21_01"]),
                    GenotypeHaplotypeDefinition(name: "21_02", diagnosticAlleles: ["DPB1_21_02"]),
                    GenotypeHaplotypeDefinition(name: "21_03", diagnosticAlleles: ["DPB1_21_03"]),
                    GenotypeHaplotypeDefinition(name: "23_01", diagnosticAlleles: ["DPB1_23_01"]),
                    GenotypeHaplotypeDefinition(name: "23_02", diagnosticAlleles: ["DPB1_23_02"]),
                    GenotypeHaplotypeDefinition(name: "24_01", diagnosticAlleles: ["DPB1_24_01"])
                ]
            )
        ]
    )

    public static let pigTailedMacaqueMHCExon2MiSeq = GenotypeHaplotypeDefinitionSet(
        id: "MHC-exon2-miSeq.pig-tailed-macaques",
        assayID: "MHC-exon2-miSeq",
        displayName: "Pig-tailed macaques",
        speciesName: "Pig-tailed macaques",
        speciesCode: "MANE",
        prefix: "Mane",
        locusDefinitions: [
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-A",
                sourceLocus: "Mane-A",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "A001.01", diagnosticAlleles: ["A1_001"]),
                    GenotypeHaplotypeDefinition(name: "A002.01", diagnosticAlleles: ["A1_002_01"]),
                    GenotypeHaplotypeDefinition(name: "A003.01", diagnosticAlleles: ["A1_003"]),
                    GenotypeHaplotypeDefinition(name: "A004.01", diagnosticAlleles: ["A1_004"]),
                    GenotypeHaplotypeDefinition(name: "A006.01", diagnosticAlleles: ["A1_006"]),
                    GenotypeHaplotypeDefinition(name: "A007.01", diagnosticAlleles: ["A1_007"]),
                    GenotypeHaplotypeDefinition(name: "A008.01", diagnosticAlleles: ["A1_008"]),
                    GenotypeHaplotypeDefinition(name: "A011.01", diagnosticAlleles: ["A1_011"]),
                    GenotypeHaplotypeDefinition(name: "A012.01", diagnosticAlleles: ["A1_012"]),
                    GenotypeHaplotypeDefinition(name: "A016.01", diagnosticAlleles: ["A1_016"]),
                    GenotypeHaplotypeDefinition(name: "A018.01", diagnosticAlleles: ["A1_018"]),
                    GenotypeHaplotypeDefinition(name: "A018.02", diagnosticAlleles: ["A1_018", "A2_01"]),
                    GenotypeHaplotypeDefinition(name: "A019.01", diagnosticAlleles: ["A1_019"]),
                    GenotypeHaplotypeDefinition(name: "A019.02", diagnosticAlleles: ["A1_019_11", "A1_003"]),
                    GenotypeHaplotypeDefinition(name: "A022.01", diagnosticAlleles: ["A1_022"]),
                    GenotypeHaplotypeDefinition(name: "A023.01", diagnosticAlleles: ["A1_023"]),
                    GenotypeHaplotypeDefinition(name: "A025.01", diagnosticAlleles: ["A1_025"]),
                    GenotypeHaplotypeDefinition(name: "A026.01", diagnosticAlleles: ["A1_026"]),
                    GenotypeHaplotypeDefinition(name: "A028.01", diagnosticAlleles: ["A1_028g"]),
                    GenotypeHaplotypeDefinition(name: "A055.01", diagnosticAlleles: ["A1_055"]),
                    GenotypeHaplotypeDefinition(name: "A074.01", diagnosticAlleles: ["A1_074"]),
                    GenotypeHaplotypeDefinition(name: "A110-A111.01", diagnosticAlleles: ["A1_110_A1_111"]),
                    GenotypeHaplotypeDefinition(name: "A224.01", diagnosticAlleles: ["A2_24", "A1_003"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-B",
                sourceLocus: "Mane-B",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "B001.01", diagnosticAlleles: ["B_001", "B_007", "B_030"]),
                    GenotypeHaplotypeDefinition(name: "B001.03", diagnosticAlleles: ["B_001_02", "B_094", "B_095"]),
                    GenotypeHaplotypeDefinition(name: "B002.01", diagnosticAlleles: ["B_002"]),
                    GenotypeHaplotypeDefinition(name: "B008.01", diagnosticAlleles: ["B_008", "B_006"]),
                    GenotypeHaplotypeDefinition(name: "B012.01", diagnosticAlleles: ["B_012", "B_030", "B_082"]),
                    GenotypeHaplotypeDefinition(name: "B012.02", diagnosticAlleles: ["B_012", "B_022", "B_030"]),
                    GenotypeHaplotypeDefinition(name: "B012.03", diagnosticAlleles: ["B_012", "B_022", "B_030", "B_031g"]),
                    GenotypeHaplotypeDefinition(name: "B015.01", diagnosticAlleles: ["B_015g2", "B_005g"]),
                    GenotypeHaplotypeDefinition(name: "B015.02", diagnosticAlleles: ["B_015g2", "B_068g1"]),
                    GenotypeHaplotypeDefinition(name: "B015.03", diagnosticAlleles: ["B_015g2", "B_031g", "B_068g1"]),
                    GenotypeHaplotypeDefinition(name: "B017.01", diagnosticAlleles: ["B_017", "B_029"]),
                    GenotypeHaplotypeDefinition(name: "B017.02", diagnosticAlleles: ["B_017", "B_065", "B_083"]),
                    GenotypeHaplotypeDefinition(name: "B017.04", diagnosticAlleles: ["B_017", "B_065", "B_068", "B_083"]),
                    GenotypeHaplotypeDefinition(name: "B024.01", diagnosticAlleles: ["B_024", "B_019"]),
                    GenotypeHaplotypeDefinition(name: "B028.01", diagnosticAlleles: ["B_028", "B_021"]),
                    GenotypeHaplotypeDefinition(name: "B043.01", diagnosticAlleles: ["B_043", "B_030"]),
                    GenotypeHaplotypeDefinition(name: "B043.02", diagnosticAlleles: ["B_043", "B_030", "B_031_03", "B_073"]),
                    GenotypeHaplotypeDefinition(name: "B043.03", diagnosticAlleles: ["B_043", "B_030", "B_073"]),
                    GenotypeHaplotypeDefinition(name: "B045.01", diagnosticAlleles: ["B_045", "B_037"]),
                    GenotypeHaplotypeDefinition(name: "B047.01", diagnosticAlleles: ["B_047"]),
                    GenotypeHaplotypeDefinition(name: "B048.01", diagnosticAlleles: ["B_048", "B_041"]),
                    GenotypeHaplotypeDefinition(name: "B055.01", diagnosticAlleles: ["B_055", "B_052", "B_058"]),
                    GenotypeHaplotypeDefinition(name: "B056.01", diagnosticAlleles: ["B_056", "B_067"]),
                    GenotypeHaplotypeDefinition(name: "B056.02", diagnosticAlleles: ["B_056", "B_066", "B_068"]),
                    GenotypeHaplotypeDefinition(name: "B069.01", diagnosticAlleles: ["B_069", "B_065"]),
                    GenotypeHaplotypeDefinition(name: "B069.02", diagnosticAlleles: ["B_069", "B_068", "B_075"]),
                    GenotypeHaplotypeDefinition(name: "B071.01", diagnosticAlleles: ["B_047_B_071", "B_006"]),
                    GenotypeHaplotypeDefinition(name: "B080.01", diagnosticAlleles: ["B_080", "B_081"]),
                    GenotypeHaplotypeDefinition(name: "B091.01", diagnosticAlleles: ["B_091", "B_068"]),
                    GenotypeHaplotypeDefinition(name: "B093.01", diagnosticAlleles: ["B_093"]),
                    GenotypeHaplotypeDefinition(name: "B106.01", diagnosticAlleles: ["B_106", "B_033"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DRB",
                sourceLocus: "Mane-DRB",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "DR01.01", diagnosticAlleles: ["DRB1_04_06_01", "DRB5_03_01"]),
                    GenotypeHaplotypeDefinition(name: "DR01.03", diagnosticAlleles: ["DRB1_04_11", "DRB5_03_09"]),
                    GenotypeHaplotypeDefinition(name: "DR01.04", diagnosticAlleles: ["DRB1_04_06_01", "DRB5_03_09"]),
                    GenotypeHaplotypeDefinition(name: "DR02.01", diagnosticAlleles: ["DRB3_04_03", "DRB_W003_05"]),
                    GenotypeHaplotypeDefinition(name: "DR03.01", diagnosticAlleles: ["DRB1_03_03_01", "DRB1_10_07"]),
                    GenotypeHaplotypeDefinition(name: "DR03.02", diagnosticAlleles: ["DRB1_03_12", "DRB1_10_07"]),
                    GenotypeHaplotypeDefinition(name: "DR03.03", diagnosticAlleles: ["DRB1_03_17", "DRB1_10_08"]),
                    GenotypeHaplotypeDefinition(name: "DR03.04", diagnosticAlleles: ["DRB1_03_18", "DRB1_10_03"]),
                    GenotypeHaplotypeDefinition(name: "DR03.05", diagnosticAlleles: ["DRB1_03_06", "DRB1_10_07"]),
                    GenotypeHaplotypeDefinition(name: "DR03.06", diagnosticAlleles: ["DRB1_03_06", "DRB1_10_03"]),
                    GenotypeHaplotypeDefinition(name: "DR03.07", diagnosticAlleles: ["DRB1_03_19", "DRB1_10_03"]),
                    GenotypeHaplotypeDefinition(name: "DR03.08", diagnosticAlleles: ["DRB1_03_03_01", "DRB1_10_03"]),
                    GenotypeHaplotypeDefinition(name: "DR03.09", diagnosticAlleles: ["DRB1_03_20", "DRB1_10_02_02"]),
                    GenotypeHaplotypeDefinition(name: "DR04.01", diagnosticAlleles: ["DRB1_03_09", "DRB_W002_01"]),
                    GenotypeHaplotypeDefinition(name: "DR04.02", diagnosticAlleles: ["DRB1_03_18", "DRB_W002_01"]),
                    GenotypeHaplotypeDefinition(name: "DR04.03", diagnosticAlleles: ["DRB1_03_09", "DRB_W002_03"]),
                    GenotypeHaplotypeDefinition(name: "DR05.01", diagnosticAlleles: ["DRB1_04_03", "DRB_W005_01"]),
                    GenotypeHaplotypeDefinition(name: "DR05.02", diagnosticAlleles: ["DRB1_04_03", "DRB_W005_02"]),
                    GenotypeHaplotypeDefinition(name: "DR06.01", diagnosticAlleles: ["DRB_W003_03", "DRB_W004_01"]),
                    GenotypeHaplotypeDefinition(name: "DR08.01", diagnosticAlleles: ["DRB_W028_01", "DRB3_04_09", "DRB5_03_07"]),
                    GenotypeHaplotypeDefinition(name: "DR09.01", diagnosticAlleles: ["DRB1_04_04", "DRB_W007_02_01", "DRB_W003_07"]),
                    GenotypeHaplotypeDefinition(name: "DR09.02", diagnosticAlleles: ["DRB1_04_08", "DRB_W007_01"]),
                    GenotypeHaplotypeDefinition(name: "DR10.01", diagnosticAlleles: ["DRB1_07_01", "DRB3_04_05", "DRB5_03_03"]),
                    GenotypeHaplotypeDefinition(name: "DR10.02", diagnosticAlleles: ["DRB1_07_01", "DRB3_04_05", "DRB5_03_01"]),
                    GenotypeHaplotypeDefinition(name: "DR11.01", diagnosticAlleles: ["DRB_W025_01"]),
                    GenotypeHaplotypeDefinition(name: "DR11.02", diagnosticAlleles: ["DRB_W205_w_01"]),
                    GenotypeHaplotypeDefinition(name: "DR11.03", diagnosticAlleles: ["DRB_W025_05", "DRB1_07_04"]),
                    GenotypeHaplotypeDefinition(name: "DR13.01", diagnosticAlleles: ["DRB1_03_18", "DRB_W006_03", "DRB_W006_04"]),
                    GenotypeHaplotypeDefinition(name: "DR13.02", diagnosticAlleles: ["DRB1_03_18", "DRB_W006_11", "DRB_W006_04"]),
                    GenotypeHaplotypeDefinition(name: "DR14.01", diagnosticAlleles: ["DRB3_04_10", "DRB_W004_02", "DRB_W027_01"]),
                    GenotypeHaplotypeDefinition(name: "DR14.02", diagnosticAlleles: ["DRB3_04_10", "DRB_W004_02", "DRB_W027_02"]),
                    GenotypeHaplotypeDefinition(name: "DR15.01/02", diagnosticAlleles: ["DRB_W006_06", "DRB_W021_04", "DRB_W026g"]),
                    GenotypeHaplotypeDefinition(name: "DR15.03", diagnosticAlleles: ["DRB_W006_06", "DRB_W021_04", "DRB_W002_01"]),
                    GenotypeHaplotypeDefinition(name: "DR16.01", diagnosticAlleles: ["DRB1_03_10", "DRB_W001_01", "DRB_W006_02", "DRB_W006_09_01"]),
                    GenotypeHaplotypeDefinition(name: "DR18.01", diagnosticAlleles: ["DRB4_01_02", "DRB5_03_06"]),
                    GenotypeHaplotypeDefinition(name: "DR28.01", diagnosticAlleles: ["DRB1_07g", "DRB4_01_04", "DRB_W102_01"]),
                    GenotypeHaplotypeDefinition(name: "DR29.01", diagnosticAlleles: ["DRB1_10_11", "DRB_W001_05"]),
                    GenotypeHaplotypeDefinition(name: "DR30.01", diagnosticAlleles: ["DRB1_07_05", "DRB_W002_03"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DQA",
                sourceLocus: "Mane-DQA",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "01_02", diagnosticAlleles: ["DQA1_01_02"]),
                    GenotypeHaplotypeDefinition(name: "01_07", diagnosticAlleles: ["DQA1_01_07"]),
                    GenotypeHaplotypeDefinition(name: "01_09", diagnosticAlleles: ["DQA1_01_09"]),
                    GenotypeHaplotypeDefinition(name: "01g1", diagnosticAlleles: ["DQA1_01g1"]),
                    GenotypeHaplotypeDefinition(name: "01g2", diagnosticAlleles: ["DQA1_01g2"]),
                    GenotypeHaplotypeDefinition(name: "01g3", diagnosticAlleles: ["DQA1_01g3"]),
                    GenotypeHaplotypeDefinition(name: "01g4", diagnosticAlleles: ["DQA1_01g4"]),
                    GenotypeHaplotypeDefinition(name: "05_01", diagnosticAlleles: ["DQA1_05_01"]),
                    GenotypeHaplotypeDefinition(name: "05_02", diagnosticAlleles: ["DQA1_05_02"]),
                    GenotypeHaplotypeDefinition(name: "05_03", diagnosticAlleles: ["DQA1_05_03"]),
                    GenotypeHaplotypeDefinition(name: "05_04", diagnosticAlleles: ["DQA1_05_04"]),
                    GenotypeHaplotypeDefinition(name: "05_05", diagnosticAlleles: ["DQA1_05_05"]),
                    GenotypeHaplotypeDefinition(name: "05_06", diagnosticAlleles: ["DQA1_05_06"]),
                    GenotypeHaplotypeDefinition(name: "05_07", diagnosticAlleles: ["DQA1_05_07"]),
                    GenotypeHaplotypeDefinition(name: "23_01", diagnosticAlleles: ["DQA1_23_01"]),
                    GenotypeHaplotypeDefinition(name: "23_02", diagnosticAlleles: ["DQA1_23_02"]),
                    GenotypeHaplotypeDefinition(name: "23_03", diagnosticAlleles: ["DQA1_23_03"]),
                    GenotypeHaplotypeDefinition(name: "24_02", diagnosticAlleles: ["DQA1_24_02"]),
                    GenotypeHaplotypeDefinition(name: "24_04", diagnosticAlleles: ["DQA1_24_04"]),
                    GenotypeHaplotypeDefinition(name: "24_08", diagnosticAlleles: ["DQA1_24_08"]),
                    GenotypeHaplotypeDefinition(name: "24g1", diagnosticAlleles: ["DQA1_24g1"]),
                    GenotypeHaplotypeDefinition(name: "24g2", diagnosticAlleles: ["DQA1_24g2"]),
                    GenotypeHaplotypeDefinition(name: "26_01", diagnosticAlleles: ["DQA1_26_01"]),
                    GenotypeHaplotypeDefinition(name: "26g1", diagnosticAlleles: ["DQA1_26g1"]),
                    GenotypeHaplotypeDefinition(name: "26g2", diagnosticAlleles: ["DQA1_26g2"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DQB",
                sourceLocus: "Mane-DQB",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "06_01", diagnosticAlleles: ["DQB1_06_01"]),
                    GenotypeHaplotypeDefinition(name: "06_07", diagnosticAlleles: ["DQB1_06_07"]),
                    GenotypeHaplotypeDefinition(name: "06_08", diagnosticAlleles: ["DQB1_06_08"]),
                    GenotypeHaplotypeDefinition(name: "06_09", diagnosticAlleles: ["DQB1_06_09"]),
                    GenotypeHaplotypeDefinition(name: "06_10", diagnosticAlleles: ["DQB1_06_10"]),
                    GenotypeHaplotypeDefinition(name: "06_13_01", diagnosticAlleles: ["DQB1_06_13_01"]),
                    GenotypeHaplotypeDefinition(name: "06g1", diagnosticAlleles: ["DQB1_06g1"]),
                    GenotypeHaplotypeDefinition(name: "06g2", diagnosticAlleles: ["DQB1_06g2"]),
                    GenotypeHaplotypeDefinition(name: "06g3", diagnosticAlleles: ["DQB1_06g3"]),
                    GenotypeHaplotypeDefinition(name: "06g4", diagnosticAlleles: ["DQB1_06g4"]),
                    GenotypeHaplotypeDefinition(name: "15_02", diagnosticAlleles: ["DQB1_15_02"]),
                    GenotypeHaplotypeDefinition(name: "15g1", diagnosticAlleles: ["DQB1_15g1"]),
                    GenotypeHaplotypeDefinition(name: "15g2", diagnosticAlleles: ["DQB1_15g2"]),
                    GenotypeHaplotypeDefinition(name: "16_01", diagnosticAlleles: ["DQB1_16_01"]),
                    GenotypeHaplotypeDefinition(name: "16_03", diagnosticAlleles: ["DQB1_16_03"]),
                    GenotypeHaplotypeDefinition(name: "17_03", diagnosticAlleles: ["DQB1_17_03"]),
                    GenotypeHaplotypeDefinition(name: "17g1", diagnosticAlleles: ["DQB1_17g1"]),
                    GenotypeHaplotypeDefinition(name: "17g2", diagnosticAlleles: ["DQB1_17g2"]),
                    GenotypeHaplotypeDefinition(name: "17g3", diagnosticAlleles: ["DQB1_17g3"]),
                    GenotypeHaplotypeDefinition(name: "18_08", diagnosticAlleles: ["DQB1_18_08"]),
                    GenotypeHaplotypeDefinition(name: "18_10", diagnosticAlleles: ["DQB1_18_10"]),
                    GenotypeHaplotypeDefinition(name: "18_12", diagnosticAlleles: ["DQB1_18_12"]),
                    GenotypeHaplotypeDefinition(name: "18_17", diagnosticAlleles: ["DQB1_18_17"]),
                    GenotypeHaplotypeDefinition(name: "18_20", diagnosticAlleles: ["DQB1_18_20"]),
                    GenotypeHaplotypeDefinition(name: "18_24", diagnosticAlleles: ["DQB1_18_24"]),
                    GenotypeHaplotypeDefinition(name: "18g3", diagnosticAlleles: ["DQB1_18g3"]),
                    GenotypeHaplotypeDefinition(name: "18g4", diagnosticAlleles: ["DQB1_18g4"]),
                    GenotypeHaplotypeDefinition(name: "18g5", diagnosticAlleles: ["DQB1_18g5"]),
                    GenotypeHaplotypeDefinition(name: "24_01", diagnosticAlleles: ["DQB1_24_01"]),
                    GenotypeHaplotypeDefinition(name: "27g", diagnosticAlleles: ["DQB1_27g"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DPA",
                sourceLocus: "Mane-DPA",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "02_03", diagnosticAlleles: ["DPA1_02_03"]),
                    GenotypeHaplotypeDefinition(name: "02_08", diagnosticAlleles: ["DPA1_02_08"]),
                    GenotypeHaplotypeDefinition(name: "02_13", diagnosticAlleles: ["DPA1_02_13"]),
                    GenotypeHaplotypeDefinition(name: "02_14", diagnosticAlleles: ["DPA1_02_14"]),
                    GenotypeHaplotypeDefinition(name: "02_15", diagnosticAlleles: ["DPA1_02_15"]),
                    GenotypeHaplotypeDefinition(name: "02_16", diagnosticAlleles: ["DPA1_02_16"]),
                    GenotypeHaplotypeDefinition(name: "02_20", diagnosticAlleles: ["DPA1_02_20"]),
                    GenotypeHaplotypeDefinition(name: "02g1", diagnosticAlleles: ["DPA1_02g1"]),
                    GenotypeHaplotypeDefinition(name: "02g2", diagnosticAlleles: ["DPA1_02g2"]),
                    GenotypeHaplotypeDefinition(name: "02g3", diagnosticAlleles: ["DPA1_02g3"]),
                    GenotypeHaplotypeDefinition(name: "02g4", diagnosticAlleles: ["DPA1_02g4"]),
                    GenotypeHaplotypeDefinition(name: "04_01", diagnosticAlleles: ["DPA1_04_01"]),
                    GenotypeHaplotypeDefinition(name: "04_04", diagnosticAlleles: ["DPA1_04_04"]),
                    GenotypeHaplotypeDefinition(name: "04g", diagnosticAlleles: ["DPA1_04g"]),
                    GenotypeHaplotypeDefinition(name: "06g", diagnosticAlleles: ["DPA1_06g"]),
                    GenotypeHaplotypeDefinition(name: "07_01", diagnosticAlleles: ["DPA1_07_01"]),
                    GenotypeHaplotypeDefinition(name: "07_04", diagnosticAlleles: ["DPA1_07_04"]),
                    GenotypeHaplotypeDefinition(name: "07_09", diagnosticAlleles: ["DPA1_07_09"]),
                    GenotypeHaplotypeDefinition(name: "07g1", diagnosticAlleles: ["DPA1_07g1"]),
                    GenotypeHaplotypeDefinition(name: "07g2", diagnosticAlleles: ["DPA1_07g2"]),
                    GenotypeHaplotypeDefinition(name: "07g3", diagnosticAlleles: ["DPA1_07g3"]),
                    GenotypeHaplotypeDefinition(name: "08g", diagnosticAlleles: ["DPA1_08g"]),
                    GenotypeHaplotypeDefinition(name: "09_01", diagnosticAlleles: ["DPA1_09_01"]),
                    GenotypeHaplotypeDefinition(name: "10_01", diagnosticAlleles: ["DPA1_10_01"]),
                    GenotypeHaplotypeDefinition(name: "11_01", diagnosticAlleles: ["DPA1_11_01"])
                ]
            ),
            GenotypeHaplotypeLocusDefinition(
                locus: "MHC-DPB",
                sourceLocus: "Mane-DPB",
                haplotypes: [
                    GenotypeHaplotypeDefinition(name: "01g1", diagnosticAlleles: ["DPB1_01g1"]),
                    GenotypeHaplotypeDefinition(name: "01g2", diagnosticAlleles: ["DPB1_01g2"]),
                    GenotypeHaplotypeDefinition(name: "01g3", diagnosticAlleles: ["DPB1_01g3"]),
                    GenotypeHaplotypeDefinition(name: "01g4", diagnosticAlleles: ["DPB1_01g4"]),
                    GenotypeHaplotypeDefinition(name: "01g5", diagnosticAlleles: ["DPB1_01g5"]),
                    GenotypeHaplotypeDefinition(name: "02_02", diagnosticAlleles: ["DPB1_02_02"]),
                    GenotypeHaplotypeDefinition(name: "02g", diagnosticAlleles: ["DPB1_02g"]),
                    GenotypeHaplotypeDefinition(name: "03g", diagnosticAlleles: ["DPB1_03g"]),
                    GenotypeHaplotypeDefinition(name: "04_01", diagnosticAlleles: ["DPB1_04_01"]),
                    GenotypeHaplotypeDefinition(name: "05_01", diagnosticAlleles: ["DPB1_05_01"]),
                    GenotypeHaplotypeDefinition(name: "05_02", diagnosticAlleles: ["DPB1_05_02"]),
                    GenotypeHaplotypeDefinition(name: "06_04", diagnosticAlleles: ["DPB1_06_04"]),
                    GenotypeHaplotypeDefinition(name: "06g", diagnosticAlleles: ["DPB1_06g"]),
                    GenotypeHaplotypeDefinition(name: "07g1", diagnosticAlleles: ["DPB1_07g1"]),
                    GenotypeHaplotypeDefinition(name: "07g2", diagnosticAlleles: ["DPB1_07g2"]),
                    GenotypeHaplotypeDefinition(name: "08_01", diagnosticAlleles: ["DPB1_08_01"]),
                    GenotypeHaplotypeDefinition(name: "08_02", diagnosticAlleles: ["DPB1_08_02"]),
                    GenotypeHaplotypeDefinition(name: "15_03", diagnosticAlleles: ["DPB1_15_03"]),
                    GenotypeHaplotypeDefinition(name: "15g", diagnosticAlleles: ["DPB1_15g"]),
                    GenotypeHaplotypeDefinition(name: "16_01", diagnosticAlleles: ["DPB1_16_01"]),
                    GenotypeHaplotypeDefinition(name: "17_01", diagnosticAlleles: ["DPB1_17_01"]),
                    GenotypeHaplotypeDefinition(name: "18_01", diagnosticAlleles: ["DPB1_18_01"]),
                    GenotypeHaplotypeDefinition(name: "19_02", diagnosticAlleles: ["DPB1_19_02"]),
                    GenotypeHaplotypeDefinition(name: "19_06", diagnosticAlleles: ["DPB1_19_06"]),
                    GenotypeHaplotypeDefinition(name: "19g1", diagnosticAlleles: ["DPB1_19g1"]),
                    GenotypeHaplotypeDefinition(name: "19g2", diagnosticAlleles: ["DPB1_19g2"]),
                    GenotypeHaplotypeDefinition(name: "21_01", diagnosticAlleles: ["DPB1_21_01"]),
                    GenotypeHaplotypeDefinition(name: "21_02", diagnosticAlleles: ["DPB1_21_02"]),
                    GenotypeHaplotypeDefinition(name: "21_03", diagnosticAlleles: ["DPB1_21_03"]),
                    GenotypeHaplotypeDefinition(name: "23_01", diagnosticAlleles: ["DPB1_23_01"]),
                    GenotypeHaplotypeDefinition(name: "23_02", diagnosticAlleles: ["DPB1_23_02"]),
                    GenotypeHaplotypeDefinition(name: "24_01", diagnosticAlleles: ["DPB1_24_01"])
                ]
            )
        ]
    )
}
