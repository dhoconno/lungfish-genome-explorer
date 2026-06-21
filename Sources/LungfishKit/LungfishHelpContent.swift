// LungfishHelpContent.swift - Shared in-app scientific help copy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

@MainActor
public enum LungfishHelpContent {
    public enum Audience: String, Sendable {
        case benchScientist
        case analyst
        case powerUser
    }

    public struct HelpItem: Identifiable, Equatable, Sendable {
        public let id: String
        public let summary: String
        public let detail: String?
        public let audience: Audience
        public let provenanceRelevant: Bool

        public init(
            id: String,
            summary: String,
            detail: String? = nil,
            audience: Audience,
            provenanceRelevant: Bool = false
        ) {
            self.id = id
            self.summary = summary
            self.detail = detail
            self.audience = audience
            self.provenanceRelevant = provenanceRelevant
        }
    }

    public static let operationToolSidebar = HelpItem(
        id: "workflow.operation.toolSidebar",
        summary: "Choose the operation to run on the selected scientific inputs.",
        audience: .benchScientist
    )

    public static let operationReadiness = HelpItem(
        id: "workflow.operation.readiness",
        summary: "Shows whether the selected inputs and settings are ready to run.",
        detail: "If Run is unavailable, this text names the missing input or setting to fix.",
        audience: .benchScientist
    )

    public static let operationRun = HelpItem(
        id: "workflow.operation.run",
        summary: "Run with the visible settings and write output provenance.",
        detail: "Scientific outputs keep provenance for the command, inputs, defaults, checksums, status, and runtime.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqOverview = HelpItem(
        id: "workflow.fastq.overview",
        summary: "Review what this operation will do to the selected reads.",
        audience: .benchScientist
    )

