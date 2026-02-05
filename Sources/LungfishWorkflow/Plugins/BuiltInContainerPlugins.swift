// BuiltInContainerPlugins.swift - Built-in bioinformatics tool plugin definitions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - BuiltInContainerPlugins

/// Registry of built-in container tool plugins for reference genome bundle creation.
///
/// This enum provides factory methods for creating plugin definitions for common
/// bioinformatics tools used in the reference genome bundle pipeline:
///
/// - **samtools**: FASTA indexing (faidx), bgzip compression, BAM/SAM manipulation
/// - **bcftools**: VCF to BCF conversion and indexing
/// - **UCSC tools**: bedToBigBed, bedGraphToBigWig for UCSC track formats
///
/// ## Usage
///
/// ```swift
/// // Get all built-in plugins
/// let plugins = BuiltInContainerPlugins.all
///
/// // Get a specific plugin
/// if let samtools = BuiltInContainerPlugins.samtools {
///     let manager = ContainerPluginManager.shared
///     try await manager.execute(
///         pluginId: samtools.id,
///         command: "faidx",
///         parameters: ["INPUT": "/workspace/genome.fa"],
///         workspacePath: workDir
///     )
/// }
/// ```
public enum BuiltInContainerPlugins {
    
    // MARK: - Pre-built Bioinformatics Images

    /// Pre-built samtools image with tools already installed.
    /// Uses biocontainers image (amd64) with Rosetta emulation on Apple Silicon.
    public static let samtoolsImage = "quay.io/biocontainers/samtools:1.18--h50ea8bc_1"

    /// Pre-built bcftools image.
    public static let bcftoolsImage = "quay.io/biocontainers/bcftools:1.18--h8b25389_0"

    /// Pre-built UCSC tools image.
    public static let ucscToolsImage = "quay.io/biocontainers/ucsc-bedtobigbed:377--h199ee4e_4"

    /// Pre-built htslib (bgzip) image.
    public static let htslibImage = "quay.io/biocontainers/htslib:1.18--h81da01d_0"

    // MARK: - All Plugins

    /// All built-in container plugins.
    public static var all: [ContainerToolPlugin] {
        [
            samtools,
            bcftools,
            bedToBigBed,
            bedGraphToBigWig,
            bgzip
        ]
    }

    /// Returns a plugin by ID.
    public static func plugin(id: String) -> ContainerToolPlugin? {
        all.first { $0.id == id }
    }

    // MARK: - SAMtools

    /// SAMtools plugin for FASTA/BAM manipulation and indexing.
    ///
    /// Commands:
    /// - `faidx`: Create .fai index for FASTA files
    /// - `faidx_bgzip`: Create .fai and .gzi indices for bgzip-compressed FASTA
    /// - `view`: Convert SAM/BAM/CRAM formats
    /// - `sort`: Sort BAM files
    /// - `index`: Create .bai index for BAM files
    ///
    /// Uses biocontainers pre-built image with Rosetta emulation on Apple Silicon.
    public static let samtools = ContainerToolPlugin(
        id: "samtools",
        name: "SAMtools",
        description: "Tools for manipulating alignments in SAM/BAM/CRAM format and FASTA indexing",
        imageReference: samtoolsImage,
        commands: [
            "faidx": CommandTemplate(
                executable: "samtools",
                arguments: ["faidx", "${INPUT}"],
                description: "Index a FASTA file, creating a .fai index",
                producesOutput: true
            ),
            "faidx_bgzip": CommandTemplate(
                executable: "samtools",
                arguments: ["faidx", "${INPUT}"],
                description: "Index a bgzip-compressed FASTA file, creating .fai and .gzi indices",
                producesOutput: true
            ),
            "view": CommandTemplate(
                executable: "samtools",
                arguments: ["view", "-b", "${INPUT}", "-o", "${OUTPUT}"],
                description: "Convert SAM to BAM format",
                producesOutput: true
            ),
            "sort": CommandTemplate(
                executable: "samtools",
                arguments: ["sort", "-o", "${OUTPUT}", "${INPUT}"],
                description: "Sort a BAM file by coordinate",
                producesOutput: true
            ),
            "index": CommandTemplate(
                executable: "samtools",
                arguments: ["index", "${INPUT}"],
                description: "Create a .bai index for a BAM file",
                producesOutput: true
            ),
            "dict": CommandTemplate(
                executable: "samtools",
                arguments: ["dict", "${INPUT}", "-o", "${OUTPUT}"],
                description: "Create a sequence dictionary from a FASTA file",
                producesOutput: true
            )
        ],
        inputs: [
            PluginInput(
                name: "INPUT",
                type: .file,
                required: true,
                description: "Input file (FASTA, SAM, BAM, or CRAM)",
                acceptedExtensions: ["fa", "fasta", "fna", "fa.gz", "sam", "bam", "cram"]
            )
        ],
        outputs: [
            PluginOutput(
                name: "OUTPUT",
                type: .file,
                description: "Output file"
            ),
            PluginOutput(
                name: "INDEX",
                type: .file,
                description: "Index file (.fai, .bai, .csi)",
                fileExtension: "fai"
            )
        ],
        resources: ResourceRequirements(cpuCount: 4, memoryGB: 4),
        category: .indexing,
        version: "1.18",
        documentationURL: URL(string: "https://www.htslib.org/doc/samtools.html"),
        setupCommands: nil  // Tools are pre-installed in the biocontainers image
    )

