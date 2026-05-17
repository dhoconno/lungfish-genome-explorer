// DocumentCapability.swift - Capability-based document modeling
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - DocumentCapability

/// Describes what a document can provide or what a tool requires.
///
/// Capabilities are composable - a document may have multiple capabilities,
/// and tools can require combinations of capabilities. This approach models
/// documents by what they can do rather than just their file format.
///
/// ## Overview
///
/// The capability system enables:
/// - **Format-agnostic validation**: Tools declare required capabilities, not formats
/// - **Automatic conversion**: The system can find conversion paths to satisfy requirements
/// - **Data loss warnings**: Users are warned when conversions lose capabilities
///
/// ## Example
/// ```swift
/// // FASTA provides only nucleotide sequences
/// let fastaCapabilities: DocumentCapability = [.nucleotideSequence]
///
/// // FASTQ adds quality scores
/// let fastqCapabilities: DocumentCapability = [.nucleotideSequence, .qualityScores]
///
/// // BAM provides alignment information
/// let bamCapabilities: DocumentCapability = [.nucleotideSequence, .qualityScores, .alignment]
///
/// // GenBank provides rich annotations
/// let genbankCapabilities: DocumentCapability = [.nucleotideSequence, .annotations, .richMetadata]
/// ```
///
/// ## Tool Requirements
/// ```swift
/// // BLAST requires nucleotide sequences
/// if document.satisfies(requirements: .nucleotideSequence) {
///     // Can run BLAST
/// }
///
/// // Variant calling requires sorted, indexed alignment
/// let variantRequirements: DocumentCapability = [.alignment, .sorted, .indexed]
/// if !document.satisfies(requirements: variantRequirements) {
///     let missing = document.missingCapabilities(for: variantRequirements)
///     // Handle missing capabilities
/// }
/// ```
public struct DocumentCapability: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // MARK: - Sequence Types

    /// Contains nucleotide sequence data (DNA or RNA).
    ///
    /// This is the most fundamental capability, present in FASTA, FASTQ,
    /// GenBank, BAM, and most other sequence formats.
    public static let nucleotideSequence = DocumentCapability(rawValue: 1 << 0)

    /// Contains amino acid/protein sequence data.
    ///
    /// Present in protein FASTA files and protein databases.
    public static let aminoAcidSequence = DocumentCapability(rawValue: 1 << 1)

    /// Contains per-base quality scores (Phred scores).
    ///
    /// Present in FASTQ files and BAM/SAM alignments. Quality scores
    /// indicate the confidence in each base call.
    public static let qualityScores = DocumentCapability(rawValue: 1 << 2)

    // MARK: - Annotations

    /// Contains feature annotations (genes, CDS, exons, etc.).
    ///
    /// Present in GenBank, GFF3, GTF, and BED formats. Annotations
    /// describe regions of interest on sequences.
    public static let annotations = DocumentCapability(rawValue: 1 << 3)

    /// Contains variant calls (SNPs, indels, structural variants).
    ///
    /// Present in VCF and BCF formats. Variants describe differences
    /// from a reference sequence.
    public static let variants = DocumentCapability(rawValue: 1 << 4)

    /// Contains quantitative/coverage data (e.g., BigWig signal).
    ///
    /// Present in BigWig, bedGraph, and similar coverage formats.
    /// Used for displaying read depth, expression levels, etc.
    public static let coverage = DocumentCapability(rawValue: 1 << 5)

    // MARK: - Alignment

    /// Contains aligned reads (mapped to a reference).
    ///
    /// Present in BAM, SAM, and CRAM formats. Indicates that sequences
    /// have positional information relative to a reference.
    public static let alignment = DocumentCapability(rawValue: 1 << 6)

    /// Contains paired-end read information.
    ///
    /// Present in paired-end BAM/SAM files. Indicates that reads have
    /// mate pair information for structural analysis.
    public static let pairedReads = DocumentCapability(rawValue: 1 << 7)

    /// Contains multiple sequence alignment (MSA).
    ///
    /// Present in alignment formats like CLUSTAL, Stockholm, and
    /// aligned FASTA. Different from read alignments - this is for
    /// evolutionary/comparative analysis.
    public static let multipleAlignment = DocumentCapability(rawValue: 1 << 8)

    // MARK: - Reference Features

    /// Can serve as a reference sequence.
    ///
    /// Indicates the document is suitable for use as a reference
    /// genome for alignment or variant calling.
    public static let referenceSequence = DocumentCapability(rawValue: 1 << 9)

    /// Has an associated index for random access.
    ///
    /// Present when .fai (FASTA index), .bai (BAM index), or .tbi
    /// (tabix index) files are available. Enables efficient region queries.
    public static let indexed = DocumentCapability(rawValue: 1 << 10)

    /// Is coordinate-sorted (required for many operations).
    ///
    /// Present when BAM/VCF files are sorted by genomic position.
    /// Required for indexing and many downstream tools.
    public static let sorted = DocumentCapability(rawValue: 1 << 11)

    /// Is compressed (gzip, bgzf, etc.).
    ///
    /// Indicates the file uses compression. BGZF compression is
    /// required for indexed access to BAM and tabix files.
    public static let compressed = DocumentCapability(rawValue: 1 << 12)

    // MARK: - Structural

    /// Contains assembly information (contigs, scaffolds).
    ///
    /// Present in assembly files with AGP data or scaffold information.
    public static let assembly = DocumentCapability(rawValue: 1 << 13)

    /// Contains phylogenetic tree data.
    ///
    /// Present in Newick, NEXUS, and phyloXML formats.
    public static let phylogeny = DocumentCapability(rawValue: 1 << 14)

    /// Contains primer/oligo information.
    ///
    /// Present in primer design output files.
    public static let primers = DocumentCapability(rawValue: 1 << 15)

    // MARK: - Metadata

    /// Contains rich metadata (organism, accession, references, etc.).
    ///
    /// Present in GenBank, EMBL, and other richly annotated formats.
    /// Includes taxonomic information, literature references, etc.
    public static let richMetadata = DocumentCapability(rawValue: 1 << 16)

    /// Contains circular topology information.
    ///
    /// Indicates the sequence is circular (plasmids, mitochondria, etc.).
    /// Important for proper display and analysis.
    public static let circularTopology = DocumentCapability(rawValue: 1 << 17)

    /// Contains translation/protein product information.
    ///
    /// Present when CDS features include their protein translations.
    public static let translationProducts = DocumentCapability(rawValue: 1 << 18)

    /// Contains cross-references to external databases.
    ///
    /// Present when annotations include database identifiers (UniProt, GO, etc.).
    public static let databaseCrossReferences = DocumentCapability(rawValue: 1 << 19)

    // MARK: - Read Information

    /// Contains read group information.
    ///
    /// Present in BAM files with @RG header entries. Used for
    /// sample tracking and multi-sample analysis.
    public static let readGroups = DocumentCapability(rawValue: 1 << 20)

    /// Contains supplementary alignments.
    ///
    /// Present when reads have chimeric/split alignments.
    public static let supplementaryAlignments = DocumentCapability(rawValue: 1 << 21)

    /// Contains base modification information (methylation, etc.).
    ///
    /// Present in BAM files with MM/ML tags from long-read sequencing.
    public static let baseModifications = DocumentCapability(rawValue: 1 << 22)

    // MARK: - Reserved for Future Use

    // Bits 23-31 are reserved for future capabilities

    // MARK: - Common Combinations

    /// Standard sequence with annotations (like GenBank).
    ///
    /// This combination is typical for reference sequences with
    /// gene annotations from databases like NCBI.
    public static let annotatedSequence: DocumentCapability = DocumentCapability(
        rawValue: DocumentCapability.nucleotideSequence.rawValue |
                  DocumentCapability.annotations.rawValue |
                  DocumentCapability.richMetadata.rawValue
    )

    /// Sequencing reads with quality (like FASTQ).
    ///
    /// This combination is typical for raw sequencing output.
    public static let sequencingReads: DocumentCapability = DocumentCapability(
        rawValue: DocumentCapability.nucleotideSequence.rawValue |
                  DocumentCapability.qualityScores.rawValue
    )

    /// Aligned reads (like BAM).
    ///
    /// This combination is typical for mapped sequencing data.
    public static let alignedReads: DocumentCapability = DocumentCapability(
        rawValue: DocumentCapability.nucleotideSequence.rawValue |
                  DocumentCapability.qualityScores.rawValue |
                  DocumentCapability.alignment.rawValue
    )

    /// Analysis-ready BAM (sorted and indexed).
    ///
    /// This combination is required for most downstream analysis
    /// tools like variant callers.
    public static let analysisReadyAlignment: DocumentCapability = DocumentCapability(
        rawValue: DocumentCapability.nucleotideSequence.rawValue |
                  DocumentCapability.qualityScores.rawValue |
                  DocumentCapability.alignment.rawValue |
                  DocumentCapability.sorted.rawValue |
                  DocumentCapability.indexed.rawValue
    )

    /// Reference genome (indexed for efficient access).
    ///
    /// This combination is typical for reference genomes used
    /// in alignment and variant calling.
    public static let indexedReference: DocumentCapability = DocumentCapability(
        rawValue: DocumentCapability.nucleotideSequence.rawValue |
                  DocumentCapability.referenceSequence.rawValue |
                  DocumentCapability.indexed.rawValue
    )

    /// Empty capability set.
    public static let none: DocumentCapability = DocumentCapability(rawValue: 0)

    /// All capabilities (for testing/debugging).
    public static let all = DocumentCapability(rawValue: UInt32.max)
}

