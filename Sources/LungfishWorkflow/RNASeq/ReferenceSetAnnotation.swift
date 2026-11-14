// ReferenceSetAnnotation.swift - Reading a set's GTF and FASTA files and deriving its tables (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

struct ReferenceSetGeneRow: Equatable {
    var id: String
    var name: String
    var biotype: String
    var contig: String
    var length: Int
    var notHost: Bool
}

struct ReferenceSetAnnotationRead {
    var genes: [ReferenceSetGeneRow] = []
    /// One pair a record gffread writes from the GTF LGE writes, keyed on the id that GTF gives the transcript.
    var transcriptGenes: [(transcript: String, gene: String)] = []
    /// Every sequence name a feature line gives, in the order first seen.
    var sequenceNames: [String] = []
    var exonsAdded: [String] = []
    var keptWithoutExon: [String] = []
    var dropped: [String] = []
    var renamed: [ReferenceSetManifest.RenamedTranscript] = []
    /// Each gene with no exon line and no CDS line as `<gene_id>\t<contig>\t<biotype>`, in the order of its first line.
    var withoutFeatures: [String] = []
}

struct ReferenceSetFASTARecord: Equatable {
    var name: String
    var length: Int
    var header: String
}

enum ReferenceSetAnnotationReader {
    final class Gene {
        let contig: String
        let firstLine: Int
        var name: String?
        var biotype: String?
        var firstExon: Int?
        var firstCDS: Int?
        var exons: [ClosedRange<Int>] = []
        /// The CDS and stop codon span of each transcript, with its contig and strand.
        var coding: [String: (span: ClosedRange<Int>, contig: String, strand: String)] = [:]
        /// The transcripts with a CDS line, in order, which LGE's layout gives one exon each.
        var codingOrder: [String] = []
        init(contig: String, firstLine: Int) {
            self.contig = contig
            self.firstLine = firstLine
        }
    }

    /// What the first pass over a GTF found.
    struct Scan {
        var genes: [String: Gene] = [:]
        /// Each transcript id with the distinct genes, contigs and strands its lines name.
        var owners: [String: [(gene: String, place: String)]] = [:]
        var transcriptOrder: [String] = []
        /// Each transcript and gene of a transcript, exon or CDS line, in order, as gffread writes records.
        var pairs: [(transcript: String, gene: String)] = []
    }

    /// Reads a GTF, plain or gzip, and writes to `gtf` the one GTF that gffread reads (`docs/formats/reference-set.md`).
    /// With `addExon` (LGE's layout) a gene with a CDS and no exon gets one exon a transcript from its CDS and stop
    /// codon span. Without it (the deposit layout) the gene keeps no exon, counts 0 and gives gffread no line.
    static func read(_ url: URL, addExon: Bool, notHost: Bool, writingGTFTo gtf: URL) throws -> ReferenceSetAnnotationRead {
        var read = ReferenceSetAnnotationRead()
        let scan = try scanGTF(url, into: &read)
        let ordered = scan.genes.compactMap { id, gene in (gene.firstExon ?? gene.firstCDS).map { ($0, id, gene) } }
            .sorted { $0.0 < $1.0 }
        var leftOut = Set<String>()
        for (id, gene) in scan.genes.filter({ $0.value.firstExon == nil && $0.value.firstCDS == nil })
            .sorted(by: { $0.value.firstLine < $1.value.firstLine }) {
            leftOut.insert(id)
            read.withoutFeatures.append("\(id)\t\(gene.contig)\t\(gene.biotype ?? "")")
        }
        for (_, id, gene) in ordered {
            var spans = gene.exons
            if spans.isEmpty {
                if addExon {
                    spans = gene.codingOrder.compactMap { gene.coding[$0]?.span }
                    read.exonsAdded.append(id)
                } else {
                    read.keptWithoutExon.append(id)
                    leftOut.insert(id)
                }
            }
            read.genes.append(ReferenceSetGeneRow(
                id: id, name: gene.name ?? id, biotype: gene.biotype ?? "", contig: gene.contig,
                length: mergedLength(spans), notHost: notHost))
        }
        var shared = Set<String>()
        for transcript in scan.transcriptOrder {
            let owners = (scan.owners[transcript] ?? []).filter { !leftOut.contains($0.gene) }
            guard owners.count > 1 else { continue }
            shared.insert(transcript)
            var named = Set<String>()
            for owner in owners where named.insert(owner.gene).inserted {
                read.renamed.append(.init(transcript: transcript, gene: owner.gene, renamed: "\(owner.gene):\(transcript)"))
            }
        }
        let rename = { (transcript: String, gene: String) in shared.contains(transcript) ? "\(gene):\(transcript)" : transcript }
        read.transcriptGenes = scan.pairs.filter { !leftOut.contains($0.gene) }
            .map { (transcript: rename($0.transcript, $0.gene), gene: $0.gene) }
        let added: [(id: String, gene: Gene)] = addExon ? ordered.filter { $0.2.exons.isEmpty }.map { (id: $0.1, gene: $0.2) } : []
        try writeGTF(from: url, to: gtf, leaving: leftOut, keepingGeneLines: Set(read.keptWithoutExon), rename: rename, addedExons: added)
        return read
    }

