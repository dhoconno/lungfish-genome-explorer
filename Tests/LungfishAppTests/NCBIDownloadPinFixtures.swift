// NCBIDownloadPinFixtures.swift - Recorded NCBI responses for the download bundle pins
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// Recorded NCBI responses in NCBI's own layouts, shortened to a few hundred bases. The sequences
/// and accessions are stand-ins (the `ZZ`, `SI` and `PP` prefixes), not biological records.
enum NCBIDownloadPinFixtures {

    // MARK: - GenBank nucleotide record

    static let genBankAccession = "ZZ000001.1"

    /// An EFetch `rettype=gb` answer with a slippage join, a complement feature and qualifiers
    /// that hold a semicolon and an equals sign.
    static let genBankRecord = """
    LOCUS       ZZ000001                 150 bp    RNA     linear   VRL 01-JAN-2024
    DEFINITION  Lungfish stand-in virus isolate LGE-1 segment 1, complete sequence.
    ACCESSION   ZZ000001
    VERSION     ZZ000001.1
    KEYWORDS    .
    SOURCE      Lungfish stand-in virus
      ORGANISM  Lungfish stand-in virus
                Viruses; Riboviria.
    FEATURES             Location/Qualifiers
         source          1..150
                         /organism="Lungfish stand-in virus"
                         /mol_type="genomic RNA"
                         /isolate="LGE-1"
                         /db_xref="taxon:0"
         5'UTR           1..9
         gene            10..140
                         /gene="orf1"
                         /locus_tag="LGE_001"
         CDS             join(10..60,60..140)
                         /gene="orf1"
                         /locus_tag="LGE_001"
                         /ribosomal_slippage
                         /codon_start=1
                         /product="stand-in polyprotein; with a semicolon"
                         /protein_id="ZZP00001.1"
                         /translation="MSTNPKPQRKTKRNTNRRPQDVKFPGG"
         misc_feature    complement(100..120)
                         /note="stand-in hairpin = folded"
    ORIGIN
            1 atgtctacga acccaaaacc tcaaagaaaa accaaacgta acaccaaccg tcgcccacag
           61 gacgtcaagt tcccgggcgg tggtcagatc gttggtggag tttacttgtt gccgcgcagg
          121 ggccctagat tgggtgtgcg cgcgacgtaa
    //

    """

    /// An EFetch `rettype=gff3` answer for the record above.
    static let genBankGFF3 = gff3([
        "##gff-version 3",
        "#!gff-spec-version 1.21",
        "##sequence-region ZZ000001.1 1 150",
        row("ZZ000001.1", "Genbank", "region", "1", "150", ".", "+", ".",
            "ID=ZZ000001.1:1..150;Dbxref=taxon:0;gbkey=Src;isolate=LGE-1;mol_type=genomic RNA"),
        row("ZZ000001.1", "Genbank", "five_prime_UTR", "1", "9", ".", "+", ".",
            "ID=id-ZZ000001.1:1..9;gbkey=5'UTR"),
        row("ZZ000001.1", "Genbank", "gene", "10", "140", ".", "+", ".",
            "ID=gene-orf1;Name=orf1;gbkey=Gene;gene=orf1;gene_biotype=protein_coding;locus_tag=LGE_001"),
        row("ZZ000001.1", "Genbank", "CDS", "10", "60", ".", "+", "0",
            "ID=cds-ZZP00001.1;Parent=gene-orf1;Name=ZZP00001.1;exception=ribosomal slippage;gbkey=CDS;"
                + "gene=orf1;locus_tag=LGE_001;product=stand-in polyprotein%3B with a semicolon;protein_id=ZZP00001.1"),
        row("ZZ000001.1", "Genbank", "CDS", "60", "140", ".", "+", "0",
            "ID=cds-ZZP00001.1;Parent=gene-orf1;Name=ZZP00001.1;exception=ribosomal slippage;gbkey=CDS;"
                + "gene=orf1;locus_tag=LGE_001;product=stand-in polyprotein%3B with a semicolon;protein_id=ZZP00001.1"),
        row("ZZ000001.1", "Genbank", "sequence_feature", "100", "120", ".", "-", ".",
            "ID=id-ZZ000001.1:100..120;Note=stand-in hairpin %3D folded;gbkey=misc_feature"),
    ])

