// ReferenceSetCountingGTF.swift - `derived/genes.gtf`, the GTF that STAR, STARsolo and featureCounts read
// (Phase 5.3 lane RS-COUNTING-GTF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A set keeps one GTF for counting: the GTF gffread read, byte for byte, then each extra's lines in the order given.
// Before the manifest is published, a check ties its exons to `derived/transcripts.fa`, so salmon, STAR and
// featureCounts read the same exons. A set built before LGE kept the file is refused for counting in words, and
// still counts with salmon (BIO-COUNTING-GTF item 2, ARCH-COUNTING-GTF item 1, `docs/formats/reference-set.md`).

import Foundation
import LungfishIO

enum ReferenceSetCountingGTF {
    static let fileName = "genes.gtf"

    /// What follows the host part for one extra.
    enum ExtraPart {
        /// An extra with no annotation: one `exon` line a record, the feature `recordFeatures` gives it.
        case records([ReferenceSetFASTARecord])
        /// An extra with its own annotation (the deposit layout): the GTF LGE wrote from it.
        case gtf(URL)
    }

    /// One `exon` line from 1 to the record's length on `+`, with gene and transcript id the record's name.
    static func recordLine(_ record: ReferenceSetFASTARecord) -> String {
        "\(record.name)\tLGE\texon\t1\t\(record.length)\t.\t+\t.\tgene_id \"\(record.name)\"; transcript_id \"\(record.name)\";\n"
    }

    /// Writes `output` as the bytes of `host` and the exon lines of its CDS-only transcripts, then each extra's part in
    /// the order given, a deposit extra's GTF followed by its own. A record of no bases gets no line, and the check
    /// then names it.
    static func write(host: URL, extras: [ExtraPart], to output: URL) throws {
        try FileManager.default.copyItem(at: host, to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(try cdsExonLines(of: host).joined().utf8))
        for extra in extras {
            switch extra {
            case .records(let records):
                for record in records where record.length > 0 { try handle.write(contentsOf: Data(recordLine(record).utf8)) }
            case .gtf(let url):
                try url.forEachChunkAutoDecompressing { chunk in try handle.write(contentsOf: chunk) }
                try handle.write(contentsOf: Data(try cdsExonLines(of: url).joined().utf8))
            }
        }
        try handle.synchronize()
    }

    /// One `exon` line a merged span of the CDS and stop codon lines of each transcript in `gtf` that has CDS lines
    /// and no exon line, in the order of its first such line. gffread 0.12.9 writes that transcript's record from
    /// those spans, the stop codon joined to the CDS it touches (measured in RS-COUNTING-GTF milestone 2), so its
    /// record and its exons then agree. RefSeq Macaca_fascicularis_5.0 release 101 has 232 such transcripts, the
    /// CDS of V_segment and C_region genes under `unknown_transcript_1`, renamed `<gene>:unknown_transcript_1`.
    static func cdsExonLines(of gtf: URL) throws -> [String] {
        var withExon = Set<String>()
        var order: [String] = []
        var coding: [String: (contig: String, strand: String, gene: String, spans: [ClosedRange<Int>], hasCDS: Bool)] = [:]
        try gtf.forEachLineAutoDecompressing { line in
            guard let feature = ReferenceSetGTFFeature(line), ["exon", "CDS", "stop_codon"].contains(feature.type) else { return }
            let transcript = feature.transcript
            guard !transcript.isEmpty else { return }
            if feature.type == "exon" {
                withExon.insert(transcript)
                return
            }
            guard let start = Int(feature.start), let end = Int(feature.end), start >= 1, start <= end else { return }
            if coding[transcript] == nil {
                order.append(transcript)
                coding[transcript] = (feature.contig, feature.strand, feature.gene, [], false)
            }
            coding[transcript]?.spans.append(start...end)
            if feature.type == "CDS" { coding[transcript]?.hasCDS = true }
        }
        return order.flatMap { transcript -> [String] in
            guard !withExon.contains(transcript), let entry = coding[transcript], entry.hasCDS else { return [] }
            return joined(entry.spans).map { span in
                "\(entry.contig)\tLGE\texon\t\(span.lowerBound)\t\(span.upperBound)\t.\t\(entry.strand)\t.\t"
                    + "gene_id \"\(entry.gene)\"; transcript_id \"\(transcript)\";\n"
            }
        }
    }

