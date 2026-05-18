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

// MARK: - Result Viewport Controller

/// Base protocol for all result viewport controllers.
///
/// Each viewport class (Taxonomy Browser, Alignment Viewer, Assembly Viewer,
/// Variant Browser, Sequence Viewer) implements this protocol to provide a
/// uniform interface for the main window controller.
///
/// The `ResultType` associated type allows each viewport to define its own
/// strongly-typed result model while sharing a common configuration and
/// export interface.
///
/// ## Conformance
/// Conforming types are typically `NSViewController` subclasses that manage
/// a split view with a summary bar, main content area, and optional detail pane.
///
/// ```swift
/// final class TaxonomyResultViewController: NSViewController, ResultViewportController {
///     typealias ResultType = ClassificationResult
///
///     func configure(result: ClassificationResult) { ... }
///     var summaryBarView: NSView { summaryBar }
///     func exportResults(to url: URL, format: ResultExportFormat) throws { ... }
///     static var resultTypeName: String { "Classification" }
/// }
/// ```
@MainActor
public protocol ResultViewportController: AnyObject {

    /// The type of result this viewport displays.
    associatedtype ResultType

    /// Configure the viewport with result data.
    ///
    /// Called when a result is loaded or refreshed. Implementations should
    /// update all subviews (summary bar, tables, charts) to reflect the
    /// new result.
    ///
    /// - Parameter result: The result data to display
    func configure(result: ResultType)

    /// The summary bar view displayed at the top of the viewport.
    ///
    /// Typically a ``GenomicSummaryCardBar`` subclass showing key metrics
    /// (e.g., read count, species count, N50, coverage depth).
    var summaryBarView: NSView { get }

    /// Export results to a file in the specified format.
    ///
    /// - Parameters:
    ///   - url: Destination file URL
    ///   - format: The export format to use
    /// - Throws: If export fails (e.g., unsupported format, I/O error)
    func exportResults(to url: URL, format: ResultExportFormat) throws

    /// The display name for this result type.
    ///
    /// Used in menus, window titles, and export dialogs.
    /// Examples: "Classification", "Alignment", "Assembly", "Variants".
    static var resultTypeName: String { get }
}

// MARK: - BLAST Verifiable

/// Protocol for viewports that support BLAST verification of sequences.
///
/// Taxonomy-oriented viewports (Kraken2, EsViritu, TaxTriage, NAO-MGS)
/// conform to this protocol so users can verify classified taxa against
/// the NCBI nucleotide database.
///
/// The ``onBlastVerification`` callback is set by the parent controller
/// (typically `ViewerViewController` or `MainSplitViewController`) and
/// routes the request through ``BlastService``.
@MainActor
public protocol BlastVerifiable: AnyObject {

    /// Callback fired when the user requests BLAST verification.
    ///
    /// Set by the parent controller to handle the request. The closure
    /// receives a ``BlastRequest`` containing the sequences to verify.
    var onBlastVerification: ((BlastRequest) -> Void)? { get set }
}