// MARK: - CustomStringConvertible

extension DocumentCapability: CustomStringConvertible {
    /// A human-readable description of the capabilities.
    public var description: String {
        var components: [String] = []

        if contains(.nucleotideSequence) { components.append("nucleotideSequence") }
        if contains(.aminoAcidSequence) { components.append("aminoAcidSequence") }
        if contains(.qualityScores) { components.append("qualityScores") }
        if contains(.annotations) { components.append("annotations") }
        if contains(.variants) { components.append("variants") }
        if contains(.coverage) { components.append("coverage") }
        if contains(.alignment) { components.append("alignment") }
        if contains(.pairedReads) { components.append("pairedReads") }
        if contains(.multipleAlignment) { components.append("multipleAlignment") }
        if contains(.referenceSequence) { components.append("referenceSequence") }
        if contains(.indexed) { components.append("indexed") }
        if contains(.sorted) { components.append("sorted") }
        if contains(.compressed) { components.append("compressed") }
        if contains(.assembly) { components.append("assembly") }
        if contains(.phylogeny) { components.append("phylogeny") }
        if contains(.primers) { components.append("primers") }
        if contains(.richMetadata) { components.append("richMetadata") }
        if contains(.circularTopology) { components.append("circularTopology") }
        if contains(.translationProducts) { components.append("translationProducts") }
        if contains(.databaseCrossReferences) { components.append("databaseCrossReferences") }
        if contains(.readGroups) { components.append("readGroups") }
        if contains(.supplementaryAlignments) { components.append("supplementaryAlignments") }
        if contains(.baseModifications) { components.append("baseModifications") }

        if components.isEmpty {
            return "DocumentCapability(none)"
        }
        return "DocumentCapability([\(components.joined(separator: ", "))])"
    }
}