    /// A sequence as a Pathoplexus record gives it, with case, spaces, digits, gaps and a U to clean.
    static let pathoplexusSequence = "acgu nn ACGT-.\n1234ryk" + String(repeating: "ACGTNACGTA", count: 17)

    // MARK: - NCBI assembly

    static let assemblyDirectory = "GCF_000000001.1_StandInAsm1"
    static let assemblyFTPPath = "/genomes/all/GCF/000/000/001/GCF_000000001.1_StandInAsm1"

    /// An ESummary `db=assembly` document whose FTP path points at `ftpBase`.
    static func assemblySummary(ftpBase: String) throws -> NCBIAssemblySummary {
        let document: [String: Any] = [
            "uid": "9900001",
            "assemblyaccession": "GCF_000000001.1",
            "assemblyname": "StandInAsm1",
            "organism": "Lungfish stand-in organism (stand-ins)",
            "speciesname": "Lungfish stand-in organism",
            "taxid": "9999999",
            "ftppath_refseq": ftpBase + assemblyFTPPath,
            "ftppath_genbank": "",
            "submitter": "Lungfish Contributors",
            "coverage": "30",
            "contig_n50": 130,
            "scaffold_n50": "130",
            "assemblystatus": "Chromosome",
            "assemblylevel": "Chromosome",
            "refseq_category": "reference genome",
            "biosampleaccn": "SAMN00000001",
            "bioprojectaccn": "PRJNA000001",
            "total_length": "200",
            "chromosome_count": "2",
            "releasetype": "Major",
            "submitterorganization": "Lungfish Contributors",
        ]
        let data = try JSONSerialization.data(withJSONObject: document)
        return try JSONDecoder().decode(NCBIAssemblySummary.self, from: data)
    }

    /// The `_genomic.fna` the FTP folder holds, before gzip. Chromosome 1 has soft-masked bases.
    static let assemblyFASTA = """
    >SI_000001.1 Lungfish stand-in organism chromosome 1, complete sequence
    ATGGCGTACGTTAGCCGATCGATCGGCTAACGTTACGCCATGGATCCGTAGCTAGCTAGG
    CTAGCTAGCAacgtacgtaaNNNNNNNNNNGGCCTTAAGGCCTTAAGCGCGCATATATCG
    ATCGATCGTA
    >SI_000002.1 Lungfish stand-in organism mitochondrion, complete genome
    GATCACAGGTCTATCACCCTATTAACCACTCACGGGAGCTCTCCATGCATTTGGTATTTT
    CGTCTGGGGG

    """