    public static let fastqInputs = HelpItem(
        id: "workflow.fastq.inputs",
        summary: "Select the reference, database, or barcode file required by this tool.",
        detail: "External inputs and copied bundle payloads are recorded separately in provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqOutputStrategy = HelpItem(
        id: "workflow.fastq.outputStrategy",
        summary: "Choose whether outputs stay per input or combine compatible inputs.",
        detail: "Output strategy changes bundle topology and checksums in provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqAdvancedArguments = HelpItem(
        id: "workflow.fastq.advancedArguments",
        summary: "Pass extra arguments directly to the underlying command.",
        detail: "Extra arguments change the command argv and are written exactly in provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let fastqQualityThreshold = HelpItem(
        id: "workflow.fastq.field.qualityThreshold",
        summary: "Minimum base quality used when trimming low-quality read ends.",
        detail: "This value changes the command and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqWindowSize = HelpItem(
        id: "workflow.fastq.field.windowSize",
        summary: "Number of bases evaluated together by sliding-window trimming.",
        detail: "The resolved window size changes trimming behavior and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqQualityMode = HelpItem(
        id: "workflow.fastq.field.qualityMode",
        summary: "Choose which read ends are scanned for quality trimming.",
        detail: "The selected mode changes command arguments and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqAdapterMode = HelpItem(
        id: "workflow.fastq.field.adapterMode",
        summary: "Auto-detect adapters, or enter a known adapter sequence.",
        detail: "Adapter mode and resolved sequence choices are written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqAdapterSequence = HelpItem(
        id: "workflow.fastq.field.adapterSequence",
        summary: "Adapter sequence to remove from each read.",
        detail: "Use the sequence expected by the underlying trimmer. The value is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqPrimerSource = HelpItem(
        id: "workflow.fastq.field.primerSource",
        summary: "Use a literal primer sequence or a reference FASTA from Inputs.",
        detail: "Primer source changes command inputs and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqPrimerSequence = HelpItem(
        id: "workflow.fastq.field.primerSequence",
        summary: "Primer sequence to trim before downstream analysis.",
        detail: "The literal primer sequence changes trimming behavior and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqKmerSize = HelpItem(
        id: "workflow.fastq.field.kmerSize",
        summary: "K-mer length used for matching, correction, or filtering.",
        detail: "K-mer size changes command sensitivity and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqMinimumKmer = HelpItem(
        id: "workflow.fastq.field.minimumKmer",
        summary: "Smallest k-mer size to try when matching short seeds.",
        detail: "This value changes primer matching and is written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let fastqHammingDistance = HelpItem(
        id: "workflow.fastq.field.hammingDistance",
        summary: "Allowed mismatches for k-mer or sequence matching.",
        detail: "Mismatch tolerance changes filtering behavior and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqFixedBaseTrim = HelpItem(
        id: "workflow.fastq.field.fixedBaseTrim",
        summary: "Number of bases to remove from the selected read end.",
        detail: "Fixed trim counts change output reads and are written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqMinLength = HelpItem(
        id: "workflow.fastq.field.minLength",
        summary: "Minimum read length to keep. Leave blank to skip it.",
        detail: "Length bounds change retained reads and are written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqMaxLength = HelpItem(
        id: "workflow.fastq.field.maxLength",
        summary: "Maximum read length to keep. Leave blank to skip it.",
        detail: "Length bounds change retained reads and are written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqContaminantMode = HelpItem(
        id: "workflow.fastq.field.contaminantMode",
        summary: "Use PhiX filtering or provide a custom contaminant reference.",
        detail: "The selected mode and reference input are written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqRiboRetention = HelpItem(
        id: "workflow.fastq.field.riboRetention",
        summary: "Choose whether to keep non-rRNA reads or rRNA matches.",
        detail: "Retention choice changes output reads and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqDeduplicatePreset = HelpItem(
        id: "workflow.fastq.field.deduplicatePreset",
        summary: "Choose the duplicate matching rules to apply.",
        detail: "Preset and custom duplicate parameters are written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqDeduplicateSubstitutions = HelpItem(
        id: "workflow.fastq.field.deduplicateSubstitutions",
        summary: "Allowed substitutions when judging reads as duplicates.",
        detail: "This tolerance changes duplicate removal and is written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let fastqOpticalDuplicates = HelpItem(
        id: "workflow.fastq.field.opticalDuplicates",
        summary: "Also mark nearby flow-cell clusters as optical duplicates.",
        detail: "Optical duplicate handling changes command arguments and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqOpticalDistance = HelpItem(
        id: "workflow.fastq.field.opticalDistance",
        summary: "Maximum pixel distance for optical duplicate matching.",
        detail: "Optical distance changes duplicate classification and is written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let fastqMergeStrictness = HelpItem(
        id: "workflow.fastq.field.mergeStrictness",
        summary: "Choose normal or stricter paired-read overlap requirements.",
        detail: "Merge strictness changes output reads and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqMinimumOverlap = HelpItem(
        id: "workflow.fastq.field.minimumOverlap",
        summary: "Minimum overlapping bases required to merge paired reads.",
        detail: "Minimum overlap changes merged reads and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqOrientWordLength = HelpItem(
        id: "workflow.fastq.field.orientWordLength",
        summary: "Seed word length used when orienting reads to a reference.",
        detail: "Word length changes orientation matching and is written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let fastqDatabaseMask = HelpItem(
        id: "workflow.fastq.field.databaseMask",
        summary: "Choose whether low-complexity masking is applied to the database.",
        detail: "Database masking choice changes command arguments and is written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let fastqOutputName = HelpItem(
        id: "workflow.fastq.field.outputName",
        summary: "Name the output bundle or report written by this operation.",
        detail: "Output names and paths are recorded in command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqReportName = HelpItem(
        id: "workflow.fastq.field.reportName",
        summary: "Name the report file written by this workflow.",
        detail: "Report output path is recorded in command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqAnalysisName = HelpItem(
        id: "workflow.fastq.field.analysisName",
        summary: "Short label used inside generated analysis outputs.",
        detail: "Analysis labels are written with output command provenance when the workflow runs.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqThreads = HelpItem(
        id: "workflow.fastq.field.threads",
        summary: "Number of worker threads to request. Leave blank for default when allowed.",
        detail: "Thread count is part of the resolved command and provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let fastqSeed = HelpItem(
        id: "workflow.fastq.field.seed",
        summary: "Random seed used for reproducible clustering or sampling.",
        detail: "The seed is written with command provenance so stochastic steps can be repeated.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqMinReads = HelpItem(
        id: "workflow.fastq.field.minReads",
        summary: "Minimum supporting reads required before reporting a call.",
        detail: "Support threshold changes reported calls and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqProportion = HelpItem(
        id: "workflow.fastq.field.proportion",
        summary: "Fraction of reads to sample, from 0 to 1.",
        detail: "Sampling proportion changes output reads and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqCount = HelpItem(
        id: "workflow.fastq.field.count",
        summary: "Number of reads to sample. Leave blank to use the tool default.",
        detail: "Sampling count changes output reads and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqQuery = HelpItem(
        id: "workflow.fastq.field.query",
        summary: "Text to match against the selected FASTQ header field.",
        detail: "Search query changes extracted reads and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqSearchField = HelpItem(
        id: "workflow.fastq.field.searchField",
        summary: "Choose whether the query searches read IDs or descriptions.",
        detail: "Search field changes extracted reads and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqPattern = HelpItem(
        id: "workflow.fastq.field.pattern",
        summary: "Motif or pattern to match in read sequences.",
        detail: "Pattern matching changes extracted reads and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqRegex = HelpItem(
        id: "workflow.fastq.field.regex",
        summary: "Interpret the query or motif as a regular expression.",
        detail: "Regular-expression mode changes search behavior and is written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let fastqSequenceOrFasta = HelpItem(
        id: "workflow.fastq.field.sequenceOrFasta",
        summary: "Enter a sequence directly, or a FASTA path to search with.",
        detail: "Sequence input changes selected reads and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqSearchEnd = HelpItem(
        id: "workflow.fastq.field.searchEnd",
        summary: "Choose which read end must match the sequence search.",
        detail: "Search-end choice changes selected reads and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqErrorRate = HelpItem(
        id: "workflow.fastq.field.errorRate",
        summary: "Maximum allowed mismatch rate for approximate matching.",
        detail: "Error rate changes matching tolerance and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqKeepMatchedReads = HelpItem(
        id: "workflow.fastq.field.keepMatchedReads",
        summary: "Keep matching reads instead of removing them.",
        detail: "Keep/remove behavior changes output reads and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqSearchReverseComplement = HelpItem(
        id: "workflow.fastq.field.searchReverseComplement",
        summary: "Also search the reverse complement of the entered sequence.",
        detail: "Reverse-complement search changes selected reads and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqMAFFTStrategy = HelpItem(
        id: "workflow.fastq.field.mafftStrategy",
        summary: "Choose the MAFFT algorithm preset for the sequence set.",
        detail: "MAFFT strategy changes command arguments and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqMAFFTSequenceType = HelpItem(
        id: "workflow.fastq.field.mafftSequenceType",
        summary: "Tell MAFFT whether inputs are nucleotide, protein, or auto-detected.",
        detail: "Sequence type changes alignment behavior and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqMAFFTOutputOrder = HelpItem(
        id: "workflow.fastq.field.mafftOutputOrder",
        summary: "Choose whether aligned records keep input order or MAFFT order.",
        detail: "Output order is recorded with alignment command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqMAFFTDirectionAdjustment = HelpItem(
        id: "workflow.fastq.field.mafftDirectionAdjustment",
        summary: "Allow MAFFT to reverse-complement nucleotide records when needed.",
        detail: "Direction adjustment changes command arguments and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqMAFFTSymbolPolicy = HelpItem(
        id: "workflow.fastq.field.mafftSymbolPolicy",
        summary: "Choose how unexpected sequence symbols are handled before alignment.",
        detail: "Symbol policy changes preprocessing and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqMAFFTDeterministicThreads = HelpItem(
        id: "workflow.fastq.field.mafftDeterministicThreads",
        summary: "Use one thread when exact deterministic alignment is required.",
        detail: "Deterministic threading changes command arguments and is written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let fastqMAFFTAllowFASTQAssemblyInputs = HelpItem(
        id: "workflow.fastq.field.mafftAllowFASTQAssemblyInputs",
        summary: "Allow FASTQ records that represent assembled or consensus sequences.",
        detail: "This choice changes input validation and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqBarcodeSource = HelpItem(
        id: "workflow.fastq.field.barcodeSource",
        summary: "Use a built-in barcode kit or a custom barcode definition.",
        detail: "Barcode source and input path are written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqBarcodeKit = HelpItem(
        id: "workflow.fastq.field.barcodeKit",
        summary: "Built-in barcode kit expected for the sequencing library.",
        detail: "Kit identity changes demultiplexing and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqDemultiplexEngine = HelpItem(
        id: "workflow.fastq.field.demultiplexEngine",
        summary: "Choose exact barcode matching or cutadapt fuzzy matching.",
        detail: "Demultiplexing engine changes command arguments and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqDemultiplexLocation = HelpItem(
        id: "workflow.fastq.field.demultiplexLocation",
        summary: "Choose where cutadapt should look for barcode sequences.",
        detail: "Barcode search location changes matching behavior and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqDemultiplexDistance = HelpItem(
        id: "workflow.fastq.field.demultiplexDistance",
        summary: "Maximum bases from the read end to search for barcodes.",
        detail: "Distance limits change barcode matching and are written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let fastqDemultiplexTrimBarcodes = HelpItem(
        id: "workflow.fastq.field.demultiplexTrimBarcodes",
        summary: "Remove matched barcode sequence from demultiplexed reads.",
        detail: "Barcode trimming changes output reads and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqImportPlatform = HelpItem(
        id: "workflow.fastq.import.platform",
        summary: "Confirm the sequencing platform used to generate these reads.",
        detail: "Confirmed platform affects defaults and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqImportPairing = HelpItem(
        id: "workflow.fastq.import.pairing",
        summary: "Confirm whether files are single-end, paired-end, or interleaved.",
        detail: "Pairing mode changes import interpretation and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqImportQualityBinning = HelpItem(
        id: "workflow.fastq.import.qualityBinning",
        summary: "Choose quality-score binning for storage and downstream reuse.",
        detail: "Quality binning changes stored reads and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqImportClumpify = HelpItem(
        id: "workflow.fastq.import.clumpify",
        summary: "Reorder reads by k-mer similarity for better compression.",
        detail: "Clumpify changes storage order and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqImportCompression = HelpItem(
        id: "workflow.fastq.import.compression",
        summary: "Choose the compression speed and size tradeoff.",
        detail: "Compression choice changes output files and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let fastqImportRecipe = HelpItem(
        id: "workflow.fastq.import.recipe",
        summary: "Run a processing recipe immediately after import.",
        detail: "Recipe steps, inputs, command choices, and outputs are written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqImportBarcodeSheet = HelpItem(
        id: "workflow.fastq.import.barcodeSheet",
        summary: "CSV, TSV, or text sheet mapping barcodes to samples.",
        detail: "Barcode sheet path, size, and checksum are written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let fastqImportDemuxFolder = HelpItem(
        id: "workflow.fastq.import.demuxFolder",
        summary: "Project subfolder where demultiplexed FASTQ bundles will be written.",
        detail: "Output folder path is written in import command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamPrimerScheme = HelpItem(
        id: "workflow.bam.primerTrim.scheme",
        summary: "Choose the primer scheme matching the amplicon protocol used for this BAM.",
        detail: "The scheme name, input path, checksum, command, and runtime are written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamPrimerTrimAlignmentTrack = HelpItem(
        id: "workflow.bam.primerTrim.alignmentTrack",
        summary: "Select the BAM track to primer-trim.",
        detail: "The source BAM path and checksum are written in command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamPrimerTrimOutputTrack = HelpItem(
        id: "workflow.bam.primerTrim.outputTrack",
        summary: "Name the primer-trimmed BAM track added to the bundle.",
        detail: "The output track name and paths are written in command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let bamPrimerTrimRetainsUnmatchedReads = HelpItem(
        id: "workflow.bam.primerTrim.retainsUnmatchedReads",
        summary: "Reads without matching primers are retained by iVar trim.",
        detail: "Lungfish runs iVar trim with -e; review downstream QC before variant calling.",
        audience: .analyst
    )

