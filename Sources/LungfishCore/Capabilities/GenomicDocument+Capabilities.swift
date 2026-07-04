// GenomicDocument+Capabilities.swift - MainActor capability computation for GenomicDocument
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - MainActor Capability Computation

extension GenomicDocument {
    /// Computes capabilities on the MainActor where document properties are accessible.
    ///
    /// `GenomicDocument` does not conform directly to ``CapabilityProvider``
    /// because its state is MainActor-isolated while that protocol is synchronous
    /// and nonisolated. Use this method to compute a snapshot, then wrap it in
    /// ``DocumentCapabilityWrapper`` when a generic capability provider is needed.
    ///
    /// - Returns: The computed capabilities based on document content.
    @MainActor
    public func computeCapabilities() -> DocumentCapability {
        var caps: DocumentCapability = .none

        // Check sequences for their capabilities
        for sequence in sequences {
            // Sequence type capabilities
            switch sequence.alphabet {
            case .dna, .rna:
                caps.insert(.nucleotideSequence)
            case .protein:
                caps.insert(.aminoAcidSequence)
            }

            // Quality scores
            if sequence.qualityScores != nil {
                caps.insert(.qualityScores)
            }

            // Circular topology
            if sequence.isCircular {
                caps.insert(.circularTopology)
            }
        }

        // Annotation capabilities
        if annotationCount > 0 {
            caps.insert(.annotations)

            // Check for specific annotation types that indicate additional capabilities
            let allAnnotations = annotationsBySequence.values.flatMap { $0 }

            // Check for variant annotations
            let variantTypes: Set<AnnotationType> = [.snp, .variation, .insertion, .deletion]
            if allAnnotations.contains(where: { variantTypes.contains($0.type) }) {
                caps.insert(.variants)
            }

            // Check for primer annotations
            if allAnnotations.contains(where: { $0.type == .primer || $0.type == .primerPair }) {
                caps.insert(.primers)
            }

            // Check for translation products in CDS features
            if allAnnotations.contains(where: { annotation in
                annotation.type == .cds && annotation.qualifier("translation") != nil
            }) {
                caps.insert(.translationProducts)
            }

            // Check for database cross-references
            if allAnnotations.contains(where: { annotation in
                annotation.qualifier("db_xref") != nil ||
                annotation.qualifier("Dbxref") != nil
            }) {
                caps.insert(.databaseCrossReferences)
            }
        }

        // Metadata capabilities
        if metadata.organism != nil || metadata.accession != nil || metadata.taxonomyID != nil {
            caps.insert(.richMetadata)
        }

        // Document type specific capabilities
        switch documentCategory {
        case .reference:
            caps.insert(.referenceSequence)
        case .alignment:
            caps.insert(.multipleAlignment)
        case .variants:
            caps.insert(.variants)
        case .assembly:
            caps.insert(.assembly)
        case .primers:
            caps.insert(.primers)
        case .reads:
            // Reads typically have quality scores
            if !caps.contains(.qualityScores) && sequences.contains(where: { $0.qualityScores != nil }) {
                caps.insert(.qualityScores)
            }
        case .annotations:
            // Annotation-only documents
            if !caps.contains(.annotations) && annotationCount > 0 {
                caps.insert(.annotations)
            }
        case .generic:
            break
        }

        return caps
    }

    /// Checks if this document satisfies the given capability requirements.
    ///
    /// This is a convenience method that computes capabilities and checks
    /// if all required capabilities are present.
    ///
    /// - Parameter requirements: The capabilities that must be present.
    /// - Returns: `true` if all required capabilities are present.
    @MainActor
    public func satisfiesRequirements(_ requirements: DocumentCapability) -> Bool {
        computeCapabilities().contains(requirements)
    }

    /// Returns the capabilities that are required but missing from this document.
    ///
    /// - Parameter requirements: The capabilities that should be present.
    /// - Returns: The set of capabilities that are required but not present.
    @MainActor
    public func missingCapabilitiesForRequirements(_ requirements: DocumentCapability) -> DocumentCapability {
        requirements.subtracting(computeCapabilities())
    }

    /// Validates this document against a set of capability requirements.
    ///
    /// - Parameter validator: The capability validator to use.
    /// - Returns: The validation result.
    @MainActor
    public func validate(with validator: CapabilityValidator) -> CapabilityValidationResult {
        // Create a wrapper that provides the computed capabilities
        let wrapper = DocumentCapabilityWrapper(capabilities: computeCapabilities())
        return validator.validate(wrapper)
    }
}