    /// `spans` in order of start, with spans that overlap or touch joined into one.
    static func joined(_ spans: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, span.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Refuses `gtf` when the transcript ids of its `exon` lines differ from those of `transcriptTable`, or when a
    /// transcript's merged exon length differs from its record's length in `transcripts`.
    static func check(_ gtf: URL, transcriptTable: URL, transcripts: URL) throws {
        var spans: [String: [ClosedRange<Int>]] = [:]
        var order: [String] = []
        var unreadable: [String] = []
        try gtf.forEachLineAutoDecompressing { line in
            guard let feature = ReferenceSetGTFFeature(line), feature.type == "exon" else { return }
            let transcript = feature.transcript
            if spans[transcript] == nil {
                order.append(transcript)
                spans[transcript] = []
            }
            guard let start = Int(feature.start), let end = Int(feature.end), start >= 1, start <= end else {
                if !unreadable.contains(transcript) { unreadable.append(transcript) }
                return
            }
            spans[transcript]?.append(start...end)
        }
        var table: [String] = []
        var header = true
        try transcriptTable.forEachLineAutoDecompressing { line in
            defer { header = false }
            guard !header, !line.isEmpty else { return }
            table.append(String(line.prefix { $0 != "\t" }))
        }
        let tableSet = Set(table)
        let onlyInGTF = order.filter { !tableSet.contains($0) }
        let onlyInTable = table.filter { spans[$0] == nil }
        var lengths: [String] = []
        for record in try ReferenceSetAnnotationReader.fastaRecords(transcripts) {
            guard let exons = spans[record.name] else { continue }
            let merged = unreadable.contains(record.name) ? 0 : ReferenceSetAnnotationReader.mergedLength(exons)
            if merged != record.length {
                lengths.append("\(record.name) (\(merged) bases of exons in the GTF, \(record.length) in the FASTA)")
            }
        }
        guard onlyInGTF.isEmpty, onlyInTable.isEmpty, lengths.isEmpty else {
            throw ReferenceSetError.countingGTFDiffers(onlyInGTF: onlyInGTF, onlyInTable: onlyInTable, lengths: lengths)
        }
    }

    /// The `derived` entry of a checked `derived/genes.gtf`.
    static func checkedEntry(in derived: URL) throws -> ReferenceSetManifest.DerivedFile {
        let url = derived.appendingPathComponent(fileName)
        try check(url, transcriptTable: derived.appendingPathComponent("transcripts.tsv"),
                  transcripts: derived.appendingPathComponent("transcripts.fa"))
        return .init(path: "derived/\(fileName)", sha256: try ProvenanceFileHasher.sha256(of: url), size: url.fileSizeBytes,
                     tool: "lungfish", version: WorkflowRun.currentAppVersion)
    }

    /// Why the annotation as given would count wrong on a set that keeps no counting GTF, in BIO-COUNTING-GTF
    /// section 3's words: the genes LGE gave an exon, each extra, the renamed transcripts and the features left out.
    static func gaps(of manifest: ReferenceSetManifest) -> [String] {
        var reasons: [String] = []
        let added = manifest.derivation.exonsAdded
        if added.count == 1 {
            reasons.append("LGE gave 1 gene an exon from its CDS and stop codon (\(added[0])), and the set keeps no GTF "
                + "with that exon, so STAR would count 0 for it.")
        } else if added.count > 1 {
            reasons.append("LGE gave \(added.count) genes an exon from their CDS and stop codon (\(named(added, limit: 3))), "
                + "and the set keeps no GTF with those exons, so STAR would count 0 for them.")
        }
        let extras = manifest.extras.map(\.name)
        if extras.count == 1 {
            reasons.append("The set holds the extra \(extras[0]), which has no GTF line.")
        } else if extras.count > 1 {
            reasons.append("The set holds the extras \(named(extras, limit: 3)), which have no GTF line.")
        }
        let renamed = manifest.derivation.renamedTranscripts.count
        if renamed > 0 { reasons.append("LGE renamed \(renamed) transcript\(renamed == 1 ? "" : "s").") }
        let dropped = manifest.derivation.droppedFeatures.count
        if dropped > 0 { reasons.append("LGE left out \(dropped) feature\(dropped == 1 ? "" : "s") with no gene_id.") }
        return reasons
    }

    /// Up to `limit` names, `A`, `A and B`, `A, B and C`, or `A, B, C and 10 more`.
    static func named(_ names: [String], limit: Int) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        guard names.count > limit else { return names.dropLast().joined(separator: ", ") + " and " + names.last! }
        return names.prefix(limit).joined(separator: ", ") + " and \(names.count - limit) more"
    }
}

extension ReferenceSetManifest {
    /// The entry of `derived/genes.gtf`, the only GTF that a STAR, STARsolo or featureCounts plan may pin. A set built
    /// before LGE kept that file is refused in words that name the rebuild and, first, each reason the annotation as
    /// given would count wrong. Every such plan calls this, and the set still counts with salmon.
    public func requireCountingGTF() throws -> DerivedFile {
        if let entry = derived.countingGTF { return entry }
        throw ReferenceSetError.builtBeforeCountingGTF(id: id, reasons: ReferenceSetCountingGTF.gaps(of: self))
    }
}