    public static let bamPrimerTrimThresholds = HelpItem(
        id: "workflow.bam.primerTrim.thresholds",
        summary: "Adjust only if your assay requires non-default iVar trimming behavior.",
        detail: "These values become part of the command and provenance used by later iVar calls.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamPrimerTrimMinReadLength = HelpItem(
        id: "workflow.bam.primerTrim.minReadLength",
        summary: "Discard reads shorter than this length after primer trimming.",
        detail: "Minimum read length changes retained alignments and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamPrimerTrimMinQuality = HelpItem(
        id: "workflow.bam.primerTrim.minQuality",
        summary: "Minimum base quality used by the trimming filter.",
        detail: "Quality threshold changes retained bases and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamPrimerTrimSlidingWindow = HelpItem(
        id: "workflow.bam.primerTrim.slidingWindow",
        summary: "Window width used while trimming low-quality sequence.",
        detail: "Sliding window width changes trimming behavior and is written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let bamPrimerTrimOffset = HelpItem(
        id: "workflow.bam.primerTrim.offset",
        summary: "Primer coordinate offset for assays with shifted primer positions.",
        detail: "Primer offset changes trim coordinates and is written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let bamVariantAlignmentTrack = HelpItem(
        id: "workflow.bam.variantCalling.alignmentTrack",
        summary: "Select the analysis-ready BAM track to use as variant-calling input.",
        detail: "The track ID, source BAM path, and checksums are written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamVariantOutputTrack = HelpItem(
        id: "workflow.bam.variantCalling.outputTrack",
        summary: "Name the variant track that will be added to the bundle.",
        detail: "The output path, track name, command status, and runtime are written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamVariantThresholds = HelpItem(
        id: "workflow.bam.variantCalling.thresholds",
        summary: "Leave blank to use caller defaults, or enter explicit thresholds.",
        detail: "Resolved defaults and explicit thresholds are both written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamVariantIvarPrimerTrim = HelpItem(
        id: "workflow.bam.variantCalling.ivarPrimerTrim",
        summary: "Mark only if primers were removed from this exact BAM.",
        detail: "Prefer a primer-trim sidecar recorded by provenance because manual attestation affects iVar interpretation.",
        audience: .analyst
    )

