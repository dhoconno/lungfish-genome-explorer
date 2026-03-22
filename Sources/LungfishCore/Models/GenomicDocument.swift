// GenomicDocument.swift - Container for sequences and metadata
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A document containing one or more sequences with their annotations and metadata.
///
/// GenomicDocument is the primary container for working with sequence data in Lungfish.
/// It manages sequences, annotations, and version history.
///
/// ## Example
/// ```swift
/// let document = GenomicDocument(name: "My Project")
/// try document.addSequence(mySequence)
/// document.addAnnotation(myAnnotation, to: mySequence.id)
/// ```
@MainActor
public final class GenomicDocument: ObservableObject, Identifiable {
    /// Unique identifier
    public let id: UUID

    /// Document name (typically the filename without extension)
    @Published public var name: String

    /// File path if loaded from disk
    @Published public var filePath: URL?

    /// Document type (determines available operations)
    @Published public var documentType: DocumentType

    /// Document metadata
    @Published public var metadata: DocumentMetadata

    /// Sequences in this document
    @Published public private(set) var sequences: [Sequence]

    /// Annotations indexed by sequence ID
    @Published public private(set) var annotationsBySequence: [UUID: [SequenceAnnotation]]

    /// Whether the document has unsaved changes
    @Published public var isModified: Bool = false

    /// Creates a new empty document.
    public init(
        id: UUID = UUID(),
        name: String,
        documentType: DocumentType = .generic,
        filePath: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.documentType = documentType
        self.filePath = filePath
        self.metadata = DocumentMetadata()
        self.sequences = []
        self.annotationsBySequence = [:]
    }

    // MARK: - Sequence Management

    /// Adds a sequence to the document.
    public func addSequence(_ sequence: Sequence) {
        sequences.append(sequence)
        annotationsBySequence[sequence.id] = []
        isModified = true
    }

    /// Removes a sequence from the document.
    public func removeSequence(id: UUID) {
        sequences.removeAll { $0.id == id }
        annotationsBySequence.removeValue(forKey: id)
        isModified = true
    }

    /// Returns a sequence by ID.
    public func sequence(byID id: UUID) -> Sequence? {
        sequences.first { $0.id == id }
    }

    /// Returns a sequence by name.
    public func sequence(byName name: String) -> Sequence? {
        sequences.first { $0.name == name }
    }

    // MARK: - Annotation Management

    /// Adds an annotation to a sequence.
    public func addAnnotation(_ annotation: SequenceAnnotation, to sequenceID: UUID) {
        if annotationsBySequence[sequenceID] != nil {
            annotationsBySequence[sequenceID]?.append(annotation)
        } else {
            annotationsBySequence[sequenceID] = [annotation]
        }
        isModified = true
    }

    /// Removes an annotation.
    public func removeAnnotation(id: UUID, from sequenceID: UUID) {
        annotationsBySequence[sequenceID]?.removeAll { $0.id == id }
        isModified = true
    }

    /// Returns all annotations for a sequence.
    public func annotations(for sequenceID: UUID) -> [SequenceAnnotation] {
        annotationsBySequence[sequenceID] ?? []
    }

    /// Returns annotations overlapping a given range.
    public func annotations(for sequenceID: UUID, overlapping start: Int, end: Int) -> [SequenceAnnotation] {
        annotations(for: sequenceID).filter { $0.overlaps(start: start, end: end) }
    }

    /// Returns annotations of a specific type.
    public func annotations(for sequenceID: UUID, ofType type: AnnotationType) -> [SequenceAnnotation] {
        annotations(for: sequenceID).filter { $0.type == type }
    }

    // MARK: - Statistics

    /// Total number of sequences
    public var sequenceCount: Int {
        sequences.count
    }

    /// Total length of all sequences
    public var totalLength: Int {
        sequences.reduce(0) { $0 + $1.length }
    }

    /// Total number of annotations
    public var annotationCount: Int {
        annotationsBySequence.values.reduce(0) { $0 + $1.count }
    }
}

// MARK: - DocumentType

/// Type of genomic document
public enum DocumentType: String, Codable, Sendable {
    /// Generic sequence document
    case generic
    /// Reference genome
    case reference
    /// Sequencing reads
    case reads
    /// Assembly contigs/scaffolds
    case assembly
    /// Alignment (multiple sequences)
    case alignment
    /// Annotation-only (GFF/GTF without sequence)
    case annotations
    /// Primer/oligo collection
    case primers
    /// Variant collection
    case variants
}

// MARK: - DocumentMetadata

/// Metadata for a genomic document
public struct DocumentMetadata: Codable, Sendable {
    /// Date created
    public var created: Date

    /// Date last modified
    public var modified: Date

    /// Source organism
    public var organism: String?

    /// Taxonomy ID (e.g., NCBI TaxID)
    public var taxonomyID: Int?

    /// Assembly name (e.g., "GRCh38")
    public var assemblyName: String?

    /// Accession number
    public var accession: String?

    /// Data source (e.g., "NCBI", "ENA", "local")
    public var source: String?

    /// Custom key-value metadata
    public var custom: [String: String]

    public init(
        created: Date = Date(),
        modified: Date = Date(),
        organism: String? = nil,
        taxonomyID: Int? = nil,
        assemblyName: String? = nil,
        accession: String? = nil,
        source: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.created = created
        self.modified = modified
        self.organism = organism
        self.taxonomyID = taxonomyID
        self.assemblyName = assemblyName
        self.accession = accession
        self.source = source
        self.custom = custom
    }
}