    // MARK: - BCFtools

    /// BCFtools plugin for VCF/BCF manipulation and conversion.
    ///
    /// Commands:
    /// - `view`: Convert VCF to BCF and vice versa
    /// - `index`: Create CSI or TBI index for VCF/BCF files
    /// - `sort`: Sort VCF/BCF files
    /// - `norm`: Normalize variants
    ///
    /// Uses biocontainers pre-built image with Rosetta emulation on Apple Silicon.
    public static let bcftools = ContainerToolPlugin(
        id: "bcftools",
        name: "BCFtools",
        description: "Tools for variant calling and manipulating VCF/BCF files",
        imageReference: bcftoolsImage,
        commands: [
            "view": CommandTemplate(
                executable: "bcftools",
                arguments: ["view", "-O", "b", "-o", "${OUTPUT}", "${INPUT}"],
                description: "Convert VCF to BCF format",
                producesOutput: true
            ),
            "view_vcf": CommandTemplate(
                executable: "bcftools",
                arguments: ["view", "-O", "v", "-o", "${OUTPUT}", "${INPUT}"],
                description: "Convert BCF to VCF format",
                producesOutput: true
            ),
            "index": CommandTemplate(
                executable: "bcftools",
                arguments: ["index", "-c", "${INPUT}"],
                description: "Create CSI index for BCF file",
                producesOutput: true
            ),
            "index_tbi": CommandTemplate(
                executable: "bcftools",
                arguments: ["index", "-t", "${INPUT}"],
                description: "Create TBI (tabix) index for VCF file",
                producesOutput: true
            ),
            "sort": CommandTemplate(
                executable: "bcftools",
                arguments: ["sort", "-o", "${OUTPUT}", "${INPUT}"],
                description: "Sort VCF/BCF file",
                producesOutput: true
            ),
            "norm": CommandTemplate(
                executable: "bcftools",
                arguments: ["norm", "-f", "${REFERENCE}", "-o", "${OUTPUT}", "${INPUT}"],
                description: "Normalize variants against reference",
                producesOutput: true
            )
        ],
        inputs: [
            PluginInput(
                name: "INPUT",
                type: .file,
                required: true,
                description: "Input VCF or BCF file",
                acceptedExtensions: ["vcf", "vcf.gz", "bcf"]
            ),
            PluginInput(
                name: "REFERENCE",
                type: .file,
                required: false,
                description: "Reference FASTA file (for normalization)",
                acceptedExtensions: ["fa", "fasta", "fna", "fa.gz"]
            )
        ],
        outputs: [
            PluginOutput(
                name: "OUTPUT",
                type: .file,
                description: "Output VCF or BCF file"
            ),
            PluginOutput(
                name: "INDEX",
                type: .file,
                description: "Index file (.csi or .tbi)",
                fileExtension: "csi"
            )
        ],
        resources: ResourceRequirements(cpuCount: 2, memoryGB: 4),
        category: .variants,
        version: "1.18",
        documentationURL: URL(string: "https://samtools.github.io/bcftools/bcftools.html"),
        setupCommands: nil  // Tools are pre-installed in the biocontainers image
    )

