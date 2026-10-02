// MHCReferenceRecordCatalogError.swift - Errors from MHC reference record resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

public enum MHCReferenceRecordCatalogError: Error, LocalizedError, Equatable, Sendable {
    case invalidCDNAThreshold(Int)
    case manifestReadFailed(path: String, reason: String)
    case manifestMissingGenomePath(path: String)
    case unsafeBundlePath(field: String, path: String)
    case recordStoreOpenFailed(path: String, reason: String)
    case recordStoreQueryFailed(path: String, reason: String)
    case annotationStoreOpenFailed(path: String, reason: String)
    case annotationStoreQueryFailed(path: String, reason: String)
    case duplicateSequenceID(String)
    case conflictingMoleculeClasses(sequenceID: String, values: [String])
    case unsupportedMoleculeTypeValues(sequenceID: String, values: [String])
    case conflictingAlleles(sequenceID: String, values: [String])
    case invalidAlleleAnnotations(sequenceID: String, values: [String])
    case ambiguousFASTAAlleles(sequenceID: String, candidates: [String])
    case conflictingLoci(sequenceID: String, alleleLocus: String, annotatedGenes: [String])
    case unresolvedAlleleOrLocus(sequenceID: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCDNAThreshold(let value):
            return "The MHC cDNA length threshold must be greater than zero; received \(value)."
        case .manifestReadFailed(let path, let reason):
            return "Could not read the MHC reference manifest at \(path): \(reason)"
        case .manifestMissingGenomePath(let path):
            return "The MHC reference manifest at \(path) does not declare genome.path."
        case .unsafeBundlePath(let field, let path):
            return "The MHC reference manifest field \(field) must name a file inside the bundle; received '\(path)'."
        case .recordStoreOpenFailed(let path, let reason):
            return "Could not open the MHC reference record store read-only at \(path): \(reason)"
        case .recordStoreQueryFailed(let path, let reason):
            return "Could not query MHC allele metadata from \(path): \(reason)"
        case .annotationStoreOpenFailed(let path, let reason):
            return "Could not open the MHC reference annotation store read-only at \(path): \(reason)"
        case .annotationStoreQueryFailed(let path, let reason):
            return "Could not query MHC exon/intron annotations from \(path): \(reason)"
        case .duplicateSequenceID(let sequenceID):
            return "The MHC reference FASTA contains duplicate sequence ID '\(sequenceID)', so metadata cannot be joined unambiguously."
        case .conflictingMoleculeClasses(let sequenceID, let values):
            return "Reference sequence '\(sequenceID)' has conflicting molecule-class annotations: \(values.joined(separator: ", "))."
        case .unsupportedMoleculeTypeValues(let sequenceID, let values):
            return "Reference sequence '\(sequenceID)' has unsupported nonempty molecule-class annotations: \(values.joined(separator: ", ")). Use a recognized genomic DNA, mRNA, or cDNA value."
        case .conflictingAlleles(let sequenceID, let values):
            return "Reference sequence '\(sequenceID)' has conflicting allele annotations: \(values.joined(separator: ", "))."
        case .invalidAlleleAnnotations(let sequenceID, let values):
            return "Reference sequence '\(sequenceID)' has malformed nonempty MHC allele annotations: \(values.joined(separator: ", "))."
        case .ambiguousFASTAAlleles(let sequenceID, let candidates):
            return "Reference sequence '\(sequenceID)' has multiple valid MHC allele names in its FASTA description: \(candidates.joined(separator: ", "))."
        case .conflictingLoci(let sequenceID, let alleleLocus, let annotatedGenes):
            return "Reference sequence '\(sequenceID)' resolves to allele locus '\(alleleLocus)' but has conflicting gene annotations: \(annotatedGenes.joined(separator: ", "))."
        case .unresolvedAlleleOrLocus(let sequenceID):
            return "Reference sequence '\(sequenceID)' has no resolvable MHC allele name and locus in record metadata, its FASTA description, or a recognized legacy IPD-MHC sequence identifier."
        }
    }
}
