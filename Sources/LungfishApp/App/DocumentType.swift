// DocumentType.swift - Types of documents the app can handle
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "DocumentManager")

/// Types of documents the app can handle.
public enum DocumentType: String, CaseIterable, Sendable {
    case fasta
    case fastq
    case genbank
    case gff3
    case bed
    case vcf
    case bam
    case lungfishProject         // Native .lungfish project format
    case lungfishReferenceBundle // .lungfishref reference genome bundle
    case lungfishMultipleSequenceAlignmentBundle // .lungfishmsa MSA bundle
    case lungfishPhylogeneticTreeBundle // .lungfishtree tree bundle
    case lungfishPrimerAnalysisBundle // .lungfishprimeranalysis saved results
    case lungfishMHCReferenceBundle // .lungfishmhcref MHC amplicon reference bundle

    /// File extensions for this document type.
    public var extensions: [String] {
        switch self {
        case .fasta: return ["fa", "fasta", "fna", "fas"]
        case .fastq: return ["fq", "fastq", FASTQBundle.directoryExtension]
        case .genbank: return ["gb", "gbk", "genbank"]
        case .gff3: return ["gff", "gff3"]
        case .bed: return ["bed"]
        case .vcf: return ["vcf"]
        case .bam: return ["bam", "cram", "sam"]
        case .lungfishProject: return ["lungfish"]
        case .lungfishReferenceBundle: return ["lungfishref"]
        case .lungfishMultipleSequenceAlignmentBundle: return [MultipleSequenceAlignmentBundle.directoryExtension]
        case .lungfishPhylogeneticTreeBundle: return ["lungfishtree"]
        case .lungfishPrimerAnalysisBundle: return ["lungfishprimeranalysis"]
        case .lungfishMHCReferenceBundle: return [MHCAmpliconReferenceBundle.directoryExtension]
        }
    }

    /// Whether this is a directory-based format
    public var isDirectoryFormat: Bool {
        switch self {
        case .lungfishProject, .lungfishReferenceBundle, .lungfishMultipleSequenceAlignmentBundle,
             .lungfishPhylogeneticTreeBundle, .lungfishMHCReferenceBundle, .lungfishPrimerAnalysisBundle:
            return true
        default:
            return false
        }
    }

    /// Detect document type from file extension.
    /// Handles gzip-compressed files (e.g., .fasta.gz, .fastq.gz)
    public static func detect(from url: URL) -> DocumentType? {
        var ext = url.pathExtension.lowercased()
        var urlToCheck = url

        // Handle gzip-compressed files: strip .gz and check the underlying extension
        if ext == "gz" {
            urlToCheck = url.deletingPathExtension()
            ext = urlToCheck.pathExtension.lowercased()
            logger.debug("DocumentType.detect: Stripped .gz, checking extension='\(ext, privacy: .public)'")
        }

        let detected = DocumentType.allCases.first { $0.extensions.contains(ext) }
        logger.debug("DocumentType.detect: extension='\(ext, privacy: .public)' -> \(detected?.rawValue ?? "nil", privacy: .public)")
        return detected
    }
}