    // MARK: - UCSC bedToBigBed

    /// UCSC bedToBigBed plugin for converting BED to BigBed format.
    ///
    /// BigBed is an indexed binary format for BED files that allows efficient
    /// random access to annotation tracks.
    ///
    /// Uses biocontainers pre-built image with Rosetta emulation on Apple Silicon.
    public static let bedToBigBed = ContainerToolPlugin(
        id: "bedToBigBed",
        name: "bedToBigBed",
        description: "Convert BED format to indexed BigBed format for efficient random access",
        imageReference: ucscToolsImage,
        commands: [
            "convert": CommandTemplate(
                executable: "bedToBigBed",
                arguments: ["${INPUT}", "${CHROM_SIZES}", "${OUTPUT}"],
                description: "Convert BED to BigBed format",
                producesOutput: true
            ),
            "convert_as": CommandTemplate(
                executable: "bedToBigBed",
                arguments: ["-as=${AS_FILE}", "-type=${BED_TYPE}", "${INPUT}", "${CHROM_SIZES}", "${OUTPUT}"],
                description: "Convert BED to BigBed with custom AutoSQL schema",
                producesOutput: true
            )
        ],
        inputs: [
            PluginInput(
                name: "INPUT",
                type: .file,
                required: true,
                description: "Input BED file (must be sorted)",
                acceptedExtensions: ["bed", "bed.gz"]
            ),
            PluginInput(
                name: "CHROM_SIZES",
                type: .file,
                required: true,
                description: "Chromosome sizes file",
                acceptedExtensions: ["sizes", "chrom.sizes", "txt"]
            ),
            PluginInput(
                name: "AS_FILE",
                type: .file,
                required: false,
                description: "AutoSQL schema file for custom BED types"
            ),
            PluginInput(
                name: "BED_TYPE",
                type: .string,
                required: false,
                description: "BED type (e.g., bed3, bed6, bed12)",
                defaultValue: "bed6"
            )
        ],
        outputs: [
            PluginOutput(
                name: "OUTPUT",
                type: .file,
                description: "Output BigBed file",
                fileExtension: "bb"
            )
        ],
        resources: ResourceRequirements(cpuCount: 1, memoryGB: 2),
        category: .conversion,
        version: "377",
        documentationURL: URL(string: "https://genome.ucsc.edu/goldenPath/help/bigBed.html"),
        setupCommands: nil  // Tools are pre-installed in the biocontainers image
    )

    // MARK: - UCSC bedGraphToBigWig

    /// UCSC bedGraphToBigWig plugin for converting bedGraph to BigWig format.
    ///
    /// BigWig is an indexed binary format for continuous signal data (coverage,
    /// GC content, conservation scores, etc.) that allows efficient random access.
    ///
    /// Uses biocontainers pre-built image with Rosetta emulation on Apple Silicon.
    public static let bedGraphToBigWig = ContainerToolPlugin(
        id: "bedGraphToBigWig",
        name: "bedGraphToBigWig",
        description: "Convert bedGraph format to indexed BigWig format for signal tracks",
        imageReference: "quay.io/biocontainers/ucsc-bedgraphtobigwig:377--h199ee4e_4",
        commands: [
            "convert": CommandTemplate(
                executable: "bedGraphToBigWig",
                arguments: ["${INPUT}", "${CHROM_SIZES}", "${OUTPUT}"],
                description: "Convert bedGraph to BigWig format",
                producesOutput: true
            )
        ],
        inputs: [
            PluginInput(
                name: "INPUT",
                type: .file,
                required: true,
                description: "Input bedGraph file (must be sorted)",
                acceptedExtensions: ["bedGraph", "bg", "bedgraph"]
            ),
            PluginInput(
                name: "CHROM_SIZES",
                type: .file,
                required: true,
                description: "Chromosome sizes file",
                acceptedExtensions: ["sizes", "chrom.sizes", "txt"]
            )
        ],
        outputs: [
            PluginOutput(
                name: "OUTPUT",
                type: .file,
                description: "Output BigWig file",
                fileExtension: "bw"
            )
        ],
        resources: ResourceRequirements(cpuCount: 1, memoryGB: 2),
        category: .conversion,
        version: "377",
        documentationURL: URL(string: "https://genome.ucsc.edu/goldenPath/help/bigWig.html"),
        setupCommands: nil  // Tools are pre-installed in the biocontainers image
    )

