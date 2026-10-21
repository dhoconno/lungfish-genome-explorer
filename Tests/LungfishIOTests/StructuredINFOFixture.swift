// StructuredINFOFixture.swift - VCFs with SnpEff ANN and VEP CSQ annotations and their import helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
@testable import LungfishIO

/// The three-record VCF of the BIO ruling on lane 12.07 (a real SnpEff ANN header with no `Format: ` and a real VEP CSQ
/// header with one), a VCF whose CSQ header lists its parts in its own order, and the reads the structured INFO tests
/// make on the databases they import.
enum StructuredINFOFixture {

    /// POS 100 holds two SnpEff entries (missense MODERATE, upstream MODIFIER), POS 200 one (synonymous LOW) and
    /// POS 300 one VEP entry (stop_gained HIGH) with 18 of its 23 parts filled.
    static let threeRecordVCF = """
    ##fileformat=VCFv4.2
    ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
    ##INFO=<ID=ANN,Number=.,Type=String,Description="Functional annotations: 'Allele | Annotation | Annotation_Impact | Gene_Name | Gene_ID | Feature_Type | Feature_ID | Transcript_BioType | Rank | HGVS.c | HGVS.p | cDNA.pos / cDNA.length | CDS.pos / CDS.length | AA.pos / AA.length | Distance | ERRORS / WARNINGS / INFO' ">
    ##INFO=<ID=CSQ,Number=.,Type=String,Description="Consequence annotations from Ensembl VEP. Format: Allele|Consequence|IMPACT|SYMBOL|Gene|Feature_type|Feature|BIOTYPE|EXON|INTRON|HGVSc|HGVSp|cDNA_position|CDS_position|Protein_position|Amino_acids|Codons|Existing_variation|DISTANCE|STRAND|FLAGS|SYMBOL_SOURCE|HGNC_ID">
    ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
    ##contig=<ID=chr1,length=1000>
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1
    chr1\t100\t.\tC\tT\t50\tPASS\tDP=40;ANN=T|missense_variant|MODERATE|geneA|GENE_A|transcript|TX_A|protein_coding|2/5|c.100C>T|p.Pro34Ser|150/1200|100/900|34/299||,T|upstream_gene_variant|MODIFIER|geneB|GENE_B|transcript|TX_B|protein_coding||c.-120C>T|||||120|\tGT\t0/1
    chr1\t200\t.\tA\tG\t50\tPASS\tDP=35;ANN=G|synonymous_variant|LOW|geneA|GENE_A|transcript|TX_A|protein_coding|3/5|c.200A>G|p.Leu67Leu|250/1200|200/900|67/299||\tGT\t0/1
    chr1\t300\t.\tC\tA\t50\tPASS\tDP=30;CSQ=A|stop_gained|HIGH|geneC|ENSG000003|Transcript|ENST000003|protein_coding|4/9||c.300C>A|p.Tyr100Ter|320|300|100|Y/*|taC/taA|||-1|||HGNC:3\tGT\t0/1

    """

    /// One CSQ record whose header lists `IMPACT|Allele|Consequence`, the order a VEP run with its own `--fields` writes.
    static let customOrderCSQVCF = """
    ##fileformat=VCFv4.2
    ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
    ##INFO=<ID=CSQ,Number=.,Type=String,Description="Consequence annotations from Ensembl VEP. Format: IMPACT|Allele|Consequence">
    ##contig=<ID=chr1,length=1000>
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    chr1\t300\t.\tC\tA\t50\tPASS\tDP=30;CSQ=HIGH|A|stop_gained

    """

    /// One ANN record whose header Description lists its own parts after `Format: `, as a VEP run with
    /// `--vcf_info_field ANN` writes it, so the parts are not the SnpEff template.
    static let vepANNVCF = """
    ##fileformat=VCFv4.2
    ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
    ##INFO=<ID=ANN,Number=.,Type=String,Description="Consequence annotations from Ensembl VEP. Format: Allele|Consequence|IMPACT|SYMBOL">
    ##contig=<ID=chr1,length=1000>
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    chr1\t300\t.\tC\tA\t50\tPASS\tDP=30;ANN=A|stop_gained|HIGH|geneC

    """

    /// One multi-allelic record (`C` to `T,G`) with a `Number=A` AF and a SnpEff ANN that holds one entry an allele.
    static let multiAllelicVCF = """
    ##fileformat=VCFv4.2
    ##INFO=<ID=AF,Number=A,Type=Float,Description="Allele frequency">
    ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
    ##INFO=<ID=ANN,Number=.,Type=String,Description="Functional annotations: 'Allele | Annotation | Annotation_Impact | Gene_Name | Gene_ID | Feature_Type | Feature_ID | Transcript_BioType | Rank | HGVS.c | HGVS.p | cDNA.pos / cDNA.length | CDS.pos / CDS.length | AA.pos / AA.length | Distance | ERRORS / WARNINGS / INFO' ">
    ##contig=<ID=chr1,length=1000>
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    chr1\t100\t.\tC\tT,G\t50\tPASS\tAF=0.25,0.5;DP=40;ANN=T|missense_variant|MODERATE|geneA|GENE_A|transcript|TX_A|protein_coding|2/5|c.100C>T|p.Pro34Ser|150/1200|100/900|34/299||,G|stop_gained|HIGH|geneA|GENE_A|transcript|TX_A|protein_coding|2/5|c.101C>G|p.Pro34Ter|150/1200|100/900|34/299||

    """

