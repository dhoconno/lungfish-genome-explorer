# Format Conversion Architecture

**Design Document: DESIGN-003**
**Author:** Lungfish Development Team
**Date:** 2026-02-03
**Status:** Draft

---

## Executive Summary

This document defines a comprehensive file format conversion architecture for Lungfish Genome Explorer, inspired by Geneious Prime's capability-based document system. The architecture enables:

1. **Capability-based document modeling** - Documents declare what they can do, not just what format they are
2. **Tool input/output constraints** - Tools declare required capabilities, enabling automatic validation
3. **Unified format registry** - Single point of truth for all importers and exporters
4. **Automatic conversion pipelines** - Seamless format conversion when tools require different inputs
5. **External tool integration** - Temp file management for BAM/SAM processing with samtools

---

## 1. Document Capability System

### 1.1 DocumentCapability Enum

Documents are characterized by their capabilities rather than just their file format. This allows tools to express requirements in terms of what data they need, not what format it must be in.

```swift
// File: Sources/LungfishCore/Models/DocumentCapability.swift

import Foundation

/// Describes what a document can provide or what a tool requires.
///
/// Capabilities are composable - a document may have multiple capabilities,
/// and tools can require combinations of capabilities.
///
/// ## Example
/// ```swift
/// let fastaCapabilities: DocumentCapabilities = [.nucleotideSequence]
/// let fastqCapabilities: DocumentCapabilities = [.nucleotideSequence, .qualityScores]
/// let bamCapabilities: DocumentCapabilities = [.nucleotideSequence, .qualityScores, .alignment, .pairedReads]
/// ```
public struct DocumentCapability: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // MARK: - Sequence Types

    /// Contains nucleotide sequence data (DNA or RNA)
    public static let nucleotideSequence = DocumentCapability(rawValue: 1 << 0)

    /// Contains amino acid/protein sequence data
    public static let aminoAcidSequence = DocumentCapability(rawValue: 1 << 1)

    /// Contains per-base quality scores (Phred scores)
    public static let qualityScores = DocumentCapability(rawValue: 1 << 2)

    // MARK: - Annotations

    /// Contains feature annotations (genes, CDS, etc.)
    public static let annotations = DocumentCapability(rawValue: 1 << 3)

    /// Contains variant calls (SNPs, indels, etc.)
    public static let variants = DocumentCapability(rawValue: 1 << 4)

    /// Contains quantitative/coverage data (e.g., BigWig signal)
    public static let coverage = DocumentCapability(rawValue: 1 << 5)

    // MARK: - Alignment

    /// Contains aligned reads (mapped to reference)
    public static let alignment = DocumentCapability(rawValue: 1 << 6)

    /// Contains paired-end read information
    public static let pairedReads = DocumentCapability(rawValue: 1 << 7)

    /// Contains multiple sequence alignment (MSA)
    public static let multipleAlignment = DocumentCapability(rawValue: 1 << 8)

    // MARK: - Reference Features

    /// Can serve as a reference sequence
    public static let referenceSequence = DocumentCapability(rawValue: 1 << 9)

    /// Has an associated index for random access
    public static let indexed = DocumentCapability(rawValue: 1 << 10)

    /// Is coordinate-sorted (required for many operations)
    public static let sorted = DocumentCapability(rawValue: 1 << 11)

    // MARK: - Structural

    /// Contains assembly information (contigs, scaffolds)
    public static let assembly = DocumentCapability(rawValue: 1 << 12)

    /// Contains phylogenetic tree data
    public static let phylogeny = DocumentCapability(rawValue: 1 << 13)

    /// Contains primer/oligo information
    public static let primers = DocumentCapability(rawValue: 1 << 14)

    // MARK: - Metadata

    /// Contains rich metadata (organism, accession, etc.)
    public static let richMetadata = DocumentCapability(rawValue: 1 << 15)

    /// Contains circular topology information
    public static let circularTopology = DocumentCapability(rawValue: 1 << 16)

    // MARK: - Common Combinations

    /// Standard sequence with annotations (like GenBank)
    public static let annotatedSequence: DocumentCapability = [
        .nucleotideSequence, .annotations, .richMetadata
    ]

    /// Sequencing reads with quality (like FASTQ)
    public static let sequencingReads: DocumentCapability = [
        .nucleotideSequence, .qualityScores
    ]

    /// Aligned reads (like BAM)
    public static let alignedReads: DocumentCapability = [
        .nucleotideSequence, .qualityScores, .alignment
    ]
}

/// Type alias for a set of capabilities
public typealias DocumentCapabilities = DocumentCapability
```

### 1.2 CapabilityProvider Protocol

Documents and data sources implement this protocol to declare their capabilities.

```swift
// File: Sources/LungfishCore/Protocols/CapabilityProvider.swift

import Foundation

/// A type that can provide document capabilities.
///
/// Implement this protocol to declare what capabilities a document,
/// format, or data source can provide.
public protocol CapabilityProvider: Sendable {
    /// The capabilities this provider offers
    var capabilities: DocumentCapabilities { get }

    /// Check if this provider has all required capabilities
    func satisfies(requirements: DocumentCapabilities) -> Bool

    /// Returns missing capabilities if requirements are not satisfied
    func missingCapabilities(for requirements: DocumentCapabilities) -> DocumentCapabilities
}

extension CapabilityProvider {
    public func satisfies(requirements: DocumentCapabilities) -> Bool {
        capabilities.contains(requirements)
    }

    public func missingCapabilities(for requirements: DocumentCapabilities) -> DocumentCapabilities {
        requirements.subtracting(capabilities)
    }
}
```

### 1.3 Extend GenomicDocument with Capabilities

```swift
// Extension to existing GenomicDocument.swift

extension GenomicDocument: CapabilityProvider {
    /// Computed capabilities based on document content
    public var capabilities: DocumentCapabilities {
        var caps: DocumentCapabilities = []

        // Check sequences
        for sequence in sequences {
            switch sequence.alphabet {
            case .dna, .rna:
                caps.insert(.nucleotideSequence)
            case .protein:
                caps.insert(.aminoAcidSequence)
            }

            if sequence.qualityScores != nil {
                caps.insert(.qualityScores)
            }

            if sequence.isCircular {
                caps.insert(.circularTopology)
            }
        }

        // Check annotations
        if annotationCount > 0 {
            caps.insert(.annotations)
        }

        // Check metadata
        if metadata.organism != nil || metadata.accession != nil {
            caps.insert(.richMetadata)
        }

        // Document type specific
        switch documentType {
        case .reference:
            caps.insert(.referenceSequence)
        case .alignment:
            caps.insert(.multipleAlignment)
        case .variants:
            caps.insert(.variants)
        case .assembly:
            caps.insert(.assembly)
        default:
            break
        }

        return caps
    }
}
```

---

## 2. Tool Input/Output Constraints

### 2.1 InputSignature Struct

Tools declare their input requirements using InputSignature. This enables the system to validate inputs and automatically suggest or perform conversions.

```swift
// File: Sources/LungfishCore/Tools/InputSignature.swift

import Foundation

/// Declares the input requirements for a tool or operation.
///
/// InputSignature allows tools to specify:
/// - Required capabilities (must have all of these)
/// - Optional capabilities (can use if available)
/// - Minimum/maximum number of inputs
/// - Format preferences for optimization
///
/// ## Example
/// ```swift
/// // BLAST requires nucleotide sequences
/// let blastInput = InputSignature(
///     required: .nucleotideSequence,
///     optional: .annotations,
///     minInputs: 1,
///     maxInputs: nil, // unlimited
///     preferredFormats: [.fasta]
/// )
///
/// // Variant calling requires aligned, sorted, indexed BAM
/// let variantCallingInput = InputSignature(
///     required: [.alignment, .sorted, .indexed],
///     optional: .pairedReads,
///     minInputs: 1,
///     maxInputs: 1,
///     preferredFormats: [.bam]
/// )
/// ```
public struct InputSignature: Sendable, Hashable {

