// DefaultContainerImages.swift - Default container image definitions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - DefaultContainerImages

/// Default container images for Lungfish bioinformatics tools.
///
/// This enum provides the catalog of pre-configured container images organized by:
///
/// ## Core Images (Required for bundle creation)
/// - `samtools`: FASTA indexing, BAM manipulation
/// - `bcftools`: VCF/BCF conversion and indexing
/// - `htslib`: bgzip compression
/// - `ucsc-bedtobigbed`: BED to BigBed conversion
/// - `ucsc-bedgraphtobigwig`: bedGraph to BigWig conversion
///
/// ## Optional Images (Extended functionality)
/// - Aligners (minimap2, bwa, bowtie2)
/// - Assemblers (spades, flye)
/// - Quality control (fastqc, multiqc)
/// - Annotation tools (prokka, bakta)
///
/// ## Architecture
///
/// All images are OCI-compliant and pulled from registries like:
/// - Docker Hub (docker.io/*)
/// - Conda-Forge (for multi-arch support)
/// - GitHub Container Registry (ghcr.io/*)
///
/// ## Architecture Support
///
/// For Apple Silicon (arm64) support, we use `condaforge/mambaforge` as a base
/// image with tools installed via bioconda. This provides multi-arch support
/// (arm64 + amd64) for all bioinformatics tools.
///
/// The same base VM (vminit with Linux kernel) is used to run all containers.
/// Different tool images provide different capabilities within that VM.
public enum DefaultContainerImages {
    
    // MARK: - Base Image
    
    /// Multi-arch base image for bioinformatics tools.
    /// Uses conda-forge/mambaforge which supports arm64 (Apple Silicon) and amd64.
    public static let baseImage = "docker.io/condaforge/mambaforge:latest"
    
    // MARK: - All Images
    
    /// All default container images.
    public static var all: [ContainerImageSpec] {
        coreImages + optionalImages
    }
    
    /// Core images required for basic Lungfish functionality.
    public static var coreImages: [ContainerImageSpec] {
        [
            samtools,
            bcftools,
            htslib,
            ucscBedToBigBed,
            ucscBedGraphToBigWig
        ]
    }
    
    /// Optional images for extended functionality.
    public static var optionalImages: [ContainerImageSpec] {
        [
            minimap2,
            bwa,
            fastqc,
            multiqc
        ]
    }
    
    // MARK: - Core Images
    
    /// SAMtools - Tools for SAM/BAM/CRAM and FASTA indexing.
    ///
    /// Essential for creating .fai indices for FASTA files in reference bundles.
    /// Uses mambaforge base image with bioconda for arm64 support on Apple Silicon.
    public static let samtools = ContainerImageSpec(
        id: "samtools",
        name: "SAMtools",
        description: "Tools for manipulating alignments in SAM/BAM/CRAM format and FASTA indexing",
        reference: baseImage,
        category: .core,
        purpose: .indexing,
        version: "1.18",
        supportedExtensions: ["fa", "fasta", "fna", "fa.gz", "sam", "bam", "cram"],
        estimatedSizeBytes: 500_000_000, // ~500 MB (mambaforge base + tools)
        documentationURL: URL(string: "https://www.htslib.org/doc/samtools.html"),
        setupCommands: [
            ["mamba", "install", "-y", "-c", "conda-forge", "-c", "bioconda", "samtools=1.18", "htslib=1.18"]
        ]
    )
    
    /// BCFtools - Tools for VCF/BCF manipulation.
    ///
    /// Essential for converting VCF to indexed BCF in reference bundles.
    /// Uses mambaforge base image with bioconda for arm64 support on Apple Silicon.
    public static let bcftools = ContainerImageSpec(
        id: "bcftools",
        name: "BCFtools",
        description: "Tools for variant calling and manipulating VCF/BCF files",
        reference: baseImage,
        category: .core,
        purpose: .conversion,
        version: "1.18",
        supportedExtensions: ["vcf", "vcf.gz", "bcf"],
        estimatedSizeBytes: 500_000_000, // ~500 MB (mambaforge base + tools)
        documentationURL: URL(string: "https://samtools.github.io/bcftools/bcftools.html"),
        setupCommands: [
            ["mamba", "install", "-y", "-c", "conda-forge", "-c", "bioconda", "bcftools=1.18"]
        ]
    )
    
