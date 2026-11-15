// STARIndexKey.swift - The key of a STAR index built on Linux, and the words of a refusal (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// A refusal of the STAR index plan, its batch or its adopt, in the words a person reads.
package struct STARIndexError: Error, LocalizedError, Equatable {
    package var message: String
    package init(_ message: String) { self.message = message }
    package var errorDescription: String? { message }
}

/// The two STAR builds the image holds, each in a prefix of its own (one conda environment cannot hold both).
package enum STARIndexVersion: String, CaseIterable, Sendable {
    case v2_7_11b = "2.7.11b"
    case v2_7_3a = "2.7.3a"
}

/// Names a STAR index as the salmon key names its index (`docs/formats/reference-set.md`, The salmon index cache): the
/// STAR version, every argument that changes the index's bytes and the sha256 of the set's `reference-set.json`. The
/// index is never byte-pinned across platforms, so the key is what a later plan finds an index by (BIO-LINUX-HOST item 8).
package struct STARIndexKey: Codable, Sendable, Equatable {
    /// The index's folder name, `star-<version>-sa<n>-sparse<d>`, which a `reference` entry's `index.key` carries.
    package var folderName: String
    package var setID: String
    /// The sha256 of the set's `reference-set.json`, which covers `derived/genes.gtf`.
    package var referenceSetSHA256: String
    package var star: PlanToolPin
    /// `--genomeSAindexNbases`, as `scripts/repro/rnaseq/gse225770/star.sh` computes it from the FASTA files' bases.
    package var genomeSAindexNbases: Int
    package var genomeSAsparseD: Int
    /// `--sjdbOverhang`, the length of genome taken on each side of an annotated junction, which changes the index's bytes.
    package var sjdbOverhang: Int
    /// The set's genome and then each extra, in the gentrome's order, as paths inside the set.
    package var genomeFastaFiles: [String]
    package var countingGTFSHA256: String

    package static func folderName(star version: String, nbases: Int, sparseD: Int) -> String {
        "star-\(version)-sa\(nbases)-sparse\(sparseD)"
    }

    /// `min(14, round(log2(bases) / 2 - 1))`, the rule of `star.sh:29`, never below 1.
    package static func nbases(forBases bases: Int) -> Int {
        guard bases > 1 else { return 1 }
        return min(14, max(1, Int((log2(Double(bases)) / 2 - 1).rounded())))
    }
}