    /// Capabilities that MUST be present
    public let required: DocumentCapabilities

    /// Capabilities that CAN be used if available
    public let optional: DocumentCapabilities

    /// Minimum number of input documents
    public let minInputs: Int

    /// Maximum number of input documents (nil = unlimited)
    public let maxInputs: Int?

    /// Preferred file formats for optimization (empty = no preference)
    public let preferredFormats: [FormatIdentifier]

    /// Human-readable description of requirements
    public let description: String?

    public init(
        required: DocumentCapabilities,
        optional: DocumentCapabilities = [],
        minInputs: Int = 1,
        maxInputs: Int? = 1,
        preferredFormats: [FormatIdentifier] = [],
        description: String? = nil
    ) {
        self.required = required
        self.optional = optional
        self.minInputs = minInputs
        self.maxInputs = maxInputs
        self.preferredFormats = preferredFormats
        self.description = description
    }

    /// Validates that a set of documents satisfies this signature
    public func validate(_ providers: [any CapabilityProvider]) -> InputValidationResult {
        // Check count constraints
        if providers.count < minInputs {
            return .failure(.tooFewInputs(expected: minInputs, got: providers.count))
        }
        if let max = maxInputs, providers.count > max {
            return .failure(.tooManyInputs(expected: max, got: providers.count))
        }

        // Check capability requirements for each input
        var missingByInput: [Int: DocumentCapabilities] = [:]
        for (index, provider) in providers.enumerated() {
            let missing = provider.missingCapabilities(for: required)
            if !missing.isEmpty {
                missingByInput[index] = missing
            }
        }

        if !missingByInput.isEmpty {
            return .failure(.missingCapabilities(missingByInput))
        }

        return .success
    }
}

/// Result of validating inputs against a signature
public enum InputValidationResult: Sendable {
    case success
    case failure(InputValidationError)

    public var isValid: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Errors that can occur during input validation
public enum InputValidationError: Error, LocalizedError, Sendable {
    case tooFewInputs(expected: Int, got: Int)
    case tooManyInputs(expected: Int, got: Int)
    case missingCapabilities([Int: DocumentCapabilities])

    public var errorDescription: String? {
        switch self {
        case .tooFewInputs(let expected, let got):
            return "Expected at least \(expected) inputs, got \(got)"
        case .tooManyInputs(let expected, let got):
            return "Expected at most \(expected) inputs, got \(got)"
        case .missingCapabilities(let missing):
            let descriptions = missing.map { "Input \($0.key): missing capabilities" }
            return descriptions.joined(separator: "; ")
        }
    }
}
```

### 2.2 OutputType Enum

Tools declare what they produce using OutputType.

```swift
// File: Sources/LungfishCore/Tools/OutputType.swift

import Foundation

/// Describes what a tool produces as output.
public enum OutputType: Sendable, Hashable {
    /// Produces a single document with specified capabilities
    case document(capabilities: DocumentCapabilities)

    /// Produces multiple documents (one per input)
    case documentsPerInput(capabilities: DocumentCapabilities)

    /// Produces a single merged/combined document
    case mergedDocument(capabilities: DocumentCapabilities)

    /// Produces a report/statistics (not a genomic document)
    case report(format: ReportFormat)

    /// Produces a file in a specific format
    case file(format: FormatIdentifier)

    /// Produces multiple files
    case files(formats: [FormatIdentifier])

    /// No output (side-effect only, like indexing)
    case none
}

/// Supported report formats
public enum ReportFormat: String, Sendable, Hashable {
    case html
    case pdf
    case csv
    case tsv
    case json
    case text
}
```

### 2.3 ToolDefinition Protocol

```swift
// File: Sources/LungfishCore/Tools/ToolDefinition.swift

import Foundation

/// Defines a tool's interface for input/output validation.
///
/// Tools implement this protocol to declare their requirements,
/// enabling automatic validation and conversion suggestions.
public protocol ToolDefinition: Sendable {
    /// Unique identifier for the tool
    var toolID: String { get }

    /// Human-readable name
    var displayName: String { get }

    /// Tool category for organization
    var category: ToolCategory { get }

    /// Input requirements
    var inputSignature: InputSignature { get }

    /// Output specification
    var outputType: OutputType { get }

    /// Whether this tool requires external executables
    var requiresExternalBinary: Bool { get }

    /// External binary name if required (e.g., "samtools", "blast")
    var externalBinaryName: String? { get }
}

/// Categories for organizing tools
public enum ToolCategory: String, Sendable, CaseIterable {
    case alignment
    case assembly
    case annotation
    case variantCalling
    case phylogenetics
    case sequenceAnalysis
    case qualityControl
    case conversion
    case visualization
    case utility
}
```

### 2.4 Example Tool Definitions

```swift
// File: Sources/LungfishWorkflow/Tools/BuiltInTools.swift

import LungfishCore

/// Built-in tool definitions for common operations
public enum BuiltInTools {

    /// BLAST sequence alignment
    public static let blast = GenericToolDefinition(
        toolID: "blast",
        displayName: "BLAST Search",
        category: .alignment,
        inputSignature: InputSignature(
            required: .nucleotideSequence,
            optional: .annotations,
            minInputs: 1,
            maxInputs: nil,
            preferredFormats: [.fasta],
            description: "Nucleotide sequences to search"
        ),
        outputType: .report(format: .tsv),
        requiresExternalBinary: true,
        externalBinaryName: "blastn"
    )

    /// BWA alignment
    public static let bwaAlign = GenericToolDefinition(
        toolID: "bwa-mem",
        displayName: "BWA MEM Alignment",
        category: .alignment,
        inputSignature: InputSignature(
            required: .nucleotideSequence,
            optional: .qualityScores,
            minInputs: 1,
            maxInputs: 2, // single or paired
            preferredFormats: [.fastq],
            description: "Sequencing reads (single or paired-end)"
        ),
        outputType: .file(format: .bam),
        requiresExternalBinary: true,
        externalBinaryName: "bwa"
    )

    /// Variant calling with bcftools
    public static let variantCalling = GenericToolDefinition(
        toolID: "bcftools-call",
        displayName: "Variant Calling",
        category: .variantCalling,
        inputSignature: InputSignature(
            required: [.alignment, .sorted, .indexed],
            optional: .pairedReads,
            minInputs: 1,
            maxInputs: 1,
            preferredFormats: [.bam],
            description: "Sorted, indexed BAM file"
        ),
        outputType: .file(format: .vcf),
        requiresExternalBinary: true,
        externalBinaryName: "bcftools"
    )

    /// Sequence extraction (built-in)
    public static let extractSequences = GenericToolDefinition(
        toolID: "extract-sequences",
        displayName: "Extract Sequences",
        category: .utility,
        inputSignature: InputSignature(
            required: .nucleotideSequence,
            optional: .annotations,
            minInputs: 1,
            maxInputs: nil,
            description: "Documents containing sequences"
        ),
        outputType: .documentsPerInput(capabilities: .nucleotideSequence),
        requiresExternalBinary: false,
        externalBinaryName: nil
    )

