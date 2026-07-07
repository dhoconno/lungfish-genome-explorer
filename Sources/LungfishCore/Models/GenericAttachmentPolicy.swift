// GenericAttachmentPolicy.swift - Guardrails for non-scientific bundle attachments
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum GenericAttachmentValidationError: Error, Equatable, LungfishError, Sendable {
    case scientificDataRequiresImportWorkflow(filename: String, formatDescription: String)

    public var userTitle: String {
        "Use an Import Workflow for Scientific Data"
    }

    public var userMessage: String {
        switch self {
        case .scientificDataRequiresImportWorkflow(let filename, let formatDescription):
            return "\"\(filename)\" looks like \(formatDescription). Generic attachments are for documents such as PDFs, images, and notes."
        }
    }

    public var recoverySuggestion: String? {
        "Import scientific data with the matching Lungfish import or workflow action so the bundle records reproducibility provenance."
    }
}

public enum GenericAttachmentPolicy {
    public static func validateNonScientificAttachmentSource(_ sourceURL: URL) throws {
        if let formatDescription = scientificFormatDescription(forFilename: sourceURL.lastPathComponent) {
            throw GenericAttachmentValidationError.scientificDataRequiresImportWorkflow(
                filename: sourceURL.lastPathComponent,
                formatDescription: formatDescription
            )
        }
    }

    public static func scientificFormatDescription(forFilename filename: String) -> String? {
        let normalized = filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return blockedSuffixes.first { normalized.hasSuffix($0.suffix) }?.description
    }

    public static func userFacingMessage(for error: Error) -> String {
        guard let lungfishError = error as? any LungfishError else {
            return error.localizedDescription
        }
        return [lungfishError.userMessage, lungfishError.recoverySuggestion]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let blockedSuffixes: [(suffix: String, description: String)] = [
        (".vcf.gz.tbi", "a tabix index for a compressed VCF variant file"),
        (".vcf.gz.csi", "a CSI index for a compressed VCF variant file"),
        (".fa.gz.fai", "a FASTA index"),
        (".fasta.gz.fai", "a FASTA index"),
        (".fna.gz.fai", "a FASTA index"),
        (".fa.gz.gzi", "a bgzip FASTA index"),
        (".fasta.gz.gzi", "a bgzip FASTA index"),
        (".fna.gz.gzi", "a bgzip FASTA index"),
        (".bam.bai", "a BAM alignment index"),
        (".cram.crai", "a CRAM alignment index"),
        (".fastq.gz", "a FASTQ read file"),
        (".fastq.bgz", "a FASTQ read file"),
        (".fastq.bz2", "a FASTQ read file"),
        (".fastq.xz", "a FASTQ read file"),
        (".fq.gz", "a FASTQ read file"),
        (".fq.bgz", "a FASTQ read file"),
        (".fq.bz2", "a FASTQ read file"),
        (".fq.xz", "a FASTQ read file"),
        (".fasta.gz", "a FASTA sequence file"),
        (".fasta.bgz", "a FASTA sequence file"),
        (".fasta.bz2", "a FASTA sequence file"),
        (".fasta.xz", "a FASTA sequence file"),
        (".fna.gz", "a FASTA sequence file"),
        (".fna.bgz", "a FASTA sequence file"),
        (".fa.gz", "a FASTA sequence file"),
        (".fa.bgz", "a FASTA sequence file"),
        (".vcf.gz", "a VCF variant file"),
        (".gff3.gz", "a genomic annotation file"),
        (".gff.gz", "a genomic annotation file"),
        (".gtf.gz", "a genomic annotation file"),
        (".bed.gz", "a genomic interval file"),
        (".tsv.gz", "a compressed scientific table"),
        (".csv.gz", "a compressed scientific table"),
        (".lungfishfastq", "a Lungfish FASTQ bundle"),
        (".lungfishref", "a Lungfish reference bundle"),
        (".lungfishmsa", "a Lungfish alignment bundle"),
        (".lungfishtree", "a Lungfish tree bundle"),
        (".lungfishprimers", "a Lungfish primer scheme bundle"),
        (".lungfishmhcref", "a Lungfish MHC reference bundle"),
        (".lungfishgenotype", "a Lungfish genotype result bundle"),
        (".lungfish12s", "a Lungfish 12S result bundle"),
        (".lungfish12sref", "a Lungfish 12S reference bundle"),
        (".lungfishrun", "a Lungfish workflow run bundle"),
        (".fastq", "a FASTQ read file"),
        (".fq", "a FASTQ read file"),
        (".fasta", "a FASTA sequence file"),
        (".fna", "a FASTA sequence file"),
        (".fsa", "a FASTA sequence file"),
        (".fas", "a FASTA sequence file"),
        (".fa", "a FASTA sequence file"),
        (".faa", "a FASTA protein sequence file"),
        (".ffn", "a FASTA nucleotide sequence file"),
        (".frn", "a FASTA RNA sequence file"),
        (".gb", "a GenBank sequence file"),
        (".gbk", "a GenBank sequence file"),
        (".gbff", "a GenBank sequence file"),
        (".genbank", "a GenBank sequence file"),
        (".embl", "an EMBL sequence file"),
        (".sam", "a SAM alignment file"),
        (".bam", "a BAM alignment file"),
        (".cram", "a CRAM alignment file"),
        (".bai", "a BAM alignment index"),
        (".crai", "a CRAM alignment index"),
        (".vcf", "a VCF variant file"),
        (".bcf", "a BCF variant file"),
        (".tbi", "a tabix index"),
        (".csi", "a CSI index"),
        (".gff3", "a genomic annotation file"),
        (".gff", "a genomic annotation file"),
        (".gtf", "a genomic annotation file"),
        (".bed", "a genomic interval file"),
        (".bedgraph", "a genome signal file"),
        (".bigwig", "a genome signal file"),
        (".bigbed", "a genome interval file"),
        (".bw", "a genome signal file"),
        (".bb", "a genome interval file"),
        (".fai", "a FASTA index"),
        (".gzi", "a bgzip index"),
        (".mmi", "a minimap2 index"),
        (".bt2", "a Bowtie2 index"),
        (".bt2l", "a Bowtie2 index"),
        (".k2d", "a Kraken2 database file"),
        (".kreport", "a Kraken2 classification report"),
        (".kreport2", "a Kraken2 classification report"),
        (".kraken", "a Kraken2 per-read classification output"),
        (".bracken", "a Bracken abundance output"),
        (".blast6", "a BLAST tabular alignment output"),
        (".m8", "a BLAST tabular alignment output"),
        (".aln", "a multiple sequence alignment file"),
        (".clustal", "a multiple sequence alignment file"),
        (".clw", "a multiple sequence alignment file"),
        (".phy", "a phylogenetic alignment file"),
        (".phylip", "a phylogenetic alignment file"),
        (".nex", "a NEXUS alignment or tree file"),
        (".nexus", "a NEXUS alignment or tree file"),
        (".sto", "a Stockholm alignment file"),
        (".stockholm", "a Stockholm alignment file"),
        (".a2m", "a multiple sequence alignment file"),
        (".a3m", "a multiple sequence alignment file"),
        (".nwk", "a Newick tree file"),
        (".newick", "a Newick tree file"),
        (".tree", "a phylogenetic tree file"),
        (".tre", "a phylogenetic tree file"),
        (".treefile", "a phylogenetic tree file"),
        (".contree", "a consensus tree file"),
        (".sqlite", "a scientific SQLite database"),
        (".sqlite3", "a scientific SQLite database"),
        (".db", "a scientific database file"),
    ]
}
