// LungfishIO - File format parsing and I/O for Lungfish Genome Explorer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore

/// LungfishIO provides file format parsing and I/O capabilities.
///
/// ## Overview
///
/// This module contains:
/// - **Formats**: Parsers for FASTA, FASTQ, GenBank, GFF3, BAM, VCF, BigWig, etc.
/// - **Compression**: Support for gzip, BGZF, Zstandard
/// - **Index**: Index generation and access (FAI, BAI, CSI, TBI, R-tree)
///
/// ## Supported Formats
///
/// ### Sequence Formats
/// - FASTA (.fa, .fasta, .fna)
/// - FASTQ (.fq, .fastq)
/// - GenBank (.gb, .gbk)
/// - 2bit (.2bit)
///
/// ### Alignment Formats
/// - BAM (.bam) via htslib
/// - CRAM (.cram) via htslib
/// - SAM (.sam)
///
/// ### Annotation Formats
/// - GFF3 (.gff, .gff3)
/// - GTF (.gtf)
/// - BED (.bed)
/// - VCF (.vcf)
/// - BigBed (.bb)
///
/// ### Coverage/Signal
/// - BigWig (.bw)
/// - bedGraph (.bedgraph)
///
/// ## Example
///
/// ```swift
/// // Read a FASTA file
/// let reader = try FASTAReader(url: fastaURL)
/// for try await sequence in reader.sequences() {
///     print(sequence.name, sequence.length)
/// }
///
/// // Read with index for random access
/// let indexedReader = try IndexedFASTAReader(url: fastaURL)
/// let subsequence = try await indexedReader.fetch(region: region)
/// ```

// Re-export LungfishCore types for convenience
@_exported import LungfishCore
