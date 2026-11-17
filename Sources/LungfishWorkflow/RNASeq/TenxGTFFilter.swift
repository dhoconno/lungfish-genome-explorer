// TenxGTFFilter.swift - The 10x filter rule that makes a STARsolo index's GTF from a set's derived/genes.gtf
// (Phase 5.3 lane SOLO-PLAN)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The 10x filter rule (BIO-SOLO-GTF items 2 and 3, ARCH-SOLO-GTF items 1 and 2) in two versions, one for each list.
/// Version 1, the rule of `mkgtf-3.0.0`, reads a gene's biotype from its `gene` line, or from its `transcript` lines when
/// its gene line names none. Version 2, the rule of `gencode-2020-A` (SOLO-PLAN-M1-BIO R1), keeps a gene when one of its
/// `transcript` lines has a `gene_type` and a `transcript_type` on the list and its text holds neither
/// `tag "readthrough_transcript"` nor `tag "PAR"`, as 10x's GRCh38-2020-A reference does (`tenx_gtf.py:85-109`). It reads
/// the tags from the line's text, since `parseAttributes` keeps only the first value of a repeated key. It keeps each id
/// as the set names it and leaves out 10x's move of an id's version into `gene_version`, so the index's gene ids stay
/// those of `derived/genes.tsv`. Both versions keep every line of a kept gene, LGE's `exon` lines among them, and never
/// test a line's own `gene_biotype`, which LGE's lines lack, so 10x's own scripts would drop them. Every line on an extra's
/// record passes whatever its biotype. The Mac makes the file from the bytes of `derived/genes.gtf` each time it needs it,
/// so neither the set nor the storage root holds it, and the index plan writes it into its own folder only.
package enum TenxGTFFilter {
    package static let rule = "tenx"

    /// The two biotype lists of `scripts/repro/rnaseq/tenx-controls/tenx_gtf.py:33-47`, named by the 10x reference
    /// generation that used each.
    package enum List: String, CaseIterable, Sendable {
        case mkgtf300 = "mkgtf-3.0.0"
        case gencode2020A = "gencode-2020-A"

        package var biotypes: Set<String> {
            switch self {
            case .mkgtf300:
                return ["protein_coding", "lincRNA", "antisense", "IG_LV_gene", "IG_V_gene", "IG_V_pseudogene", "IG_D_gene",
                        "IG_J_gene", "IG_J_pseudogene", "IG_C_gene", "IG_C_pseudogene", "TR_V_gene", "TR_V_pseudogene",
                        "TR_D_gene", "TR_J_gene", "TR_J_pseudogene", "TR_C_gene"]
            case .gencode2020A:
                return ["protein_coding", "lncRNA", "IG_C_gene", "IG_D_gene", "IG_J_gene", "IG_LV_gene", "IG_V_gene",
                        "IG_V_pseudogene", "IG_J_pseudogene", "IG_C_pseudogene", "TR_C_gene", "TR_D_gene", "TR_J_gene",
                        "TR_V_gene", "TR_V_pseudogene", "TR_J_pseudogene"]
            }
        }

        /// The version of the rule that reads the list, 1 for `mkgtf-3.0.0` and 2 for `gencode-2020-A`. No record of
        /// `gencode-2020-A` under version 1 was ever written, so there is none to refuse (SOLO-PLAN-M1-BIO R1).
        package var ruleVersion: Int { self == .mkgtf300 ? 1 : 2 }

        /// `tenx<rule version>-<list>`, the folder of the made file and the suffix of the index key's folder name.
        package var folderName: String { "\(TenxGTFFilter.rule)\(ruleVersion)-\(rawValue)" }
        /// `made/tenx<rule version>-<list>/genes.gtf`, the path a `reference` entry carries (ARCH-SOLO-GTF item 2).
        package var path: String { "made/\(folderName)/genes.gtf" }
    }

    /// The file the rule made, which the plan pins and the index key names.
    package struct Made: Sendable, Equatable {
        package var list: List
        package var bytes: Data
        package var sha256: String
        package var size: Int64
        /// Each gene id the rule left out, in the order of its first line.
        package var genesLeftOut: [String]
    }

    /// Makes the file from the set's `derived/genes.gtf`. A set that keeps none is refused first, through
    /// ``ReferenceSetManifest/requireCountingGTF()``, and a file whose bytes differ from the SHA-256 the manifest names is
    /// refused, since the made file would then not be the set's.
    package static func make(from setFolder: URL, manifest: ReferenceSetManifest, list: List) throws -> Made {
        let gtf = try manifest.requireCountingGTF()
        let data = try Data(contentsOf: setFolder.appendingPathComponent(gtf.path))
        guard PortableDigest.sha256Hex(of: data) == gtf.sha256 else {
            throw STARIndexError("The set \(manifest.id)'s \(gtf.path) is not the file its reference-set.json names by SHA-256, "
                + "so the 10x filter rule made no GTF from it. Build the set again from the same files.")
        }
        return try filter(data, list: list, extraRecords: manifest.extras.flatMap(\.records),
                          exonsAdded: manifest.derivation.exonsAdded)
    }

    /// The rule on the bytes of a `derived/genes.gtf`. A line that is no feature, such as a comment, passes as it is. The
    /// made file is refused in words when an extra's record, or a kept gene that LGE gave an exon, has no `exon` line,
    /// since STAR would then give it no row of `features.tsv` (BIO-SOLO-GTF item 3).
    package static func filter(_ data: Data, list: List, extraRecords: [String], exonsAdded: [String]) throws -> Made {
        try filter(data, list: list, ruleVersion: list.ruleVersion, extraRecords: extraRecords, exonsAdded: exonsAdded)
    }

    /// The rule of `ruleVersion` with the biotypes of `list`. Only a test or a measurement names a version that is not the
    /// list's own, such as version 1 of `gencode-2020-A`, whose figures BIO's review still compares.
    static func filter(_ data: Data, list: List, ruleVersion: Int, extraRecords: [String], exonsAdded: [String]) throws -> Made {
        let extras = Set(extraRecords)
        let biotypes = list.biotypes
        // A line keeps its byte range and the three fields the second pass reads. The parsed feature, whose attribute
        // dictionary and Substrings hold the line's String, would stay in memory for the whole file.
        var lines: [(range: Range<Data.Index>, feature: (contig: String, gene: String, type: String)?)] = []
        var order: [String] = [], seen = Set<String>()
        var geneBiotype: [String: String] = [:], transcriptBiotypes: [String: Set<String>] = [:]
        var listedTranscript = Set<String>()
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? data.endIndex
            var text = String(decoding: data[start..<end], as: UTF8.self)
            while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
            let feature = ReferenceSetGTFFeature(text)
            lines.append((start..<end, feature.map { (contig: $0.contig, gene: $0.gene, type: $0.type) }))
            start = end
            guard let feature, !extras.contains(feature.contig), !feature.gene.isEmpty else { continue }
            if seen.insert(feature.gene).inserted { order.append(feature.gene) }
            if feature.type == "transcript", let geneType = feature.attributes["gene_type"],
               let transcriptType = feature.attributes["transcript_type"], biotypes.contains(geneType),
               biotypes.contains(transcriptType), !text.contains("tag \"readthrough_transcript\""), !text.contains("tag \"PAR\"") {
                listedTranscript.insert(feature.gene)
            }
            guard let biotype = feature.attributes["gene_biotype"] ?? feature.attributes["gene_type"] else { continue }
            if feature.type == "gene", geneBiotype[feature.gene] == nil { geneBiotype[feature.gene] = biotype }
            if feature.type == "transcript" { transcriptBiotypes[feature.gene, default: []].insert(biotype) }
        }
        let kept = ruleVersion == 1 ? Set(order.filter { gene in
            geneBiotype[gene].map(biotypes.contains) ?? !(transcriptBiotypes[gene] ?? []).isDisjoint(with: biotypes)
        }) : listedTranscript
        // A GTF that names no listed biotype on any host gene keeps none of them, and STAR would index the extras only.
        guard order.isEmpty || !kept.isEmpty else {
            let why = ruleVersion == 1 ? "no gene has a gene_biotype or gene_type on its list"
                : "no transcript line has a gene_type and a transcript_type on its list without the tag readthrough_transcript "
                    + "or PAR, as 10x's GRCh38-2020-A rule asks"
            let annotation = ruleVersion == 1 ? "an annotation that names each gene's biotype"
                : "a GENCODE annotation, whose transcript lines name both"
            throw STARIndexError("The 10x filter rule \(list.rawValue) keeps none of the \(order.count) genes of derived/genes.gtf, "
                + "since \(why), so STAR would index no gene of the set and its matrix would hold none. Index the set without "
                + "--tenx-filter, or build it from \(annotation). No plan or record was written.")
        }
        var output = Data()
        output.reserveCapacity(data.count)
        var exonContigs = Set<String>(), exonGenes = Set<String>()
        for line in lines {
            guard let feature = line.feature else {
                output.append(data[line.range])
                continue
            }
            guard extras.contains(feature.contig) || kept.contains(feature.gene) else { continue }
            output.append(data[line.range])
            if feature.type == "exon" {
                exonContigs.insert(feature.contig)
                exonGenes.insert(feature.gene)
            }
        }
        let records = extraRecords.filter { !exonContigs.contains($0) }
        let genes = exonsAdded.filter { kept.contains($0) && !exonGenes.contains($0) }
        guard records.isEmpty, genes.isEmpty else { throw refusal(list: list, records: records, genes: genes) }
        return Made(list: list, bytes: output, sha256: PortableDigest.sha256Hex(of: output), size: Int64(output.count),
                    genesLeftOut: order.filter { !kept.contains($0) })
    }

    static func refusal(list: List, records: [String], genes: [String]) -> STARIndexError {
        let named = ReferenceSetCountingGTF.named
        let parts = [
            records.isEmpty ? nil : "the extra record\(records.count == 1 ? "" : "s") \(named(records, 3))",
            genes.isEmpty ? nil : "the gene\(genes.count == 1 ? "" : "s") \(named(genes, 3)) that LGE gave an exon",
        ].compactMap { $0 }
        let one = records.count + genes.count == 1
        return STARIndexError("The GTF that the 10x filter rule \(list.rawValue) makes from derived/genes.gtf holds no exon line "
            + "for \(parts.joined(separator: " and for ")), so STAR would give \(one ? "it" : "them") no row of features.tsv and "
            + "count 0. LGE refused the file, and no plan or record was written.")
    }
}
