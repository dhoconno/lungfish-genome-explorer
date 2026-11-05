// TaxTriageRowReferenceMaps.swift - The accession maps that a page of TaxTriage database rows gives the viewer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The accession maps of a page of database rows (3.2 lane TTACCESSIONS, BIO F7).
///
/// A row stands for every reference of its organism that the build stored, each with its own length and the mapped
/// records its sample's BAM holds on it. Extract Reads, BLAST Verify and the alignment pane read these maps, so an
/// Influenza A row reaches all eight segments, and the pane, which opens the best-supported reference, opens the
/// segment that holds the reads at that segment's own length. A row of a database that stored no references stands
/// for its primary accession alone, at the length stored for it.
struct TaxTriageRowReferenceMaps: Sendable {
    private let stored: [String: [TaxTriageOrganismReference]]
    private(set) var organismToAccessionsBySample: [String: [String: [String]]] = [:]
    private(set) var taxIDToAccessionsBySample: [String: [Int: [String]]] = [:]
    private(set) var accessionLengths: [String: Int] = [:]
    /// The mapped records on each reference, by sample, since one reference holds different reads in each sample.
    private(set) var readCountsBySample: [String: [String: Int]] = [:]

    init(stored: [String: [TaxTriageOrganismReference]]) {
        self.stored = stored
    }

    /// Adds the references of `row` to the maps.
    mutating func add(_ row: TaxTriageTaxonomyRow) {
        let normalized = OrganismNameNormalizer.normalizedKey(row.organism)
        for reference in references(of: row) {
            organismToAccessionsBySample[row.sample, default: [:]][normalized, default: []].append(reference.accession)
            if let taxID = row.taxId {
                taxIDToAccessionsBySample[row.sample, default: [:]][taxID, default: []].append(reference.accession)
            }
            if let length = reference.length, length > 0 {
                accessionLengths[reference.accession] = length
            }
            if let reads = reference.mappedReads {
                readCountsBySample[row.sample, default: [:]][reference.accession] = reads
            }
        }
    }

    /// The stored references of `row`, or its primary accession alone when the database stored none for it.
    func references(of row: TaxTriageTaxonomyRow) -> [TaxTriageOrganismReference] {
        guard let primary = row.primaryAccession, !primary.isEmpty else { return [] }
        if let own = stored[TaxTriageOrganismReference.rowKey(sample: row.sample, primaryAccession: primary)], !own.isEmpty {
            return own
        }
        return [TaxTriageOrganismReference(
            sample: row.sample, primaryAccession: primary, accession: primary, length: row.accessionLength, mappedReads: nil
        )]
    }
}
