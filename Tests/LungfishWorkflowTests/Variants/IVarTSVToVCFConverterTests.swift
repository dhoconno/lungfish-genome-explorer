import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("IVarTSVToVCFConverter")
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
}