    /// HTSlib - Block compression utilities.
    ///
    /// Provides bgzip for creating indexed compressed FASTA files.
    /// Uses mambaforge base image with bioconda for arm64 support on Apple Silicon.
    public static let htslib = ContainerImageSpec(
        id: "htslib",
        name: "HTSlib",
        description: "Block compression/decompression utility for indexed random access",
        reference: baseImage,
        category: .core,
        purpose: .compression,
        version: "1.18",
        supportedExtensions: ["fa", "fasta", "fna", "vcf", "bed", "gff", "gz"],
        estimatedSizeBytes: 500_000_000, // ~500 MB (mambaforge base + tools)
        documentationURL: URL(string: "https://www.htslib.org/doc/bgzip.html"),
        setupCommands: [
            ["mamba", "install", "-y", "-c", "conda-forge", "-c", "bioconda", "htslib=1.18"]
        ]
    )
    
    /// UCSC bedToBigBed - BED to BigBed converter.
    ///
    /// Essential for creating indexed BigBed annotation tracks in reference bundles.
    /// Uses mambaforge base image with bioconda for arm64 support on Apple Silicon.
    public static let ucscBedToBigBed = ContainerImageSpec(
        id: "ucsc-bedtobigbed",
        name: "bedToBigBed",
        description: "Convert BED format to indexed BigBed format for efficient random access",
        reference: baseImage,
        category: .core,
        purpose: .conversion,
        version: "377",
        supportedExtensions: ["bed", "bed.gz"],
        estimatedSizeBytes: 500_000_000, // ~500 MB (mambaforge base + tools)
        documentationURL: URL(string: "https://genome.ucsc.edu/goldenPath/help/bigBed.html"),
        setupCommands: [
            ["mamba", "install", "-y", "-c", "conda-forge", "-c", "bioconda", "ucsc-bedtobigbed"]
        ]
    )
    
    /// UCSC bedGraphToBigWig - bedGraph to BigWig converter.
    ///
    /// Essential for creating indexed BigWig signal tracks in reference bundles.
    /// Uses mambaforge base image with bioconda for arm64 support on Apple Silicon.
    public static let ucscBedGraphToBigWig = ContainerImageSpec(
        id: "ucsc-bedgraphtobigwig",
        name: "bedGraphToBigWig",
        description: "Convert bedGraph format to indexed BigWig format for signal tracks",
        reference: baseImage,
        category: .core,
        purpose: .conversion,
        version: "377",
        supportedExtensions: ["bedGraph", "bg", "bedgraph"],
        estimatedSizeBytes: 500_000_000, // ~500 MB (mambaforge base + tools)
        documentationURL: URL(string: "https://genome.ucsc.edu/goldenPath/help/bigWig.html"),
        setupCommands: [
            ["mamba", "install", "-y", "-c", "conda-forge", "-c", "bioconda", "ucsc-bedgraphtobigwig"]
        ]
    )
    
    // MARK: - Optional Images: Aligners
    
    /// Minimap2 - Fast sequence aligner.
    ///
    /// High-performance aligner for long reads (PacBio, ONT) and assembly-to-assembly alignment.
    /// Uses mambaforge base image with bioconda for arm64 support on Apple Silicon.
    public static let minimap2 = ContainerImageSpec(
        id: "minimap2",
        name: "Minimap2",
        description: "A versatile sequence alignment program for DNA/RNA sequences",
        reference: baseImage,
        category: .optional,
        purpose: .alignment,
        version: "2.26",
        supportedExtensions: ["fa", "fasta", "fq", "fastq", "fa.gz", "fq.gz"],
        estimatedSizeBytes: 500_000_000, // ~500 MB (mambaforge base + tools)
        documentationURL: URL(string: "https://github.com/lh3/minimap2"),
        setupCommands: [
            ["mamba", "install", "-y", "-c", "conda-forge", "-c", "bioconda", "minimap2=2.26"]
        ]
    )
    
