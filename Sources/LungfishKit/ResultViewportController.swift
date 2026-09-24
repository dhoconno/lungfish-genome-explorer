// ResultViewportController.swift - Base protocol for result viewport controllers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

// MARK: - Result Export Format

/// Export format for result data from viewport controllers.
///
/// Each viewport class supports a subset of these formats. For example,
/// taxonomy viewports typically export CSV/TSV/JSON, while assembly
/// viewports may also offer FASTA for contig sequences.
public enum ResultExportFormat: String, Sendable, CaseIterable {
    case csv = "csv"
    case tsv = "tsv"
    case json = "json"
    case fasta = "fasta"
}

// MARK: - BLAST Request

/// A request to BLAST-verify sequences from a result viewport.
///
/// This is the viewport-layer type passed from ``BlastVerifiable`` controllers
/// to the app delegate or coordinator, which then constructs a full
/// ``BlastVerificationRequest`` for submission to the NCBI BLAST API.
///
/// ## Usage
/// ```swift
/// let request = BlastRequest(
///     taxId: 130309,
///     sequences: [">read_1\nATGCGATCGA..."],
///     readCount: 42,
///     sourceLabel: "taxid 130309"
/// )
/// onBlastVerification?(request)
/// ```
public struct BlastRequest: Sendable {

    /// The NCBI taxonomy ID of the target taxon, if applicable.
    public let taxId: Int?

    /// FASTA-formatted sequences to verify.
    public let sequences: [String]

    /// Number of reads represented by this request.
    public let readCount: Int

    /// Human-readable label describing the source (e.g., "taxid 130309" or "contig NODE_1").
    public let sourceLabel: String

    /// Creates a new BLAST request.
    ///
    /// - Parameters:
    ///   - taxId: NCBI taxonomy ID, or `nil` if not taxonomy-related
    ///   - sequences: FASTA-formatted sequence strings
    ///   - readCount: Number of reads in the request
    ///   - sourceLabel: Display label for the source of these sequences
    public init(taxId: Int?, sequences: [String], readCount: Int, sourceLabel: String) {
        self.taxId = taxId
        self.sequences = sequences
        self.readCount = readCount
        self.sourceLabel = sourceLabel
    }
}