    /// Translate to protein (built-in)
    public static let translate = GenericToolDefinition(
        toolID: "translate",
        displayName: "Translate to Protein",
        category: .sequenceAnalysis,
        inputSignature: InputSignature(
            required: .nucleotideSequence,
            optional: .annotations,
            minInputs: 1,
            maxInputs: nil,
            description: "DNA or RNA sequences to translate"
        ),
        outputType: .documentsPerInput(capabilities: .aminoAcidSequence),
        requiresExternalBinary: false,
        externalBinaryName: nil
    )
}

/// Generic implementation of ToolDefinition
public struct GenericToolDefinition: ToolDefinition {
    public let toolID: String
    public let displayName: String
    public let category: ToolCategory
    public let inputSignature: InputSignature
    public let outputType: OutputType
    public let requiresExternalBinary: Bool
    public let externalBinaryName: String?
}
```

---

## 3. Format Registry System

### 3.1 FormatIdentifier

```swift
// File: Sources/LungfishIO/Registry/FormatIdentifier.swift

import Foundation

/// Identifies a file format in the registry.
public struct FormatIdentifier: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    /// The unique identifier string (e.g., "fasta", "bam", "vcf")
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.lowercased()
    }

    public init(stringLiteral value: String) {
        self.rawValue = value.lowercased()
    }

    // MARK: - Standard Format Identifiers

    // Sequence formats
    public static let fasta: FormatIdentifier = "fasta"
    public static let fastq: FormatIdentifier = "fastq"
    public static let genbank: FormatIdentifier = "genbank"
    public static let embl: FormatIdentifier = "embl"
    public static let twoBit: FormatIdentifier = "2bit"

    // Alignment formats
    public static let sam: FormatIdentifier = "sam"
    public static let bam: FormatIdentifier = "bam"
    public static let cram: FormatIdentifier = "cram"

    // Annotation formats
    public static let gff3: FormatIdentifier = "gff3"
    public static let gtf: FormatIdentifier = "gtf"
    public static let bed: FormatIdentifier = "bed"

    // Variant formats
    public static let vcf: FormatIdentifier = "vcf"
    public static let bcf: FormatIdentifier = "bcf"

    // Coverage/signal formats
    public static let bigwig: FormatIdentifier = "bigwig"
    public static let bigbed: FormatIdentifier = "bigbed"
    public static let bedgraph: FormatIdentifier = "bedgraph"

    // Index formats
    public static let fai: FormatIdentifier = "fai"
    public static let bai: FormatIdentifier = "bai"
    public static let csi: FormatIdentifier = "csi"
    public static let tbi: FormatIdentifier = "tbi"
}
```

### 3.2 FormatDescriptor

```swift
// File: Sources/LungfishIO/Registry/FormatDescriptor.swift

import Foundation
import LungfishCore

/// Describes a file format's properties and capabilities.
public struct FormatDescriptor: Sendable {
    /// Unique identifier for this format
    public let identifier: FormatIdentifier

    /// Human-readable name
    public let displayName: String

    /// Brief description
    public let description: String

    /// File extensions associated with this format
    public let extensions: Set<String>

    /// MIME types for this format
    public let mimeTypes: Set<String>

    /// Magic bytes for format detection (first N bytes)
    public let magicBytes: Data?

    /// Capabilities that documents in this format provide
    public let providedCapabilities: DocumentCapabilities

    /// Whether this format supports compression
    public let supportsCompression: Bool

    /// Compression types supported
    public let supportedCompression: Set<CompressionType>

    /// Whether this format requires an external index
    public let requiresIndex: Bool

    /// Associated index format if applicable
    public let indexFormat: FormatIdentifier?

    /// Whether this format is binary
    public let isBinary: Bool

    /// Whether we can read this format
    public let canRead: Bool

    /// Whether we can write this format
    public let canWrite: Bool

    public init(
        identifier: FormatIdentifier,
        displayName: String,
        description: String,
        extensions: Set<String>,
        mimeTypes: Set<String> = [],
        magicBytes: Data? = nil,
        providedCapabilities: DocumentCapabilities,
        supportsCompression: Bool = true,
        supportedCompression: Set<CompressionType> = [.gzip],
        requiresIndex: Bool = false,
        indexFormat: FormatIdentifier? = nil,
        isBinary: Bool = false,
        canRead: Bool = true,
        canWrite: Bool = true
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.description = description
        self.extensions = extensions
        self.mimeTypes = mimeTypes
        self.magicBytes = magicBytes
        self.providedCapabilities = providedCapabilities
        self.supportsCompression = supportsCompression
        self.supportedCompression = supportedCompression
        self.requiresIndex = requiresIndex
        self.indexFormat = indexFormat
        self.isBinary = isBinary
        self.canRead = canRead
        self.canWrite = canWrite
    }
}

/// Supported compression types
public enum CompressionType: String, Sendable, CaseIterable {
    case none
    case gzip
    case bgzf
    case zstd
    case bzip2
    case xz
}
```

### 3.3 FormatImporter Protocol

```swift
// File: Sources/LungfishIO/Registry/FormatImporter.swift

import Foundation
import LungfishCore

/// Protocol for types that can import files into GenomicDocument.
///
/// Implement this protocol to add support for reading a new file format.
/// Importers should be:
/// - Thread-safe (Sendable)
/// - Async-friendly (use async/await)
/// - Memory-efficient (stream large files)
///
/// ## Example
/// ```swift
/// public final class FASTAImporter: FormatImporter {
///     public static let formatIdentifier: FormatIdentifier = .fasta
///
///     public func canImport(url: URL) -> Bool {
///         FASTAReader.supportedExtensions.contains(url.pathExtension.lowercased())
///     }
///
///     public func importDocument(from url: URL, options: ImportOptions) async throws -> GenomicDocument {
///         let reader = try FASTAReader(url: url)
///         let sequences = try await reader.readAll()
///         // ... create document
///     }
/// }
/// ```
public protocol FormatImporter: Sendable {
    /// The format this importer handles
    static var formatIdentifier: FormatIdentifier { get }

    /// Check if this importer can handle the given URL
    func canImport(url: URL) -> Bool

    /// Import a document from the URL
    @MainActor
    func importDocument(from url: URL, options: ImportOptions) async throws -> GenomicDocument

    /// Import with progress reporting
    @MainActor
    func importDocument(
        from url: URL,
        options: ImportOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> GenomicDocument

    /// Quickly scan the file for metadata without full parsing
    func scanMetadata(from url: URL) async throws -> FormatMetadata
}

/// Default implementations
extension FormatImporter {
    @MainActor
    public func importDocument(
        from url: URL,
        options: ImportOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> GenomicDocument {
        // Default: no progress reporting
        try await importDocument(from: url, options: options)
    }

    public func scanMetadata(from url: URL) async throws -> FormatMetadata {
        // Default: minimal metadata
        FormatMetadata(
            formatIdentifier: Self.formatIdentifier,
            estimatedRecordCount: nil,
            estimatedSize: try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        )
    }
}

/// Options for import operations
public struct ImportOptions: Sendable {
    /// Maximum number of sequences to import (nil = all)
    public var maxSequences: Int?

    /// Whether to import annotations
    public var importAnnotations: Bool

    /// Whether to validate sequences strictly
    public var strictValidation: Bool

    /// Quality encoding for FASTQ (nil = auto-detect)
    public var qualityEncoding: QualityEncoding?

    /// Custom options dictionary
    public var customOptions: [String: String]

    public init(
        maxSequences: Int? = nil,
        importAnnotations: Bool = true,
        strictValidation: Bool = false,
        qualityEncoding: QualityEncoding? = nil,
        customOptions: [String: String] = [:]
    ) {
        self.maxSequences = maxSequences
        self.importAnnotations = importAnnotations
        self.strictValidation = strictValidation
        self.qualityEncoding = qualityEncoding
        self.customOptions = customOptions
    }