    public static let bamVariantOntModel = HelpItem(
        id: "workflow.bam.variantCalling.ontModel",
        summary: "Enter the model name or path matching the basecaller chemistry.",
        detail: "Model identity, runtime, and command arguments are written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let bamVariantIvarConsensusAF = HelpItem(
        id: "workflow.bam.variantCalling.ivarConsensusAF",
        summary: "Allele-frequency threshold for including bases in iVar consensus.",
        detail: "Consensus allele-frequency threshold changes calls and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamVariantIvarMergeAF = HelpItem(
        id: "workflow.bam.variantCalling.ivarMergeAF",
        summary: "Allele-frequency distance used when merging nearby iVar calls.",
        detail: "Merge threshold changes iVar call grouping and is written with command provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let bamVariantIvarBadQuality = HelpItem(
        id: "workflow.bam.variantCalling.ivarBadQuality",
        summary: "Minimum ALT base quality required before iVar keeps a variant.",
        detail: "ALT quality threshold changes retained calls and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let bamVariantIvarStrandBias = HelpItem(
        id: "workflow.bam.variantCalling.ivarStrandBias",
        summary: "Disable strand-bias filtering when amplicon design makes it inappropriate.",
        detail: "Strand-bias handling changes iVar filtering and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let classifierBlastVerify = HelpItem(
        id: "workflow.classifier.blastVerify",
        summary: "Submit selected reads to NCBI BLAST for review.",
        detail: "Uses BLASTN nt without taxon restriction by default; reads leave the app for NCBI. This supports review, not diagnosis.",
        audience: .benchScientist
    )

