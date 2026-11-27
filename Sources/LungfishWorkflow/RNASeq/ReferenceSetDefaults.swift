// ReferenceSetDefaults.swift - The named default sets and the owner's refusals (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The rows are P5-REFS's table (records `lanes/P5-REFS.md:9-18`), plus the mouse GENCODE row of 2026-11-26. With
// `rnaseq reference-set --default` the person passes the files and the owner checks their sha256 against the row. The
// rows that `ReferenceSetCatalog` lists are downloaded by `rnaseq install-reference`. Every row pins its genome and its GTF.

import Foundation

public struct ReferenceSetDefault: Sendable, Equatable {
    public var id: String
    public var role: String
    public var species: String
    public var assemblyName: String
    public var assemblyAccession: String?
    public var annotationSource: String
    public var annotationRelease: String
    public var genomeURL: String
    public var genomeSHA256: String?
    public var annotationURL: String
    public var annotationSHA256: String?

    public static func named(_ id: String) throws -> ReferenceSetDefault {
        guard let row = all.first(where: { $0.id == id }) else {
            throw ReferenceSetError.invalidRequest(
                "No default set is named \(id). The named sets are \(all.map(\.id).joined(separator: ", ")).")
        }
        return row
    }

    static func row(
        _ id: String, _ role: String, _ species: String, _ assembly: String, _ accession: String?, _ source: String,
        _ release: String, _ genomeURL: String, _ genomeSHA: String?, _ gtfURL: String, _ gtfSHA: String?
    ) -> ReferenceSetDefault {
        ReferenceSetDefault(
            id: id, role: role, species: species, assemblyName: assembly, assemblyAccession: accession,
            annotationSource: source, annotationRelease: release, genomeURL: genomeURL, genomeSHA256: genomeSHA,
            annotationURL: gtfURL, annotationSHA256: gtfSHA)
    }

    static let gencode = "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_50/"
    static let gencodeMouse = "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_mouse/release_M39/"
    static let ensembl = "https://ftp.ensembl.org/pub/"
    static let ncbi = "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/"

