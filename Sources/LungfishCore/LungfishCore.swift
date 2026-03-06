// LungfishCore - Core data models and services for Lungfish Genome Explorer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

/// LungfishCore provides the foundational data models and services for the genome browser.
///
/// ## Overview
///
/// This module contains:
/// - **Models**: Core data types like `Sequence`, `SequenceAnnotation`, `GenomicDocument`
/// - **Services**: NCBI, ENA, and other data access services
/// - **Versioning**: Diff-based sequence version control
/// - **Translation**: Codon tables and amino acid translation
/// - **Storage**: Document and project management
///
/// ## Key Types
///
/// - ``Sequence``: Memory-efficient sequence representation with 2-bit DNA encoding
/// - ``SequenceAnnotation``: Feature annotations with qualifiers
/// - ``GenomicDocument``: Container for sequences and their metadata
/// - ``GenomicRegion``: Coordinate-based region representation
///
/// ## Example
///
/// ```swift
/// let sequence = try Sequence(
///     name: "my_sequence",
///     alphabet: .dna,
///     bases: "ATCGATCGATCG"
/// )
///
/// let region = GenomicRegion(
///     chromosome: "chr1",
///     start: 1000,
///     end: 2000
/// )
/// ```

// Re-export public types
@_exported import struct Foundation.UUID
@_exported import struct Foundation.URL
@_exported import struct Foundation.Date