    public static let classifierBlastReadCount = HelpItem(
        id: "workflow.classifier.blastReadCount",
        summary: "Choose how many selected reads to submit to BLAST.",
        detail: "Default is 20 reads and the maximum is 50. BLAST searches nt with E-value 1e-10 by default.",
        audience: .benchScientist
    )

    public static let classifierExtractFASTQ = HelpItem(
        id: "workflow.classifier.extractFASTQ",
        summary: "Extract reads matching the current selection.",
        detail: "The output keeps provenance for the command, inputs, checksums, and runtime.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let classifierExtractionSummary = HelpItem(
        id: "workflow.classifier.extraction.summary",
        summary: "Selected rows are combined into unique backing reads.",
        detail: "Extraction provenance records the command, inputs, selectors, output paths, checksums, and runtime.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let classifierExtractionFormat = HelpItem(
        id: "workflow.classifier.extraction.format",
        summary: "FASTQ preserves qualities; FASTA keeps sequence only.",
        detail: "Format choice changes output files and is written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let classifierExtractionUnmappedMates = HelpItem(
        id: "workflow.classifier.extraction.unmappedMates",
        summary: "Include unmapped mates from selected mapped read pairs.",
        detail: "Mate inclusion changes extracted reads and is written with command provenance.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let classifierExtractionDestination = HelpItem(
        id: "workflow.classifier.extraction.destination",
        summary: "Choose where extracted reads should be written.",
        detail: "Saved bundles and files preserve output paths and checksums in command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let classifierExtractionName = HelpItem(
        id: "workflow.classifier.extraction.name",
        summary: "Name the extracted output.",
        detail: "Output name and path are written with command provenance.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let metagenomicsNvdImportSource = HelpItem(
        id: "workflow.metagenomics.import.nvd.source",
        summary: "Select the NVD run folder containing 05_labkey_bundling.",
        detail: "Import provenance records source paths, input checksums, output paths, command status, and runtime.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let metagenomicsNaoMgsImportSource = HelpItem(
        id: "workflow.metagenomics.import.naoMgs.source",
        summary: "Select virus_hits_final.tsv.gz or its results directory.",
        detail: "Import provenance records source paths, input checksums, output paths, command status, and runtime.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let metagenomicsCzIdImportSource = HelpItem(
        id: "workflow.metagenomics.import.czId.source",
        summary: "Select a CZ-ID TSV, ZIP export, or extracted folder.",
        detail: "Import provenance records source paths, input checksums, output paths, command status, and runtime.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let metagenomicsImportDestination = HelpItem(
        id: "workflow.metagenomics.import.destination",
        summary: "Review where imported results will be stored.",
        detail: "Final stored payload paths are written in import provenance with checksums.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let operationCLIReplay = HelpItem(
        id: "operations.panel.cliReplay",
        summary: "Copy the replay command for debugging.",
        detail: "Stored bundle provenance remains authoritative for command, inputs, checksums, status, and runtime.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let operationOutputFiles = HelpItem(
        id: "operations.panel.outputFiles",
        summary: "Reveal files written by this operation.",
        detail: "Use provenance to verify final stored payload paths, checksums, command status, and runtime.",
        audience: .benchScientist,
        provenanceRelevant: true
    )