    public static let all: [ReferenceSetDefault] = [
        row("human/gencode-50", "human default", "Homo sapiens", "GRCh38", nil, "GENCODE", "50",
            gencode + "GRCh38.primary_assembly.genome.fa.gz", "b760d18dbb651dd14dfc290083371b3ef3bff122d43a9cefb13ca4ecf38f05ca",
            gencode + "gencode.v50.primary_assembly.annotation.gtf.gz", "89bbad69a8c89fee5fadec0a2f14a098752d27a4ef7f24e4de9bac681e1b18f4"),
        // GENCODE M39 is Ensembl 116, the Ensembl release of GENCODE 50 (BIO ruling 2026-11-26). GENCODE publishes md5
        // only, so the sha256 was taken from bytes whose size and MD5SUMS md5 matched.
        row("mouse/gencode-M39", "mouse default", "Mus musculus", "GRCm39", nil, "GENCODE", "M39",
            gencodeMouse + "GRCm39.primary_assembly.genome.fa.gz", "82724ccc3726f7bbc3d1cf46a86bbda753f05c1c1b27772e3ff87641fc71669f",
            gencodeMouse + "gencode.vM39.primary_assembly.annotation.gtf.gz", "d6da97913ce30f99883fc1216b111569f9947cf203886a5afb607b59228574d4"),
        row("rhesus/ensembl-116", "rhesus default", "Macaca mulatta", "Mmul_10", "GCA_003339765.3", "Ensembl", "116",
            ensembl + "release-116/fasta/macaca_mulatta/dna/Macaca_mulatta.Mmul_10.dna.toplevel.fa.gz",
            "679dd90651c50366858152b62989c26d587340711e60622458815d19b272fd3a",
            ensembl + "release-116/gtf/macaca_mulatta/Macaca_mulatta.Mmul_10.116.gtf.gz",
            "96678d8c283d92d889b4dda4149f039f0a4ae47f0ccaaa7148eb86ad373304d1"),
        row("rhesus/refseq-GCF_003339765.1", "rhesus equal choice", "Macaca mulatta", "Mmul_10", "GCF_003339765.1", "RefSeq", "103",
            ncbi + "003/339/765/GCF_003339765.1_Mmul_10/GCF_003339765.1_Mmul_10_genomic.fna.gz",
            "24598acaa632972b5603d6ee96874e29b051ca507bf0b77db7b1a14d8842bf07",
            ncbi + "003/339/765/GCF_003339765.1_Mmul_10/GCF_003339765.1_Mmul_10_genomic.gtf.gz",
            "2fe11d44f5e3978959f73fbbbc5122dd70a124135a4643630b814e1c5c04ef74"),
        row("rhesus/refseq-GCF_049350105.2", "rhesus offered", "Macaca mulatta", "T2T-MMU8v2.0", "GCF_049350105.2", "RefSeq", "RS_2025_08",
            ncbi + "049/350/105/GCF_049350105.2_T2T-MMU8v2.0/GCF_049350105.2_T2T-MMU8v2.0_genomic.fna.gz",
            "11f5cafd900bd75bc08b81164febd643ebee916365e6d430faf18461d7fd12ee",
            ncbi + "049/350/105/GCF_049350105.2_T2T-MMU8v2.0/GCF_049350105.2_T2T-MMU8v2.0_genomic.gtf.gz",
            "1141b9417f2285f711edea342e7ecc946513fc779286255958c8c9b9b60a0620"),
        row("cynomolgus/refseq-GCF_037993035.2", "cynomolgus default", "Macaca fascicularis", "T2T-MFA8v1.1", "GCF_037993035.2", "RefSeq", "RS_2025_03",
            ncbi + "037/993/035/GCF_037993035.2_T2T-MFA8v1.1/GCF_037993035.2_T2T-MFA8v1.1_genomic.fna.gz",
            "833c69901acdf5843c8af622295a48c8d211bd9e280cd39edacc3d447c213d9d",
            ncbi + "037/993/035/GCF_037993035.2_T2T-MFA8v1.1/GCF_037993035.2_T2T-MFA8v1.1_genomic.gtf.gz",
            "9f61744ec0497390e1d93bd74d098f8a5fd599675318b62217060fbd49fa3758"),
        row("cynomolgus/ensembl-107", "cynomolgus offered", "Macaca fascicularis", "Macaca_fascicularis_6.0", "GCA_011100615.1", "Ensembl", "107",
            ensembl + "release-107/fasta/macaca_fascicularis/dna/Macaca_fascicularis.Macaca_fascicularis_6.0.dna.toplevel.fa.gz",
            "1a7d9bae467018eaf79f622b4fbae849e4f877879144cd1761f3dafac144c535",
            ensembl + "release-107/gtf/macaca_fascicularis/Macaca_fascicularis.Macaca_fascicularis_6.0.107.gtf.gz",
            "aef041357910d2757f272db9d30f64a206d388eb0850fa5713f9fd9eb6aee2c0"),
        row("cynomolgus/refseq-GCF_000364345.1", "cynomolgus offered", "Macaca fascicularis", "Macaca_fascicularis_5.0", "GCF_000364345.1", "RefSeq", "101",
            ncbi + "000/364/345/GCF_000364345.1_Macaca_fascicularis_5.0/GCF_000364345.1_Macaca_fascicularis_5.0_genomic.fna.gz",
            "0c411a03613308bdc537e11f5978536fb3eded44b0e437b240ecca8985c17d26",
            ncbi + "000/364/345/GCF_000364345.1_Macaca_fascicularis_5.0/GCF_000364345.1_Macaca_fascicularis_5.0_genomic.gtf.gz",
            "43726f01d1ff70520fb02661dd594552dab3b4e53fb8f06c6a4c092d55dfb3c3"),
        row("rhesus/ensembl-100", "check set (GR)", "Macaca mulatta", "Mmul_10", "GCA_003339765.3", "Ensembl", "100",
            ensembl + "release-100/fasta/macaca_mulatta/dna/Macaca_mulatta.Mmul_10.dna.toplevel.fa.gz",
            "679dd90651c50366858152b62989c26d587340711e60622458815d19b272fd3a",
            ensembl + "release-100/gtf/macaca_mulatta/Macaca_mulatta.Mmul_10.100.gtf.gz",
            "73ba46e5b962e55d1307b0ceea8aedef33e1aed5b7e29840fc9da28d15e5c7a9"),
    ]
}

