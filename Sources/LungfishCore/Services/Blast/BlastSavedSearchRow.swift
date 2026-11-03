// BlastSavedSearchRow.swift - The lineage that ties a saved BLAST search to the row it was sent from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The classifier row a saved `blast submit` record belongs to, in the fields of the record's lineage (Phase 3.1 lane
/// REOPEN, UX-BLAST-TIMEOUT Q2).
///
/// NAO-MGS, EsViritu, TaxTriage and NVD save their searches in the project's `blast-verifications` folder, so that
/// folder holds searches of many results. A row's search is the one whose source result, sample, tax ID and contig are
/// the row's own, so a search of the same taxon from another result or sample never shows on this row. The row's value
/// of each field comes from the code its submit plan writes that field with: ``lineageSample(of:)``,
/// ``lineageContig(of:)`` and ``lineageTaxId(ofRequestTaxId:)``, and the row builders in LungfishIO. Assembly and 12S
/// selections have keys here too (lane REOPEN2), ``assemblySelection(contigs:resultURL:)`` and
/// ``twelveSSelection(sequenceIDs:bundleURL:)``.
public struct BlastSavedSearchRow: Sendable, Equatable {
    public var sourceResultURL: URL
    public var sample: String?
    public var taxId: Int?
    public var contig: String?
    /// The IDs a search's query holds, for a search whose lineage does not name its sequences. A 12S search pools its
    /// sequences across samples and names no sample or contig, so its own query tells one selection's search from
    /// another's. Nil when the lineage alone tells them apart.
    public var querySequenceIDs: [String]?

    public init(sourceResultURL: URL, sample: String?, taxId: Int?, contig: String?, querySequenceIDs: [String]? = nil) {
        self.sourceResultURL = sourceResultURL
        self.sample = sample
        self.taxId = taxId
        self.contig = contig
        self.querySequenceIDs = querySequenceIDs
    }

    /// The key of an Assembly selection, in the fields `assemblyBlastSubmitPlan` records, the result folder and the
    /// contigs. Nil for no contigs. An Assembly request has no taxon and the plan names no sample.
    public static func assemblySelection(contigs: [String], resultURL: URL) -> BlastSavedSearchRow? {
        lineageContig(of: contigs).map { BlastSavedSearchRow(sourceResultURL: resultURL, sample: nil, taxId: nil, contig: $0) }
    }

    /// The key of a 12S unresolved selection. `twelveSUnresolvedBlastSubmitPlan` records only the bundle, so the key adds
    /// the IDs the search's query holds. Nil for no sequences.
    public static func twelveSSelection(sequenceIDs: [String], bundleURL: URL) -> BlastSavedSearchRow? {
        guard !sequenceIDs.isEmpty else { return nil }
        return BlastSavedSearchRow(sourceResultURL: bundleURL, sample: nil, taxId: nil, contig: nil, querySequenceIDs: sequenceIDs)
    }

    /// The sequence IDs of a FASTA's headers, each header's first word.
    public static func sequenceIDs(ofFASTA text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix(">") else { return nil }
            return line.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
    }

    /// The lineage's sample of a search that drew reads from `samples`, each named once and sorted. Nil for none.
    public static func lineageSample(of samples: [String]) -> String? {
        let names = Set(samples).sorted()
        return names.isEmpty ? nil : names.joined(separator: ",")
    }

    /// The lineage's contig of a search of `accessions`. Nil for none.
    public static func lineageContig(of accessions: [String]) -> String? {
        accessions.isEmpty ? nil : accessions.joined(separator: ",")
    }

    /// The lineage's tax ID of a request whose tax ID is `taxId`. A request's 0 is its "none", which records no taxon.
    public static func lineageTaxId(ofRequestTaxId taxId: Int) -> Int? {
        taxId == 0 ? nil : taxId
    }

    /// Whether the record stored at `recordURL` with `lineage` is a search of this row. A tax ID of 0 reads as none, as
    /// a request's does. The source result compares with its symbolic links resolved, since its `@/` path resolves in
    /// the project that holds the record now. Resolving a path reads the disk, so this runs off the main actor.
    public func isSource(of lineage: BlastSubmissionRecord.Lineage, recordAt recordURL: URL) -> Bool {
        guard lineage.sample == sample,
              Self.contigList(lineage.contig) == Self.contigList(contig),
              (lineage.taxId ?? 0) == (taxId ?? 0),
              let recorded = lineage.sourceResultURL(recordAt: recordURL),
              Self.comparablePath(recorded) == Self.comparablePath(sourceResultURL) else {
            return false
        }
        guard let querySequenceIDs else { return true }
        return Self.query(ofRecordAt: recordURL, holds: querySequenceIDs)
    }

    /// Whether the query copy beside the record holds exactly `ids`, in any order. A copy that cannot be read holds none.
    private static func query(ofRecordAt recordURL: URL, holds ids: [String]) -> Bool {
        let queryURL = recordURL.deletingLastPathComponent().appendingPathComponent(BlastSubmissionRecord.queryFileName)
        guard let text = try? String(contentsOf: queryURL, encoding: .utf8) else { return false }
        return sequenceIDs(ofFASTA: text).sorted() == ids.sorted()
    }

    /// A contig value's IDs in one order. A multi-contig search joins its IDs in selection or lookup order, and TaxTriage
    /// ranks its accessions by read support, so the same contigs in another order are the same search. Nil stays nil.
    private static func contigList(_ contig: String?) -> [Substring]? {
        contig?.split(separator: ",", omittingEmptySubsequences: false).sorted()
    }

    private static func comparablePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
