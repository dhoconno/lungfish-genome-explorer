// ClassifierBlastSavedSearchRow.swift - The saved-search key of each classifier row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// Phase 3.1 lane REOPEN. Each builder names the row's lineage with the same fields and helpers its submit plan writes
// (`ViewerViewController+NaoMgs.swift`, `+EsViritu.swift`, `+TaxTriage.swift`, `+Nvd.swift`), so a row's key and the
// record of its search cannot drift. `BlastSavedSearchRowPlanTests` builds both and compares them.

extension NaoMgsTaxonSummaryRow {
    /// A NAO-MGS row draws its reads from its own sample, so the plan's list of samples names that one.
    public func blastSavedSearchRow(sourceResultURL: URL) -> BlastSavedSearchRow {
        BlastSavedSearchRow(
            sourceResultURL: sourceResultURL, sample: BlastSavedSearchRow.lineageSample(of: [sample]), taxId: taxId, contig: nil
        )
    }
}

extension TaxTriageOrganism {
    /// `accessions` are the row's references, which the plan records as the contig.
    public func blastSavedSearchRow(accessions: [String], sourceResultURL: URL) -> BlastSavedSearchRow {
        BlastSavedSearchRow(
            sourceResultURL: sourceResultURL, sample: sample,
            taxId: BlastSavedSearchRow.lineageTaxId(ofRequestTaxId: taxId ?? 0),
            contig: BlastSavedSearchRow.lineageContig(of: accessions)
        )
    }
}

extension ViralDetection {
    /// An EsViritu request has no tax ID, so a row matches on its result, its sample and the accessions it searches.
    public func blastSavedSearchRow(accessions: [String], sourceResultURL: URL) -> BlastSavedSearchRow {
        BlastSavedSearchRow(
            sourceResultURL: sourceResultURL, sample: sampleId, taxId: nil,
            contig: BlastSavedSearchRow.lineageContig(of: accessions)
        )
    }
}

extension ViralAssembly {
    /// An assembly row searches every contig under its first contig's sample, as its BLAST request does.
    public func blastSavedSearchRow(sourceResultURL: URL) -> BlastSavedSearchRow? {
        contigs.first?.blastSavedSearchRow(accessions: contigs.map(\.accession), sourceResultURL: sourceResultURL)
    }
}

extension NvdBlastHit {
    /// A contig with no adjusted tax ID sends 0, which records no taxon, so its row matches on result, sample and contig.
    public func blastSavedSearchRow(sourceResultURL: URL) -> BlastSavedSearchRow {
        BlastSavedSearchRow(
            sourceResultURL: sourceResultURL, sample: sampleId,
            taxId: BlastSavedSearchRow.lineageTaxId(ofRequestTaxId: Int(adjustedTaxid) ?? 0), contig: qseqid
        )
    }
}