    public static let `default` = ImportOptions()
}

/// Metadata about a file's contents
public struct FormatMetadata: Sendable {
    public let formatIdentifier: FormatIdentifier
    public let estimatedRecordCount: Int?
    public let estimatedSize: Int64?
    public var sequenceNames: [String]?
    public var organism: String?
    public var accession: String?
    public var customMetadata: [String: String] = [:]
}
```

### 3.4 FormatExporter Protocol

```swift
// File: Sources/LungfishIO/Registry/FormatExporter.swift

import Foundation
import LungfishCore

/// Protocol for types that can export GenomicDocument to files.
///
/// Implement this protocol to add support for writing a new file format.
public protocol FormatExporter: Sendable {
    /// The format this exporter handles
    static var formatIdentifier: FormatIdentifier { get }

    /// Capabilities required for export (must have all of these)
    static var requiredCapabilities: DocumentCapabilities { get }

    /// Check if this exporter can handle the document
    @MainActor
    func canExport(document: GenomicDocument) -> Bool

    /// Export the document to the URL
    @MainActor
    func exportDocument(_ document: GenomicDocument, to url: URL, options: ExportOptions) async throws

    /// Export with progress reporting
    @MainActor
    func exportDocument(
        _ document: GenomicDocument,
        to url: URL,
        options: ExportOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Get warnings about data that will be lost in this format
    @MainActor
    func dataLossWarnings(for document: GenomicDocument) -> [DataLossWarning]
}

/// Default implementations
extension FormatExporter {
    @MainActor
    public func canExport(document: GenomicDocument) -> Bool {
        document.satisfies(requirements: Self.requiredCapabilities)
    }

    @MainActor
    public func exportDocument(
        _ document: GenomicDocument,
        to url: URL,
        options: ExportOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await exportDocument(document, to: url, options: options)
    }

    @MainActor
    public func dataLossWarnings(for document: GenomicDocument) -> [DataLossWarning] {
        []
    }
}

/// Options for export operations
public struct ExportOptions: Sendable {
    /// Whether to compress the output
    public var compress: Bool

    /// Compression type if compressing
    public var compressionType: CompressionType

    /// Line width for text formats
    public var lineWidth: Int

    /// Whether to include annotations
    public var includeAnnotations: Bool

    /// Quality encoding for FASTQ output
    public var qualityEncoding: QualityEncoding

    /// Custom options dictionary
    public var customOptions: [String: String]

    public init(
        compress: Bool = false,
        compressionType: CompressionType = .gzip,
        lineWidth: Int = 60,
        includeAnnotations: Bool = true,
        qualityEncoding: QualityEncoding = .phred33,
        customOptions: [String: String] = [:]
    ) {
        self.compress = compress
        self.compressionType = compressionType
        self.lineWidth = lineWidth
        self.includeAnnotations = includeAnnotations
        self.qualityEncoding = qualityEncoding
        self.customOptions = customOptions
    }

    public static let `default` = ExportOptions()
}

/// Warning about data that will be lost during export
public struct DataLossWarning: Sendable {
    public let severity: Severity
    public let message: String
    public let affectedCapability: DocumentCapability

    public enum Severity: Sendable {
        case info
        case warning
        case critical
    }
}
```

### 3.5 FormatRegistry Singleton

```swift
// File: Sources/LungfishIO/Registry/FormatRegistry.swift

import Foundation
import LungfishCore

/// Central registry for all file format importers and exporters.
///
/// FormatRegistry is the single point of truth for:
/// - Available file formats
/// - Format detection
/// - Importer/exporter lookup
/// - Format capability queries
///
/// ## Thread Safety
/// FormatRegistry is thread-safe and can be accessed from any thread.
///
/// ## Example
/// ```swift
/// // Register a custom format
/// FormatRegistry.shared.register(importer: MyCustomImporter())
///
/// // Detect format from file
/// let format = try await FormatRegistry.shared.detectFormat(url: fileURL)
///
/// // Import a file
/// let document = try await FormatRegistry.shared.importDocument(from: fileURL)
/// ```
public final class FormatRegistry: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = FormatRegistry()

    // MARK: - Storage

    private let lock = NSLock()
    private var descriptors: [FormatIdentifier: FormatDescriptor] = [:]
    private var importers: [FormatIdentifier: any FormatImporter] = [:]
    private var exporters: [FormatIdentifier: any FormatExporter] = [:]
    private var extensionMap: [String: FormatIdentifier] = [:]

    // MARK: - Initialization

    private init() {
        registerBuiltInFormats()
    }

    // MARK: - Registration

    /// Register a format descriptor
    public func register(descriptor: FormatDescriptor) {
        lock.lock()
        defer { lock.unlock() }

        descriptors[descriptor.identifier] = descriptor
        for ext in descriptor.extensions {
            extensionMap[ext.lowercased()] = descriptor.identifier
        }
    }

    /// Register an importer
    public func register<I: FormatImporter>(importer: I) {
        lock.lock()
        defer { lock.unlock() }

        importers[I.formatIdentifier] = importer
    }

    /// Register an exporter
    public func register<E: FormatExporter>(exporter: E) {
        lock.lock()
        defer { lock.unlock() }

        exporters[E.formatIdentifier] = exporter
    }

    // MARK: - Lookup

    /// Get the format descriptor for an identifier
    public func descriptor(for identifier: FormatIdentifier) -> FormatDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[identifier]
    }

    /// Get the importer for a format
    public func importer(for identifier: FormatIdentifier) -> (any FormatImporter)? {
        lock.lock()
        defer { lock.unlock() }
        return importers[identifier]
    }

    /// Get the exporter for a format
    public func exporter(for identifier: FormatIdentifier) -> (any FormatExporter)? {
        lock.lock()
        defer { lock.unlock() }
        return exporters[identifier]
    }

    /// Get all registered format identifiers
    public var registeredFormats: [FormatIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return Array(descriptors.keys)
    }

    /// Get all formats that support specific capabilities
    public func formats(supporting capabilities: DocumentCapabilities) -> [FormatIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.values
            .filter { $0.providedCapabilities.contains(capabilities) }
            .map(\.identifier)
    }

    /// Get all readable formats
    public var readableFormats: [FormatIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.values.filter(\.canRead).map(\.identifier)
    }

    /// Get all writable formats
    public var writableFormats: [FormatIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.values.filter(\.canWrite).map(\.identifier)
    }

    // MARK: - Format Detection

    /// Detect the format of a file
    public func detectFormat(url: URL) async throws -> FormatIdentifier? {
        // First try by extension
        let ext = url.pathExtension.lowercased()

        // Handle compound extensions like .fa.gz
        let compoundExt = url.deletingPathExtension().pathExtension.lowercased() + "." + ext

        lock.lock()
        if let format = extensionMap[compoundExt] ?? extensionMap[ext] {
            lock.unlock()
            return format
        }
        let descriptorsCopy = Array(descriptors.values)
        lock.unlock()

        // Try magic bytes detection
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            let header = data.prefix(16)
            for descriptor in descriptorsCopy {
                if let magic = descriptor.magicBytes, header.starts(with: magic) {
                    return descriptor.identifier
                }
            }
        }

        // Try content sniffing via importers
        for (identifier, importer) in importers {
            if importer.canImport(url: url) {
                return identifier
            }
        }

        return nil
    }

    // MARK: - Import/Export Convenience

    /// Import a document, auto-detecting format
    @MainActor
    public func importDocument(
        from url: URL,
        options: ImportOptions = .default
    ) async throws -> GenomicDocument {
        guard let formatID = try await detectFormat(url: url) else {
            throw FormatRegistryError.unknownFormat(url)
        }

        guard let importer = importer(for: formatID) else {
            throw FormatRegistryError.noImporterAvailable(formatID)
        }

        return try await importer.importDocument(from: url, options: options)
    }

    /// Export a document to a specific format
    @MainActor
    public func exportDocument(
        _ document: GenomicDocument,
        to url: URL,
        format: FormatIdentifier,
        options: ExportOptions = .default
    ) async throws {
        guard let exporter = exporter(for: format) else {
            throw FormatRegistryError.noExporterAvailable(format)
        }

        guard exporter.canExport(document: document) else {
            throw FormatRegistryError.incompatibleDocument(
                format: format,
                required: type(of: exporter).requiredCapabilities,
                provided: document.capabilities
            )
        }

        try await exporter.exportDocument(document, to: url, options: options)
    }

