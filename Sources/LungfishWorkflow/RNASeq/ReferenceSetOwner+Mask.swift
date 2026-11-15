// ReferenceSetOwner+Mask.swift - A bacterium extra's rRNA mask from a GTF the person gives (Phase 5.2 lane RS-NOTHOST)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// BIO-NOTHOST-BARCODE items 1 to 6. The mask is the `gene` lines of `gene_biotype "rRNA"` of the GTF, each by its
// gene-line span, as `scripts/repro/rnaseq/gse296788/mtb.py:71-79` reads them. Erdman's exon lines carry no gene
// biotype, so only gene lines count. The set keeps the GTF's bytes as `extras/<name>.mask.gtf[.gz]` and its genes as
// intervals of `masks[]`, never as features, so in LGE's layout the extra still counts as one feature a record.

import Foundation
import LungfishCore
import LungfishIO

extension ReferenceSetOwner {
    /// Copies `extra`'s mask GTF into the stage, checks its sha256 and reads its rRNA genes. A GTF that names a sequence
    /// the extra lacks, or that holds no rRNA gene, is refused in words, so an empty mask never passes in silence.
    func copyMask(
        _ source: URL, given: URL, sha: String, extra: String, records: [String], in stage: URL
    ) throws -> ReferenceSetManifest.Mask {
        let path = "extras/\(extra).mask.\(given.isGzipCompressed ? "gtf.gz" : "gtf")"
        let copied = try copyChecked(source, to: path, in: stage, sha: sha)
        let intervals = try Self.rRNAIntervals(copied, fileName: given.lastPathComponent, extra: extra, records: records)
        return .init(name: extra, path: path, sha256: sha, rule: ReferenceSetManifest.Mask.rRNARule, intervals: intervals)
    }

    /// The `gene_biotype "rRNA"` gene lines of `gtf` in the order given, 1-based as given.
    static func rRNAIntervals(
        _ gtf: URL, fileName: String, extra: String, records: [String]
    ) throws -> [ReferenceSetManifest.Mask.Interval] {
        let known = Set(records)
        var absent: [String] = []
        var intervals: [ReferenceSetManifest.Mask.Interval] = []
        try gtf.forEachLineAutoDecompressing { line in
            guard let feature = ReferenceSetGTFFeature(line) else { return }
            if !known.contains(feature.contig), !absent.contains(feature.contig) { absent.append(feature.contig) }
            guard feature.type == "gene", feature.attributes["gene_biotype"] == "rRNA",
                  let start = Int(feature.start), let end = Int(feature.end) else { return }
            intervals.append(.init(record: feature.contig, start: start, end: end, geneID: feature.gene))
        }
        guard absent.isEmpty else {
            throw ReferenceSetError.invalidRequest("The annotation \(fileName) names sequences the extra \(extra) lacks: "
                + "\(ReferenceSetError.listed(absent)). It gives \(extra) no mask, and nothing was built.")
        }
        guard !intervals.isEmpty else {
            throw ReferenceSetError.invalidRequest("The annotation \(fileName) holds no rRNA gene, so it gives \(extra) no mask.")
        }
        return intervals
    }
}