    // MARK: - bgzip (from htslib)

    /// bgzip plugin for block-gzip compression.
    ///
    /// bgzip creates blocked gzip files that support random access when paired
    /// with an index (.gzi file). This is essential for large FASTA files.
    ///
    /// Uses biocontainers pre-built htslib image with Rosetta emulation on Apple Silicon.
    public static let bgzip = ContainerToolPlugin(
        id: "bgzip",
        name: "bgzip",
        description: "Block compression/decompression utility for indexed random access",
        imageReference: htslibImage,
        commands: [
            "compress": CommandTemplate(
                executable: "bgzip",
                arguments: ["-c", "-i", "${INPUT}"],
                description: "Compress file with bgzip, creating .gz and .gzi files",
                producesOutput: true
            ),
            "compress_force": CommandTemplate(
                executable: "bgzip",
                arguments: ["-f", "-i", "${INPUT}"],
                description: "Compress file in place with bgzip (overwrites input)",
                producesOutput: true
            ),
            "decompress": CommandTemplate(
                executable: "bgzip",
                arguments: ["-d", "-c", "${INPUT}"],
                description: "Decompress bgzip file to stdout",
                producesOutput: true
            ),
            "index": CommandTemplate(
                executable: "bgzip",
                arguments: ["-r", "${INPUT}"],
                description: "Create .gzi index for existing .gz file",
                producesOutput: true
            )
        ],
        inputs: [
            PluginInput(
                name: "INPUT",
                type: .file,
                required: true,
                description: "Input file to compress or decompress",
                acceptedExtensions: ["fa", "fasta", "fna", "vcf", "bed", "gff", "gz"]
            )
        ],
        outputs: [
            PluginOutput(
                name: "OUTPUT",
                type: .file,
                description: "Compressed output file",
                fileExtension: "gz"
            ),
            PluginOutput(
                name: "INDEX",
                type: .file,
                description: "Block gzip index file",
                fileExtension: "gzi"
            )
        ],
        resources: ResourceRequirements(cpuCount: 1, memoryGB: 1),
        category: .conversion,
        version: "1.18",
        documentationURL: URL(string: "https://www.htslib.org/doc/bgzip.html"),
        setupCommands: nil  // Tools are pre-installed in the biocontainers image
    )
}

// MARK: - Plugin Discovery Extension

extension BuiltInContainerPlugins {

    /// Returns plugins for a specific category.
    public static func plugins(for category: PluginCategory) -> [ContainerToolPlugin] {
        all.filter { $0.category == category }
    }

    /// Returns plugins that can process a given file extension.
    public static func plugins(forExtension ext: String) -> [ContainerToolPlugin] {
        all.filter { plugin in
            plugin.inputs.contains { input in
                input.acceptedExtensions.contains(ext.lowercased())
            }
        }
    }

    /// Returns plugins required for reference bundle creation.
    ///
    /// These are the core tools needed for the reference genome bundle pipeline:
    /// - samtools (FASTA indexing)
    /// - bcftools (VCF to BCF)
    /// - bedToBigBed (BED to BigBed)
    /// - bedGraphToBigWig (bedGraph to BigWig)
    /// - bgzip (compression)
    public static var bundleCreationPlugins: [ContainerToolPlugin] {
        [samtools, bcftools, bedToBigBed, bedGraphToBigWig, bgzip]
    }
}
