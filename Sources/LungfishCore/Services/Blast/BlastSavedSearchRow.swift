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
/// ``lineageContig(of:)`` and ``lineageTaxId(ofRequestTaxId:)``, and the row builders in LungfishIO.
public struct BlastSavedSearchRow: Sendable, Equatable {
    public var sourceResultURL: URL
    public var sample: String?
    public var taxId: Int?
    public var contig: String?

    public init(sourceResultURL: URL, sample: String?, taxId: Int?, contig: String?) {
        self.sourceResultURL = sourceResultURL
        self.sample = sample
        self.taxId = taxId
        self.contig = contig
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
              lineage.contig == contig,
              (lineage.taxId ?? 0) == (taxId ?? 0),
              let recorded = lineage.sourceResultURL(recordAt: recordURL) else {
            return false
        }
        return Self.comparablePath(recorded) == Self.comparablePath(sourceResultURL)
    }

    private static func comparablePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