    public static let operationDiagnosticLog = HelpItem(
        id: "operations.panel.diagnosticLog",
        summary: "Open local diagnostic logs for troubleshooting.",
        detail: "Logs help debug failures. Command, inputs, checksums, status, and runtime stay in provenance.",
        audience: .powerUser,
        provenanceRelevant: true
    )

    public static let resultExport = HelpItem(
        id: "result.export",
        summary: "Export the current results table.",
        detail: "Exports that create scientific files write provenance for inputs, command choices, checksums, and runtime.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let resultProvenance = HelpItem(
        id: "result.provenance",
        summary: "Show tool, database, inputs, runtime, and import provenance.",
        detail: "Use provenance to verify the command, defaults, input checksums, output paths, status, and runtime.",
        audience: .analyst,
        provenanceRelevant: true
    )

    public static let workflowItems: [HelpItem] = [
        operationToolSidebar,
        operationReadiness,
        operationRun,
        fastqOverview,
        fastqInputs,
        fastqOutputStrategy,
        fastqAdvancedArguments,
    ]

    public static let fastqOperationFieldItems: [HelpItem] = [
        fastqQualityThreshold,
        fastqWindowSize,
        fastqQualityMode,
        fastqAdapterMode,
        fastqAdapterSequence,
        fastqPrimerSource,
        fastqPrimerSequence,
        fastqKmerSize,
        fastqMinimumKmer,
        fastqHammingDistance,
        fastqFixedBaseTrim,
        fastqMinLength,
        fastqMaxLength,
        fastqContaminantMode,
        fastqRiboRetention,
        fastqDeduplicatePreset,
        fastqDeduplicateSubstitutions,
        fastqOpticalDuplicates,
        fastqOpticalDistance,
        fastqMergeStrictness,
        fastqMinimumOverlap,
        fastqOrientWordLength,
        fastqDatabaseMask,
        fastqOutputName,
        fastqReportName,
        fastqAnalysisName,
        fastqThreads,
        fastqSeed,
        fastqMinReads,
        fastqProportion,
        fastqCount,
        fastqQuery,
        fastqSearchField,
        fastqPattern,
        fastqRegex,
        fastqSequenceOrFasta,
        fastqSearchEnd,
        fastqErrorRate,
        fastqKeepMatchedReads,
        fastqSearchReverseComplement,
        fastqMAFFTStrategy,
        fastqMAFFTSequenceType,
        fastqMAFFTOutputOrder,
        fastqMAFFTDirectionAdjustment,
        fastqMAFFTSymbolPolicy,
        fastqMAFFTDeterministicThreads,
        fastqMAFFTAllowFASTQAssemblyInputs,
        fastqBarcodeSource,
        fastqBarcodeKit,
        fastqDemultiplexEngine,
        fastqDemultiplexLocation,
        fastqDemultiplexDistance,
        fastqDemultiplexTrimBarcodes,
    ]

