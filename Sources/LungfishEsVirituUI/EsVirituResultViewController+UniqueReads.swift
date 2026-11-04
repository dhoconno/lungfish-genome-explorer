// EsVirituResultViewController+UniqueReads.swift - The stored Unique Reads of each contig row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import LungfishWorkflow

extension EsVirituResultViewController {
    /// The stored Unique Reads of each (sample, contig accession) row, raised to 1 only when the row has reads, as the
    /// virus row sums them and the export writes them. A row never counted has no entry, so its segment row shows a dash.
    static func uniqueReadsBySampleContig(from rows: [EsVirituDetectionRow]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows {
            guard let unique = ClassifierUniqueReads.normalized(stored: row.uniqueReads, readCount: row.readCount) else {
                continue
            }
            counts["\(row.sample)\t\(row.accession)"] = unique
        }
        return counts
    }
}
