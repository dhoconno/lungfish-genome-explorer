// TaxTriageResultViewController+BlastRestore.swift - What a TaxTriage row's BLAST request and saved search name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

// Phase 3.1 lane REOPEN. A row's BLAST request and the key of its saved search are built from one organism, so the key
// names the sample and tax ID the search records.

extension TaxTriageResultViewController {

    /// The organism a BLAST request of `row` names, with the sample that owns the BAM held now.
    func blastOrganism(for row: TaxTriageTableRow) -> TaxTriageOrganism {
        TaxTriageOrganism(
            name: row.organism,
            score: row.tassScore,
            reads: row.reads,
            coverage: row.coverage,
            taxId: row.taxId,
            rank: row.rank,
            sample: Self.sample(owning: bamURL, in: bamFilesBySample)
        )
    }

    /// The organism a BLAST request of `metric` names. It names the sample whose BAM goes with the request: the
    /// metric's own, else the owner of the BAM held now.
    func blastOrganism(for metric: TaxTriageMetric) -> TaxTriageOrganism {
        let ownBamURL = metric.sample.flatMap { bamFilesBySample[$0] }
        return TaxTriageOrganism(
            name: metric.organism,
            score: metric.tassScore,
            reads: metric.reads,
            coverage: metric.coverageBreadth,
            taxId: metric.taxId,
            rank: metric.rank,
            sample: ownBamURL == nil ? Self.sample(owning: bamURL, in: bamFilesBySample) : metric.sample
        )
    }

    /// The saved-search key of `row`, nil when this view has no result folder.
    func blastSavedSearchRow(for row: TaxTriageTableRow) -> BlastSavedSearchRow? {
        batchGroupURL.map {
            blastOrganism(for: row).blastSavedSearchRow(accessions: accessions(for: row) ?? [], sourceResultURL: $0)
        }
    }

    /// The saved-search key of `metric`, nil when this view has no result folder.
    func blastSavedSearchRow(for metric: TaxTriageMetric) -> BlastSavedSearchRow? {
        batchGroupURL.map {
            blastOrganism(for: metric).blastSavedSearchRow(accessions: accessions(for: metric) ?? [], sourceResultURL: $0)
        }
    }

    /// What Run Again repeats while the pane shows a restored search: that row's sample, accessions, BAM and index,
    /// never those of the run this view held before. Nil once a run's own result shows.
    func blastRequestOfRestoredRow() -> (sample: String?, accessions: [String]?, bamURL: URL?, bamIndexURL: URL?)? {
        guard let row = resultActions.restoredBlastRow else { return nil }
        return (
            sample: row.sample,
            accessions: row.contig.map { $0.components(separatedBy: ",") },
            bamURL: row.sample.flatMap { bamFilesBySample[$0] } ?? bamURL,
            bamIndexURL: row.sample.flatMap { bamIndexesBySample[$0] } ?? bamIndexURL
        )
    }
}