// MARK: - ExpressibleByArrayLiteral

extension DocumentCapability: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: DocumentCapability...) {
        self = elements.reduce(DocumentCapability(rawValue: 0)) { $0.union($1) }
    }
}

// MARK: - CapabilityProvider Protocol

/// A type that can provide document capabilities.
///
/// Implement this protocol to declare what capabilities a document,
/// format, or data source can provide. This enables tools to validate
/// inputs and the system to suggest appropriate conversions.
///
/// ## Example Implementation
/// ```swift
/// extension GenomicDocument: CapabilityProvider {
///     var capabilities: DocumentCapability {
///         var caps: DocumentCapability = []
///
///         // Check sequence types
///         for sequence in sequences {
///             switch sequence.alphabet {
///             case .dna, .rna:
///                 caps.insert(.nucleotideSequence)
///             case .protein:
///                 caps.insert(.aminoAcidSequence)
///             }
///         }
///
///         // Check for annotations
///         if annotationCount > 0 {
///             caps.insert(.annotations)
///         }
///
///         return caps
///     }
/// }
/// ```
public protocol CapabilityProvider: Sendable {
    /// The capabilities this provider offers.
    var capabilities: DocumentCapability { get }

    /// Check if this provider has all required capabilities.
    ///
    /// - Parameter requirements: The capabilities that must be present.
    /// - Returns: `true` if all required capabilities are present.
    func satisfies(requirements: DocumentCapability) -> Bool

