import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("IVarTSVToVCFConverter", .tags(.vcf))
struct IVarTSVToVCFConverterTests {
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ivar-converter")
            .appendingPathComponent(name)
    }

    @Test("converts a single SNP row with anchored representation")
    func singleSNP() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivar-converter-snp-\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let options = IVarTSVToVCFConverter.Options(
            consensusAF: 0.75,
            mergeAFThreshold: 0.25,
            badQualityThreshold: 20,
            ignoreStrandBias: true,
            sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
            contigs: [.init(name: "chr1", length: 29903)]
        )
        try IVarTSVToVCFConverter().convert(
            tsvURL: fixtureURL("single-snp.tsv"),
            primaryVCFURL: tmp,
            allHaplotypesVCFURL: nil,
            options: options
        )
        let actual = try String(contentsOf: tmp, encoding: .utf8)
        let expected = try String(contentsOf: fixtureURL("single-snp.expected.vcf"), encoding: .utf8)
        #expect(actual == expected)
    }

    @Test("converts an insertion to anchored alleles")
    func insertion() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivar-converter-ins-\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: fixtureURL("insertion.tsv"),
            primaryVCFURL: tmp,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75,
                mergeAFThreshold: 0.25,
                badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)]
            )
        )
        let actual = try String(contentsOf: tmp, encoding: .utf8)
        #expect(actual.contains("\tA\tATG\t"))
        #expect(actual.contains("TYPE=INS"))
    }

    @Test("converts a deletion to anchored alleles")
    func deletion() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivar-converter-del-\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: fixtureURL("deletion.tsv"),
            primaryVCFURL: tmp,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75,
                mergeAFThreshold: 0.25,
                badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)]
            )
        )
        let actual = try String(contentsOf: tmp, encoding: .utf8)
        #expect(actual.contains("\tACG\tA\t"))
        #expect(actual.contains("TYPE=DEL"))
    }

    @Test("emits ft filter when iVar PASS column is FALSE")
    func ftFilter() throws {
        let tsvURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tsv")
        let header = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"
        let row = "chr1\t44\tC\tT\t75\t75\t38\t4\t2\t38\t0.05\t79\t0.06\tFALSE\tNA\tNA\tNA\tNA\tNA\tNA"
        try (header + "\n" + row + "\n").write(to: tsvURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tsvURL) }
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: tsvURL,
            primaryVCFURL: outURL,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)]
            )
        )
        let actual = try String(contentsOf: outURL, encoding: .utf8)
        #expect(actual.contains("\tft\t"))
    }

    @Test("describes custom bad-quality threshold in VCF filter metadata")
    func badQualityHeaderUsesConfiguredThreshold() throws {
        let tsvURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tsv")
        let header = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"
        let row = "chr1\t44\tC\tT\t75\t75\t38\t4\t2\t24\t0.05\t79\t0.06\tTRUE\tNA\tNA\tNA\tNA\tNA\tNA"
        try (header + "\n" + row + "\n").write(to: tsvURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tsvURL) }
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: outURL) }

        try IVarTSVToVCFConverter().convert(
            tsvURL: tsvURL,
            primaryVCFURL: outURL,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 25,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)]
            )
        )

        let actual = try String(contentsOf: outURL, encoding: .utf8)
        #expect(actual.contains(#"##FILTER=<ID=bq,Description="Bad quality variant: ALT_QUAL lower than 25">"#))
        #expect(actual.contains("\tbq\t"))
        #expect(!actual.contains("ALT_QUAL lower than 20"))
    }

    @Test("emits sb filter when strand bias detected and not ignored")
    func sbFilter() throws {
        let tsvURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tsv")
        let header = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"
        // Strand-biased: REF entirely forward, ALT entirely reverse.
        let row = "chr1\t100\tC\tT\t100\t0\t37\t100\t100\t37\t0.5\t200\t0\tTRUE\tNA\tNA\tNA\tNA\tNA\tNA"
        try (header + "\n" + row + "\n").write(to: tsvURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tsvURL) }
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: tsvURL,
            primaryVCFURL: outURL,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: false,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)]
            )
        )
        let actual = try String(contentsOf: outURL, encoding: .utf8)
        #expect(actual.contains("\tsb\t"))
    }

    @Test("writes codon-merged adjacent SNPs as a multi-base VCF row")
    func codonMergedRowsUseMultiBaseAllelesAndMergedMetrics() throws {
        let tsvURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tsv")
        let header = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"
        let rows = [
            "chr1\t100\tG\tA\t5\t0\t38\t95\t0\t38\t0.95\t100\t0\tTRUE\tgene:cds1\tGGT\tG\tAGT\tS\t1",
            "chr1\t101\tG\tT\t6\t0\t38\t94\t0\t38\t0.94\t100\t0\tTRUE\tgene:cds1\tGGT\tG\tGTT\tV\t1",
        ]
        try ([header] + rows).joined(separator: "\n").appending("\n")
            .write(to: tsvURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tsvURL) }

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: tsvURL,
            primaryVCFURL: outURL,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 1000)]
            )
        )

        let actual = try String(contentsOf: outURL, encoding: .utf8)
        #expect(actual.contains("chr1\t100\t.\tGG\tAT\t.\tPASS\tTYPE=SNP"))
        #expect(actual.contains("GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ:MERGED_AF:MERGED_DP"))
        #expect(actual.contains("1:100:5:0:38:95:0:38:0.94:0.95,0.94:95,94"))
        #expect(!actual.contains("\t101\t.\tG\tT\t"))
    }

    @Test("duplicate rows for overlapping CDS (ORF1a/ORF1ab) collapse to one VCF record")
    func deduplicatesOverlappingCDSRows() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivar-converter-dup-\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: fixtureURL("overlapping-cds-duplicate.tsv"),
            primaryVCFURL: tmp,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)]
            )
        )
        let actual = try String(contentsOf: tmp, encoding: .utf8)
        let dataLines = actual.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(dataLines.count == 1)
        #expect(actual.contains("chr1\t3030\t.\tG\tA\t"))
    }

    @Test("IVarTSVToVCFConverter.deduplicated keeps one row per (region, pos, ref, alt) and merges GFF_FEATURE")
    func deduplicatedMergesGFFFeatures() throws {
        let header = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"
        let rowA = try #require(IVarTSVRow.parse(
            line: "chr1\t3030\tG\tA\t0\t0\t0\t1950\t935\t37\t1\t1950\t0\tTRUE\torf1ab\tGGT\tG\tAGT\tS\t922",
            header: header
        ))
        let rowB = try #require(IVarTSVRow.parse(
            line: "chr1\t3030\tG\tA\t0\t0\t0\t1950\t935\t37\t1\t1950\t0\tTRUE\torf1a\tGGT\tG\tAGT\tS\t922",
            header: header
        ))
        let otherPosition = try #require(IVarTSVRow.parse(
            line: "chr1\t4000\tC\tT\t0\t0\t0\t1950\t935\t37\t1\t1950\t0\tTRUE\tNA\tNA\tNA\tNA\tNA\tNA",
            header: header
        ))

        let result = IVarTSVToVCFConverter.deduplicated([rowA, rowB, otherPosition])

        #expect(result.count == 2)
        #expect(result[0].pos == 3030)
        #expect(result[0].gffFeature == "orf1ab,orf1a")
        #expect(result[1].pos == 4000)
    }

    @Test("emits LungfishNote when no GFF info present")
    func emitsLungfishNoteOnEmptyGFF() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vcf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try IVarTSVToVCFConverter().convert(
            tsvURL: fixtureURL("single-snp.tsv"),
            primaryVCFURL: tmp,
            allHaplotypesVCFURL: nil,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: "chr1", length: 29903)],
                gffMissingNote: true
            )
        )
        let actual = try String(contentsOf: tmp, encoding: .utf8)
        #expect(actual.contains("##LungfishNote=GFF unavailable"))
    }

    // MARK: F6 (IVAR-CODON-MERGE)

    private static let ivarTSVHeader = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"

    /// Every row of NC_002017.1 469 and 470 in the iVar 1.4.4 TSV of PR8 (SRR5428776), copied from
    /// `hand/SRR5428776/ivar.tsv` of the SWEEP-1 run. iVar writes one row for each CDS that covers the
    /// position, nine for each of the two positions, with different codons in each.
    private static let pr8Rows469And470 = [
        "NC_002017.1\t469\tC\tA\t6179\t2538\t43\t2630\t1313\t39\t0.295572\t8898\t0\tTRUE\tM1:cds-NP_040978.1\tAAC\tN\tAAA\tK\t148",
        "NC_002017.1\t469\tC\tA\t6179\t2538\t43\t2630\t1313\t39\t0.295572\t8898\t0\tTRUE\tHA:cds-NP_040980.1\tACC\tT\tAAC\tN\t146",
        "NC_002017.1\t469\tC\tA\t6179\t2538\t43\t2630\t1313\t39\t0.295572\t8898\t0\tTRUE\tNA:cds-NP_040981.1\tACC\tT\tAAC\tN\t150",
        "NC_002017.1\t469\tC\tA\t6179\t2538\t43\t2630\t1313\t39\t0.295572\t8898\t0\tTRUE\tNP:cds-NP_040982.1\tCCA\tP\tACA\tT\t142",
        "NC_002017.1\t469\tC\tA\t6179\t2538\t43\t2630\t1313\t39\t0.295572\t8898\t0\tTRUE\tNS1:cds-NP_040984.1\tACC\tT\tAAC\tN\t148",
        "NC_002017.1\t469\tC\tA\t6179\t2538\t43\t2630\t1313\t39\t0.295572\t8898\t0\tTRUE\tPB1:cds-NP_040985.1\tCCA\tP\tACA\tT\t149",
        "NC_002017.1\t469\tC\tA\t6179\t2538\t43\t2630\t1313\t39\t0.295572\t8898\t0\tTRUE\tPA:cds-NP_040986.1\tCCA\tP\tACA\tT\t149",
        "NC_002017.1\t469\tC\tA\t6179\t2538\t43\t2630\t1313\t39\t0.295572\t8898\t0\tTRUE\tPA-X:cds-YP_006495785.1\tCCA\tP\tACA\tT\t149",
        "NC_002017.1\t469\tC\tA\t6179\t2538\t43\t2630\t1313\t39\t0.295572\t8898\t0\tTRUE\tPB2:cds-NP_040987.1\tCCA\tP\tACA\tT\t148",
        "NC_002017.1\t470\tC\tA\t6696\t2853\t44\t705\t505\t31\t0.0948601\t7432\t0\tTRUE\tM1:cds-NP_040978.1\tCAA\tQ\tAAA\tK\t149",
        "NC_002017.1\t470\tC\tA\t6696\t2853\t44\t705\t505\t31\t0.0948601\t7432\t0\tTRUE\tHA:cds-NP_040980.1\tACC\tT\tACA\tT\t146",
        "NC_002017.1\t470\tC\tA\t6696\t2853\t44\t705\t505\t31\t0.0948601\t7432\t0\tTRUE\tNA:cds-NP_040981.1\tACC\tT\tACA\tT\t150",
        "NC_002017.1\t470\tC\tA\t6696\t2853\t44\t705\t505\t31\t0.0948601\t7432\t0\tTRUE\tNP:cds-NP_040982.1\tCCA\tP\tCAA\tQ\t142",
        "NC_002017.1\t470\tC\tA\t6696\t2853\t44\t705\t505\t31\t0.0948601\t7432\t0\tTRUE\tNS1:cds-NP_040984.1\tACC\tT\tACA\tT\t148",
        "NC_002017.1\t470\tC\tA\t6696\t2853\t44\t705\t505\t31\t0.0948601\t7432\t0\tTRUE\tPB1:cds-NP_040985.1\tCCA\tP\tCAA\tQ\t149",
        "NC_002017.1\t470\tC\tA\t6696\t2853\t44\t705\t505\t31\t0.0948601\t7432\t0\tTRUE\tPA:cds-NP_040986.1\tCCA\tP\tCAA\tQ\t149",
        "NC_002017.1\t470\tC\tA\t6696\t2853\t44\t705\t505\t31\t0.0948601\t7432\t0\tTRUE\tPA-X:cds-YP_006495785.1\tCCA\tP\tCAA\tQ\t149",
        "NC_002017.1\t470\tC\tA\t6696\t2853\t44\t705\t505\t31\t0.0948601\t7432\t0\tTRUE\tPB2:cds-NP_040987.1\tCCA\tP\tCAA\tQ\t148",
    ]

    /// Converts TSV rows with the app's defaults and returns the data lines of the primary VCF and of
    /// the all-haplotypes VCF.
    private func convertRows(_ rows: [String], contig: String) throws -> (primary: [String], allHaplotypes: [String]) {
        let tsvURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tsv")
        let primaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vcf")
        let allHaplotypesURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vcf")
        try ([Self.ivarTSVHeader] + rows).joined(separator: "\n").appending("\n")
            .write(to: tsvURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: tsvURL)
            try? FileManager.default.removeItem(at: primaryURL)
            try? FileManager.default.removeItem(at: allHaplotypesURL)
        }
        try IVarTSVToVCFConverter().convert(
            tsvURL: tsvURL,
            primaryVCFURL: primaryURL,
            allHaplotypesVCFURL: allHaplotypesURL,
            options: .init(
                consensusAF: 0.75, mergeAFThreshold: 0.25, badQualityThreshold: 20,
                ignoreStrandBias: true,
                sourceLine: "iVar 1.4.4 (TSV-to-VCF: Lungfish)",
                contigs: [.init(name: contig, length: 100_000)]
            )
        )
        func dataLines(_ url: URL) throws -> [String] {
            try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.hasPrefix("#") }
                .map(String.init)
        }
        return (try dataLines(primaryURL), try dataLines(allHaplotypesURL))
    }

    @Test("PR8 469 C>A and 470 C>A are written as viralrecon writes them, each with its own frequency")
    func pr8NeighbouringChangesMatchViralReconRecords() throws {
        let result = try convertRows(Self.pr8Rows469And470, contig: "NC_002017.1")
        // The two data lines that viralrecon 3.0.0's converter wrote from these rows
        // (`hand/SRR5428776/vr_ivar.vcf`, lines 63 and 64). At the base commit LGE wrote one line,
        // `469 CC>AA`, at ALT_FREQ 0.0948601, and no line held the 0.295572 allele.
        #expect(result.primary == [
            "NC_002017.1\t469\t.\tC\tA\t.\tPASS\tTYPE=SNP\tGT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ\t1:8898:6179:2538:43:2630:1313:39:0.295572",
            "NC_002017.1\t470\t.\tC\tA\t.\tPASS\tTYPE=SNP\tGT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ\t1:7432:6696:2853:44:705:505:31:0.0948601",
        ])
        // The all-haplotypes VCF is not part of the fix. It lists each change and the pair.
        #expect(result.allHaplotypes.count == 3)
        #expect(result.allHaplotypes.contains { $0.hasPrefix("NC_002017.1\t469\t.\tCC\tAA\t") })
    }

    @Test("two minor changes of one codon both reach the primary VCF")
    func twoMinorChangesOfOneCodonBothReachThePrimaryVCF() throws {
        let rows = [
            "chr1\t100\tG\tA\t70\t35\t38\t30\t15\t38\t0.3\t100\t0\tTRUE\tgene:cds1\tGGT\tG\tAGT\tS\t1",
            "chr1\t101\tG\tT\t96\t48\t38\t4\t2\t38\t0.04\t100\t0\tTRUE\tgene:cds1\tGGT\tG\tGTT\tV\t1",
        ]
        let result = try convertRows(rows, contig: "chr1")
        // At the base commit the primary VCF held no record for either change.
        #expect(result.primary == [
            "chr1\t100\t.\tG\tA\t.\tPASS\tTYPE=SNP\tGT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ\t1:100:70:35:38:30:15:38:0.3",
            "chr1\t101\t.\tG\tT\t.\tPASS\tTYPE=SNP\tGT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ\t1:100:96:48:38:4:2:38:0.04",
        ])
    }
}