public enum ReferenceSetError: Error, LocalizedError, Equatable, Sendable {
    case namesMissingFromGenome([String])
    case transcriptsDiffer(onlyInAnnotation: [String], onlyInTranscripts: [String])
    case transcriptsWrittenTwice([String])
    case checksumMismatch(file: String, expected: String, found: String)
    case newerSchema(Int)
    case publishedSetDiffers(id: String, file: String)
    case unreadable(String)
    case invalidRequest(String)
    case toolFailed(String)
    /// The exons of `derived/genes.gtf` and the records of `derived/transcripts.fa` differ. Each length names a
    /// transcript with both lengths.
    case countingGTFDiffers(onlyInGTF: [String], onlyInTable: [String], lengths: [String])
    /// A set built before it kept `derived/genes.gtf`, with each reason the GTF as given would count wrong.
    case builtBeforeCountingGTF(id: String, reasons: [String])

    public var errorDescription: String? {
        switch self {
        case .namesMissingFromGenome(let names):
            return "The annotation names sequences the genome lacks: \(Self.listed(names)). Nothing was renamed."
        case .transcriptsDiffer(let annotation, let transcripts):
            return "The transcript FASTA and the annotation name different transcripts. Only in the annotation: "
                + "\(Self.listed(annotation)). Only in the FASTA: \(Self.listed(transcripts)). Nothing was renamed."
        case .transcriptsWrittenTwice(let names):
            return "The transcript FASTA holds more than one record named \(Self.listed(names)). A count could not tell "
                + "them apart, so the set was not built."
        case .checksumMismatch(let file, let expected, let found):
            return "\(file) has sha256 \(found), not \(expected) as its set names."
        case .newerSchema(let version):
            return "This reference set has schema \(version), newer than this version of Lungfish reads. Update Lungfish to use it."
        case .publishedSetDiffers(let id, let file):
            return "The reference set \(id) differs from its manifest at \(file). Build it again or remove it."
        case .unreadable(let path):
            return "Lungfish could not read \(path)."
        case .invalidRequest(let words), .toolFailed(let words):
            return words
        case .countingGTFDiffers(let onlyInGTF, let onlyInTable, let lengths):
            var words = "The GTF that STAR and featureCounts would read and the transcript FASTA that salmon reads differ, "
                + "so the set was not built."
            if !onlyInGTF.isEmpty { words += " Only in the GTF's exon lines: \(Self.listed(onlyInGTF, limit: 5))." }
            if !onlyInTable.isEmpty { words += " Only in the transcript table: \(Self.listed(onlyInTable, limit: 5))." }
            if !lengths.isEmpty { words += " Exon lengths differ for \(Self.listed(lengths, limit: 5))." }
            return words
        case .builtBeforeCountingGTF(let id, let reasons):
            return (["The set \(id) was built before LGE kept the GTF that STAR and featureCounts read."] + reasons
                + ["Build the set again from the same files. It gets a new id, and \(id) stays for its salmon results."])
                .joined(separator: " ")
        }
    }

    static func listed(_ names: [String], limit: Int = 50) -> String {
        guard !names.isEmpty else { return "none" }
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "\(shown) and \(names.count - limit) more" : shown
    }
}