    // MARK: - Built-in Formats

    private func registerBuiltInFormats() {
        // FASTA
        register(descriptor: FormatDescriptor(
            identifier: .fasta,
            displayName: "FASTA",
            description: "Simple sequence format",
            extensions: ["fa", "fasta", "fna", "faa", "ffn", "frn"],
            mimeTypes: ["text/x-fasta"],
            providedCapabilities: .nucleotideSequence,
            canRead: true,
            canWrite: true
        ))
        register(importer: FASTAImporter())
        register(exporter: FASTAExporter())

        // FASTQ
        register(descriptor: FormatDescriptor(
            identifier: .fastq,
            displayName: "FASTQ",
            description: "Sequence with quality scores",
            extensions: ["fq", "fastq"],
            mimeTypes: ["text/x-fastq"],
            providedCapabilities: [.nucleotideSequence, .qualityScores],
            canRead: true,
            canWrite: true
        ))
        register(importer: FASTQImporter())
        register(exporter: FASTQExporter())

        // GenBank
        register(descriptor: FormatDescriptor(
            identifier: .genbank,
            displayName: "GenBank",
            description: "Annotated sequence format",
            extensions: ["gb", "gbk", "genbank", "gbff"],
            mimeTypes: ["text/x-genbank"],
            providedCapabilities: [.nucleotideSequence, .annotations, .richMetadata],
            canRead: true,
            canWrite: true
        ))
        register(importer: GenBankImporter())
        register(exporter: GenBankExporter())

        // GFF3
        register(descriptor: FormatDescriptor(
            identifier: .gff3,
            displayName: "GFF3",
            description: "General Feature Format",
            extensions: ["gff", "gff3"],
            mimeTypes: ["text/x-gff3"],
            providedCapabilities: .annotations,
            canRead: true,
            canWrite: true
        ))
        register(importer: GFF3Importer())

        // BAM
        register(descriptor: FormatDescriptor(
            identifier: .bam,
            displayName: "BAM",
            description: "Binary Alignment Map",
            extensions: ["bam"],
            mimeTypes: ["application/x-bam"],
            magicBytes: Data([0x1f, 0x8b, 0x08]), // gzip magic (BAM is bgzf compressed)
            providedCapabilities: [.nucleotideSequence, .qualityScores, .alignment],
            supportsCompression: false, // already compressed
            requiresIndex: true,
            indexFormat: .bai,
            isBinary: true,
            canRead: true,
            canWrite: false // requires samtools
        ))
        register(importer: BAMImporter())

        // SAM
        register(descriptor: FormatDescriptor(
            identifier: .sam,
            displayName: "SAM",
            description: "Sequence Alignment Map",
            extensions: ["sam"],
            mimeTypes: ["text/x-sam"],
            providedCapabilities: [.nucleotideSequence, .qualityScores, .alignment],
            isBinary: false,
            canRead: true,
            canWrite: true
        ))

        // VCF
        register(descriptor: FormatDescriptor(
            identifier: .vcf,
            displayName: "VCF",
            description: "Variant Call Format",
            extensions: ["vcf"],
            mimeTypes: ["text/x-vcf"],
            providedCapabilities: .variants,
            canRead: true,
            canWrite: true
        ))
        register(importer: VCFImporter())

        // BED
        register(descriptor: FormatDescriptor(
            identifier: .bed,
            displayName: "BED",
            description: "Browser Extensible Data",
            extensions: ["bed"],
            mimeTypes: ["text/x-bed"],
            providedCapabilities: .annotations,
            canRead: true,
            canWrite: true
        ))
        register(importer: BEDImporter())

        // BigWig
        register(descriptor: FormatDescriptor(
            identifier: .bigwig,
            displayName: "BigWig",
            description: "Binary coverage/signal format",
            extensions: ["bw", "bigwig", "bigWig"],
            magicBytes: Data([0x26, 0xfc, 0x8f, 0x88]), // BigWig magic
            providedCapabilities: .coverage,
            supportsCompression: false,
            isBinary: true,
            canRead: true,
            canWrite: false
        ))
        register(importer: BigWigImporter())
    }
}

// MARK: - Errors

public enum FormatRegistryError: Error, LocalizedError {
    case unknownFormat(URL)
    case noImporterAvailable(FormatIdentifier)
    case noExporterAvailable(FormatIdentifier)
    case incompatibleDocument(format: FormatIdentifier, required: DocumentCapabilities, provided: DocumentCapabilities)

    public var errorDescription: String? {
        switch self {
        case .unknownFormat(let url):
            return "Unknown file format: \(url.lastPathComponent)"
        case .noImporterAvailable(let format):
            return "No importer available for format: \(format.rawValue)"
        case .noExporterAvailable(let format):
            return "No exporter available for format: \(format.rawValue)"
        case .incompatibleDocument(let format, let required, _):
            return "Document is incompatible with \(format.rawValue) format"
        }
    }
}
```

---

## 4. Conversion Pipeline

### 4.1 ConversionService

```swift
// File: Sources/LungfishIO/Conversion/ConversionService.swift

import Foundation
import LungfishCore

