// VariantGeneAliasFilterTests.swift - A typed gene filter reads every gene key the file holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Row TYPED-GENE-FIRST-ALIAS (S1). A file annotated by VEP and by SnpEff holds CSQ_SYMBOL and ANN_Gene. A typed
// `gene=GENEB` read the first of them (CSQ_SYMBOL) and dropped the rest, so it counted the variants VEP ties to the gene
// and hid rows whose Gene column shows it from SnpEff. A plain `GENE` key made the filter read that key alone, and a flat
// `SYMBOL` key, as `bcftools +split-vep -c SYMBOL` writes it, was not an alias at all. Once every held gene key is read,
// a plain key beside list keys must not turn the member match of the list keys off.
//
// The counts are those of bcftools 1.24 on the flat form of the same records, the keys as LGE stores them with the
// values of a part comma-joined (`bcftools view -H -i ... | wc -l`), given with each constant.

import XCTest
@testable import LungfishIO
@testable import LungfishApp

@MainActor
final class VariantGeneAliasFilterTests: XCTestCase {

    private nonisolated(unsafe) var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("variant-gene-alias-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    // MARK: - Fixtures and the counts of bcftools

    /// Seven records with raw VEP `CSQ` and SnpEff `ANN`. Who names GENEB: 100 both, 200 VEP only (SnpEff has the
    /// intergenic `GENEA-GENEB`), 300 SnpEff only, 400 SnpEff only (second entry), 600 both (VEP in the first of two
    /// entries), and neither 500 (GENEA) nor 700 (GENEB2).
    private static let records: [(pos: Int, id: String, ann: String, csq: String)] = [
        (100, "both_missense",
         "T|missense_variant|MODERATE|GENEB|ENSG2|transcript|ENST2|protein_coding|1/2|c.1A>T|p.Met1Leu|1/100|1/90|1/30||",
         "T|missense_variant|MODERATE|GENEB|ENSG2|Transcript|ENST2|protein_coding"),
        (200, "vep_only_upstream",
         "T|intergenic_region|MODIFIER|GENEA-GENEB|ENSG1-ENSG2|intergenic_region|ENSG1-ENSG2|||n.200A>T||||||",
         "T|upstream_gene_variant|MODIFIER|GENEB|ENSG2|Transcript|ENST2|protein_coding"),
        (300, "snpeff_only_upstream",
         "T|upstream_gene_variant|MODIFIER|GENEB|ENSG2|transcript|ENST2|protein_coding||c.-3000A>T|||||3000|",
         "T|intergenic_variant|MODIFIER|||||"),
        (400, "snpeff_only_second_entry",
         "T|missense_variant|MODERATE|GENEC|ENSG3|transcript|ENST3|protein_coding|1/2|c.5A>T|p.Lys2Met|5/100|5/90|2/30||"
             + ",T|downstream_gene_variant|MODIFIER|GENEB|ENSG2|transcript|ENST2|protein_coding||c.*400A>T|||||400|",
         "T|missense_variant|MODERATE|GENEC|ENSG3|Transcript|ENST3|protein_coding"),
        (500, "neither_genea",
         "T|missense_variant|MODERATE|GENEA|ENSG1|transcript|ENST1|protein_coding|1/2|c.9A>T|p.Lys3Met|9/100|9/90|3/30||",
         "T|missense_variant|MODERATE|GENEA|ENSG1|Transcript|ENST1|protein_coding"),
        (600, "both_vep_two_entries",
         "T|missense_variant|MODERATE|GENEB|ENSG2|transcript|ENST2|protein_coding|1/2|c.12A>T|p.Lys4Met|12/100|12/90|4/30||",
         "T|missense_variant|MODERATE|GENEB|ENSG2|Transcript|ENST2|protein_coding"
             + ",T|downstream_gene_variant|MODIFIER|GENEC|ENSG3|Transcript|ENST3|protein_coding"),
        (700, "neither_geneb2",
         "T|missense_variant|MODERATE|GENEB2|ENSG4|transcript|ENST4|protein_coding|1/2|c.15A>T|p.Lys5Met|15/100|15/90|5/30||",
         "T|missense_variant|MODERATE|GENEB2|ENSG4|Transcript|ENST4|protein_coding"),
    ]

    /// The records as a VCF, with a plain `GENE` key on the positions of `plainGeneKeys` when it is not empty.
    private static func vcf(plainGeneKeys: [Int: String] = [:]) -> String {
        var lines = [
            "##fileformat=VCFv4.2",
            "##contig=<ID=chr1,length=100000>",
            "##INFO=<ID=ANN,Number=.,Type=String,Description=\"Functional annotations: 'Allele | Annotation | "
                + "Annotation_Impact | Gene_Name | Gene_ID | Feature_Type | Feature_ID | Transcript_BioType | Rank | "
                + "HGVS.c | HGVS.p | cDNA.pos / cDNA.length | CDS.pos / CDS.length | AA.pos / AA.length | Distance | "
                + "ERRORS / WARNINGS / INFO' \">",
            "##INFO=<ID=CSQ,Number=.,Type=String,Description=\"Consequence annotations from Ensembl VEP. "
                + "Format: Allele|Consequence|IMPACT|SYMBOL|Gene|Feature_type|Feature|BIOTYPE\">",
        ]
        if !plainGeneKeys.isEmpty {
            lines.append("##INFO=<ID=GENE,Number=1,Type=String,Description=\"Gene\">")
        }
        lines.append("#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO")
        for record in records {
            var info = "ANN=\(record.ann);CSQ=\(record.csq)"
            if let gene = plainGeneKeys[record.pos] { info += ";GENE=\(gene)" }
            lines.append("chr1\t\(record.pos)\t\(record.id)\tA\tT\t50\tPASS\t\(info)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A file whose only gene key is a flat `SYMBOL`, two of three variants in GENEB.
    private static let flatSymbolVCF = """
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        ##INFO=<ID=SYMBOL,Number=.,Type=String,Description="Gene symbol">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t150\trs1\tA\tG\t30\tPASS\tSYMBOL=GENEB
        chr1\t250\trs2\tC\tT\t40\tPASS\tSYMBOL=GENEA
        chr1\t350\trs3\tG\tA\t40\tPASS\tSYMBOL=GENEB

        """

    /// On `two-annotators-flat.vcf`, `bcftools view -H -i 'INFO/CSQ_SYMBOL="GENEB"' | wc -l` prints 3.
    private static let bcftoolsCSQSymbolGeneB = 3

    /// `bcftools view -H -i 'INFO/ANN_Gene="GENEB"' two-annotators-flat.vcf | wc -l` prints 4.
    private static let bcftoolsANNGeneGeneB = 4

    /// `bcftools view -H -i 'INFO/CSQ_SYMBOL="GENEB" || INFO/ANN_Gene="GENEB"' two-annotators-flat.vcf | wc -l` prints 5,
    /// and 2 with GENEC for GENEB.
    private static let bcftoolsEitherKeyGeneB = 5
    private static let bcftoolsEitherKeyGeneC = 2

    /// With `GENE` added on 400 (GENEC), 500 (GENEB) and 700 (GENEB2), `bcftools view -H -i 'INFO/GENE="GENEB" ||
    /// INFO/CSQ_SYMBOL="GENEB" || INFO/ANN_Gene="GENEB"' plain-gene-flat.vcf | wc -l` prints 6, and the same for GENEC
    /// prints 2 and for GENEB2 prints 1.
    private static let bcftoolsThreeKeysGeneB = 6
    private static let bcftoolsThreeKeysGeneC = 2
    private static let bcftoolsThreeKeysGeneB2 = 1

    /// `bcftools view -H -i 'INFO/SYMBOL="GENEB"' flat-symbol.vcf | wc -l` prints 2.
    private static let bcftoolsFlatSymbolGeneB = 2

    // MARK: - Tests

    func testATypedGeneFilterCountsTheVariantsOfEveryGeneKeyTheFileHolds() throws {
        let database = try VariantDatabase(url: try importDatabase(Self.vcf(), name: "two-annotators"))
        for text in ["gene=GENEB", "GENE=GENEB", "Gene=GENEB"] {
            XCTAssertEqual(typedCount(text, in: database), Self.bcftoolsEitherKeyGeneB, text)
        }
        XCTAssertEqual(typedCount("gene=GENEC", in: database), Self.bcftoolsEitherKeyGeneC, "gene=GENEC")
        // A key typed in full stays that key.
        XCTAssertEqual(typedCount("CSQ_SYMBOL=GENEB", in: database), Self.bcftoolsCSQSymbolGeneB, "CSQ_SYMBOL=GENEB")
        XCTAssertEqual(typedCount("ANN_Gene=GENEB", in: database), Self.bcftoolsANNGeneGeneB, "ANN_Gene=GENEB")
    }

    func testAPlainGeneKeyIsComparedByItsWholeValueAndTheListKeysByTheirMembers() throws {
        let genes = [400: "GENEC", 500: "GENEB", 700: "GENEB2"]
        let database = try VariantDatabase(url: try importDatabase(Self.vcf(plainGeneKeys: genes), name: "plain-gene"))
        XCTAssertEqual(typedCount("gene=GENEB", in: database), Self.bcftoolsThreeKeysGeneB, "gene=GENEB")
        XCTAssertEqual(typedCount("gene=GENEC", in: database), Self.bcftoolsThreeKeysGeneC, "gene=GENEC")
        XCTAssertEqual(typedCount("gene=GENEB2", in: database), Self.bcftoolsThreeKeysGeneB2, "gene=GENEB2")
    }

    func testATypedGeneFilterReadsAFlatSymbolKey() throws {
        let database = try VariantDatabase(url: try importDatabase(Self.flatSymbolVCF, name: "flat-symbol"))
        XCTAssertEqual(typedCount("gene=GENEB", in: database), Self.bcftoolsFlatSymbolGeneB, "gene=GENEB")
    }

    // MARK: - Helpers

    /// The number of variants the filter bar finds for `text` in `database`.
    private func typedCount(_ text: String, in database: VariantDatabase) -> Int {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.infoColumnKeys = database.infoKeys().map { (key: $0.key, type: $0.type, description: $0.description) }
        return database.queryForTable(infoFilters: drawer.parseVariantFilterText(text).infoFilters).count
    }

    private func importDatabase(_ vcf: String, name: String) throws -> URL {
        let vcfURL = directory.appendingPathComponent("\(name).vcf")
        try vcf.write(to: vcfURL, atomically: true, encoding: .utf8)
        let dbURL = directory.appendingPathComponent("\(name).db")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        return dbURL
    }
}