    /// One feature a record, named by the record (an extra in LGE's layout).
    static func recordFeatures(_ records: [ReferenceSetFASTARecord], biotype: String) -> ReferenceSetAnnotationRead {
        var read = ReferenceSetAnnotationRead()
        for record in records {
            read.genes.append(ReferenceSetGeneRow(
                id: record.name, name: record.name, biotype: biotype, contig: record.name, length: record.length, notHost: true))
            read.transcriptGenes.append((record.name, record.name))
            read.sequenceNames.append(record.name)
        }
        return read
    }

    /// The `key "value"` pairs of a GTF attribute column. A quoted value may hold a `;`.
    static func parseAttributes(_ column: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var index = column.startIndex
        while index < column.endIndex {
            while index < column.endIndex, column[index] == " " || column[index] == ";" { index = column.index(after: index) }
            guard let space = column[index...].firstIndex(of: " ") else { break }
            let key = String(column[index..<space])
            var cursor = column.index(after: space)
            var value = ""
            if cursor < column.endIndex, column[cursor] == "\"" {
                let open = column.index(after: cursor)
                let close = column[open...].firstIndex(of: "\"") ?? column.endIndex
                value = String(column[open..<close])
                cursor = close < column.endIndex ? column.index(after: close) : close
            } else {
                let stop = column[cursor...].firstIndex(of: ";") ?? column.endIndex
                value = String(column[cursor..<stop])
                cursor = stop
            }
            if result[key] == nil { result[key] = value }
            index = column[cursor...].firstIndex(of: ";") ?? column.endIndex
        }
        return result
    }

    /// The bases the spans cover, each base once.
    static func mergedLength(_ spans: [ClosedRange<Int>]) -> Int {
        var total = 0
        var current: ClosedRange<Int>?
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let open = current, span.lowerBound <= open.upperBound + 1 {
                current = open.lowerBound...max(open.upperBound, span.upperBound)
            } else {
                if let open = current { total += open.count }
                current = span
            }
        }
        return total + (current?.count ?? 0)
    }

    /// The records of a FASTA, plain or gzip, with each name the first word of its header.
    static func fastaRecords(_ url: URL) throws -> [ReferenceSetFASTARecord] {
        var records: [ReferenceSetFASTARecord] = []
        try url.forEachLineAutoDecompressing { line in
            if line.hasPrefix(">") {
                let header = String(line.dropFirst())
                let name = header.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                records.append(ReferenceSetFASTARecord(name: name, length: 0, header: header))
            } else if !records.isEmpty {
                records[records.count - 1].length += line.trimmingCharacters(in: .whitespacesAndNewlines).count
            }
        }
        return records
    }

    /// The mitochondrial contigs: the ones named, else the assembly report's Mitochondrion, else a header that says
    /// mitochondrion, else a contig of a mitochondrial name. Never a gene name prefix (`refcheck.py:225`).
    static func mitochondrialContigs(
        named: [String], report: URL?, genome: [ReferenceSetFASTARecord], annotationNames: [String]
    ) throws -> [String] {
        let known = Set(genome.map(\.name)).union(annotationNames)
        if !named.isEmpty {
            let absent = named.filter { !known.contains($0) }
            guard absent.isEmpty else {
                throw ReferenceSetError.invalidRequest(
                    "--mitochondrial-contig names \(ReferenceSetError.listed(absent)), which neither the genome nor the annotation holds.")
            }
            return named
        }
        if let report {
            var hits: [String] = []
            try report.forEachLineAutoDecompressing { line in
                let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard !line.hasPrefix("#"), cells.count > 6, cells[3] == "Mitochondrion" else { return }
                for index in [6, 4, 0, 9] where index < cells.count && cells[index] != "na" && known.contains(cells[index]) {
                    if !hits.contains(cells[index]) { hits.append(cells[index]) }
                }
            }
            if !hits.isEmpty { return hits }
        }
        let headers = genome.filter { $0.header.lowercased().contains("mitochondrion") }.map(\.name)
        if !headers.isEmpty { return headers }
        return ["MT", "chrM", "chrMT", "M", "Mt"].filter(known.contains)
    }
}