/// Service for converting between file formats and preparing data for tools.
///
/// ConversionService handles:
/// - Format conversion (e.g., GenBank -> FASTA)
/// - Capability augmentation (e.g., adding index to BAM)
/// - Temporary file management for external tools
/// - Pipeline composition for complex conversions
///
/// ## Example
/// ```swift
/// let service = ConversionService.shared
///
/// // Convert format
/// let fastaURL = try await service.convert(
///     document: genbankDoc,
///     to: .fasta,
///     destination: .temporary
/// )
///
/// // Prepare BAM for variant calling (sort + index)
/// let preparedBAM = try await service.prepareForTool(
///     url: rawBAMURL,
///     requirements: [.sorted, .indexed]
/// )
/// ```
public actor ConversionService {

    // MARK: - Singleton

    public static let shared = ConversionService()

    // MARK: - Properties

    private let tempDirectory: URL
    private var activeTemporaryFiles: Set<URL> = []
    private let cleanupInterval: TimeInterval = 3600 // 1 hour

    // MARK: - Initialization

    private init() {
        let baseTemp = FileManager.default.temporaryDirectory
        self.tempDirectory = baseTemp.appendingPathComponent("lungfish-conversions", isDirectory: true)

        // Ensure temp directory exists
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Schedule periodic cleanup
        Task {
            await self.startCleanupTimer()
        }
    }

    // MARK: - Conversion Destination

    public enum Destination: Sendable {
        /// Create a temporary file (auto-cleaned)
        case temporary
        /// Write to a specific URL
        case url(URL)
        /// Write alongside the source file
        case alongside(suffix: String)
    }

    // MARK: - Format Conversion

    /// Convert a document to a different format
    @MainActor
    public func convert(
        document: GenomicDocument,
        to targetFormat: FormatIdentifier,
        destination: Destination,
        options: ExportOptions = .default
    ) async throws -> URL {
        let registry = FormatRegistry.shared

        guard let exporter = registry.exporter(for: targetFormat) else {
            throw ConversionError.noExporterAvailable(targetFormat)
        }

        // Determine output URL
        let outputURL = try resolveDestination(
            destination,
            sourceURL: document.filePath,
            format: targetFormat
        )

        // Perform export
        try await exporter.exportDocument(document, to: outputURL, options: options)

        // Track temporary files
        if case .temporary = destination {
            activeTemporaryFiles.insert(outputURL)
        }

        return outputURL
    }

    /// Convert a file to a different format
    @MainActor
    public func convert(
        file url: URL,
        to targetFormat: FormatIdentifier,
        destination: Destination,
        importOptions: ImportOptions = .default,
        exportOptions: ExportOptions = .default
    ) async throws -> URL {
        let registry = FormatRegistry.shared

        // Import the source file
        let document = try await registry.importDocument(from: url, options: importOptions)

        // Convert to target format
        return try await convert(
            document: document,
            to: targetFormat,
            destination: destination,
            options: exportOptions
        )
    }

    // MARK: - Tool Preparation

    /// Prepare a file for use by a tool
    ///
    /// This method ensures the file has all required capabilities,
    /// performing conversions and processing as needed.
    public func prepareForTool(
        url: URL,
        requirements: DocumentCapabilities,
        preferredFormat: FormatIdentifier? = nil
    ) async throws -> PreparedInput {
        var currentURL = url
        var conversionsApplied: [String] = []

        // Detect current format
        guard let currentFormat = try await FormatRegistry.shared.detectFormat(url: url),
              let descriptor = FormatRegistry.shared.descriptor(for: currentFormat) else {
            throw ConversionError.unknownFormat(url)
        }

        var currentCapabilities = descriptor.providedCapabilities

        // Check if format conversion is needed
        if let preferred = preferredFormat, preferred != currentFormat {
            currentURL = try await convert(
                file: url,
                to: preferred,
                destination: .temporary
            )
            conversionsApplied.append("Converted \(currentFormat.rawValue) to \(preferred.rawValue)")

            if let newDesc = FormatRegistry.shared.descriptor(for: preferred) {
                currentCapabilities = newDesc.providedCapabilities
            }
        }

        // Handle BAM/SAM specific requirements
        if requirements.contains(.sorted) && !currentCapabilities.contains(.sorted) {
            if currentFormat == .bam || currentFormat == .sam {
                currentURL = try await sortBAM(url: currentURL)
                currentCapabilities.insert(.sorted)
                conversionsApplied.append("Sorted BAM file")
            }
        }

        if requirements.contains(.indexed) && !currentCapabilities.contains(.indexed) {
            if currentFormat == .bam {
                try await indexBAM(url: currentURL)
                currentCapabilities.insert(.indexed)
                conversionsApplied.append("Created BAM index")
            } else if currentFormat == .fasta {
                try await indexFASTA(url: currentURL)
                currentCapabilities.insert(.indexed)
                conversionsApplied.append("Created FASTA index")
            }
        }

        // Verify all requirements are met
        let missing = requirements.subtracting(currentCapabilities)
        if !missing.isEmpty {
            throw ConversionError.cannotSatisfyRequirements(missing)
        }

        return PreparedInput(
            url: currentURL,
            capabilities: currentCapabilities,
            conversionsApplied: conversionsApplied,
            isTemporary: currentURL != url
        )
    }

    // MARK: - BAM/SAM Processing

    /// Sort a BAM file using samtools
    private func sortBAM(url: URL) async throws -> URL {
        let outputURL = try createTemporaryURL(extension: "bam")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "samtools", "sort",
            "-o", outputURL.path,
            "-@", "4", // 4 threads
            url.path
        ]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ConversionError.externalToolFailed("samtools sort", errorMessage)
        }

        activeTemporaryFiles.insert(outputURL)
        return outputURL
    }

    /// Index a BAM file using samtools
    private func indexBAM(url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["samtools", "index", url.path]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ConversionError.externalToolFailed("samtools index", errorMessage)
        }

        // Track the index file as temporary too
        let indexURL = URL(fileURLWithPath: url.path + ".bai")
        activeTemporaryFiles.insert(indexURL)
    }

    /// Index a FASTA file using samtools
    private func indexFASTA(url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["samtools", "faidx", url.path]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ConversionError.externalToolFailed("samtools faidx", errorMessage)
        }

        // Track the index file as temporary
        let indexURL = URL(fileURLWithPath: url.path + ".fai")
        activeTemporaryFiles.insert(indexURL)
    }

    // MARK: - Temporary File Management

    /// Create a temporary URL with the given extension
    private func createTemporaryURL(extension ext: String) throws -> URL {
        let filename = UUID().uuidString + "." + ext
        return tempDirectory.appendingPathComponent(filename)
    }

    /// Resolve a destination to a concrete URL
    private func resolveDestination(
        _ destination: Destination,
        sourceURL: URL?,
        format: FormatIdentifier
    ) throws -> URL {
        switch destination {
        case .temporary:
            let ext = FormatRegistry.shared.descriptor(for: format)?.extensions.first ?? format.rawValue
            return try createTemporaryURL(extension: ext)

        case .url(let url):
            return url

        case .alongside(let suffix):
            guard let source = sourceURL else {
                throw ConversionError.noSourceURL
            }
            let baseName = source.deletingPathExtension().lastPathComponent
            let ext = FormatRegistry.shared.descriptor(for: format)?.extensions.first ?? format.rawValue
            return source.deletingLastPathComponent()
                .appendingPathComponent(baseName + suffix + "." + ext)
        }
    }

    /// Release a temporary file (mark for cleanup)
    public func releaseTemporaryFile(_ url: URL) {
        activeTemporaryFiles.remove(url)
        try? FileManager.default.removeItem(at: url)
    }

    /// Cleanup old temporary files
    private func startCleanupTimer() async {
        while true {
            try? await Task.sleep(nanoseconds: UInt64(cleanupInterval * 1_000_000_000))
            cleanupOldFiles()
        }
    }

    private func cleanupOldFiles() {
        let fileManager = FileManager.default
        let cutoffDate = Date().addingTimeInterval(-cleanupInterval)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        for url in contents {
            // Don't delete active files
            guard !activeTemporaryFiles.contains(url) else { continue }

            // Check age
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let creationDate = attributes[.creationDate] as? Date,
               creationDate < cutoffDate {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

// MARK: - Supporting Types

/// Result of preparing an input for a tool
public struct PreparedInput: Sendable {
    /// URL to the prepared file
    public let url: URL

    /// Capabilities the prepared file provides
    public let capabilities: DocumentCapabilities

    /// Conversions that were applied
    public let conversionsApplied: [String]

    /// Whether this is a temporary file that should be cleaned up
    public let isTemporary: Bool
}

/// Errors from conversion operations
public enum ConversionError: Error, LocalizedError {
    case unknownFormat(URL)
    case noExporterAvailable(FormatIdentifier)
    case noImporterAvailable(FormatIdentifier)
    case cannotSatisfyRequirements(DocumentCapabilities)
    case externalToolFailed(String, String)
    case noSourceURL
    case conversionNotSupported(from: FormatIdentifier, to: FormatIdentifier)

    public var errorDescription: String? {
        switch self {
        case .unknownFormat(let url):
            return "Unknown file format: \(url.lastPathComponent)"
        case .noExporterAvailable(let format):
            return "No exporter available for \(format.rawValue)"
        case .noImporterAvailable(let format):
            return "No importer available for \(format.rawValue)"
        case .cannotSatisfyRequirements:
            return "Cannot satisfy all required capabilities"
        case .externalToolFailed(let tool, let message):
            return "\(tool) failed: \(message)"
        case .noSourceURL:
            return "No source URL available for alongside destination"
        case .conversionNotSupported(let from, let to):
            return "Conversion from \(from.rawValue) to \(to.rawValue) is not supported"
        }
    }
}
```

### 4.2 ConversionPath Finding

```swift
// File: Sources/LungfishIO/Conversion/ConversionPathFinder.swift

import Foundation
import LungfishCore

/// Finds optimal conversion paths between formats.
///
/// When direct conversion isn't available, this finds multi-step
/// paths through intermediate formats.
public struct ConversionPathFinder: Sendable {

    /// A step in a conversion path
    public struct ConversionStep: Sendable {
        public let sourceFormat: FormatIdentifier
        public let targetFormat: FormatIdentifier
        public let capabilitiesLost: DocumentCapabilities
        public let estimatedCost: Int // Higher = slower/more expensive
    }

    /// A complete path from source to target format
    public struct ConversionPath: Sendable {
        public let steps: [ConversionStep]
        public let totalCapabilitiesLost: DocumentCapabilities
        public let totalCost: Int

        public var isEmpty: Bool { steps.isEmpty }
    }

    /// Find the optimal conversion path between formats
    public static func findPath(
        from source: FormatIdentifier,
        to target: FormatIdentifier
    ) -> ConversionPath? {
        if source == target {
            return ConversionPath(steps: [], totalCapabilitiesLost: [], totalCost: 0)
        }

        // Check for direct conversion
        if let exporter = FormatRegistry.shared.exporter(for: target) {
            // Direct path possible
            let sourceDesc = FormatRegistry.shared.descriptor(for: source)
            let targetDesc = FormatRegistry.shared.descriptor(for: target)

            let sourceCaps = sourceDesc?.providedCapabilities ?? []
            let targetCaps = targetDesc?.providedCapabilities ?? []

            let step = ConversionStep(
                sourceFormat: source,
                targetFormat: target,
                capabilitiesLost: sourceCaps.subtracting(targetCaps),
                estimatedCost: 1
            )

            return ConversionPath(
                steps: [step],
                totalCapabilitiesLost: step.capabilitiesLost,
                totalCost: 1
            )
        }

        // Use BFS to find shortest path through intermediate formats
        var visited: Set<FormatIdentifier> = [source]
        var queue: [(FormatIdentifier, [ConversionStep])] = [(source, [])]

        while !queue.isEmpty {
            let (current, path) = queue.removeFirst()

            // Try all formats we can export to
            for formatID in FormatRegistry.shared.writableFormats {
                guard !visited.contains(formatID) else { continue }

                let currentDesc = FormatRegistry.shared.descriptor(for: current)
                let nextDesc = FormatRegistry.shared.descriptor(for: formatID)

                let currentCaps = currentDesc?.providedCapabilities ?? []
                let nextCaps = nextDesc?.providedCapabilities ?? []

                let step = ConversionStep(
                    sourceFormat: current,
                    targetFormat: formatID,
                    capabilitiesLost: currentCaps.subtracting(nextCaps),
                    estimatedCost: 1
                )

                var newPath = path
                newPath.append(step)

                if formatID == target {
                    // Found path!
                    let totalLost = newPath.reduce(DocumentCapabilities()) {
                        $0.union($1.capabilitiesLost)
                    }
                    return ConversionPath(
                        steps: newPath,
                        totalCapabilitiesLost: totalLost,
                        totalCost: newPath.count
                    )
                }

                visited.insert(formatID)
                queue.append((formatID, newPath))
            }
        }

        return nil // No path found
    }

    /// Get warnings about data loss for a conversion path
    public static func dataLossWarnings(for path: ConversionPath) -> [DataLossWarning] {
        var warnings: [DataLossWarning] = []

        let lost = path.totalCapabilitiesLost

        if lost.contains(.qualityScores) {
            warnings.append(DataLossWarning(
                severity: .warning,
                message: "Quality scores will be lost",
                affectedCapability: .qualityScores
            ))
        }

        if lost.contains(.annotations) {
            warnings.append(DataLossWarning(
                severity: .warning,
                message: "Annotations will be lost",
                affectedCapability: .annotations
            ))
        }

        if lost.contains(.richMetadata) {
            warnings.append(DataLossWarning(
                severity: .info,
                message: "Some metadata will be lost",
                affectedCapability: .richMetadata
            ))
        }

        if lost.contains(.pairedReads) {
            warnings.append(DataLossWarning(
                severity: .critical,
                message: "Paired-end read information will be lost",
                affectedCapability: .pairedReads
            ))
        }

        return warnings
    }
}
```

---

## 5. Implementation Plan

### 5.1 New Files to Create

| File Path | Purpose | Priority |
|-----------|---------|----------|
| `Sources/LungfishCore/Models/DocumentCapability.swift` | Capability enum and OptionSet | P0 |
| `Sources/LungfishCore/Protocols/CapabilityProvider.swift` | Protocol for capability providers | P0 |
| `Sources/LungfishCore/Tools/InputSignature.swift` | Tool input requirements | P1 |
| `Sources/LungfishCore/Tools/OutputType.swift` | Tool output specification | P1 |
| `Sources/LungfishCore/Tools/ToolDefinition.swift` | Tool interface protocol | P1 |
| `Sources/LungfishIO/Registry/FormatIdentifier.swift` | Format identifier type | P0 |
| `Sources/LungfishIO/Registry/FormatDescriptor.swift` | Format metadata | P0 |
| `Sources/LungfishIO/Registry/FormatImporter.swift` | Importer protocol | P0 |
| `Sources/LungfishIO/Registry/FormatExporter.swift` | Exporter protocol | P0 |
| `Sources/LungfishIO/Registry/FormatRegistry.swift` | Central registry singleton | P0 |
| `Sources/LungfishIO/Conversion/ConversionService.swift` | Conversion orchestration | P1 |
| `Sources/LungfishIO/Conversion/ConversionPathFinder.swift` | Path finding algorithm | P2 |
| `Sources/LungfishIO/Importers/FASTAImporter.swift` | FASTA importer wrapper | P0 |
| `Sources/LungfishIO/Importers/FASTQImporter.swift` | FASTQ importer wrapper | P0 |
| `Sources/LungfishIO/Importers/GenBankImporter.swift` | GenBank importer wrapper | P0 |
| `Sources/LungfishIO/Importers/GFF3Importer.swift` | GFF3 importer wrapper | P1 |
| `Sources/LungfishIO/Importers/BAMImporter.swift` | BAM importer (via htslib) | P1 |
| `Sources/LungfishIO/Importers/VCFImporter.swift` | VCF importer wrapper | P1 |
| `Sources/LungfishIO/Importers/BEDImporter.swift` | BED importer wrapper | P1 |
| `Sources/LungfishIO/Importers/BigWigImporter.swift` | BigWig importer wrapper | P2 |
| `Sources/LungfishIO/Exporters/FASTAExporter.swift` | FASTA exporter wrapper | P0 |
| `Sources/LungfishIO/Exporters/FASTQExporter.swift` | FASTQ exporter wrapper | P1 |
| `Sources/LungfishIO/Exporters/GenBankExporter.swift` | GenBank exporter wrapper | P1 |
| `Sources/LungfishWorkflow/Tools/BuiltInTools.swift` | Built-in tool definitions | P2 |

### 5.2 Existing Files to Modify

| File Path | Modification | Priority |
|-----------|--------------|----------|
| `Sources/LungfishCore/Models/GenomicDocument.swift` | Add `CapabilityProvider` conformance | P0 |
| `Sources/LungfishCore/Models/Sequence.swift` | No changes needed | - |
| `Sources/LungfishIO/LungfishIO.swift` | Export new registry types | P0 |
| `Sources/LungfishIO/Formats/FASTAReader.swift` | Adapter for FormatImporter | P0 |
| `Sources/LungfishIO/Formats/GenBank/GenBankReader.swift` | Adapter for FormatImporter | P0 |
| `Sources/LungfishIO/Formats/FASTQ/FASTQReader.swift` | Adapter for FormatImporter | P0 |
| `Sources/LungfishIO/Formats/GFF/GFF3Reader.swift` | Adapter for FormatImporter | P1 |

### 5.3 Phased Implementation

#### Phase 1: Foundation (Week 1-2)

1. **Create DocumentCapability system**
   - Implement `DocumentCapability` OptionSet
   - Implement `CapabilityProvider` protocol
   - Add conformance to `GenomicDocument`

2. **Create FormatRegistry core**
   - Implement `FormatIdentifier`
   - Implement `FormatDescriptor`
   - Implement `FormatImporter` protocol
   - Implement `FormatExporter` protocol
   - Implement `FormatRegistry` singleton

3. **Wrap existing readers**
   - Create `FASTAImporter` wrapping `FASTAReader`
   - Create `FASTQImporter` wrapping `FASTQReader`
   - Create `GenBankImporter` wrapping `GenBankReader`

4. **Tests**
   - Unit tests for DocumentCapability
   - Unit tests for FormatRegistry
   - Integration tests for import flow

#### Phase 2: Tool System (Week 3-4)

1. **Create tool input/output system**
   - Implement `InputSignature`
   - Implement `OutputType`
   - Implement `ToolDefinition` protocol
   - Create `GenericToolDefinition`

2. **Create ConversionService**
   - Implement basic format conversion
   - Implement temporary file management
   - Implement file cleanup

3. **Add BAM/SAM support**
   - Implement `BAMImporter`
   - Add sorting and indexing via samtools
   - Handle paired-end reads

4. **Tests**
   - Unit tests for InputSignature validation
   - Integration tests for ConversionService
   - Tests for temporary file cleanup

#### Phase 3: Advanced Features (Week 5-6)

1. **Implement ConversionPathFinder**
   - Multi-step conversion paths
   - Data loss warnings
   - Cost optimization

2. **Complete format support**
   - VCF importer/exporter
   - BED importer/exporter
   - BigWig importer

3. **Built-in tool definitions**
   - Create `BuiltInTools` collection
   - Integrate with workflow system

4. **Documentation and polish**
   - API documentation
   - Usage examples
   - Performance optimization

### 5.4 Testing Strategy

```swift
// Example test file: Tests/LungfishIOTests/FormatRegistryTests.swift

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class FormatRegistryTests: XCTestCase {

    func testFormatDetectionByExtension() async throws {
        let url = URL(fileURLWithPath: "/tmp/test.fasta")
        let format = try await FormatRegistry.shared.detectFormat(url: url)
        XCTAssertEqual(format, .fasta)
    }

    func testCapabilitySatisfaction() {
        let requirements: DocumentCapabilities = [.nucleotideSequence, .annotations]
        let provided: DocumentCapabilities = [.nucleotideSequence, .annotations, .richMetadata]

        XCTAssertTrue(provided.contains(requirements))
    }

    func testInputSignatureValidation() async throws {
        let signature = InputSignature(
            required: .nucleotideSequence,
            minInputs: 1,
            maxInputs: 2
        )

        // Create mock documents
        let doc1 = await GenomicDocument(name: "test1")
        await doc1.addSequence(try Sequence(name: "seq1", alphabet: .dna, bases: "ATCG"))

        let result = signature.validate([doc1])
        XCTAssertTrue(result.isValid)
    }
}
```

---

## 6. Dependencies

### 6.1 External Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| samtools | BAM/SAM processing, indexing | For BAM support |
| bcftools | VCF processing | For variant calling |
| htslib (C library) | Low-level BAM/VCF access | For native performance |

### 6.2 Internal Dependencies

```
LungfishCore
  |
  +-- Models/DocumentCapability.swift
  +-- Models/GenomicDocument.swift (extended)
  +-- Protocols/CapabilityProvider.swift
  +-- Tools/InputSignature.swift
  +-- Tools/OutputType.swift
  +-- Tools/ToolDefinition.swift

LungfishIO
  |
  +-- Registry/FormatIdentifier.swift
  +-- Registry/FormatDescriptor.swift
  +-- Registry/FormatImporter.swift
  +-- Registry/FormatExporter.swift
  +-- Registry/FormatRegistry.swift
  +-- Conversion/ConversionService.swift
  +-- Conversion/ConversionPathFinder.swift
  +-- Importers/*.swift
  +-- Exporters/*.swift

LungfishWorkflow
  |
  +-- Tools/BuiltInTools.swift
```

---

## 7. Usage Examples

### 7.1 Basic Import

```swift
// Import any supported format
let document = try await FormatRegistry.shared.importDocument(from: fileURL)

// Import with options
let document = try await FormatRegistry.shared.importDocument(
    from: fastqURL,
    options: ImportOptions(maxSequences: 1000)
)
```

### 7.2 Format Conversion

```swift
// Convert GenBank to FASTA
let fastaURL = try await ConversionService.shared.convert(
    file: genbankURL,
    to: .fasta,
    destination: .alongside(suffix: "_converted")
)

// Convert with data loss warning
let path = ConversionPathFinder.findPath(from: .genbank, to: .fasta)
let warnings = ConversionPathFinder.dataLossWarnings(for: path!)
// warnings: ["Annotations will be lost"]
```

### 7.3 Tool Input Validation

```swift
let tool = BuiltInTools.variantCalling

// Validate input
let result = tool.inputSignature.validate([bamDocument])
if !result.isValid {
    print("Invalid input: \(result)")
}

// Prepare input (sort + index if needed)
let prepared = try await ConversionService.shared.prepareForTool(
    url: unsortedBAMURL,
    requirements: tool.inputSignature.required
)
```

### 7.4 Capability Queries

```swift
// Find formats that support annotations
let annotationFormats = FormatRegistry.shared.formats(
    supporting: [.nucleotideSequence, .annotations]
)
// Returns: [.genbank, .gff3]

// Check if document can be exported
let document = try await FormatRegistry.shared.importDocument(from: genbankURL)
if document.satisfies(requirements: .nucleotideSequence) {
    // Can export to FASTA
}
```

---

## 8. Future Considerations

### 8.1 Plugin System

The format registry is designed to support third-party format plugins:

```swift
// Future: Plugin registration
extension FormatRegistry {
    public func loadPlugin(from bundle: Bundle) throws {
        // Load plugin's FormatImporter/Exporter implementations
    }
}
```

### 8.2 Cloud Storage Integration

```swift
// Future: Cloud-aware import
let document = try await FormatRegistry.shared.importDocument(
    from: s3URL,
    credentials: awsCredentials
)
```

### 8.3 Streaming Large Files

For very large files (10GB+), streaming conversion without loading into memory:

```swift
// Future: Streaming conversion
try await ConversionService.shared.streamConvert(
    from: hugeBAMURL,
    to: .fastq,
    destination: outputURL,
    chunkSize: 10_000_000 // 10MB chunks
)
```

---

## Appendix A: Format Capability Matrix

| Format | Nucleotide | Amino Acid | Quality | Annotations | Variants | Coverage | Alignment | Metadata |
|--------|------------|------------|---------|-------------|----------|----------|-----------|----------|
| FASTA  | Yes | Yes | No | No | No | No | No | Limited |
| FASTQ  | Yes | No | Yes | No | No | No | No | No |
| GenBank | Yes | No | No | Yes | No | No | No | Yes |
| GFF3   | No | No | No | Yes | No | No | No | Limited |
| BAM    | Yes | No | Yes | No | No | No | Yes | Limited |
| VCF    | No | No | No | No | Yes | No | No | Yes |
| BigWig | No | No | No | No | No | Yes | No | No |
| BED    | No | No | No | Yes | No | No | No | No |

---

## Appendix B: Glossary

- **Capability**: A specific type of data or functionality a document can provide
- **FormatImporter**: A type that can read a specific file format into GenomicDocument
- **FormatExporter**: A type that can write GenomicDocument to a specific file format
- **InputSignature**: Declaration of what capabilities a tool requires
- **ConversionPath**: Sequence of format conversions to transform data
- **PreparedInput**: A file ready for use by a tool, with all required capabilities