    /// Check if this provider has a specific capability.
    ///
    /// - Parameter capability: The capability to check for.
    /// - Returns: `true` if the capability is present.
    func hasCapability(_ capability: DocumentCapability) -> Bool

    /// Returns missing capabilities if requirements are not satisfied.
    ///
    /// - Parameter requirements: The capabilities that should be present.
    /// - Returns: The set of capabilities that are required but not present.
    func missingCapabilities(for requirements: DocumentCapability) -> DocumentCapability
}

// MARK: - CapabilityProvider Default Implementations

extension CapabilityProvider {
    /// Default implementation checks if capabilities contain all requirements.
    public func satisfies(requirements: DocumentCapability) -> Bool {
        capabilities.contains(requirements)
    }

    /// Default implementation checks if capabilities contain the specific capability.
    public func hasCapability(_ capability: DocumentCapability) -> Bool {
        capabilities.contains(capability)
    }

    /// Default implementation returns the set difference.
    public func missingCapabilities(for requirements: DocumentCapability) -> DocumentCapability {
        requirements.subtracting(capabilities)
    }
}

// MARK: - CapabilityRequirement

/// Describes a capability requirement with additional context.
///
/// This struct provides more information than a simple capability check,
/// including whether a capability is strictly required or just recommended,
/// and what happens if it's missing.
public struct CapabilityRequirement: Sendable, Hashable {
    /// The capability being required.
    public let capability: DocumentCapability

    /// Whether this requirement is mandatory.
    public let isRequired: Bool

    /// Human-readable description of why this capability is needed.
    public let reason: String?

    /// What happens if this capability is missing.
    public let fallbackBehavior: FallbackBehavior

    /// Creates a new capability requirement.
    ///
    /// - Parameters:
    ///   - capability: The capability being required.
    ///   - isRequired: Whether this is mandatory (default: true).
    ///   - reason: Human-readable explanation (optional).
    ///   - fallbackBehavior: What to do if missing (default: .error).
    public init(
        _ capability: DocumentCapability,
        isRequired: Bool = true,
        reason: String? = nil,
        fallbackBehavior: FallbackBehavior = .error
    ) {
        self.capability = capability
        self.isRequired = isRequired
        self.reason = reason
        self.fallbackBehavior = fallbackBehavior
    }

    /// Behavior when a capability is missing.
    public enum FallbackBehavior: Sendable, Hashable {
        /// Fail with an error.
        case error
        /// Warn but continue.
        case warn
        /// Silently continue without the capability.
        case ignore
        /// Attempt to acquire the capability through conversion.
        case attemptConversion
    }
}

// MARK: - CapabilityValidationResult

/// Result of validating capabilities against requirements.
public enum CapabilityValidationResult: Sendable {
    /// All requirements are satisfied.
    case satisfied