    /// The headers of `threeRecordVCF` over three records that each hold more than one impact. POS 100 has an ANN with a
    /// HIGH entry then a MODIFIER entry, POS 200 a CSQ with a MODERATE entry then a HIGH entry and POS 300 an ANN LOW.
    static let mixedImpactVCF: String = {
        let headers = StructuredINFOFixture.threeRecordVCF.split(separator: "\n").filter { $0.hasPrefix("#") }.map(String.init)
        let records = [
            "chr1\t100\t.\tC\tT\t50\tPASS\tDP=40;ANN=T|stop_gained|HIGH|geneA,T|upstream_gene_variant|MODIFIER|geneB\tGT\t0/1",
            "chr1\t200\t.\tA\tG\t50\tPASS\tDP=35;CSQ=G|missense_variant|MODERATE|geneC,G|stop_gained|HIGH|geneD\tGT\t0/1",
            "chr1\t300\t.\tC\tA\t50\tPASS\tDP=30;ANN=A|synonymous_variant|LOW|geneA\tGT\t0/1",
        ]
        return (headers + records).joined(separator: "\n") + "\n"
    }()

    /// The 15 SnpEff template parts that the two entries at POS 100 fill.
    static let annPartsAt100 = [
        "Allele", "Annotation", "Annotation_Impact", "Gene_Name", "Gene_ID", "Feature_Type", "Feature_ID",
        "Transcript_BioType", "Rank", "HGVS_c", "HGVS_p", "cDNA_pos_len", "CDS_pos_len", "AA_pos_len", "Distance",
    ].map { "ANN_\($0)" }

    /// The 14 SnpEff template parts that the one entry at POS 200 fills (no Distance).
    static let annPartsAt200 = Array(annPartsAt100.dropLast())

    /// The three aliases the High Impact filter and the consequence and gene searches read.
    static let annAliases = ["ANN_Consequence", "ANN_IMPACT", "ANN_Gene"]

    /// The 18 VEP parts that the entry at POS 300 fills.
    static let csqPartsAt300 = [
        "Allele", "Consequence", "IMPACT", "SYMBOL", "Gene", "Feature_type", "Feature", "BIOTYPE", "EXON", "HGVSc",
        "HGVSp", "cDNA_position", "CDS_position", "Protein_position", "Amino_acids", "Codons", "STRAND", "HGNC_ID",
    ].map { "CSQ_\($0)" }

    /// The profiles a person can pick for an import, Auto resolving to one of them.
    static let profiles: [VCFImportProfile] = [.fast, .lowMemory, .ultraLowMemory]

    /// Imports `vcf` at `profile` the way `lungfish-cli import vcf` does, materializing the INFO table after an
    /// ultra-low-memory insert, and returns the database.
    static func importDatabase(_ vcf: String, profile: VCFImportProfile, in directory: URL, name: String) throws -> URL {
        let vcfURL = directory.appendingPathComponent("\(name)-\(profile.rawValue).vcf")
        try vcf.write(to: vcfURL, atomically: true, encoding: .utf8)
        let dbURL = directory.appendingPathComponent("\(name)-\(profile.rawValue).db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL, importProfile: profile)
        if profile == .ultraLowMemory {
            try VariantDatabase.materializeVariantInfo(existingDBURL: dbURL)
        }
        return dbURL
    }

    /// The sorted `variant_info` keys of each variant, by its 1-based VCF position.
    static func keysByPosition(_ dbURL: URL) throws -> [Int: [String]] {
        var keys: [Int: [String]] = [:]
        for row in try rows(dbURL, "SELECT v.position + 1, i.key FROM variant_info i JOIN variants v ON v.id = i.variant_id") {
            keys[Int(row[0]) ?? -1, default: []].append(row[1])
        }
        return keys.mapValues { $0.sorted() }
    }

    /// The stored `variant_info` value of `key` at a 1-based VCF position, or nil when there is no row.
    static func storedValue(_ dbURL: URL, position: Int, key: String) throws -> String? {
        try rows(
            dbURL,
            "SELECT i.value FROM variant_info i JOIN variants v ON v.id = i.variant_id "
                + "WHERE v.position + 1 = \(position) AND i.key = '\(key)'"
        ).first?.first
    }

    /// The sorted 1-based positions of the variants whose ids `sql` selects in its first column.
    static func positions(_ dbURL: URL, selectingIDs sql: String) throws -> [Int] {
        try rows(dbURL, "SELECT v.position + 1 FROM variants v WHERE v.id IN (\(sql))")
            .compactMap { Int($0[0]) }
            .sorted()
    }

    /// Runs `sql` on a read-write connection, for a test that rebuilds the shape of a database built by an older release.
    static func execute(_ dbURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw VariantDatabaseError.openFailed("Could not open \(dbURL.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw VariantDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// The rows of `query` on a read-only connection, each column as text.
    static func rows(_ dbURL: URL, _ query: String) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw VariantDatabaseError.openFailed("Could not open \(dbURL.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw VariantDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "NULL"
            })
        }
        return rows
    }
}
