// SequenceExportOptions.swift - sequence export format choices
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

enum SequenceExportFormat {
    case fasta
    case genbank

    var fileExtension: String {
        switch self {
        case .fasta: return "fa"
        case .genbank: return "gb"
        }
    }

    var displayName: String {
        switch self {
        case .fasta: return "FASTA"
        case .genbank: return "GenBank"
        }
    }

    var cliFormat: String {
        switch self {
        case .fasta: return "fasta"
        case .genbank: return "genbank"
        }
    }
}

enum SequenceExportCompression {
    case none
    case gzip
    case zstd

    var fileExtension: String? {
        switch self {
        case .none: return nil
        case .gzip: return "gz"
        case .zstd: return "zst"
        }
    }
}