    /// Some requirements are missing.
    case unsatisfied(missing: DocumentCapability, details: [CapabilityMismatch])

    /// Whether the validation passed.
    public var isValid: Bool {
        if case .satisfied = self { return true }
        return false
    }

    /// The missing capabilities, if any.
    public var missingCapabilities: DocumentCapability {
        switch self {
        case .satisfied:
            return .none
        case .unsatisfied(let missing, _):
            return missing
        }
    }
}

/// Details about a specific capability mismatch.
public struct CapabilityMismatch: Sendable {
    /// The missing capability.
    public let capability: DocumentCapability

    /// The original requirement.
    public let requirement: CapabilityRequirement

    /// Suggested action to resolve the mismatch.
    public let suggestedAction: String?

    public init(
        capability: DocumentCapability,
        requirement: CapabilityRequirement,
        suggestedAction: String? = nil
    ) {
        self.capability = capability
        self.requirement = requirement
        self.suggestedAction = suggestedAction
    }
}

// MARK: - CapabilityValidator

/// Validates capabilities against a set of requirements.
///
/// Use this to check if a document or data source has all the
/// capabilities needed for a specific operation.
///
/// ## Example
/// ```swift
/// let validator = CapabilityValidator(requirements: [
///     CapabilityRequirement(.nucleotideSequence, reason: "Sequences are required for alignment"),
///     CapabilityRequirement(.qualityScores, isRequired: false, fallbackBehavior: .warn)
/// ])
///
/// let result = validator.validate(document)
/// if !result.isValid {
///     // Handle missing capabilities
/// }
/// ```
public struct CapabilityValidator: Sendable {
    /// The requirements to validate against.
    public let requirements: [CapabilityRequirement]

    /// Creates a validator with the given requirements.
    public init(requirements: [CapabilityRequirement]) {
        self.requirements = requirements
    }

    /// Creates a validator with simple capability requirements.
    public init(required: DocumentCapability, optional: DocumentCapability = .none) {
        var reqs: [CapabilityRequirement] = []

        // Add required capabilities
        for bit in 0..<32 {
            let cap = DocumentCapability(rawValue: 1 << bit)
            if required.contains(cap) {
                reqs.append(CapabilityRequirement(cap, isRequired: true))
            } else if optional.contains(cap) {
                reqs.append(CapabilityRequirement(cap, isRequired: false, fallbackBehavior: .ignore))
            }
        }

        self.requirements = reqs
    }

    /// Validates a capability provider against the requirements.
    ///
    /// - Parameter provider: The capability provider to validate.
    /// - Returns: The validation result.
    public func validate(_ provider: some CapabilityProvider) -> CapabilityValidationResult {
        var missingCapabilities: DocumentCapability = .none
        var mismatches: [CapabilityMismatch] = []

        for requirement in requirements where requirement.isRequired {
            if !provider.hasCapability(requirement.capability) {
                missingCapabilities.formUnion(requirement.capability)
                mismatches.append(CapabilityMismatch(
                    capability: requirement.capability,
                    requirement: requirement,
                    suggestedAction: suggestedAction(for: requirement.capability)
                ))
            }
        }

        if missingCapabilities.isEmpty {
            return .satisfied
        }

        return .unsatisfied(missing: missingCapabilities, details: mismatches)
    }

    /// Suggests an action to acquire a missing capability.
    private func suggestedAction(for capability: DocumentCapability) -> String? {
        switch capability {
        case .sorted:
            return "Sort the file by coordinate using 'samtools sort'"
        case .indexed:
            return "Create an index using 'samtools index' or 'samtools faidx'"
        case .qualityScores:
            return "Use FASTQ format or BAM files which include quality scores"
        case .annotations:
            return "Load annotations from a GFF3, GTF, or GenBank file"
        case .alignment:
            return "Align reads to a reference using BWA or similar aligner"
        default:
            return nil
        }
    }
}
