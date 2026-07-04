// FormatRegistry+BuiltInDescriptors.swift - Built-in format descriptor catalog
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FormatRegistry {

    // MARK: - Built-in Formats

    /// Creates all built-in format descriptors (static helper for init).
    static func createBuiltInDescriptors() -> [FormatIdentifier: FormatDescriptor] {
        var result: [FormatIdentifier: FormatDescriptor] = [:]

        // ===== Sequence Formats =====

        // FASTA
        let fasta = FormatDescriptor(
            identifier: .fasta,
            displayName: "FASTA",
            formatDescription: "Simple sequence format",
            extensions: ["fa", "fasta", "fna", "faa", "ffn", "frn", "fas"],
            mimeTypes: ["text/x-fasta"],
            capabilities: .nucleotideSequence,
            canRead: true,
            canWrite: true,
            uiCategory: .sequence
        )
        result[fasta.identifier] = fasta

        // FASTQ
        let fastq = FormatDescriptor(
            identifier: .fastq,
            displayName: "FASTQ",
            formatDescription: "Sequence with quality scores",
            extensions: ["fq", "fastq"],
            mimeTypes: ["text/x-fastq"],
            capabilities: [.nucleotideSequence, .qualityScores],
            canRead: true,
            canWrite: true,
            uiCategory: .sequence
        )
        result[fastq.identifier] = fastq

        // GenBank
        let genbank = FormatDescriptor(
            identifier: .genbank,
            displayName: "GenBank",
            formatDescription: "Annotated sequence format",
            extensions: ["gb", "gbk", "genbank", "gbff"],
            mimeTypes: ["text/x-genbank"],
            capabilities: [.nucleotideSequence, .annotations, .richMetadata],
            canRead: true,
            canWrite: true,
            iconName: "doc.richtext",
            uiCategory: .sequence
        )
        result[genbank.identifier] = genbank

        // ===== Annotation Formats =====

        // GFF3
        let gff3 = FormatDescriptor(
            identifier: .gff3,
            displayName: "GFF3",
            formatDescription: "General Feature Format version 3",
            extensions: ["gff", "gff3"],
            mimeTypes: ["text/x-gff3"],
            capabilities: .annotations,
            canRead: true,
            canWrite: true,
            uiCategory: .annotation
        )
        result[gff3.identifier] = gff3

        // GTF
        let gtf = FormatDescriptor(
            identifier: .gtf,
            displayName: "GTF",
            formatDescription: "Gene Transfer Format",
            extensions: ["gtf"],
            mimeTypes: ["text/x-gtf"],
            capabilities: .annotations,
            canRead: true,
            canWrite: false,
            uiCategory: .annotation
        )
        result[gtf.identifier] = gtf

        // BED
        let bed = FormatDescriptor(
            identifier: .bed,
            displayName: "BED",
            formatDescription: "Browser Extensible Data format",
            extensions: ["bed"],
            mimeTypes: ["text/x-bed"],
            capabilities: .annotations,
            canRead: true,
            canWrite: true,
            uiCategory: .annotation
        )
        result[bed.identifier] = bed

        // ===== Variant Formats =====

        // VCF
        let vcf = FormatDescriptor(
            identifier: .vcf,
            displayName: "VCF",
            formatDescription: "Variant Call Format",
            extensions: ["vcf"],
            mimeTypes: ["text/x-vcf"],
            capabilities: .variants,
            canRead: true,
            canWrite: true,
            uiCategory: .variant
        )
        result[vcf.identifier] = vcf

        // BCF
        let bcf = FormatDescriptor(
            identifier: .bcf,
            displayName: "BCF",
            formatDescription: "Binary Variant Call Format",
            extensions: ["bcf"],
            mimeTypes: ["application/x-bcf"],
            capabilities: .variants,
            isBinary: true,
            canRead: true,
            canWrite: false,
            uiCategory: .variant
        )
        result[bcf.identifier] = bcf

        // ===== Alignment Formats =====

        // SAM
        let sam = FormatDescriptor(
            identifier: .sam,
            displayName: "SAM",
            formatDescription: "Sequence Alignment Map (text)",
            extensions: ["sam"],
            mimeTypes: ["text/x-sam"],
            capabilities: [.nucleotideSequence, .qualityScores, .alignment],
            isBinary: false,
            canRead: true,
            canWrite: true,
            uiCategory: .alignment
        )
        result[sam.identifier] = sam

        // BAM
        let bam = FormatDescriptor(
            identifier: .bam,
            displayName: "BAM",
            formatDescription: "Binary Alignment Map",
            extensions: ["bam"],
            mimeTypes: ["application/x-bam"],
            magicBytes: Data([0x1f, 0x8b, 0x08]), // gzip magic (BAM is bgzf compressed)
            capabilities: [.nucleotideSequence, .qualityScores, .alignment],
            supportsCompression: false, // Already compressed
            requiresIndex: true,
            indexFormat: .bai,
            isBinary: true,
            canRead: true,
            canWrite: false,
            uiCategory: .alignment
        )
        result[bam.identifier] = bam

        // CRAM
        let cram = FormatDescriptor(
            identifier: .cram,
            displayName: "CRAM",
            formatDescription: "Compressed Reference-oriented Alignment Map",
            extensions: ["cram"],
            mimeTypes: ["application/x-cram"],
            capabilities: [.nucleotideSequence, .qualityScores, .alignment],
            supportsCompression: false,
            requiresIndex: true,
            isBinary: true,
            canRead: true,
            canWrite: false,
            uiCategory: .alignment
        )
        result[cram.identifier] = cram

        // ===== Coverage/Signal Formats =====

        // BigWig
        let bigwig = FormatDescriptor(
            identifier: .bigwig,
            displayName: "BigWig",
            formatDescription: "Binary coverage/signal format (detection only; in-process reader unavailable)",
            extensions: ["bw", "bigwig"],
            magicBytes: Data([0x26, 0xfc, 0x8f, 0x88]), // BigWig magic (little-endian)
            capabilities: .coverage,
            supportsCompression: false,
            isBinary: true,
            canRead: false,
            canWrite: false,
            uiCategory: .coverage
        )
        result[bigwig.identifier] = bigwig

        // BigBed
        let bigbed = FormatDescriptor(
            identifier: .bigbed,
            displayName: "BigBed",
            formatDescription: "Binary annotation format (detection only; in-process reader unavailable)",
            extensions: ["bb", "bigbed"],
            magicBytes: Data([0x26, 0xfc, 0x8f, 0x87]), // BigBed magic (little-endian)
            capabilities: .annotations,
            supportsCompression: false,
            isBinary: true,
            canRead: false,
            canWrite: false,
            uiCategory: .coverage
        )
        result[bigbed.identifier] = bigbed

        // bedGraph
        let bedgraph = FormatDescriptor(
            identifier: .bedgraph,
            displayName: "bedGraph",
            formatDescription: "Coverage/signal in BED-like format",
            extensions: ["bedgraph", "bg"],
            mimeTypes: ["text/x-bedgraph"],
            capabilities: .coverage,
            canRead: true,
            canWrite: true,
            uiCategory: .coverage
        )
        result[bedgraph.identifier] = bedgraph

        // ===== Index Formats =====

        // FAI
        let fai = FormatDescriptor(
            identifier: .fai,
            displayName: "FASTA Index",
            formatDescription: "Index for FASTA files",
            extensions: ["fai"],
            mimeTypes: ["text/x-fai"],
            capabilities: [],
            canRead: true,
            canWrite: false,
            uiCategory: .index
        )
        result[fai.identifier] = fai

        // BAI
        let bai = FormatDescriptor(
            identifier: .bai,
            displayName: "BAM Index",
            formatDescription: "Index for BAM files",
            extensions: ["bai"],
            mimeTypes: ["application/x-bai"],
            capabilities: [],
            isBinary: true,
            canRead: true,
            canWrite: false,
            uiCategory: .index
        )
        result[bai.identifier] = bai

        // ===== Document Formats (QuickLook) =====

        // PDF
        let pdf = FormatDescriptor(
            identifier: .pdf,
            displayName: "PDF",
            formatDescription: "Portable Document Format",
            extensions: ["pdf"],
            mimeTypes: ["application/pdf"],
            capabilities: [],
            supportsCompression: false,
            isBinary: true,
            canRead: false,
            canWrite: false,
            iconName: "doc.richtext",
            supportsQuickLook: true,
            uiCategory: .document
        )
        result[pdf.identifier] = pdf

        // Plain Text
        let plainText = FormatDescriptor(
            identifier: .plainText,
            displayName: "Plain Text",
            formatDescription: "Plain text file",
            extensions: ["txt", "text"],
            mimeTypes: ["text/plain"],
            capabilities: [],
            canRead: false,
            canWrite: false,
            iconName: "doc.plaintext",
            supportsQuickLook: true,
            uiCategory: .document
        )
        result[plainText.identifier] = plainText

        // Markdown
        let markdown = FormatDescriptor(
            identifier: .markdown,
            displayName: "Markdown",
            formatDescription: "Markdown text file",
            extensions: ["md", "markdown"],
            mimeTypes: ["text/markdown"],
            capabilities: [],
            canRead: false,
            canWrite: false,
            iconName: "doc.plaintext",
            supportsQuickLook: true,
            uiCategory: .document
        )
        result[markdown.identifier] = markdown

        // CSV
        let csv = FormatDescriptor(
            identifier: .csv,
            displayName: "CSV",
            formatDescription: "Comma-separated values",
            extensions: ["csv"],
            mimeTypes: ["text/csv"],
            capabilities: [],
            canRead: false,
            canWrite: false,
            iconName: "tablecells",
            supportsQuickLook: true,
            uiCategory: .document
        )
        result[csv.identifier] = csv

        // TSV
        let tsv = FormatDescriptor(
            identifier: .tsv,
            displayName: "TSV",
            formatDescription: "Tab-separated values",
            extensions: ["tsv"],
            mimeTypes: ["text/tab-separated-values"],
            capabilities: [],
            canRead: false,
            canWrite: false,
            iconName: "tablecells",
            supportsQuickLook: true,
            uiCategory: .document
        )
        result[tsv.identifier] = tsv

        // ===== Image Formats (QuickLook) =====

        // PNG
        let png = FormatDescriptor(
            identifier: .png,
            displayName: "PNG",
            formatDescription: "Portable Network Graphics",
            extensions: ["png"],
            mimeTypes: ["image/png"],
            capabilities: [],
            supportsCompression: false,
            isBinary: true,
            canRead: false,
            canWrite: false,
            supportsQuickLook: true,
            uiCategory: .image
        )
        result[png.identifier] = png

        // JPEG
        let jpeg = FormatDescriptor(
            identifier: .jpeg,
            displayName: "JPEG",
            formatDescription: "JPEG image",
            extensions: ["jpg", "jpeg"],
            mimeTypes: ["image/jpeg"],
            capabilities: [],
            supportsCompression: false,
            isBinary: true,
            canRead: false,
            canWrite: false,
            supportsQuickLook: true,
            uiCategory: .image
        )
        result[jpeg.identifier] = jpeg

        // TIFF
        let tiff = FormatDescriptor(
            identifier: .tiff,
            displayName: "TIFF",
            formatDescription: "Tagged Image File Format",
            extensions: ["tiff", "tif"],
            mimeTypes: ["image/tiff"],
            capabilities: [],
            supportsCompression: false,
            isBinary: true,
            canRead: false,
            canWrite: false,
            supportsQuickLook: true,
            uiCategory: .image
        )
        result[tiff.identifier] = tiff

        // SVG
        let svg = FormatDescriptor(
            identifier: .svg,
            displayName: "SVG",
            formatDescription: "Scalable Vector Graphics",
            extensions: ["svg"],
            mimeTypes: ["image/svg+xml"],
            capabilities: [],
            isBinary: false,
            canRead: false,
            canWrite: false,
            supportsQuickLook: true,
            uiCategory: .image
        )
        result[svg.identifier] = svg

        return result
    }
}
