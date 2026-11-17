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
    /// The sha256 of the set's `derived/genes.gtf`, unfiltered, in a variant's key too.
    package var countingGTFSHA256: String
    /// The GTF that the 10x filter rule made from `derived/genes.gtf` and `--sjdbGTFfile` named, for the STARsolo variant
    /// only. A bulk key has none, so it writes no `gtfFilter` key and keeps its bytes (ARCH-SOLO-GTF item 3).
    package var gtfFilter: GTFFilter? = nil

    /// The rule, its version and list, the made file's sha256 and size, and the number of genes it left out.
    package struct GTFFilter: Codable, Sendable, Equatable {
        package var rule: String
        package var ruleVersion: Int
        package var list: String
        package var sha256: String
        package var size: Int64
        package var genesLeftOut: Int

        package init(rule: String, ruleVersion: Int, list: String, sha256: String, size: Int64, genesLeftOut: Int) {
            (self.rule, self.ruleVersion, self.list) = (rule, ruleVersion, list)
            (self.sha256, self.size, self.genesLeftOut) = (sha256, size, genesLeftOut)
        }

        package init(_ made: TenxGTFFilter.Made) {
            self.init(rule: TenxGTFFilter.rule, ruleVersion: made.list.ruleVersion, list: made.list.rawValue,
                      sha256: made.sha256, size: made.size, genesLeftOut: made.genesLeftOut.count)
        }
    }

    /// `star-<version>-sa<n>-sparse<d>`, and for the 10x variant `-tenx<rule version>-<list>` after it, such as
    /// `star-2.7.11b-sa14-sparse2-tenx1-mkgtf-3.0.0` or `star-2.7.11b-sa14-sparse3-tenx2-gencode-2020-A`, so the bulk and the
    /// variant index of one set, or two indexes of another `--genomeSAsparseD`, never share a folder.
    package static func folderName(star version: String, nbases: Int, sparseD: Int, filter: TenxGTFFilter.List? = nil) -> String {
        "star-\(version)-sa\(nbases)-sparse\(sparseD)" + (filter.map { "-\($0.folderName)" } ?? "")
    }

    /// `min(14, round(log2(bases) / 2 - 1))`, the rule of `star.sh:29`, never below 1.
    package static func nbases(forBases bases: Int) -> Int {
        guard bases > 1 else { return 1 }
        return min(14, max(1, Int((log2(Double(bases)) / 2 - 1).rounded())))
    }
}