    /// BWA - Burrows-Wheeler Aligner.
    ///
    /// Classic short-read aligner for Illumina sequencing data.
    /// Uses mambaforge base image with bioconda for arm64 support on Apple Silicon.
    public static let bwa = ContainerImageSpec(
        id: "bwa",
        name: "BWA",
        description: "Burrows-Wheeler Aligner for short-read alignment",
        reference: baseImage,
        category: .optional,
        purpose: .alignment,
        version: "0.7.17",
        supportedExtensions: ["fa", "fasta", "fq", "fastq", "fa.gz", "fq.gz"],
        estimatedSizeBytes: 500_000_000, // ~500 MB (mambaforge base + tools)
        documentationURL: URL(string: "https://bio-bwa.sourceforge.net/"),
        setupCommands: [
            ["mamba", "install", "-y", "-c", "conda-forge", "-c", "bioconda", "bwa=0.7.17"]
        ]
    )
    
    // MARK: - Optional Images: Quality Control
    
    /// FastQC - Quality control for sequencing data.
    ///
    /// Generates quality reports for FASTQ files.
    /// Uses mambaforge base image with bioconda for arm64 support on Apple Silicon.
    public static let fastqc = ContainerImageSpec(
        id: "fastqc",
        name: "FastQC",
        description: "Quality control tool for high throughput sequence data",
        reference: baseImage,
        category: .optional,
        purpose: .qualityControl,
        version: "0.12.1",
        supportedExtensions: ["fq", "fastq", "fq.gz", "fastq.gz", "bam", "sam"],
        estimatedSizeBytes: 600_000_000, // ~600 MB (mambaforge base + Java + tools)
        documentationURL: URL(string: "https://www.bioinformatics.babraham.ac.uk/projects/fastqc/"),
        setupCommands: [
            ["mamba", "install", "-y", "-c", "conda-forge", "-c", "bioconda", "fastqc=0.12.1"]
        ]
    )
    
    /// MultiQC - Aggregate quality reports.
    ///
    /// Aggregates results from multiple QC tools into a single report.
    /// Uses mambaforge base image with bioconda for arm64 support on Apple Silicon.
    public static let multiqc = ContainerImageSpec(
        id: "multiqc",
        name: "MultiQC",
        description: "Aggregate results from bioinformatics analyses across many samples",
        reference: baseImage,
        category: .optional,
        purpose: .qualityControl,
        version: "1.17",
        supportedExtensions: [], // Works on output directories, not specific files
        estimatedSizeBytes: 550_000_000, // ~550 MB (mambaforge base + Python + tools)
        documentationURL: URL(string: "https://multiqc.info/"),
        setupCommands: [
            ["mamba", "install", "-y", "-c", "conda-forge", "-c", "bioconda", "multiqc=1.17"]
        ]
    )
}

// MARK: - Image Lookup Extensions

extension DefaultContainerImages {
    
    /// Returns an image specification by ID.
    public static func image(id: String) -> ContainerImageSpec? {
        all.first { $0.id == id }
    }
    
    /// Returns images for a specific purpose.
    public static func images(for purpose: ImagePurpose) -> [ContainerImageSpec] {
        all.filter { $0.purpose == purpose }
    }
    
    /// Returns images for a specific category.
    public static func images(for category: ImageCategory) -> [ContainerImageSpec] {
        all.filter { $0.category == category }
    }
    
    /// Returns images that can process a given file extension.
    public static func images(forExtension ext: String) -> [ContainerImageSpec] {
        let lowercasedExt = ext.lowercased()
        return all.filter { $0.supportedExtensions.contains(lowercasedExt) }
    }
    
    /// Returns the total estimated size of all core images.
    public static var estimatedCoreSizeBytes: UInt64 {
        coreImages.compactMap(\.estimatedSizeBytes).reduce(0, +)
    }
    
    /// Returns the total estimated size of all optional images.
    public static var estimatedOptionalSizeBytes: UInt64 {
        optionalImages.compactMap(\.estimatedSizeBytes).reduce(0, +)
    }
}
