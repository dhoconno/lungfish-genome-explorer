// ResultRowMenuActions.swift - Menu bar handlers for the selected row of a result table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Menu bar handlers for the selected row of whichever table or outline is
/// first responder.
///
/// The items in Selection > Table Row send these to the first responder, so a
/// result view controller that adopts the protocol gets the commands enabled
/// only while its table has keyboard focus, and its `validateMenuItem(_:)`
/// decides per selector whether the current selection supports the command.
/// Surfaces adopt only the selectors they can honour; the rest stay disabled.
@MainActor
@objc public protocol ResultRowMenuActions {
    @objc optional func extractReadsForSelectedRows(_ sender: Any?)
    @objc optional func blastVerifySelectedRow(_ sender: Any?)
    @objc optional func copySelectedRowName(_ sender: Any?)
    @objc optional func copySelectedRowAccession(_ sender: Any?)
    @objc optional func copySelectedRowTaxonID(_ sender: Any?)
    @objc optional func copySelectedRowAsTSV(_ sender: Any?)
    @objc optional func copySelectedRowSequence(_ sender: Any?)
    @objc optional func copySelectedRowFASTA(_ sender: Any?)
    @objc optional func openSelectedRowOnNCBI(_ sender: Any?)
    @objc optional func openSelectedRowTaxonomyOnNCBI(_ sender: Any?)
    @objc optional func openSelectedRowGenBank(_ sender: Any?)
    @objc optional func searchPubMedForSelectedRow(_ sender: Any?)
    @objc optional func showSelectedRowInInspector(_ sender: Any?)
    @objc optional func extractSelectedRowsToNewBundle(_ sender: Any?)
    @objc optional func activateSelectedRow(_ sender: Any?)
}

/// Menu bar handlers for View > Expand All and View > Collapse All.
///
/// Any controller that owns an outline adopts this, so the two View items
/// act on whichever outline is first responder.
@MainActor
@objc public protocol OutlineExpandCollapseActions {
    func expandAllOutlineItems(_ sender: Any?)
    func collapseAllOutlineItems(_ sender: Any?)
}

/// The commands of Selection > Table Row, one per ``ResultRowMenuActions``
/// selector.
///
/// Result tables build their context menus and cell accessibility actions
/// from the same titles, so the three surfaces never drift.
public enum ResultRowCommand: String, CaseIterable, RowCommand, Sendable {
    case activate
    case extractReads
    case blastVerify
    case extractToNewBundle
    case copyName
    case copyAccession
    case copyTaxonID
    case copySequence
    case copyFASTA
    case copyAsTSV
    case openOnNCBI
    case openTaxonomyOnNCBI
    case openGenBank
    case searchPubMed
    case showInInspector

    public var title: String {
        switch self {
        case .activate: return "Open Row"
        case .extractReads: return "Extract Reads\u{2026}"
        case .blastVerify: return "Verify with BLAST\u{2026}"
        case .extractToNewBundle: return "Extract to New Bundle\u{2026}"
        case .copyName: return "Copy Name"
        case .copyAccession: return "Copy Accession"
        case .copyTaxonID: return "Copy Taxon ID"
        case .copySequence: return "Copy Sequence"
        case .copyFASTA: return "Copy FASTA"
        case .copyAsTSV: return "Copy Row as TSV"
        case .openOnNCBI: return "Open on NCBI"
        case .openTaxonomyOnNCBI: return "Open Taxonomy on NCBI"
        case .openGenBank: return "Open GenBank Record"
        case .searchPubMed: return "Search PubMed"
        case .showInInspector: return "Show in Inspector"
        }
    }

    public var identifierSlug: String {
        switch self {
        case .activate: return "open-row"
        case .extractReads: return "extract-reads"
        case .blastVerify: return "blast-verify"
        case .extractToNewBundle: return "extract-to-new-bundle"
        case .copyName: return "copy-name"
        case .copyAccession: return "copy-accession"
        case .copyTaxonID: return "copy-taxon-id"
        case .copySequence: return "copy-sequence"
        case .copyFASTA: return "copy-fasta"
        case .copyAsTSV: return "copy-as-tsv"
        case .openOnNCBI: return "open-on-ncbi"
        case .openTaxonomyOnNCBI: return "open-taxonomy-on-ncbi"
        case .openGenBank: return "open-genbank"
        case .searchPubMed: return "search-pubmed"
        case .showInInspector: return "show-in-inspector"
        }
    }

    /// Show in Inspector is the one row command with a chord, Cmd-Opt-S. The
    /// Selection menu offers it once, at the top level, for every surface.
    public var keyEquivalent: RowCommandKeyEquivalent? {
        switch self {
        case .showInInspector: return RowCommandKeyEquivalent("s", [.command, .option])
        default: return nil
        }
    }

    public var menuSelector: Selector {
        switch self {
        case .activate: return #selector(ResultRowMenuActions.activateSelectedRow(_:))
        case .extractReads: return #selector(ResultRowMenuActions.extractReadsForSelectedRows(_:))
        case .blastVerify: return #selector(ResultRowMenuActions.blastVerifySelectedRow(_:))
        case .extractToNewBundle: return #selector(ResultRowMenuActions.extractSelectedRowsToNewBundle(_:))
        case .copyName: return #selector(ResultRowMenuActions.copySelectedRowName(_:))
        case .copyAccession: return #selector(ResultRowMenuActions.copySelectedRowAccession(_:))
        case .copyTaxonID: return #selector(ResultRowMenuActions.copySelectedRowTaxonID(_:))
        case .copySequence: return #selector(ResultRowMenuActions.copySelectedRowSequence(_:))
        case .copyFASTA: return #selector(ResultRowMenuActions.copySelectedRowFASTA(_:))
        case .copyAsTSV: return #selector(ResultRowMenuActions.copySelectedRowAsTSV(_:))
        case .openOnNCBI: return #selector(ResultRowMenuActions.openSelectedRowOnNCBI(_:))
        case .openTaxonomyOnNCBI: return #selector(ResultRowMenuActions.openSelectedRowTaxonomyOnNCBI(_:))
        case .openGenBank: return #selector(ResultRowMenuActions.openSelectedRowGenBank(_:))
        case .searchPubMed: return #selector(ResultRowMenuActions.searchPubMedForSelectedRow(_:))
        case .showInInspector: return #selector(ResultRowMenuActions.showSelectedRowInInspector(_:))
        }
    }

    /// Menu sections of Selection > Table Row, in display order. Show in
    /// Inspector is not listed because the Selection menu carries it at the
    /// top level, shared with Sidebar Item.
    public static let menuSections: [[ResultRowCommand]] = [
        [.activate],
        [.extractReads, .blastVerify, .extractToNewBundle],
        [.copyName, .copyAccession, .copyTaxonID, .copySequence, .copyFASTA, .copyAsTSV],
        [.openOnNCBI, .openTaxonomyOnNCBI, .openGenBank, .searchPubMed],
    ]
}