    /// The `_genomic.gff` the FTP folder holds, before gzip. One feature runs past chromosome 2.
    static let assemblyGFF3 = gff3([
        "##gff-version 3",
        "#!gff-spec-version 1.21",
        "##sequence-region SI_000001.1 1 130",
        "##sequence-region SI_000002.1 1 70",
        row("SI_000001.1", "RefSeq", "region", "1", "130", ".", "+", ".",
            "ID=SI_000001.1:1..130;Dbxref=taxon:9999999;Name=1;chromosome=1;gbkey=Src;genome=chromosome"),
        row("SI_000001.1", "BestRefSeq", "gene", "11", "100", ".", "+", ".",
            "ID=gene-LGE1;Dbxref=GeneID:1;Name=LGE1;description=stand-in gene 1;gbkey=Gene;gene=LGE1;"
                + "gene_biotype=protein_coding"),
        row("SI_000001.1", "BestRefSeq", "mRNA", "11", "100", ".", "+", ".",
            "ID=rna-SI_100001.1;Parent=gene-LGE1;Name=SI_100001.1;gbkey=mRNA;gene=LGE1;"
                + "product=stand-in protein 1;transcript_id=SI_100001.1"),
        row("SI_000001.1", "BestRefSeq", "exon", "11", "40", ".", "+", ".",
            "ID=exon-SI_100001.1-1;Parent=rna-SI_100001.1;gbkey=mRNA;gene=LGE1;transcript_id=SI_100001.1"),
        row("SI_000001.1", "BestRefSeq", "exon", "61", "100", ".", "+", ".",
            "ID=exon-SI_100001.1-2;Parent=rna-SI_100001.1;gbkey=mRNA;gene=LGE1;transcript_id=SI_100001.1"),
        row("SI_000001.1", "BestRefSeq", "CDS", "14", "40", ".", "+", "0",
            "ID=cds-SI_200001.1;Parent=rna-SI_100001.1;Name=SI_200001.1;gbkey=CDS;gene=LGE1;"
                + "product=stand-in protein 1;protein_id=SI_200001.1"),
        row("SI_000001.1", "BestRefSeq", "CDS", "61", "97", ".", "+", "0",
            "ID=cds-SI_200001.1;Parent=rna-SI_100001.1;Name=SI_200001.1;gbkey=CDS;gene=LGE1;"
                + "product=stand-in protein 1;protein_id=SI_200001.1"),
        row("SI_000002.1", "RefSeq", "gene", "5", "60", ".", "-", ".",
            "ID=gene-MT1;Name=MT1;gbkey=Gene;gene=MT1;gene_biotype=protein_coding"),
        row("SI_000002.1", "RefSeq", "CDS", "5", "60", ".", "-", "0",
            "ID=cds-SI_200002.1;Parent=gene-MT1;Name=SI_200002.1;gbkey=CDS;gene=MT1;"
                + "product=stand-in mitochondrial protein;protein_id=SI_200002.1"),
        row("SI_000002.1", "RefSeq", "sequence_feature", "50", "90", ".", "+", ".",
            "ID=id-SI_000002.1:50..90;Note=runs past the end;gbkey=misc_feature"),
    ])

    /// The `_assembly_report.txt` the FTP folder holds.
    static let assemblyReport = [
        "# Assembly name:  StandInAsm1",
        "# Organism name:  Lungfish stand-in organism (stand-ins)",
        "# Taxid:          9999999",
        "# BioSample:      SAMN00000001",
        "# Assembly level: Chromosome",
        "# Genome representation: full",
        "# Assembly method: stand-in assembler v. 1.0",
        "# RefSeq assembly accession: GCF_000000001.1",
        "#",
        "## Assembly-Units:",
        "## GenBank Unit Accession\tRefSeq Unit Accession\tAssembly-Unit name",
        "## GCA_000000001.1\tGCF_000000001.1\tPrimary Assembly",
        "#",
        "# Sequence-Name\tSequence-Role\tAssigned-Molecule\tAssigned-Molecule-Location/Type\t"
            + "GenBank-Accn\tRelationship\tRefSeq-Accn\tAssembly-Unit\tSequence-Length\tUCSC-style-name",
        "1\tassembled-molecule\t1\tChromosome\tCM000001.1\t=\tSI_000001.1\tPrimary Assembly\t130\tchr1",
        "MT\tassembled-molecule\tMT\tMitochondrion\tCM000002.1\t=\tSI_000002.1\tnon-nuclear\t70\tchrM",
        "",
    ].joined(separator: "\n")

    // MARK: - Helpers

    private static func row(_ fields: String...) -> String {
        fields.joined(separator: "\t")
    }

    private static func gff3(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }
}

/// Answers NCBI EFetch from recorded text by `rettype` and keeps each URL asked for in order.
actor RecordedNCBIEFetchClient: HTTPClient {
    enum GFF3Answer: Sendable {
        case found(String)
        case missing
    }

    private let genBank: String
    private let gff3: GFF3Answer
    private(set) var requestedURLs: [String] = []

    init(genBank: String, gff3: GFF3Answer) {
        self.genBank = genBank
        self.gff3 = gff3
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        requestedURLs.append(url.absoluteString)
        let rettype = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "rettype" }?.value
        let status: Int
        let body: String
        switch (rettype, gff3) {
        case ("gb", _):
            (status, body) = (200, genBank)
        case ("gff3", .found(let text)):
            (status, body) = (200, text)
        default:
            (status, body) = (404, "")
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (Data(body.utf8), response)
    }
}