    public static let fastqImportItems: [HelpItem] = [
        fastqImportPlatform,
        fastqImportPairing,
        fastqImportQualityBinning,
        fastqImportClumpify,
        fastqImportCompression,
        fastqImportRecipe,
        fastqImportBarcodeSheet,
        fastqImportDemuxFolder,
    ]

    public static let bamItems: [HelpItem] = [
        bamPrimerScheme,
        bamPrimerTrimAlignmentTrack,
        bamPrimerTrimOutputTrack,
        bamPrimerTrimRetainsUnmatchedReads,
        bamPrimerTrimThresholds,
        bamPrimerTrimMinReadLength,
        bamPrimerTrimMinQuality,
        bamPrimerTrimSlidingWindow,
        bamPrimerTrimOffset,
        bamVariantAlignmentTrack,
        bamVariantOutputTrack,
        bamVariantThresholds,
        bamVariantIvarPrimerTrim,
        bamVariantOntModel,
        bamVariantIvarConsensusAF,
        bamVariantIvarMergeAF,
        bamVariantIvarBadQuality,
        bamVariantIvarStrandBias,
    ]

    public static let resultItems: [HelpItem] = [
        classifierBlastVerify,
        classifierBlastReadCount,
        classifierExtractFASTQ,
        classifierExtractionSummary,
        classifierExtractionFormat,
        classifierExtractionUnmappedMates,
        classifierExtractionDestination,
        classifierExtractionName,
        metagenomicsNvdImportSource,
        metagenomicsNaoMgsImportSource,
        metagenomicsCzIdImportSource,
        metagenomicsImportDestination,
        operationCLIReplay,
        operationOutputFiles,
        operationDiagnosticLog,
        resultExport,
        resultProvenance,
    ]

    public static let allItems: [HelpItem] = [
        workflowItems,
        fastqOperationFieldItems,
        fastqImportItems,
        bamItems,
        resultItems,
    ].flatMap { $0 }
}

public extension View {
    func lungfishHelp(_ item: LungfishHelpContent.HelpItem) -> some View {
        help(item.summary)
            .accessibilityHint(item.detail ?? item.summary)
    }

    @ViewBuilder
    func lungfishHelpIfPresent(_ item: LungfishHelpContent.HelpItem?) -> some View {
        if let item {
            lungfishHelp(item)
        } else {
            self
        }
    }

    func lungfishHelpSummary(_ summary: String) -> some View {
        help(summary)
            .accessibilityHint(summary)
    }
}

@MainActor
public extension NSControl {
    func applyLungfishHelp(_ item: LungfishHelpContent.HelpItem) {
        toolTip = item.summary
        setAccessibilityHelp(item.detail ?? item.summary)
    }
}