// MARK: - DocumentCapabilityWrapper

/// A simple wrapper that holds pre-computed capabilities.
///
/// This is useful when you need to pass capabilities to functions
/// that expect a `CapabilityProvider` but you've already computed
/// the capabilities.
public struct DocumentCapabilityWrapper: CapabilityProvider, Sendable {
    public let capabilities: DocumentCapability

    public init(capabilities: DocumentCapability) {
        self.capabilities = capabilities
    }
}

// MARK: - Sequence Capability Extension

extension Sequence {
    /// The capabilities this sequence provides.
    ///
    /// Individual sequences can provide a subset of document capabilities.
    public var capabilities: DocumentCapability {
        var caps: DocumentCapability = .none

        switch alphabet {
        case .dna, .rna:
            caps.insert(.nucleotideSequence)
        case .protein:
            caps.insert(.aminoAcidSequence)
        }

        if qualityScores != nil {
            caps.insert(.qualityScores)
        }

        if isCircular {
            caps.insert(.circularTopology)
        }

        return caps
    }
}

// MARK: - Capability Description Helpers

extension DocumentCapability {
    /// Returns a user-friendly name for display in the UI.
    public var displayName: String {
        var names: [String] = []

        if contains(.nucleotideSequence) { names.append("Nucleotide Sequences") }
        if contains(.aminoAcidSequence) { names.append("Protein Sequences") }
        if contains(.qualityScores) { names.append("Quality Scores") }
        if contains(.annotations) { names.append("Annotations") }
        if contains(.variants) { names.append("Variants") }
        if contains(.coverage) { names.append("Coverage Data") }
        if contains(.alignment) { names.append("Alignments") }
        if contains(.pairedReads) { names.append("Paired Reads") }
        if contains(.multipleAlignment) { names.append("Multiple Alignment") }
        if contains(.referenceSequence) { names.append("Reference Sequence") }
        if contains(.indexed) { names.append("Indexed") }
        if contains(.sorted) { names.append("Sorted") }
        if contains(.compressed) { names.append("Compressed") }
        if contains(.assembly) { names.append("Assembly") }
        if contains(.phylogeny) { names.append("Phylogeny") }
        if contains(.primers) { names.append("Primers") }
        if contains(.richMetadata) { names.append("Rich Metadata") }
        if contains(.circularTopology) { names.append("Circular") }
        if contains(.translationProducts) { names.append("Translations") }
        if contains(.databaseCrossReferences) { names.append("Database References") }
        if contains(.readGroups) { names.append("Read Groups") }
        if contains(.supplementaryAlignments) { names.append("Supplementary Alignments") }
        if contains(.baseModifications) { names.append("Base Modifications") }

        if names.isEmpty {
            return "None"
        }
        return names.joined(separator: ", ")
    }

    /// Returns individual capability flags as an array.
    public var individualCapabilities: [DocumentCapability] {
        var result: [DocumentCapability] = []

        for bit in 0..<32 {
            let cap = DocumentCapability(rawValue: 1 << bit)
            if contains(cap) && cap.rawValue != 0 {
                result.append(cap)
            }
        }

        return result
    }

    /// Returns a short label for a single capability flag.
    ///
    /// This is useful for displaying capability badges in the UI.
    public var shortLabel: String? {
        // Only works for single capabilities
        switch self {
        case .nucleotideSequence: return "DNA/RNA"
        case .aminoAcidSequence: return "Protein"
        case .qualityScores: return "Quality"
        case .annotations: return "Annot"
        case .variants: return "Variants"
        case .coverage: return "Coverage"
        case .alignment: return "Aligned"
        case .pairedReads: return "Paired"
        case .multipleAlignment: return "MSA"
        case .referenceSequence: return "Ref"
        case .indexed: return "Indexed"
        case .sorted: return "Sorted"
        case .compressed: return "Compressed"
        case .assembly: return "Assembly"
        case .phylogeny: return "Tree"
        case .primers: return "Primers"
        case .richMetadata: return "Metadata"
        case .circularTopology: return "Circular"
        case .translationProducts: return "Trans"
        case .databaseCrossReferences: return "DbXref"
        case .readGroups: return "RG"
        case .supplementaryAlignments: return "Supp"
        case .baseModifications: return "Mods"
        default: return nil
        }
    }
}
